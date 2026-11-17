import AppKit
import Foundation

#if DEBUG
@MainActor
enum GitDiffSelfTest {
    static func run() {
        Task {
            let exitCode = await performTest()
            fflush(stdout)
            exit(exitCode)
        }
    }

    private static func performTest() async -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("silica git diff selftest \(UUID().uuidString)", isDirectory: true)
        let repository = root.appendingPathComponent("repo with spaces", isDirectory: true)
        let trackedFile = repository.appendingPathComponent("tracked file.md")
        let ignoredFile = repository.appendingPathComponent("ignored.txt")
        let untrackedFile = repository.appendingPathComponent("new file.swift")
        let stagedAddedFile = repository.appendingPathComponent("staged added.swift")
        let nestedDirectory = repository.appendingPathComponent("nested folder", isDirectory: true)
        let nestedFile = nestedDirectory.appendingPathComponent("nested file.swift")
        let emptyFile = repository.appendingPathComponent("empty new file.txt")
        let newlineFile = repository.appendingPathComponent("line\nbreak.txt")
        let unbornRepository = root.appendingPathComponent("unborn repo", isDirectory: true)
        let unbornFile = unbornRepository.appendingPathComponent("initial.txt")
        let outsideFile = root.appendingPathComponent("outside.txt")
        var watcher: ProjectWatcher?
        defer {
            watcher?.stop()
            try? FileManager.default.removeItem(at: root)
        }

        do {
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outsideFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try runGit(at: repository, ["init", "-q"])
            try runGit(at: repository, ["config", "user.name", "Silica Test"])
            try runGit(at: repository, ["config", "user.email", "silica-test@example.invalid"])
            try Data("ignored.txt\n".utf8).write(to: repository.appendingPathComponent(".gitignore"))
            try Data("before\n".utf8).write(to: trackedFile)
            try runGit(at: repository, ["add", ".gitignore", trackedFile.lastPathComponent])
            try runGit(at: repository, ["commit", "-q", "-m", "base"])

            let linkedWorktree = root.appendingPathComponent("linked worktree", isDirectory: true)
            try runGit(at: repository, ["worktree", "add", "-q", "--detach", linkedWorktree.path, "HEAD"])
            var gitMetadataChanges = 0
            var workingTreeChanges = 0
            watcher = ProjectWatcher(url: linkedWorktree, onChange: {
                workingTreeChanges += 1
            }, onGitChange: {
                gitMetadataChanges += 1
            })
            try runGit(at: repository, ["update-ref", "refs/heads/silica-diff-selftest", "HEAD"])
            try await Task.sleep(for: .milliseconds(900))
            guard gitMetadataChanges > 0, workingTreeChanges == 0 else {
                return fail("Git metadata watcher missed shared worktree refs or refreshed the file tree")
            }
            watcher?.stop()
            gitMetadataChanges = 0
            workingTreeChanges = 0
            watcher = ProjectWatcher(url: repository, onChange: {
                workingTreeChanges += 1
            }, onGitChange: {
                gitMetadataChanges += 1
            })
            try runGit(at: repository, ["update-ref", "refs/heads/silica-diff-root-selftest", "HEAD"])
            try await Task.sleep(for: .milliseconds(900))
            guard gitMetadataChanges > 0, workingTreeChanges == 0 else {
                return fail("Git metadata inside watched root refreshed the file tree or was missed")
            }

            guard !(await GitDiffService.hasDiff(fileURL: trackedFile, currentText: "before\n", encoding: .utf8)) else {
                return fail("unchanged HEAD file reported a diff")
            }
            guard (await GitDiffService.status(rootURL: repository)).files.isEmpty else {
                return fail("clean repository reported Git status markers")
            }

            try Data("before\nstaged\n".utf8).write(to: trackedFile)
            try runGit(at: repository, ["add", trackedFile.lastPathComponent])
            try Data("before\nstaged\nunstaged\n".utf8).write(to: trackedFile)
            let currentText = "before\nstaged\nunstaged\nunsaved\n"
            guard await GitDiffService.hasDiff(fileURL: trackedFile, currentText: currentText, encoding: .utf8),
                  let trackedDiff = try await GitDiffService.diff(fileURL: trackedFile, currentText: currentText, encoding: .utf8),
                  trackedDiff.patch.contains("--- a/tracked file.md"),
                  trackedDiff.patch.contains("+++ b/tracked file.md"),
                  trackedDiff.patch.contains("+staged"),
                  trackedDiff.patch.contains("+unstaged"),
                  trackedDiff.patch.contains("+unsaved") else {
                return fail("HEAD diff omitted staged, unstaged, or unsaved edits, or did not label spaced path")
            }

            try Data("added\n".utf8).write(to: untrackedFile)
            try Data("staged addition\n".utf8).write(to: stagedAddedFile)
            try runGit(at: repository, ["add", stagedAddedFile.lastPathComponent])
            try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
            try Data("nested addition\n".utf8).write(to: nestedFile)
            try Data("newline path\n".utf8).write(to: newlineFile)
            let statusSnapshot = await GitDiffService.status(rootURL: repository)
            guard statusSnapshot.status(for: trackedFile.lastPathComponent) == .modified,
                  statusSnapshot.status(for: untrackedFile.lastPathComponent) == .untracked,
                  statusSnapshot.status(for: stagedAddedFile.lastPathComponent) == .added,
                  statusSnapshot.status(for: newlineFile.lastPathComponent) == .untracked,
                  statusSnapshot.status(for: "nested folder/nested file.swift") == .untracked,
                  statusSnapshot.hasChanges(in: "nested folder"),
                  !statusSnapshot.hasChanges(in: "clean folder") else {
                return fail("Git status did not map staged, modified, untracked, newline, or folder changes")
            }
            let nestedStatus = await GitDiffService.status(rootURL: nestedDirectory)
            guard nestedStatus.status(for: "nested file.swift") == .untracked,
                  nestedStatus.status(for: trackedFile.lastPathComponent) == nil else {
                return fail("nested workspace status was not scoped and rebased to its root")
            }

            guard await GitDiffService.hasDiff(fileURL: untrackedFile, currentText: "added\n", encoding: .utf8),
                  let newDiff = try await GitDiffService.diff(fileURL: untrackedFile, currentText: "added\n", encoding: .utf8),
                  newDiff.isNewFile,
                  newDiff.patch.contains("diff --git a/new file.swift b/new file.swift"),
                  newDiff.patch.contains("+added") else {
                return fail("untracked file was not shown as an addition")
            }

            guard FileManager.default.createFile(atPath: emptyFile.path, contents: Data()) else {
                return fail("could not create empty untracked file")
            }
            guard await GitDiffService.hasDiff(fileURL: emptyFile, currentText: "", encoding: .utf8),
                  let emptyDiff = try await GitDiffService.diff(fileURL: emptyFile, currentText: "", encoding: .utf8),
                  emptyDiff.isNewFile else {
                return fail("empty untracked file was not shown")
            }

            guard let newlineDiff = try await GitDiffService.diff(fileURL: newlineFile, currentText: "newline path\n", encoding: .utf8),
                  newlineDiff.patch.contains(#"diff --git "a/line\nbreak.txt" "b/line\nbreak.txt""#),
                  newlineDiff.patch.contains(#"+++ "b/line\nbreak.txt""#) else {
                return fail("newline path was not escaped in patch headers")
            }

            // The displayed patch: the file-level header lines (`diff --git`, `---`,
            // `+++`, `/dev/null` included) are stripped while `@@` hunks and their
            // lines stay, and the display line ↔ file line map lands exactly inside
            // hunks and on the nearest hunk outside them.
            let newFileDisplay = GitDiffDisplay(patch: newDiff.patch)
            guard newFileDisplay.text.hasPrefix("@@"),
                  !newFileDisplay.text.contains("diff --git"),
                  !newFileDisplay.text.contains("/dev/null"),
                  !newFileDisplay.text.contains("+++ b/new file.swift"),
                  newFileDisplay.text.contains("+added"),
                  newFileDisplay.displayedLine(forSourceLine: 1) == 2 else {
                return fail("displayed patch kept file headers or lost the hunk")
            }

            let samplePatch = """
                diff --git a/sample.txt b/sample.txt
                --- a/sample.txt
                +++ b/sample.txt
                @@ -1,3 +1,4 @@
                 one
                -two
                +TWO
                +extra
                 three
                @@ -10 +10,2 @@
                 ten
                +eleven
                """
            let sample = GitDiffDisplay(patch: samplePatch)
            guard sample.text.contains("@@ -1,3 +1,4 @@"),
                  !sample.text.contains("--- a/sample.txt"),
                  sample.displayedLine(forSourceLine: 1) == 2,
                  sample.displayedLine(forSourceLine: 2) == 4,
                  sample.displayedLine(forSourceLine: 3) == 5,
                  sample.displayedLine(forSourceLine: 4) == 6,
                  sample.displayedLine(forSourceLine: 5) == 6,
                  sample.displayedLine(forSourceLine: 9) == 7,
                  sample.displayedLine(forSourceLine: 10) == 8,
                  sample.displayedLine(forSourceLine: 11) == 9,
                  sample.displayedLine(forSourceLine: 99) == 9 else {
                return fail("source lines did not map onto the displayed hunks")
            }
            guard sample.sourceLine(forDisplayedLine: 1) == 1,
                  sample.sourceLine(forDisplayedLine: 3) == 2,
                  sample.sourceLine(forDisplayedLine: 7) == 10,
                  sample.sourceLine(forDisplayedLine: 9) == 11 else {
                return fail("displayed lines did not map back onto source lines")
            }

            // Hunk edge cases: a hunk that only removes lines pulls the source back
            // to its header, a removed line maps forward to where the following line
            // now is, and a trailing `\ No newline` marker maps back to the last
            // shown line.
            let deletionPatch = """
                diff --git a/gone.txt b/gone.txt
                --- a/gone.txt
                +++ b/gone.txt
                @@ -4,2 +3,0 @@
                -alpha
                -beta
                @@ -8 +5 @@
                 last
                \\ No newline at end of file
                """
            let deletion = GitDiffDisplay(patch: deletionPatch)
            guard deletion.text.contains("\\ No newline at end of file"),
                  deletion.displayedLine(forSourceLine: 3) == 1,
                  deletion.displayedLine(forSourceLine: 5) == 5,
                  deletion.sourceLine(forDisplayedLine: 2) == 5,
                  deletion.sourceLine(forDisplayedLine: 6) == 5 else {
                return fail("hunk edge cases did not map as expected")
            }

            // A patch with no hunks (an empty new file) displays nothing and maps nowhere.
            let headerOnly = GitDiffDisplay(patch: "diff --git a/empty b/empty\n--- a/empty\n+++ b/empty\n")
            guard headerOnly.text.isEmpty,
                  headerOnly.displayedLine(forSourceLine: 1) == 1,
                  headerOnly.sourceLine(forDisplayedLine: 1) == 1 else {
                return fail("a header-only patch did not display as nothing")
            }

            try FileManager.default.createDirectory(at: unbornRepository, withIntermediateDirectories: true)
            try runGit(at: unbornRepository, ["init", "-q"])
            try Data("initial\n".utf8).write(to: unbornFile)
            guard let initialDiff = try await GitDiffService.diff(fileURL: unbornFile, currentText: "initial\n", encoding: .utf8),
                  initialDiff.isNewFile,
                  initialDiff.patch.contains("+initial") else {
                return fail("untracked file in repository without HEAD was not shown")
            }

            try Data("ignored\n".utf8).write(to: ignoredFile)
            guard (await GitDiffService.status(rootURL: repository)).status(for: ignoredFile.lastPathComponent) == nil else {
                return fail("ignored untracked file received a Git status marker")
            }
            guard !(await GitDiffService.hasDiff(fileURL: ignoredFile, currentText: "ignored\n", encoding: .utf8)) else {
                return fail("ignored untracked file was reported as a diff")
            }

            try Data("outside\n".utf8).write(to: outsideFile)
            guard !(await GitDiffService.hasDiff(fileURL: outsideFile, currentText: "outside\n", encoding: .utf8)) else {
                return fail("file outside a repository was reported as a diff")
            }

            // The buffer's side-by-side diff mode: the source stays editable and
            // available while a read-only .diff-highlighted patch shows beside it,
            // the rendered preview and the diff are mutually exclusive either way,
            // and both toggling and asking for the source put the diff away.
            let modeBuffer = EditorBuffer(url: trackedFile)
            guard modeBuffer.previewFormat != nil else {
                return fail("markdown buffer had no preview format")
            }
            let patch = trackedDiff.patch
            let sourceText = modeBuffer.textController?.textView.string
            func checkSourceEditable(_ when: String) -> Int32? {
                guard let controller = modeBuffer.textController,
                      controller.textView.isEditable,
                      controller.textView.string == sourceText else {
                    return fail("source was not editable beside the diff (\(when))")
                }
                return nil
            }
            modeBuffer.setShowingPreview(true)
            guard modeBuffer.isShowingPreview else {
                return fail("markdown preview did not show")
            }
            modeBuffer.setShowingGitDiff(true, patch: patch)
            guard modeBuffer.isShowingGitDiff, !modeBuffer.isShowingPreview,
                  let diffController = modeBuffer.gitDiffController,
                  diffController.textView.string == GitDiffDisplay(patch: patch).text,
                  !diffController.textView.isEditable,
                  diffController.textView.language == .diff,
                  modeBuffer.textController?.scrollPeer === diffController,
                  diffController.scrollPeer === modeBuffer.textController else {
                return fail("git diff did not replace the preview with a read-only, scroll-linked .diff patch")
            }
            if let failure = checkSourceEditable("diff shown") { return failure }
            // A recomputed patch whose displayed lines didn't change keeps the pane,
            // so an idle Git refresh doesn't jump the diff back to its top.
            modeBuffer.updateGitDiff(patch: patch + "\n")
            guard modeBuffer.isShowingGitDiff, modeBuffer.gitDiffController === diffController else {
                return fail("an unchanged patch was not left in place")
            }
            let editedPatch = patch + "+tail\n"
            modeBuffer.updateGitDiff(patch: editedPatch)
            guard modeBuffer.isShowingGitDiff, let swapped = modeBuffer.gitDiffController,
                  swapped !== diffController,
                  swapped.textView.string == GitDiffDisplay(patch: editedPatch).text,
                  modeBuffer.textController?.scrollPeer === swapped else {
                return fail("a recomputed patch was not swapped into the shown diff")
            }
            if let failure = checkSourceEditable("patch swapped") { return failure }
            modeBuffer.setShowingPreview(true)
            guard modeBuffer.isShowingPreview, !modeBuffer.isShowingGitDiff,
                  modeBuffer.gitDiffController == nil,
                  modeBuffer.textController?.scrollPeer == nil,
                  modeBuffer.textController?.peerTopLine == nil else {
                return fail("the preview did not take the card back from the git diff")
            }
            modeBuffer.setShowingGitDiff(true, patch: patch)
            modeBuffer.setShowingGitDiff(false)
            guard !modeBuffer.isShowingGitDiff, modeBuffer.gitDiffController == nil,
                  !modeBuffer.isShowingPreview,
                  modeBuffer.textController?.scrollPeer == nil,
                  modeBuffer.textController?.peerTopLine == nil else {
                return fail("toggling the diff off did not return to the source")
            }
            if let failure = checkSourceEditable("diff toggled off") { return failure }
            modeBuffer.setShowingGitDiff(true, patch: patch)
            modeBuffer.setShowingPreview(false)
            guard !modeBuffer.isShowingGitDiff, !modeBuffer.isShowingPreview else {
                return fail("asking for the source did not put the git diff away")
            }

            print("GIT DIFF SELFTEST: PASS")
            return 0
        } catch {
            return fail("\(error)")
        }
    }

    private static func runGit(at directory: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitDiffSelfTest",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
            )
        }
    }

    private static func fail(_ message: String) -> Int32 {
        print("GIT DIFF SELFTEST: FAIL: \(message)")
        return 1
    }
}
#endif
