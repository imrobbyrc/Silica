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

    private static func waitForDiagnostics(
        in coordinator: LanguageServerCoordinator,
        url: URL,
        expected: LSPDiagnosticCounts
    ) async -> Bool {
        for _ in 0..<500 {
            if coordinator.diagnosticCounts(for: url) == expected { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func waitForServerRequests(in logURL: URL, count: Int) async -> Bool {
        for _ in 0..<500 {
            if let contents = try? String(contentsOf: logURL, encoding: .utf8),
               let events = try? contents.split(separator: "\n").map({ line in
                   try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] ?? [:]
               }),
               events.filter({ $0["method"] as? String == "workspace/configuration/response" }).count >= count,
               events.filter({ $0["method"] as? String == "workspace/workspaceFolders/response" }).count >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Writes a scripted value for the fake server to re-read on its next request.
    private static func script(_ text: String, to file: URL) {
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            fatalError("selftest could not script \(file.lastPathComponent): \(error)")
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
        let sourceText = "func greet() {}\nlet greeting = \"hi\"\ngreet()\nstruct Greeting {}\nlet greetingType: Greeting = Greeting()\n"
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
        // The server inherits its environment at spawn, so per-probe values go
        // through files it re-reads on every request instead of setenv.
        setenv("FAKE_LSP_TARGET_URI", targetURL.absoluteString, 1)
        setenv("FAKE_LSP_RANGE", "2:4:2:14", 1)
        let requestLog = root.appending(component: "requests.log").path
        setenv("FAKE_LSP_REQUEST_LOG", requestLog, 1)
        let completionsResultFile = root.appending(component: "completions-result.json")
        script("", to: completionsResultFile)
        setenv("FAKE_LSP_COMPLETIONS_RESULT_FILE", completionsResultFile.path, 1)

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

        let expectedDiagnostics = LSPDiagnosticCounts(errors: 1, warnings: 1)
        guard await waitForDiagnostics(in: coordinator, url: sourceURL, expected: expectedDiagnostics),
              await waitForDiagnostics(in: coordinator, url: peerURL, expected: expectedDiagnostics) else {
            print("LSP SELFTEST: FAIL: opening a supported file did not start its server and publish diagnostics")
            return 1
        }

        // The call expression on line 2 should be a command-hover link.
        let callRange = (sourceText as NSString).range(of: "greet()", options: .backwards)
        let offset = callRange.location
        guard buffer.textController?.textView.commandLinkRangeAt?(offset)
                == NSRange(location: offset, length: "greet".utf16.count) else {
            print("LSP SELFTEST: FAIL: function call is not recognized as a command-hover link")
            return 1
        }
        let swiftAnnotation = (sourceText as NSString).range(of: "let greetingType: Greeting")
        let swiftTypeRange = NSRange(
            location: swiftAnnotation.location + "let greetingType: ".utf16.count,
            length: "Greeting".utf16.count
        )
        guard buffer.textController?.textView.commandLinkRangeAt?(swiftTypeRange.location) == swiftTypeRange else {
            print("LSP SELFTEST: FAIL: Swift type reference is not a command-hover candidate")
            return 1
        }
        let pythonText = "# from django.fake import fake\n"
            + "EXAMPLE = \"\"\"\n"
            + "import django.stringmodule\n"
            + "\"\"\"\n"
            + "from django.shortcuts import (\n    render,\n    redirect as go,\n)\n"
            + "import django.conf\n"
            + "from ordering_system.settings import AdditionalPaymentMethod\n"
            + "value = AdditionalPaymentMethod.CUSTOM\n"
            + "from ordering_system.apps.accounting_integrations.models import AccountingIntegrationSettings\n"
            + "def get_oauth_key(settings: AccountingIntegrationSettings) -> str:\n"
            + "    return \"\"\n"
            + "local_settings = 1\n"
            + "message = f\"{merchant_identifier}\"\n"
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
        coordinator.documentDidOpen(pythonBuffer)

        let javascriptText = "const value = 1;\nconst copy = value;\n"
        let javascriptURL = root.appending(component: "source.js")
        let typescriptText = "interface Result {}\nconst result: Result = {};\n"
        let typescriptURL = root.appending(component: "source.ts")
        do {
            try javascriptText.write(to: javascriptURL, atomically: false, encoding: .utf8)
            try typescriptText.write(to: typescriptURL, atomically: false, encoding: .utf8)
        } catch {
            print("LSP SELFTEST: FAIL: could not write JavaScript/TypeScript fixtures: \(error)")
            return 1
        }
        let javascriptBuffer = EditorBuffer(url: javascriptURL)
        let typescriptBuffer = EditorBuffer(url: typescriptURL)
        guard let javascriptView = javascriptBuffer.textController?.textView,
              let typescriptView = typescriptBuffer.textController?.textView else {
            print("LSP SELFTEST: FAIL: could not open JavaScript/TypeScript fixtures")
            return 1
        }
        let jsValueRange = (javascriptText as NSString).range(of: "value", options: .backwards)
        let tsAnnotation = (typescriptText as NSString).range(of: "const result: Result")
        let tsTypeRange = NSRange(
            location: tsAnnotation.location + "const result: ".utf16.count,
            length: "Result".utf16.count
        )
        guard javascriptView.commandLinkRangeAt?(jsValueRange.location) == jsValueRange,
              typescriptView.commandLinkRangeAt?(tsTypeRange.location) == tsTypeRange else {
            print("LSP SELFTEST: FAIL: JavaScript/TypeScript identifiers are not command-hover candidates")
            return 1
        }
        coordinator.documentDidOpen(javascriptBuffer)
        coordinator.documentDidOpen(typescriptBuffer)
        for url in [pythonURL, javascriptURL, typescriptURL] {
            guard await waitForDiagnostics(in: coordinator, url: url, expected: expectedDiagnostics) else {
                print("LSP SELFTEST: FAIL: opening \(url.pathExtension) did not start its server and publish diagnostics")
                return 1
            }
        }
        guard await waitForServerRequests(in: URL(filePath: requestLog), count: 4) else {
            print("LSP SELFTEST: FAIL: did not receive workspace request replies from all servers")
            return 1
        }
        let pythonNSString = pythonText as NSString
        let dottedModuleRange = pythonNSString.range(of: "django.shortcuts")
        let moduleRange = NSRange(location: dottedModuleRange.location, length: "django".utf16.count)
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
        let localSettingsRange = pythonNSString.range(of: "local_settings")
        let fStringValueRange = pythonNSString.range(of: "merchant_identifier")
        guard pythonView.commandLinkRangeAt?(localSettingsRange.location) == localSettingsRange,
              pythonView.commandLinkRangeAt?(fStringValueRange.location) == fStringValueRange else {
            print("LSP SELFTEST: FAIL: Python bare/f-string identifiers are not command-hover candidates")
            return 1
        }
        let commentRange = pythonNSString.range(of: "django.fake")
        let stringRange = pythonNSString.range(of: "django.stringmodule")
        let commentIdentifier = NSRange(location: commentRange.location, length: "django".utf16.count)
        let stringIdentifier = NSRange(location: stringRange.location, length: "django".utf16.count)
        guard pythonView.commandLinkRangeAt?(commentRange.location) == commentIdentifier,
              pythonView.commandLinkRangeAt?(stringRange.location) == stringIdentifier else {
            print("LSP SELFTEST: FAIL: identifiers in comments/strings are not candidates for server resolution")
            return 1
        }

        let pythonCallRange = pythonNSString.range(of: "render(request")
        let functionLinkRange = NSRange(location: pythonCallRange.location, length: "render".utf16.count)
        guard pythonView.commandLinkRangeAt?(pythonCallRange.location) == functionLinkRange else {
            print("LSP SELFTEST: FAIL: Python function call is not a command-hover link")
            return 1
        }

        let dottedUsage = pythonNSString.range(of: "AdditionalPaymentMethod.CUSTOM")
        guard dottedUsage.location != NSNotFound else {
            print("LSP SELFTEST: FAIL: Python dotted member fixture is missing")
            return 1
        }
        let typeRange = NSRange(location: dottedUsage.location, length: "AdditionalPaymentMethod".utf16.count)
        let memberRange = NSRange(
            location: typeRange.location + typeRange.length + 1,
            length: "CUSTOM".utf16.count
        )
        guard pythonView.commandLinkRangeAt?(typeRange.location) == typeRange,
              pythonView.commandLinkRangeAt?(memberRange.location) == memberRange else {
            print("LSP SELFTEST: FAIL: Python dotted type/member usage is not a command-hover link")
            return 1
        }
        let annotationType = pythonNSString.range(
            of: "AccountingIntegrationSettings",
            options: .backwards
        )
        guard annotationType.location != NSNotFound,
              pythonView.commandLinkRangeAt?(annotationType.location) == annotationType else {
            print("LSP SELFTEST: FAIL: Python imported type in annotation is not a command-hover link")
            return 1
        }
        let annotationOutcome = await coordinator.definition(
            in: pythonBuffer,
            atUTF16Offset: annotationType.location,
            currentText: pythonText
        )
        guard case .definition = annotationOutcome else {
            print("LSP SELFTEST: FAIL: Python annotation type definition request returned \(annotationOutcome)")
            return 1
        }
        let memberOutcome = await coordinator.definition(
            in: pythonBuffer,
            atUTF16Offset: memberRange.location,
            currentText: pythonText
        )
        guard case .definition = memberOutcome else {
            print("LSP SELFTEST: FAIL: Python member definition request returned \(memberOutcome)")
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
            let initializations = events.filter { $0["method"] as? String == "initialize" }
            guard initializations.count == 4 else {
                print("LSP SELFTEST: FAIL: expected one server per supported language")
                return 1
            }
            let workspaceCapabilitiesCorrect = initializations.allSatisfy { event in
                guard let params = event["params"] as? [String: Any],
                      let capabilities = params["capabilities"] as? [String: Any],
                      let workspace = capabilities["workspace"] as? [String: Any],
                      let textDocument = capabilities["textDocument"] as? [String: Any],
                      let completion = textDocument["completion"] as? [String: Any],
                      let completionItem = completion["completionItem"] as? [String: Any] else { return false }
                return workspace["configuration"] as? Bool == true
                    && workspace["workspaceFolders"] as? Bool == true
                    && completion["contextSupport"] as? Bool == true
                    && completionItem["snippetSupport"] as? Bool == false
                    && textDocument["hover"] == nil
            }
            guard workspaceCapabilitiesCorrect else {
                print("LSP SELFTEST: FAIL: initialize did not advertise workspace capabilities: \(logged)")
                return 1
            }
            let configurationReplies = events.filter { $0["method"] as? String == "workspace/configuration/response" }
            guard configurationReplies.count == 4,
                  configurationReplies.allSatisfy({ event in
                      guard let result = event["result"] as? [Any] else { return false }
                      return result.count == 2 && result.allSatisfy { $0 is NSNull }
                  }) else {
                print("LSP SELFTEST: FAIL: workspace/configuration did not return null per item: \(logged)")
                return 1
            }
            let folderReplies = events.filter { $0["method"] as? String == "workspace/workspaceFolders/response" }
            guard folderReplies.count == 4,
                  folderReplies.allSatisfy({ event in
                      guard let folders = event["result"] as? [[String: Any]],
                            let folder = folders.first else { return false }
                      return folders.count == 1
                          && folder["uri"] as? String == root.absoluteString
                          && folder["name"] as? String == root.lastPathComponent
                  }) else {
                print("LSP SELFTEST: FAIL: workspace/workspaceFolders did not return the project root: \(logged)")
                return 1
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
            guard await waitForDiagnostics(in: coordinator, url: peerURL, expected: .zero) else {
                print("LSP SELFTEST: FAIL: empty diagnostics notification did not clear previous diagnostics")
                return 1
            }
        } catch {
            print("LSP SELFTEST: FAIL: could not read request log: \(error)")
            return 1
        }

        // Completions: filtered to the word prefix, snippets skipped, stable order.
        script(
            "[" + #"{"label":"greetEverything","kind":3,"insertTextFormat":1},"#
                + #"{"label":"greetZebra","kind":3,"insertTextFormat":1,"sortText":"zzzz"},"#
                + #"{"label":"snippet","kind":3,"insertTextFormat":2},"#
                + #"{"label":"unrelated","kind":3,"insertTextFormat":1},"#
                + #"{"label":"greetEdit","kind":3,"textEdit":{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":10}},"newText":"greetEdit"}},"#
                + #"{"label":"greetMismatch","kind":3,"textEdit":{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":12}},"newText":"greetMismatch"}}]"#,
            to: completionsResultFile
        )
        let greetRange = (sourceText as NSString).range(of: "greet()")
        let greetEnd = greetRange.location + "greet".utf16.count
        let completions = await coordinator.completions(
            in: buffer, atUTF16Offset: greetEnd, currentText: sourceText)
        guard completions.map(\.label) == ["greetEdit", "greetEverything", "greetZebra"],
              completions.allSatisfy({ $0.insertion == $0.label && $0.kindName == "Function" }) else {
            print("LSP SELFTEST: FAIL: completions were not filtered/sorted as scripted: \(completions.map(\.label))")
            return 1
        }
        // Empty-prefix completion still works at the start of a line, while
        // text edits with non-matching ranges remain excluded.
        let bareCaretCompletions = await coordinator.completions(
            in: buffer, atUTF16Offset: 0, currentText: sourceText)
        guard bareCaretCompletions.map(\.label) == ["greetEverything", "unrelated", "greetZebra"] else {
            print("LSP SELFTEST: FAIL: empty-prefix completion or text-edit range filtering failed: \(bareCaretCompletions.map(\.label))")
            return 1
        }

        coordinator.documentDidClose(url: sourceURL)
        guard coordinator.diagnosticCounts(for: sourceURL) == .zero else {
            print("LSP SELFTEST: FAIL: closing a document did not clear its diagnostics")
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

        guard await testCommandMouseEvents() else { return 1 }

        print("LSP SELFTEST: PASS")
        return 0
    }

    private static func testCommandMouseEvents() async -> Bool {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 640, height: 160),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }
        guard let contentView = window.contentView else {
            print("LSP SELFTEST: FAIL: could not create command-click test window")
            return false
        }

        let text = "# ghost()\nlet targetValue = 1\nlet staleValue = 2\n"
        let textView = EditorTextView(frame: contentView.bounds)
        textView.string = text
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = .zero
        contentView.addSubview(textView)
        let highlighter = SyntaxHighlighter(textView: textView, language: .python)
        textView.commandLinkRangeAt = { [weak highlighter] offset in
            highlighter?.linkRange(at: offset)
        }
        textView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let textNSString = text as NSString
        let unresolvedRange = textNSString.range(of: "ghost")
        let targetRange = textNSString.range(of: "targetValue")
        let staleRange = textNSString.range(of: "staleValue")
        var resolvedOffsets: [Int] = []
        var staleRequestStarted = false
        var staleContinuation: CheckedContinuation<Bool, Never>?
        defer { staleContinuation?.resume(returning: false) }
        textView.onCommandDefinitionCheck = { offset in
            if NSLocationInRange(offset, staleRange) {
                staleRequestStarted = true
                let result = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                    staleContinuation = continuation
                }
                resolvedOffsets.append(offset)
                return result
            }
            try? await Task.sleep(for: .milliseconds(30))
            resolvedOffsets.append(offset)
            return NSLocationInRange(offset, targetRange)
        }

        guard let unresolvedEvent = mouseEvent(
            for: NSRange(location: unresolvedRange.location, length: 1),
            type: .mouseMoved,
            modifiers: [.command],
            in: textView,
            window: window
        ) else {
            print("LSP SELFTEST: FAIL: could not create synthetic unresolved-hover event")
            return false
        }
        NSCursor.iBeam.set()
        textView.mouseMoved(with: unresolvedEvent)
        guard resolvedOffsets.isEmpty, NSCursor.current != NSCursor.pointingHand else {
            print("LSP SELFTEST: FAIL: cursor appeared before command-hover definition response")
            return false
        }
        let clock = ContinuousClock()
        let unresolvedDeadline = clock.now.advanced(by: .seconds(2))
        while !resolvedOffsets.contains(where: { NSLocationInRange($0, unresolvedRange) }),
              clock.now < unresolvedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard resolvedOffsets.contains(where: { NSLocationInRange($0, unresolvedRange) }),
              NSCursor.current != NSCursor.pointingHand else {
            print("LSP SELFTEST: FAIL: unresolved identifier showed command hand cursor")
            return false
        }

        guard let resolvedEvent = mouseEvent(
            for: NSRange(location: targetRange.location, length: 1),
            type: .mouseMoved,
            modifiers: [.command],
            in: textView,
            window: window
        ) else {
            print("LSP SELFTEST: FAIL: could not create synthetic resolved-hover event")
            return false
        }
        textView.mouseMoved(with: resolvedEvent)
        guard NSCursor.current != NSCursor.pointingHand else {
            print("LSP SELFTEST: FAIL: cursor appeared before command-hover definition response")
            return false
        }
        let resolvedDeadline = clock.now.advanced(by: .seconds(2))
        while !resolvedOffsets.contains(where: { NSLocationInRange($0, targetRange) }),
              clock.now < resolvedDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard resolvedOffsets.contains(where: { NSLocationInRange($0, targetRange) }),
              NSCursor.current == NSCursor.pointingHand else {
            print("LSP SELFTEST: FAIL: definition response did not enable command hand cursor")
            return false
        }

        let targetResponsesBeforeRace = resolvedOffsets.filter { NSLocationInRange($0, targetRange) }.count
        guard let staleEvent = mouseEvent(
            for: NSRange(location: staleRange.location, length: 1),
            type: .mouseMoved,
            modifiers: [.command],
            in: textView,
            window: window
        ) else {
            print("LSP SELFTEST: FAIL: could not create synthetic stale-hover event")
            return false
        }
        textView.mouseMoved(with: staleEvent)
        let staleDeadline = clock.now.advanced(by: .seconds(2))
        while !staleRequestStarted, clock.now < staleDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard staleRequestStarted, staleContinuation != nil else {
            print("LSP SELFTEST: FAIL: stale definition request did not start")
            return false
        }

        textView.mouseMoved(with: resolvedEvent)
        let racedTargetDeadline = clock.now.advanced(by: .seconds(2))
        while resolvedOffsets.filter({ NSLocationInRange($0, targetRange) }).count <= targetResponsesBeforeRace,
              clock.now < racedTargetDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard NSCursor.current == NSCursor.pointingHand else {
            print("LSP SELFTEST: FAIL: current definition did not retain hand cursor during stale response")
            return false
        }
        staleContinuation?.resume(returning: false)
        staleContinuation = nil
        try? await Task.sleep(for: .milliseconds(20))
        guard NSCursor.current == NSCursor.pointingHand else {
            print("LSP SELFTEST: FAIL: stale definition response changed command cursor")
            return false
        }

        var clickedOffset: Int?
        textView.onCommandClick = { clickedOffset = $0 }
        guard let clickEvent = mouseEvent(
            for: NSRange(location: targetRange.location, length: 1),
            type: .leftMouseDown,
            modifiers: [.command],
            in: textView,
            window: window
        ) else {
            print("LSP SELFTEST: FAIL: could not create synthetic command-click event")
            return false
        }
        textView.mouseDown(with: clickEvent)
        guard let clickedOffset, NSLocationInRange(clickedOffset, targetRange) else {
            print("LSP SELFTEST: FAIL: synthetic command-click did not dispatch identifier offset")
            return false
        }
        textView.string += " "
        textView.didChangeText()
        guard NSCursor.current == NSCursor.iBeam else {
            print("LSP SELFTEST: FAIL: edit left stale command hand cursor")
            return false
        }
        return true
    }

    private static func mouseEvent(
        for range: NSRange,
        type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags,
        in textView: EditorTextView,
        window: NSWindow
    ) -> NSEvent? {
        var actualRange = NSRange()
        let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actualRange)
        guard actualRange.location != NSNotFound, !screenRect.isEmpty else { return nil }
        let location = window.convertPoint(fromScreen: NSPoint(x: screenRect.midX, y: screenRect.midY))
        return NSEvent.mouseEvent(
            with: type,
            location: location,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }
}
#endif
