import Foundation

struct GitFileDiff: Identifiable, Sendable {
    let id = UUID()
    let fileName: String
    let patch: String
    let isNewFile: Bool
}

enum GitFileStatus: Equatable, Sendable {
    case modified
    case added
    case untracked

    var marker: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .modified: "Modified"
        case .added: "Added"
        case .untracked: "Untracked"
        }
    }
}

struct GitStatusSnapshot: Sendable {
    let files: [String: GitFileStatus]
    let changedDirectories: Set<String>

    nonisolated static let empty = GitStatusSnapshot(files: [:])

    nonisolated init(files: [String: GitFileStatus]) {
        self.files = files
        var directories = Set<String>()
        for path in files.keys {
            let components = path.split(separator: "/").dropLast()
            var directory: [Substring] = []
            for component in components {
                directory.append(component)
                directories.insert(directory.joined(separator: "/"))
            }
        }
        changedDirectories = directories
    }

    func status(for path: String) -> GitFileStatus? { files[path] }

    func hasChanges(in path: String) -> Bool {
        files[path] != nil || changedDirectories.contains(path)
    }
}

/// The patch as it shows in the side-by-side diff pane, with the map that links
/// its lines to the file's own lines. The file-level header (`diff --git`, `---`,
/// `+++`, including `/dev/null` labels) is left out of `text`; `@@` hunk headers
/// and the context and changed lines stay, so every displayed line is hunk
/// furniture or a line of the file.
struct GitDiffDisplay {
    let text: String
    /// Each displayed line's line in the current file; `nil` for hunk headers,
    /// removed (`-`) lines and `\ No newline` markers. Index 0 is display line 1.
    private let sourceOfLine: [Int?]
    /// The reverse lookup, for following the source pane into the patch.
    private let displayOfSource: [Int: Int]
    /// Each hunk's reach into the file's lines and the displayed lines, for
    /// positions outside any hunk.
    private let hunks: [Hunk]

    private struct Hunk {
        let headerLine: Int
        let firstSource: Int
        /// The last file line the hunk shows; one below `firstSource` when it only
        /// removes lines.
        let lastSource: Int
        let lastContentLine: Int
    }

    init(patch: String) {
        var textLines: [String] = []
        var sourceOfLine: [Int?] = []
        var displayOfSource: [Int: Int] = [:]
        var hunks: [Hunk] = []
        var newLine = 0
        var lastDisplayLine = 0
        var openHunk: (header: Int, firstSource: Int)?

        var contentLines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        // The trailing newline (git writes one) and any blank lines after the last
        // hunk show as nothing.
        while contentLines.last?.isEmpty == true { contentLines.removeLast() }

        func endHunk() {
            guard let hunk = openHunk else { return }
            hunks.append(Hunk(
                headerLine: hunk.header,
                firstSource: hunk.firstSource,
                lastSource: newLine - 1,
                lastContentLine: lastDisplayLine
            ))
            openHunk = nil
        }

        for line in contentLines {
            let text = String(line)
            if text.hasPrefix("@@") {
                endHunk()
                lastDisplayLine += 1
                textLines.append(text)
                sourceOfLine.append(nil)
                let start = Self.newFileStart(of: text) ?? newLine + 1
                openHunk = (header: lastDisplayLine, firstSource: start)
                newLine = start
                continue
            }
            // Before the first `@@` sits the file-level header; none of it shows.
            guard openHunk != nil else { continue }
            lastDisplayLine += 1
            textLines.append(text)
            let first = text.first
            if first == "+" || first == " " || text.isEmpty {
                // Added and context lines are lines of the current file.
                displayOfSource[newLine] = lastDisplayLine
                sourceOfLine.append(newLine)
                newLine += 1
            } else {
                // Removed (`-`) lines and `\ No newline` markers show without a line
                // of their own in the file.
                sourceOfLine.append(nil)
            }
        }
        endHunk()

        text = textLines.joined(separator: "\n")
        self.sourceOfLine = sourceOfLine
        self.displayOfSource = displayOfSource
        self.hunks = hunks
    }

    /// The displayed line to bring to the top of the diff pane when `line` is at
    /// the top of the source: that very line inside a hunk, else the nearest
    /// hunk — its `@@` header at or before it, its last shown line after it.
    func displayedLine(forSourceLine line: Int) -> Int {
        if let mapped = displayOfSource[line] { return mapped }
        guard let nearest = nearestHunk(toSourceLine: line) else { return 1 }
        if line <= nearest.firstSource { return nearest.headerLine }
        return max(nearest.lastContentLine, nearest.headerLine)
    }

    /// The file line to bring to the top of the source when `line` is at the top
    /// of the diff pane: the shown line itself, else the nearest shown one after
    /// it — a removed line sits in the source where the following line now is —
    /// or before it at the patch's tail.
    func sourceLine(forDisplayedLine line: Int) -> Int {
        guard !sourceOfLine.isEmpty else { return 1 }
        let index = min(max(line, 1), sourceOfLine.count) - 1
        if let mapped = sourceOfLine[index] { return mapped }
        if let after = sourceOfLine[index...].compactMap({ $0 }).first { return after }
        if let before = sourceOfLine[..<index].compactMap({ $0 }).last { return before }
        return 1
    }

    private func nearestHunk(toSourceLine line: Int) -> Hunk? {
        var nearest: Hunk?
        var nearestDistance = Int.max
        for hunk in hunks {
            let distance: Int
            if line < hunk.firstSource {
                distance = hunk.firstSource - line
            } else if line > hunk.lastSource {
                distance = line - hunk.lastSource
            } else {
                distance = 0
            }
            if distance < nearestDistance {
                nearestDistance = distance
                nearest = hunk
            }
        }
        return nearest
    }

    /// The new-file start line of an `@@ -old[,count] +new[,count] @@` header.
    private static func newFileStart(of header: String) -> Int? {
        let fields = header.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count > 2, fields[2].hasPrefix("+") else { return nil }
        return Int(fields[2].dropFirst().prefix(while: \.isNumber))
    }
}

enum GitDiffService {
    private struct Snapshot: Sendable {
        let relativePath: String
        let baseline: String
        let hasHeadBlob: Bool
        let shouldShow: Bool
    }

    private struct CommandResult {
        let status: Int32
        let output: Data
        let error: Data
    }

    nonisolated private static let gitPath = "/usr/bin/git"
    nonisolated private static let diffPath = "/usr/bin/diff"

    nonisolated static func status(rootURL: URL) async -> GitStatusSnapshot {
        await Task.detached(priority: .utility) {
            (try? readStatus(rootURL: rootURL)) ?? .empty
        }.value
    }

    nonisolated private static func readStatus(rootURL: URL) throws -> GitStatusSnapshot {
        guard FileManager.default.isExecutableFile(atPath: gitPath) else { return .empty }
        let workspace = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let rootResult = try run(
            executable: gitPath,
            arguments: ["-C", workspace.path, "rev-parse", "--show-toplevel"]
        )
        guard rootResult.status == 0,
              let rootString = String(data: rootResult.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rootString.isEmpty else { return .empty }

        let repositoryRoot = URL(fileURLWithPath: rootString, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let repositoryComponents = repositoryRoot.pathComponents
        let workspaceComponents = workspace.pathComponents
        guard workspaceComponents.starts(with: repositoryComponents) else { return .empty }
        let workspacePath = workspaceComponents.dropFirst(repositoryComponents.count).joined(separator: "/")
        let pathspec = workspacePath.isEmpty ? "." : ":(literal)\(workspacePath)"
        let result = try run(
            executable: gitPath,
            arguments: [
                "-C", repositoryRoot.path, "status", "--porcelain=v1", "-z",
                "--untracked-files=all", "--", pathspec
            ]
        )
        guard result.status == 0 else { throw commandError("status", result) }

        var files: [String: GitFileStatus] = [:]
        let records = result.output.split(separator: 0, omittingEmptySubsequences: true)
        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            let bytes = Array(record)
            guard bytes.count >= 3, bytes[2] == 0x20,
                  let path = String(bytes: bytes.dropFirst(3), encoding: .utf8) else { continue }
            let relativePath: String
            if workspacePath.isEmpty {
                relativePath = path
            } else {
                let prefix = workspacePath + "/"
                guard path.hasPrefix(prefix) else { continue }
                relativePath = String(path.dropFirst(prefix.count))
            }
            guard !relativePath.isEmpty else { continue }

            let code = String(decoding: bytes.prefix(2), as: UTF8.self)
            let status: GitFileStatus?
            if code == "??" {
                status = .untracked
            } else if code.contains("A") {
                status = .added
            } else if code.contains(where: { $0 != " " }) {
                status = .modified
            } else {
                status = nil
            }
            if let status { files[relativePath] = status }

            // In `-z` output, rename/copy records carry old path in next NUL field.
            if code.contains("R") || code.contains("C") { index += 1 }
        }
        return GitStatusSnapshot(files: files)
    }

    static func hasDiff(fileURL: URL, currentText: String, encoding: String.Encoding) async -> Bool {
        await Task.detached(priority: .utility) {
            guard let snapshot = try? snapshot(
                fileURL: fileURL,
                currentText: currentText,
                encoding: encoding.rawValue
            ) else { return false }
            return snapshot.shouldShow && (!snapshot.hasHeadBlob || snapshot.baseline != currentText)
        }.value
    }

    static func diff(fileURL: URL, currentText: String, encoding: String.Encoding) async throws -> GitFileDiff? {
        try await Task.detached(priority: .userInitiated) {
            guard let snapshot = try snapshot(
                fileURL: fileURL,
                currentText: currentText,
                encoding: encoding.rawValue
            ) else { return nil }
            guard snapshot.shouldShow else { return nil }
            if snapshot.hasHeadBlob && snapshot.baseline == currentText { return nil }

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("silica-git-diff-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

            let oldFile = temporaryDirectory.appendingPathComponent("head")
            let newFile = temporaryDirectory.appendingPathComponent("current")
            try Data(snapshot.baseline.utf8).write(to: oldFile)
            try Data(currentText.utf8).write(to: newFile)

            let oldLabel = snapshot.hasHeadBlob ? patchPath("a", snapshot.relativePath) : "/dev/null"
            let newLabel = patchPath("b", snapshot.relativePath)
            let result = try run(
                executable: diffPath,
                arguments: ["-u", "-L", oldLabel, "-L", newLabel, oldFile.path, newFile.path]
            )
            guard result.status == 0 || result.status == 1 else {
                throw commandError("diff", result)
            }

            let isNewFile = !snapshot.hasHeadBlob
            let gitHeader = "diff --git \(patchPath("a", snapshot.relativePath)) \(patchPath("b", snapshot.relativePath))\n"
            let hunk = String(decoding: result.output, as: UTF8.self)
            let patch = gitHeader + hunk
            return GitFileDiff(fileName: URL(fileURLWithPath: snapshot.relativePath).lastPathComponent, patch: patch, isNewFile: isNewFile)
        }.value
    }

    nonisolated private static func snapshot(fileURL: URL, currentText: String, encoding: UInt) throws -> Snapshot? {
        guard fileURL.isFileURL, FileManager.default.isExecutableFile(atPath: gitPath) else { return nil }
        let parent = fileURL.deletingLastPathComponent()
        let rootResult = try run(executable: gitPath, arguments: ["-C", parent.path, "rev-parse", "--show-toplevel"])
        guard rootResult.status == 0,
              let rootString = String(data: rootResult.output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rootString.isEmpty else { return nil }

        let root = URL(fileURLWithPath: rootString, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        let file = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = root.pathComponents
        let fileComponents = file.pathComponents
        guard fileComponents.count > rootComponents.count,
              Array(fileComponents.prefix(rootComponents.count)) == rootComponents else { return nil }
        let relativePath = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")

        let revisionPath = "HEAD:\(relativePath)"
        let headProbe = try run(executable: gitPath, arguments: ["-C", rootPath, "cat-file", "-e", revisionPath])
        let hasHeadBlob = headProbe.status == 0
        let baseline: String
        if hasHeadBlob {
            let blob = try run(executable: gitPath, arguments: ["-C", rootPath, "show", revisionPath])
            guard blob.status == 0,
                  let decoded = String(data: blob.output, encoding: String.Encoding(rawValue: encoding)) else {
                throw commandError("show HEAD:\(relativePath)", blob)
            }
            baseline = decoded
        } else {
            baseline = ""
        }

        if hasHeadBlob {
            return Snapshot(relativePath: relativePath, baseline: baseline, hasHeadBlob: true, shouldShow: true)
        }

        let trackedInIndex = try run(
            executable: gitPath,
            arguments: ["-C", rootPath, "ls-files", "--error-unmatch", "--", ":(literal)\(relativePath)"]
        ).status == 0
        let ignored = try run(
            executable: gitPath,
            arguments: ["-C", rootPath, "check-ignore", "-q", "--stdin", "-z"],
            input: Data(relativePath.utf8) + Data([0])
        ).status == 0
        let shouldShow = hasHeadBlob || trackedInIndex || !ignored
        return Snapshot(relativePath: relativePath, baseline: baseline, hasHeadBlob: hasHeadBlob, shouldShow: shouldShow)
    }

    nonisolated private static func patchPath(_ prefix: String, _ path: String) -> String {
        let fullPath = "\(prefix)/\(path)"
        let scalars = fullPath.unicodeScalars
        let needsQuotes = scalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0.value == 0x22 || $0.value == 0x5c }
        guard needsQuotes else { return fullPath }
        let escaped = scalars.map { scalar -> String in
            switch scalar.value {
            case 0x09: "\\t"
            case 0x0a: "\\n"
            case 0x0d: "\\r"
            case 0x22: "\\\""
            case 0x5c: "\\\\"
            case 0..<0x20, 0x7f: String(format: "\\%03o", scalar.value)
            default: String(scalar)
            }
        }.joined()
        return "\"\(escaped)\""
    }

    nonisolated private static func run(
        executable: String,
        arguments: [String],
        input: Data? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let output = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        if inputPipe == nil {
            process.standardOutput = output
            process.standardError = output
        } else {
            // `check-ignore -q` emits no output; discard both streams so writing stdin
            // cannot block behind an undrained child pipe.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        try process.run()
        if let input, let inputPipe {
            try inputPipe.fileHandleForWriting.write(contentsOf: input)
            try inputPipe.fileHandleForWriting.close()
        }
        let outputData = inputPipe == nil ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        let errorData = process.terminationStatus == 0 ? Data() : outputData
        return CommandResult(status: process.terminationStatus, output: outputData, error: errorData)
    }

    nonisolated private static func commandError(_ command: String, _ result: CommandResult) -> NSError {
        let message = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return NSError(
            domain: "GitDiffService",
            code: Int(result.status),
            userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "\(command) failed (\(result.status))." : message]
        )
    }
}
