import AppKit
import Foundation
import Observation

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

/// One diagnostic of one open document, ready for display. The range stays in
/// LSP coordinates until a view maps it against the current buffer text.
struct LSPDiagnostic: Identifiable, Equatable, Sendable {
    let id: Int
    let range: Range<Position>
    let message: String
    let severity: DiagnosticSeverity?
    let source: String?
    let code: String?
}

/// One completion entry already filtered to the typed word and safe to insert
/// as a single plain replacement. `id` is the position in the filtered list.
struct LSPCompletionItem: Identifiable, Equatable, Sendable {
    let id: Int
    let label: String
    let detail: String?
    let kindName: String?
    let insertion: String
}

struct LSPDiagnosticCounts: Equatable, Sendable {
    let errors: Int
    let warnings: Int

    static let zero = LSPDiagnosticCounts(errors: 0, warnings: 0)
}

/// The language servers of one project: starts one server per needed language,
/// keeps open documents in sync, stores diagnostics and answers definition
/// requests. Lifetime is tied to the workspace — `shutdown()` when its window
/// closes.
@MainActor
@Observable
final class LanguageServerCoordinator {
    private let rootURL: URL
    private var servers: [SyntaxLanguage: ProjectLanguageServer] = [:]
    private var serverStartTasks: [SyntaxLanguage: ServerStart] = [:]
    private var diagnosticsByURI: [DocumentURI: [Diagnostic]] = [:]
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

    private struct ServerStart {
        let id: UUID
        let task: Task<ProjectLanguageServer, Error>
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
        Task { [weak self] in await self?.prepare(language: language) }
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
        diagnosticsByURI[DocumentURI(url)] = nil
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

    func diagnosticCounts(for url: URL) -> LSPDiagnosticCounts {
        let diagnostics = diagnosticsByURI[DocumentURI(url)] ?? []
        return LSPDiagnosticCounts(
            errors: diagnostics.filter { $0.severity == .error }.count,
            warnings: diagnostics.filter { $0.severity == .warning }.count
        )
    }

    /// The current diagnostics of one open document, in server order.
    func diagnostics(for url: URL) -> [LSPDiagnostic] {
        let diagnostics = diagnosticsByURI[DocumentURI(url)] ?? []
        return diagnostics.enumerated().map { index, diagnostic in
            LSPDiagnostic(
                id: index,
                range: diagnostic.range,
                message: diagnostic.message,
                severity: diagnostic.severity,
                source: diagnostic.source,
                code: diagnostic.code.map { code in
                    switch code {
                    case .number(let value): return String(value)
                    case .string(let value): return value
                    }
                }
            )
        }
    }

    private func receiveDiagnostics(uri: DocumentURI, diagnostics: [Diagnostic]) {
        guard !isShutdown, openDocuments.keys.contains(where: { DocumentURI($0) == uri }) else { return }
        diagnosticsByURI[uri] = diagnostics
    }

    private func clearDiagnostics(for language: SyntaxLanguage) {
        for (url, document) in openDocuments where document.language == language {
            diagnosticsByURI[DocumentURI(url)] = nil
        }
    }

    // MARK: Go to definition

    /// Starts the server and synchronizes open documents so diagnostics and
    /// definition navigation are ready without waiting for a request.
    func prepare(language: SyntaxLanguage) async {
        guard !isShutdown, let spec = LanguageServerRegistry.spec(for: language) else { return }
        guard case .available(let executable, let arguments) = await LanguageServerRegistry.availability(for: language),
              !isShutdown else {
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

    /// One of the three ways resolving a server for a request can end.
    private enum ServerResolution {
        case ready(ProjectLanguageServer, OpenDocument)
        case unavailable(message: String)
        case failed(message: String)
    }

    /// Shared request preamble: verifies the caller snapshot, ensures the
    /// language's server runs and is ready, replays documents that predate it,
    /// and returns the snapshot the caller must still see at response time.
    private func resolveServer(
        for buffer: EditorBuffer,
        language: SyntaxLanguage,
        spec: LanguageServerRegistry.ServerSpec,
        currentText: String
    ) async -> ServerResolution {
        guard !isShutdown else { return .failed(message: "The workspace has closed.") }
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
            return .failed(message: "The source file closed before its request was resolved.")
        }
        guard sourceDocument.text == currentText else {
            return .failed(message: "The source file changed while the language server started; try again.")
        }

        // Files opened before this server started were recorded locally but could
        // not be sent then. Replay every open buffer now, including unsaved text.
        synchronizeOpenDocuments(for: language, with: server)
        return .ready(server, sourceDocument)
    }

    /// Asks the server for the definition of the symbol at `utf16Offset` in the
    /// buffer. Flushes the buffer's pending changes first so the server sees the
    /// text currently on screen.
    func definition(in buffer: EditorBuffer, atUTF16Offset offset: Int, currentText: String) async -> LSPDefinitionOutcome {
        guard let language = SyntaxLanguage(url: buffer.url),
              let spec = LanguageServerRegistry.spec(for: language) else {
            // Language Silica doesn't map yet: no navigation, by design.
            return .noDefinition
        }

        let server: ProjectLanguageServer
        let sourceDocument: OpenDocument
        switch await resolveServer(for: buffer, language: language, spec: spec, currentText: currentText) {
        case .ready(let resolvedServer, let document):
            server = resolvedServer
            sourceDocument = document
        case .unavailable(let message):
            return .unavailable(message: message)
        case .failed(let message):
            return .failed(message: message)
        }

        let position = LSPPositionMapper.position(atUTF16Offset: offset, in: sourceDocument.text as NSString)
        do {
            let locations = try await withTimeout(seconds: Self.requestTimeout) {
                try await server.definitionLocations(textDocumentURL: buffer.url, position: position)
            }
            // Compare against the live editor text, not the coordinator's
            // bookkeeping copy: a change that has not been synchronized yet
            // must still invalidate an in-flight request.
            guard !isShutdown,
                  buffer.textController?.textView.string == sourceDocument.text else {
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

    // MARK: Completion

    /// Most entries a completion panel should hold before filtering gets slow.
    nonisolated static let completionLimit = 50

    /// Manual (⌘Space) completion: asks the server for completions at
    /// `utf16Offset` and narrows them to the word being typed. Returns `[]`
    /// for "nothing to show" — completion never alerts.
    func completions(in buffer: EditorBuffer, atUTF16Offset offset: Int, currentText: String) async -> [LSPCompletionItem] {
        guard let language = SyntaxLanguage(url: buffer.url),
              let spec = LanguageServerRegistry.spec(for: language) else {
            return []
        }
        let prefix = Self.wordPrefix(atUTF16Offset: offset, in: currentText as NSString)

        guard case .ready(let server, let sourceDocument) = await resolveServer(
            for: buffer,
            language: language,
            spec: spec,
            currentText: currentText
        ) else {
            return []
        }
        let position = LSPPositionMapper.position(atUTF16Offset: offset, in: sourceDocument.text as NSString)
        do {
            let items = try await withTimeout(seconds: Self.requestTimeout) {
                try await server.completionItems(textDocumentURL: buffer.url, position: position)
            }
            guard !isShutdown,
                  buffer.textController?.textView.string == sourceDocument.text else {
                Self.logger.debug("Completions dropped: the document changed during the request")
                return []
            }
            let replacementRange = NSRange(
                location: offset - prefix.utf16.count,
                length: prefix.utf16.count
            )
            let textEditRange = LSPPositionMapper.lspRange(
                of: replacementRange,
                in: sourceDocument.text as NSString
            )
            return Self.filteredCompletions(
                from: items,
                forPrefix: prefix,
                matchingTextEditRange: textEditRange
            )
        } catch {
            if server.didTerminate {
                servers[language] = nil
            }
            Self.logger.debug("Completion request failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// The identifier being typed, ending at `offset` (the caret). Empty when
    /// the caret is not directly after word characters.
    static func wordPrefix(atUTF16Offset offset: Int, in text: NSString) -> String {
        guard offset > 0, offset <= text.length else { return "" }
        var start = offset
        while start > 0, isWordCharacter(text.character(at: start - 1)) {
            start -= 1
        }
        return start == offset ? "" : text.substring(with: NSRange(location: start, length: offset - start))
    }

    private static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// Narrows a server reply to the typed prefix, drops entries needing more
    /// than a plain single-range insert (snippets, extra edits, insert/replace
    /// ranges), orders exact-case prefix hits first, and caps the list.
    static func filteredCompletions(
        from items: [CompletionItem],
        forPrefix prefix: String,
        matchingTextEditRange: Range<Position>,
        limit: Int = completionLimit
    ) -> [LSPCompletionItem] {
        struct Candidate {
            let item: CompletionItem
            let insertion: String
            let exact: Bool
        }
        let lowercasePrefix = prefix.lowercased()
        var candidates: [Candidate] = []
        for item in items {
            if item.insertTextFormat == .snippet { continue }
            // insert/replace ranges and extra edits need more than one insert.
            if case .insertReplaceEdit = item.textEdit { continue }
            if let extra = item.additionalTextEdits, !extra.isEmpty { continue }
            var insertion = item.insertText ?? item.label
            if case .textEdit(let edit) = item.textEdit {
                // The UI applies only the typed-prefix range; reject wider edits
                // rather than leaving unmatched source text behind.
                guard edit.range == matchingTextEditRange else { continue }
                insertion = edit.newText
            }
            let key = item.filterText ?? item.label
            guard key.lowercased().hasPrefix(lowercasePrefix) else { continue }
            candidates.append(Candidate(item: item, insertion: insertion, exact: key.hasPrefix(prefix)))
        }
        return candidates
            .sorted { lhs, rhs in
                if lhs.exact != rhs.exact { return lhs.exact }
                return (lhs.item.sortText ?? lhs.item.label) < (rhs.item.sortText ?? rhs.item.label)
            }
            .prefix(limit)
            .enumerated()
            .map { index, candidate in
                LSPCompletionItem(
                    id: index,
                    label: candidate.item.label,
                    detail: candidate.item.detail,
                    kindName: kindName(for: candidate.item.kind),
                    insertion: candidate.insertion
                )
            }
    }

    /// Caps how many completions the panel shows; keep the list scannable.
    nonisolated private static let completionKindNames: [Int: String] = [
        1: "Text", 2: "Method", 3: "Function", 4: "Constructor", 5: "Field",
        6: "Variable", 7: "Class", 8: "Interface", 9: "Module", 10: "Property",
        11: "Unit", 12: "Value", 13: "Enum", 14: "Keyword", 15: "Snippet",
        16: "Color", 17: "File", 18: "Reference", 19: "Folder",
        20: "Enum Member", 21: "Constant", 22: "Struct", 23: "Event",
        24: "Operator", 25: "Type Parameter",
    ]

    private static func kindName(for kind: CompletionItemKind) -> String? {
        completionKindNames[kind.rawValue]
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
        if let existing = servers[language] {
            if existing.didTerminate {
                servers[language] = nil
            } else {
                try await existing.waitUntilReady(timeout: Self.startupTimeout)
                return existing
            }
        }
        if let startup = serverStartTasks[language] {
            return try await startup.task.value
        }

        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { throw LSPError.workspaceClosed }
            return try await self.launchServer(
                for: language,
                spec: spec,
                executable: executable,
                arguments: arguments
            )
        }
        serverStartTasks[language] = ServerStart(id: id, task: task)
        do {
            let server = try await task.value
            if serverStartTasks[language]?.id == id { serverStartTasks[language] = nil }
            return server
        } catch {
            if serverStartTasks[language]?.id == id { serverStartTasks[language] = nil }
            throw error
        }
    }

    private func launchServer(
        for language: SyntaxLanguage,
        spec: LanguageServerRegistry.ServerSpec,
        executable: URL,
        arguments: [String]
    ) async throws -> ProjectLanguageServer {
        let loginPath = await LanguageServerRegistry.loginPath()
        guard !isShutdown, !Task.isCancelled else { throw LSPError.workspaceClosed }
        let path = LanguageServerRegistry.environmentPath(
            for: language,
            workspaceURL: rootURL,
            loginPath: loginPath
        )
        let server = try ProjectLanguageServer.start(
            rootURL: rootURL,
            for: language,
            spec: spec,
            executable: executable,
            arguments: arguments,
            environmentPath: path,
            onDiagnostics: { [weak self] uri, diagnostics in
                self?.receiveDiagnostics(uri: uri, diagnostics: diagnostics)
            }
        ) { [weak self] terminatedServer in
            // The process exited on its own (crash or explicit exit).
            Self.logger.warning("\(terminatedServer.displayName) exited")
            guard let self, self.servers[terminatedServer.language] === terminatedServer else { return }
            self.servers[terminatedServer.language] = nil
            self.clearDiagnostics(for: terminatedServer.language)
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

    /// Runs work only when the server is ready. During startup, `prepare`
    /// replays the latest document snapshots after the handshake.
    private func scheduleServerWork(
        _ language: SyntaxLanguage,
        _ work: @escaping @MainActor (ProjectLanguageServer) -> Void
    ) {
        guard let server = servers[language], !server.didTerminate else {
            // No ready server yet. `prepare` replays the latest snapshots
            // after initialization.
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
        for startup in serverStartTasks.values {
            startup.task.cancel()
        }
        changeTasks.removeAll()
        serverStartTasks.removeAll()
        openDocuments.removeAll()
        diagnosticsByURI.removeAll()
        for server in servers.values {
            server.shutdown()
        }
        servers.removeAll()
    }
}
