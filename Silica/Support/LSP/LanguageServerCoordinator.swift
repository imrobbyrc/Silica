import AppKit
import Foundation

import LanguageServerProtocol
import os

/// What a go-to-definition attempt ended in.
enum LSPDefinitionOutcome {
    /// The server returned a definition target to navigate to.
    case definition(LSPDefinitionTarget)
    /// The language has a server mapping but the server is not installed.
    case unavailable(message: String)
    /// The server found nothing (or answered `null`).
    case noDefinition
    /// The request failed; `message` says why (logged, not shown).
    case failed(message: String)
}

/// A definition location the coordinator resolved for navigation.
struct LSPDefinitionTarget {
    let url: URL
    /// Zero-based line/UTF-16 range to reveal in the target file.
    let range: Range<Position>

    func navigationURL(from sourceURL: URL) -> URL {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        let source = sourceURL.resolvingSymlinksInPath().standardizedFileURL
        return target == source ? sourceURL : url
    }
}

/// The language servers of one project: starts one server per needed language,
/// keeps open documents in sync with the server, and answers definition
/// requests. Lifetime is tied to the workspace — `shutdown()` when its window
/// closes.
@MainActor
final class LanguageServerCoordinator {
    private let rootURL: URL
    private var servers: [SyntaxLanguage: ProjectLanguageServer] = [:]
    /// Documents reported open, with their latest known text.
    private var openDocuments: [URL: OpenDocument] = [:]
    /// Pending `didChange` pushes, debounced so fast typing doesn't flood servers.
    private var changeTasks: [URL: Task<Void, Never>] = [:]
    private var isShutdown = false

    /// Debounce window for full-text `didChange` pushes.
    private static let changeDebounce: TimeInterval = 0.3
    /// How long starting a server may take before a definition request gives up.
    private static let startupTimeout: TimeInterval = 8
    /// How long a definition request may take.
    private static let requestTimeout: TimeInterval = 10

    private static let logger = Logger(subsystem: "app.silica", category: "lsp-coordinator")

    struct OpenDocument {
        var language: SyntaxLanguage
        var text: String
    }

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    // MARK: Document lifecycle (driven by WorkspaceModel)

    /// The file was opened in the workspace.
    func documentDidOpen(_ buffer: EditorBuffer) {
        guard !isShutdown, let url = documentURL(of: buffer) else { return }
        guard let language = SyntaxLanguage(url: url),
              let spec = LanguageServerRegistry.spec(for: language) else {
            // Not a language Silica maps to a server (yet).
            return
        }
        let text = buffer.textController?.textView.string ?? ""
        openDocuments[url] = OpenDocument(language: language, text: text)
        scheduleServerWork(language) { server in
            server.didOpenDocument(url: url, lspLanguage: spec.lspLanguage, text: text)
        }
    }

    /// The file's text changed (typed, undo, external reload). Debounced.
    func documentDidChange(_ buffer: EditorBuffer) {
        guard !isShutdown, let url = documentURL(of: buffer), var document = openDocuments[url] else { return }
        document.text = buffer.textController?.textView.string ?? ""
        openDocuments[url] = document
        changeTasks[url]?.cancel()
        let language = document.language
        changeTasks[url] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.changeDebounce * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.pushDocumentChange(url: url, language: language)
        }
    }

    /// The file's tab closed, or the file moved/was replaced on disk.
    func documentDidClose(url: URL) {
        guard !isShutdown, openDocuments.removeValue(forKey: url) != nil else { return }
        changeTasks[url]?.cancel()
        changeTasks[url] = nil
        guard let language = SyntaxLanguage(url: url), servers[language] != nil else { return }
        scheduleServerWork(language) { server in
            server.didCloseDocument(url: url)
        }
    }

    private func pushDocumentChange(url: URL, language: SyntaxLanguage) {
        scheduleServerWork(language) { [weak self] server in
            guard let document = self?.openDocuments[url], document.language == language else { return }
            server.didChangeDocument(url: url, text: document.text)
        }
    }

    private func documentURL(of buffer: EditorBuffer) -> URL? {
        buffer.isUntitled ? nil : buffer.url
    }

    // MARK: Go to definition

    /// Starts a server while the user hovers a linkable token, so the first click
    /// does not pay process launch and initialize latency.
    func prepare(language: SyntaxLanguage) async {
        guard !isShutdown, let spec = LanguageServerRegistry.spec(for: language) else { return }
        guard case .available(let executable, let arguments) = await LanguageServerRegistry.availability(for: language) else {
            return
        }
        do {
            let server = try await startServer(
                for: language,
                spec: spec,
                executable: executable,
                arguments: arguments
            )
            guard !isShutdown else { return }
            synchronizeOpenDocuments(for: language, with: server)
        } catch {
            Self.logger.warning("Could not prewarm \(spec.displayName): \(String(describing: error), privacy: .public)")
        }
    }

    /// Asks the server for the definition of the symbol at `utf16Offset` in the
    /// buffer. Flushes the buffer's pending changes first so the server sees the
    /// text currently on screen.
    func definition(in buffer: EditorBuffer, atUTF16Offset offset: Int, currentText: String) async -> LSPDefinitionOutcome {
        guard !isShutdown else { return .failed(message: "The workspace has closed.") }
        guard let language = SyntaxLanguage(url: buffer.url) else {
            return .noDefinition
        }
        guard let spec = LanguageServerRegistry.spec(for: language) else {
            // Language Silica doesn't map yet: no navigation, by design.
            return .noDefinition
        }

        // The open/change callbacks own the latest snapshot. Do not overwrite
        // it with this possibly stale caller snapshot while debounced edits race.
        guard let sourceSnapshot = openDocuments[buffer.url], sourceSnapshot.language == language else {
            return .failed(message: "The source file is not open in this workspace.")
        }
        guard sourceSnapshot.text == currentText else {
            return .failed(message: "The source file changed before the request started; try again.")
        }

        let server: ProjectLanguageServer
        switch await LanguageServerRegistry.availability(for: language) {
        case .available(let executable, let arguments):
            do {
                server = try await startServer(for: language, spec: spec, executable: executable, arguments: arguments)
            } catch {
                return .failed(message: "Could not start \(spec.displayName): \(error)")
            }
        case .unavailable(let message):
            return .unavailable(message: message)
        }

        do {
            try await server.waitUntilReady(timeout: Self.startupTimeout)
        } catch {
            return .failed(message: "\(spec.displayName) is not ready: \(error)")
        }
        guard !isShutdown else { return .failed(message: "The workspace has closed.") }
        guard let sourceDocument = openDocuments[buffer.url] else {
            return .failed(message: "The source file closed before its definition was resolved.")
        }
        guard sourceDocument.text == currentText else {
            return .failed(message: "The source file changed while the language server started; try again.")
        }

        // Files opened before this server started were recorded locally but could
        // not be sent then. Replay every open buffer now, including unsaved text.
        synchronizeOpenDocuments(for: language, with: server)

        let position = LSPPositionMapper.position(atUTF16Offset: offset, in: sourceDocument.text as NSString)
        do {
            let locations = try await withTimeout(seconds: Self.requestTimeout) {
                try await server.definitionLocations(textDocumentURL: buffer.url, position: position)
            }
            guard !isShutdown, openDocuments[buffer.url]?.text == sourceDocument.text else {
                return .failed(message: "The source file changed or closed during the definition request.")
            }
            guard let location = locations.first else { return .noDefinition }
            guard let url = location.uri.fileURL else {
                return .failed(message: "The definition is not a local file (\(location.uri.stringValue)).")
            }
            return .definition(LSPDefinitionTarget(url: url.standardizedFileURL, range: location.range))
        } catch {
            if server.didTerminate {
                servers[language] = nil
                return .failed(message: "\(spec.displayName) exited during the request.")
            }
            return .failed(message: "Definition request failed: \(error)")
        }
    }

    // MARK: Server management

    private func synchronizeOpenDocuments(for language: SyntaxLanguage, with server: ProjectLanguageServer) {
        for (url, document) in openDocuments where document.language == language {
            guard let documentSpec = LanguageServerRegistry.spec(for: document.language) else { continue }
            server.didOpenDocument(url: url, lspLanguage: documentSpec.lspLanguage, text: document.text)
            server.didChangeDocument(url: url, text: document.text)
        }
    }

    /// Returns the running server for `language`, starting it if needed. The
    /// completion runs only once the handshake finished.
    private func startServer(
        for language: SyntaxLanguage,
        spec: LanguageServerRegistry.ServerSpec,
        executable: URL,
        arguments: [String]
    ) async throws -> ProjectLanguageServer {
        if let existing = servers[language], !existing.didTerminate {
            return existing
        }
        if servers[language] != nil {
            // A previous instance died; drop it and start fresh.
            servers[language] = nil
        }
        let loginPath = await LanguageServerRegistry.loginPath()
        let path = LanguageServerRegistry.environmentPath(
            for: language,
            workspaceURL: rootURL,
            loginPath: loginPath
        )
        guard !isShutdown else { throw LSPError.workspaceClosed }
        let server = try ProjectLanguageServer.start(
            for: language,
            spec: spec,
            executable: executable,
            arguments: arguments,
            environmentPath: path
        ) { [weak self] terminatedServer in
            // The process exited on its own (crash or explicit exit).
            Self.logger.warning("\(terminatedServer.displayName) exited")
            if self?.servers[terminatedServer.language] === terminatedServer {
                self?.servers[terminatedServer.language] = nil
            }
        }
        servers[language] = server
        do {
            try await withTimeout(seconds: Self.startupTimeout) {
                try await server.initialize(rootURL: self.rootURL)
            }
            return server
        } catch {
            if servers[language] === server {
                servers[language] = nil
            }
            server.shutdown()
            throw error
        }
    }

    /// Queues work that needs a running, initialized server. If the server is
    /// still starting, the work waits for the handshake to finish first.
    private func scheduleServerWork(
        _ language: SyntaxLanguage,
        _ work: @escaping @MainActor (ProjectLanguageServer) -> Void
    ) {
        guard let server = servers[language], !server.didTerminate else {
            // Server not started yet: `definition` starts it on demand and
            // pushes the open document there. Notifications before that are
            // dropped; the latest state is always (re)pushed before a request.
            return
        }
        Task { @MainActor in
            guard server.isReady, !server.didTerminate else { return }
            work(server)
        }
    }

    /// Stops every server of this project. Called when the workspace closes.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        for task in changeTasks.values {
            task.cancel()
        }
        changeTasks.removeAll()
        openDocuments.removeAll()
        for server in servers.values {
            server.shutdown()
        }
        servers.removeAll()
    }
}
