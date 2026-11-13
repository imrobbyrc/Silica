import AppKit
import Foundation
import LanguageServerProtocol

#if DEBUG
/// End-to-end proof that Silica's LSP client works: drives the real
/// `LanguageServerCoordinator` against a fake language server
/// (`scripts/fake-lsp-server.py`) inside this app process, then exits 0/1.
///
/// Run by `scripts/test-lsp-integration.sh`, which points
/// `SILICA_LSP_SWIFT_EXEC` at the fake server. Production launches never set
/// `SILICA_LSP_SELFTEST`, so this stays dormant.
@MainActor
enum LSPSelfTest {
    static func run() {
        Task {
            let exitCode = await performTest()
            fflush(stdout)
            exit(exitCode)
        }
    }

    private static func performTest() async -> Int32 {
        let fileManager = FileManager.default
        let root = URL(
            filePath: NSTemporaryDirectory(),
            directoryHint: .isDirectory
        ).appending(component: "silica-lsp-selftest-\(UUID().uuidString)")
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("LSP SELFTEST: FAIL: could not create \(root.path): \(error)")
            return 1
        }
        defer { try? fileManager.removeItem(at: root) }

        let pythonProject = root.appending(component: "python-project", directoryHint: .isDirectory)
        let pythonBin = pythonProject.appending(path: ".venv/bin", directoryHint: .isDirectory)
        let pythonExecutable = pythonBin.appending(component: "python")
        do {
            try fileManager.createDirectory(at: pythonBin, withIntermediateDirectories: true)
            guard fileManager.createFile(atPath: pythonExecutable.path, contents: Data()) else {
                print("LSP SELFTEST: FAIL: could not create test Python interpreter")
                return 1
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonExecutable.path)
        } catch {
            print("LSP SELFTEST: FAIL: could not prepare test Python environment: \(error)")
            return 1
        }
        guard LanguageServerRegistry.pythonInterpreter(for: pythonProject) == pythonExecutable,
              LanguageServerRegistry.pythonInterpreter(for: root) == nil else {
            print("LSP SELFTEST: FAIL: Python environment tooltip did not match interpreter detection")
            return 1
        }
        let loginPath = "/usr/bin:/bin"
        let pythonPath = LanguageServerRegistry.environmentPath(
            for: .python,
            workspaceURL: pythonProject,
            loginPath: loginPath
        )
        guard pythonPath == "\(pythonBin.path):\(loginPath)" else {
            print("LSP SELFTEST: FAIL: project .venv was not prepended to Python server PATH")
            return 1
        }
        let existingPythonPath = LanguageServerRegistry.environmentPath(
            for: .python,
            workspaceURL: pythonProject,
            loginPath: "/usr/bin:\(pythonBin.path):/bin"
        )
        guard existingPythonPath == "\(pythonBin.path):/usr/bin:/bin" else {
            print("LSP SELFTEST: FAIL: project .venv was not moved to the front of Python server PATH")
            return 1
        }
        guard LanguageServerRegistry.environmentPath(
            for: .python,
            workspaceURL: root,
            loginPath: loginPath
        ) == loginPath else {
            print("LSP SELFTEST: FAIL: Python PATH changed without a project .venv")
            return 1
        }
        guard LanguageServerRegistry.environmentPath(
            for: .swift,
            workspaceURL: pythonProject,
            loginPath: loginPath
        ) == loginPath else {
            print("LSP SELFTEST: FAIL: Python .venv changed another language server PATH")
            return 1
        }
        let spacedBin = root.appending(component: "tool bin", directoryHint: .isDirectory)
        let fakePyright = spacedBin.appending(component: "pyright-langserver")
        do {
            try fileManager.createDirectory(at: spacedBin, withIntermediateDirectories: true)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakePyright)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakePyright.path)
        } catch {
            print("LSP SELFTEST: FAIL: could not prepare executable with spaces in PATH: \(error)")
            return 1
        }
        guard LanguageServerRegistry.executable(
            named: "pyright-langserver",
            path: "/usr/bin:\(spacedBin.path)"
        ) == fakePyright else {
            print("LSP SELFTEST: FAIL: executable lookup failed for a PATH entry with spaces")
            return 1
        }

        // The definition target: "TARGET_DEF" on line 2 (0-based), column 4, ten
        // UTF-16 units long — i.e. UTF-16 offset 23 in the file below.
        let targetText = """
        zero line
        one line
            TARGET_DEF = 1
        """
        let targetURL = root.appending(component: "target.txt")
        let sourceURL = root.appending(component: "source.swift")
        let peerURL = root.appending(component: "peer.swift")
        let sourceText = "func greet() {}\nlet greeting = \"hi\"\ngreet()\n"
        let diskPeerText = "let diskVersion = 1\n"
        let unsavedPeerText = "let unsavedPeer = 2\n"
        let changedPeerText = "let newestPeer = 3\n"
        do {
            try targetText.write(to: targetURL, atomically: false, encoding: .utf8)
            try sourceText.write(to: sourceURL, atomically: false, encoding: .utf8)
            try diskPeerText.write(to: peerURL, atomically: false, encoding: .utf8)
        } catch {
            print("LSP SELFTEST: FAIL: could not write fixtures: \(error)")
            return 1
        }
        let targetAliasURL = root.appending(component: "target-alias.txt")
        do {
            try fileManager.createSymbolicLink(at: targetAliasURL, withDestinationURL: targetURL)
        } catch {
            print("LSP SELFTEST: FAIL: could not create same-file alias: \(error)")
            return 1
        }
        let targetRange = Position(line: 0, utf16index: 0)..<Position(line: 0, utf16index: 1)
        guard LSPDefinitionTarget(url: targetAliasURL, range: targetRange)
                .navigationURL(from: targetURL) == targetURL,
              LSPDefinitionTarget(url: sourceURL, range: targetRange)
                .navigationURL(from: targetURL) == sourceURL else {
            print("LSP SELFTEST: FAIL: definition navigation did not reuse same-file URL")
            return 1
        }

        // Script the fake server's answer and let it log the positions Silica sends.
        setenv("FAKE_LSP_TARGET_URI", targetURL.absoluteString, 1)
        setenv("FAKE_LSP_RANGE", "2:4:2:14", 1)
        let requestLog = root.appending(component: "requests.log").path
        setenv("FAKE_LSP_REQUEST_LOG", requestLog, 1)

        let coordinator = LanguageServerCoordinator(rootURL: root)
        defer { coordinator.shutdown() }

        let buffer = EditorBuffer(url: sourceURL)
        guard buffer.textController != nil else {
            print("LSP SELFTEST: FAIL: could not open \(sourceURL.path)")
            return 1
        }
        coordinator.documentDidOpen(buffer)

        // A second buffer opened before command-hover prewarming must be replayed
        // with its current unsaved contents before the first definition request.
        let peerBuffer = EditorBuffer(url: peerURL)
        guard let peerTextView = peerBuffer.textController?.textView else {
            print("LSP SELFTEST: FAIL: could not open \(peerURL.path)")
            return 1
        }
        peerTextView.string = unsavedPeerText
        coordinator.documentDidOpen(peerBuffer)

        // The call expression on line 2; the hover affordance should identify `greet`.
        let callRange = (sourceText as NSString).range(of: "greet()", options: .backwards)
        let offset = callRange.location
        guard buffer.textController?.textView.commandLinkRangeAt?(offset)
                == NSRange(location: offset, length: "greet".utf16.count) else {
            print("LSP SELFTEST: FAIL: function call is not recognized as a command-hover link")
            return 1
        }
        let pythonText = "# from django.fake import fake\n"
            + "EXAMPLE = \"\"\"\n"
            + "import django.stringmodule\n"
            + "\"\"\"\n"
            + "from django.shortcuts import (\n    render,\n    redirect as go,\n)\n"
            + "import django.conf\n"
            + "def draw(request):\n"
            + "    return render(request, \"x\")\n"
        let pythonURL = root.appending(component: "source.py")
        do {
            try pythonText.write(to: pythonURL, atomically: false, encoding: .utf8)
        } catch {
            print("LSP SELFTEST: FAIL: could not write Python fixture: \(error)")
            return 1
        }
        let pythonBuffer = EditorBuffer(url: pythonURL)
        guard let pythonView = pythonBuffer.textController?.textView else {
            print("LSP SELFTEST: FAIL: could not open Python fixture")
            return 1
        }
        let pythonNSString = pythonText as NSString
        let moduleRange = pythonNSString.range(of: "django.shortcuts")
        let moduleOffset = moduleRange.location + 2
        guard pythonView.commandLinkRangeAt?(moduleOffset) == moduleRange else {
            print("LSP SELFTEST: FAIL: Python import module is not a command-hover link")
            return 1
        }
        let importLine = pythonNSString.range(of: "    render,")
        let importedNameRange = NSRange(location: importLine.location + 4, length: "render".utf16.count)
        let aliasLine = pythonNSString.range(of: "    redirect as go,")
        let aliasRange = NSRange(location: aliasLine.location + "    redirect as ".utf16.count, length: "go".utf16.count)
        guard pythonView.commandLinkRangeAt?(importedNameRange.location) == importedNameRange,
              pythonView.commandLinkRangeAt?(aliasRange.location) == aliasRange else {
            print("LSP SELFTEST: FAIL: Python imported names are not command-hover links")
            return 1
        }
        let commentOffset = pythonNSString.range(of: "django.fake").location
        let stringOffset = pythonNSString.range(of: "django.stringmodule").location
        guard pythonView.commandLinkRangeAt?(commentOffset) == nil,
              pythonView.commandLinkRangeAt?(stringOffset) == nil else {
            print("LSP SELFTEST: FAIL: import-like text in comments/strings became a link")
            return 1
        }

        let pythonCallRange = pythonNSString.range(of: "render(request")
        let functionLinkRange = NSRange(location: pythonCallRange.location, length: "render".utf16.count)
        guard pythonView.commandLinkRangeAt?(pythonCallRange.location) == functionLinkRange else {
            print("LSP SELFTEST: FAIL: Python function call is not a command-hover link")
            return 1
        }

        await coordinator.prepare(language: .swift)
        let outcome = await coordinator.definition(
            in: buffer,
            atUTF16Offset: offset,
            currentText: sourceText
        )

        switch outcome {
        case .definition(let target):
            if target.url.standardizedFileURL != targetURL.standardizedFileURL {
                print("LSP SELFTEST: FAIL: navigated to \(target.url.path), expected \(targetURL.path)")
                return 1
            }
            guard let revealed = LSPPositionMapper.nsRange(of: target.range, in: targetText as NSString) else {
                print("LSP SELFTEST: FAIL: could not map target range \(target.range) to an NSRange")
                return 1
            }
            let expected = NSRange(location: 23, length: 10)
            if revealed != expected {
                print("LSP SELFTEST: FAIL: reveal range \(revealed.location)/\(revealed.length), expected \(expected.location)/\(expected.length)")
                return 1
            }
        case .unavailable(let message):
            print("LSP SELFTEST: FAIL: server unavailable: \(message)")
            return 1
        case .noDefinition:
            print("LSP SELFTEST: FAIL: no definition returned")
            return 1
        case .failed(let message):
            print("LSP SELFTEST: FAIL: \(message)")
            return 1
        }

        // Repeating navigation without edits must not resend whole documents.
        let repeatedOutcome = await coordinator.definition(
            in: buffer,
            atUTF16Offset: offset,
            currentText: sourceText
        )
        guard case .definition = repeatedOutcome else {
            print("LSP SELFTEST: FAIL: repeated definition request returned \(repeatedOutcome)")
            return 1
        }

        // Requests carry the mapped UTF-16 position, and repeated navigation
        // without edits sends no redundant full-text sync notifications.
        do {
            let logged = try String(contentsOf: URL(filePath: requestLog), encoding: .utf8)
            let events = try logged.split(separator: "\n").map { line in
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
            }
            guard let definition = events.last(where: { $0["method"] as? String == "textDocument/definition" }),
                  let params = definition["params"] as? [String: Any],
                  let position = params["position"] as? [String: Any],
                  position["line"] as? Int == 2,
                  position["character"] as? Int == 0 else {
                print("LSP SELFTEST: FAIL: request log does not show position line 2 character 0: \(logged)")
                return 1
            }
            let openedPeer = events.contains { event in
                guard event["method"] as? String == "textDocument/didOpen",
                      let params = event["params"] as? [String: Any],
                      let document = params["textDocument"] as? [String: Any] else { return false }
                return document["uri"] as? String == peerURL.absoluteString
                    && document["text"] as? String == unsavedPeerText
            }
            guard openedPeer else {
                print("LSP SELFTEST: FAIL: pre-opened peer buffer was not synced with unsaved text: \(logged)")
                return 1
            }
            let redundantChanges = events.filter { $0["method"] as? String == "textDocument/didChange" }
            guard redundantChanges.isEmpty else {
                print("LSP SELFTEST: FAIL: unchanged documents were resent: \(logged)")
                return 1
            }

            // A real edit still emits one full-text change to the server.
            peerTextView.string = changedPeerText
            coordinator.documentDidChange(peerBuffer)
            try? await Task.sleep(for: .milliseconds(400))
            let updatedLog = try String(contentsOf: URL(filePath: requestLog), encoding: .utf8)
            let updatedEvents = try updatedLog.split(separator: "\n").map { line in
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
            }
            let peerChanges = updatedEvents.filter { event in
                guard event["method"] as? String == "textDocument/didChange",
                      let params = event["params"] as? [String: Any],
                      let changes = params["contentChanges"] as? [[String: Any]] else { return false }
                return changes.first?["text"] as? String == changedPeerText
            }
            guard peerChanges.count == 1 else {
                print("LSP SELFTEST: FAIL: edited peer buffer was not synced once: \(updatedLog)")
                return 1
            }
        } catch {
            print("LSP SELFTEST: FAIL: could not read request log: \(error)")
            return 1
        }

        // A definition request racing shutdown must fail gracefully, not crash.
        let racingOutcome = await withTaskGroup(of: LSPDefinitionOutcome?.self) { group in
            group.addTask {
                await coordinator.definition(in: buffer, atUTF16Offset: offset, currentText: sourceText)
            }
            group.addTask {
                await coordinator.shutdown()
                return nil
            }
            for await value in group where value != nil {
                group.cancelAll()
                return value
            }
            return nil
        }
        switch racingOutcome {
        case .definition, .noDefinition, .failed, .unavailable, nil:
            break // any non-crashing outcome is acceptable under shutdown
        }

        print("LSP SELFTEST: PASS")
        return 0
    }
}
#endif
