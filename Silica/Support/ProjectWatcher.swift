import CoreServices
import Foundation

/// Reports changes anywhere under a project folder (FSEvents), batched over a
/// short delay so a `git checkout` or a build arrives as one callback.
final class ProjectWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: () -> Void
    private let onGitChange: () -> Void
    private let gitDirectoryPaths: [String]

    /// Both callbacks run on the main queue.
    init(url: URL, onChange: @escaping () -> Void, onGitChange: @escaping () -> Void = {}) {
        self.onChange = onChange
        self.onGitChange = onGitChange
        gitDirectoryPaths = Self.gitDirectories(for: url).map(\.path)
        let watchedPaths = Self.watchedPaths(root: url, gitDirectoryPaths: gitDirectoryPaths)

        var context = FSEventStreamContext(
            version: 0,
            // Released in `stop()`, so the stream never outlives its watcher.
            info: Unmanaged.passRetained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = (unsafeBitCast(paths, to: NSArray.self) as? [String]) ?? []
            MainActor.assumeIsolated { watcher.handle(changed) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        ) else {
            Unmanaged.passUnretained(self).release()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Unmanaged.passUnretained(self).release()
    }

    private func handle(_ paths: [String]) {
        let gitChanged = paths.contains(where: isGitPath)
        let workingTreeChanged = paths.contains { !isGitPath($0) }
        if workingTreeChanged { onChange() }
        if gitChanged { onGitChange() }
    }

    private func isGitPath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if gitDirectoryPaths.contains(where: { Self.contains(normalized, in: $0) }) { return true }
        return URL(fileURLWithPath: normalized).pathComponents.contains(".git")
    }

    private static func watchedPaths(root: URL, gitDirectoryPaths: [String]) -> [String] {
        let rootPath = root.standardizedFileURL.path
        // The root stream recursively covers Git metadata inside the project; add external gitdirs separately.
        let metadataPaths = Array(Set(gitDirectoryPaths.filter { !contains($0, in: rootPath) }))
        let minimalMetadataPaths = metadataPaths.filter { path in
            !metadataPaths.contains { $0 != path && contains(path, in: $0) }
        }
        return [rootPath] + minimalMetadataPaths
    }

    private static func gitDirectories(for url: URL) -> [URL] {
        var directory = url.standardizedFileURL
        while true {
            let marker = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                let gitDirectory: URL
                if isDirectory.boolValue {
                    gitDirectory = marker
                } else if let contents = try? String(contentsOf: marker, encoding: .utf8) {
                    let markerContents = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                    let prefix = "gitdir: "
                    guard markerContents.hasPrefix(prefix) else { return [] }
                    gitDirectory = URL(
                        fileURLWithPath: String(markerContents.dropFirst(prefix.count)),
                        relativeTo: directory
                    ).standardizedFileURL
                } else {
                    return []
                }
                var paths = [gitDirectory]
                let commonDirectoryFile = gitDirectory.appendingPathComponent("commondir")
                if let commonPath = try? String(contentsOf: commonDirectoryFile, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !commonPath.isEmpty {
                    paths.append(URL(fileURLWithPath: commonPath, relativeTo: gitDirectory).standardizedFileURL)
                }
                return paths
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return [] }
            directory = parent
        }
    }

    private static func contains(_ path: String, in directory: String) -> Bool {
        path == directory || path.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }
}
