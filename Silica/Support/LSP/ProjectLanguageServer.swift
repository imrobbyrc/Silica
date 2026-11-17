import Foundation

import LanguageServerProtocol
import LanguageServerProtocolTransport
import os

nonisolated private final class TerminationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var terminationReason: JSONRPCConnection.TerminationReason?
    private var handler: (@Sendable (JSONRPCConnection.TerminationReason) -> Void)?

    func install(handler: @escaping @Sendable (JSONRPCConnection.TerminationReason) -> Void) {
        lock.lock()
        self.handler = handler
        let reason = terminationReason
        lock.unlock()
        if let reason { handler(reason) }
    }

    func fire(_ reason: JSONRPCConnection.TerminationReason) {
        lock.lock()
        guard terminationReason == nil else {
            lock.unlock()
            return
        }
        terminationReason = reason
        let handler = self.handler
        lock.unlock()
        handler?(reason)
    }
}

private struct WorkspaceConfigurationRequest: LSPRequest, Hashable {
    static let method = "workspace/configuration"
    typealias Response = [LSPAny]

    struct Item: Codable, Hashable, Sendable {
        let scopeURI: DocumentURI?
        let section: String?

        enum CodingKeys: String, CodingKey {
            case scopeURI = "scopeUri"
            case section
        }
    }

    let items: [Item]
}

/// Handles requests and notifications the language server sends to Silica.
/// Called by the transport on its own queue; UI state is updated on MainActor.
final class LSPClientHandler: MessageHandler, Sendable {
    private static let logger = Logger(subsystem: "app.silica", category: "lsp-client")
    private let workspaceFolder: WorkspaceFolder
    private let onDiagnostics: @Sendable (DocumentURI, [Diagnostic]) -> Void

    init(
        workspaceFolder: WorkspaceFolder,
        onDiagnostics: @escaping @Sendable (DocumentURI, [Diagnostic]) -> Void
    ) {
        self.workspaceFolder = workspaceFolder
        self.onDiagnostics = onDiagnostics
    }

    nonisolated func handle(_ notification: some NotificationType) {
        guard let notification = notification as? PublishDiagnosticsNotification else {
            Self.logger.debug("Ignoring server notification: \(String(describing: type(of: notification)))")
            return
        }
        onDiagnostics(notification.uri, notification.diagnostics)
    }

    nonisolated func handle<Request: RequestType>(
        _ request: Request,
        id: RequestID,
        reply: @Sendable @escaping (LSPResult<Request.Response>) -> Void
    ) {
        if let request = request as? WorkspaceConfigurationRequest,
           let response = [LSPAny](repeating: .null, count: request.items.count) as? Request.Response {
            reply(.success(response))
            return
        }
        if request is WorkspaceFoldersRequest,
           let response = Optional([workspaceFolder]) as? Request.Response {
            reply(.success(response))
            return
        }
        Self.logger.debug("Replying methodNotFound to server request: \(Request.method)")
        reply(.failure(.methodNotFound(Request.method)))
    }
}

/// One language server process for one project and language: owns its stdio
/// JSON-RPC connection, runs the initialize handshake, and tracks which
/// documents are open with which version.
@MainActor
final class ProjectLanguageServer {
    let language: SyntaxLanguage
    let displayName: String
    let connection: JSONRPCConnection
    let process: Foundation.Process

    /// Set once the server replied to `initialize` and `initialized` was sent.
    /// Requests and notifications may only be sent after that.
    private(set) var isReady = false
    /// Set when the server process exited; the transport has failed all
    /// outstanding requests by then.
    private(set) var didTerminate = false

    /// Callers waiting for `isReady`, each raced against its own deadline.
    private var readinessWaiters: [ReadinessWaiter] = []

    /// `didOpen` was sent for these documents.
    private var openDocuments: Set<DocumentURI> = []
    /// Last full-text snapshot sent; identical snapshots need no LSP traffic.
    private var documentTexts: [DocumentURI: String] = [:]
    /// Version handed out with the last `didOpen`/`didChange` per document.
    private var documentVersions: [DocumentURI: Int] = [:]

    private static let logger = Logger(subsystem: "app.silica", category: "lsp-server")

    /// Starts the server process and its JSON-RPC connection. Call
    /// `initialize(rootURL:)` afterwards; document messages may only be sent
    /// once that completes.
    static func start(
        rootURL: URL,
        for language: SyntaxLanguage,
        spec: LanguageServerRegistry.ServerSpec,
        executable: URL,
        arguments: [String],
        environmentPath: String,
        onDiagnostics: @escaping @MainActor (DocumentURI, [Diagnostic]) -> Void,
        onTermination: @escaping @MainActor (ProjectLanguageServer) -> Void
    ) throws -> ProjectLanguageServer {
        // The transport calls the termination handler from its own queue before
        // the server object may exist, so route it through this box.
        let box = TerminationBox()
        let pair = try JSONRPCConnection.start(
            // Launch via /usr/bin/env so the server sees the login-shell PATH,
            // which a GUI app's own environment usually lacks (e.g. node for
            // typescript-language-server's tsserver).
            executable: URL(filePath: "/usr/bin/env"),
            arguments: ["PATH=\(environmentPath)", executable.path] + arguments,
            name: "Silica",
            protocol: MessageRegistry(
                requests: builtinRequests + [WorkspaceConfigurationRequest.self],
                notifications: builtinNotifications
            ),
            stderrLoggingCategory: "lsp-stderr",
            client: LSPClientHandler(
                workspaceFolder: WorkspaceFolder(
                    uri: DocumentURI(rootURL),
                    name: rootURL.lastPathComponent
                )
            ) { uri, diagnostics in
                Task { @MainActor in onDiagnostics(uri, diagnostics) }
            },
            terminationHandler: { reason in box.fire(reason) }
        )
        let server = ProjectLanguageServer(
            language: language,
            displayName: spec.displayName,
            connection: pair.connection,
            process: pair.process
        )
        box.install { [weak server] _ in
            Task { @MainActor [weak server] in
                guard let server else { return }
                server.handleTermination()
                onTermination(server)
            }
        }
        return server
    }

    private init(language: SyntaxLanguage, displayName: String, connection: JSONRPCConnection, process: Foundation.Process) {
        self.language = language
        self.displayName = displayName
        self.connection = connection
        self.process = process
    }

    deinit {
        // If the workspace forgot to shut us down, at least tear the transport
        // down so its queues don't leak. `close()` is idempotent.
        connection.close()
    }

    /// Runs the `initialize`/`initialized` handshake with the project root.
    func initialize(rootURL: URL) async throws {
        let root = DocumentURI(rootURL)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let request = InitializeRequest(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            clientInfo: .init(name: "Silica", version: version),
            rootPath: rootURL.path,
            rootURI: root,
            capabilities: ClientCapabilities(
                workspace: WorkspaceClientCapabilities(workspaceFolders: true, configuration: true),
                textDocument: TextDocumentClientCapabilities(
                    completion: .init(
                        completionItem: .init(snippetSupport: false),
                        contextSupport: true
                    )
                )
            ),
            workspaceFolders: [WorkspaceFolder(uri: root, name: rootURL.lastPathComponent)]
        )
        _ = try await connection.send(request)
        connection.send(InitializedNotification())
        isReady = true
        for waiter in readinessWaiters {
            waiter.resume()
        }
        readinessWaiters.removeAll()
    }

    /// Waits until `initialize` completed; throws once `timeout` seconds passed
    /// or when the server died first.
    func waitUntilReady(timeout: TimeInterval) async throws {
        if isReady { return }
        if didTerminate { throw LSPError.serverTerminated }
        let waiter = ReadinessWaiter()
        readinessWaiters.append(waiter)
        let deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.expire(waiter)
        }
        defer { deadlineTask.cancel() }
        do {
            try await waiter.awaitResult()
        } catch {
            readinessWaiters.removeAll { $0 === waiter }
            throw error
        }
    }

    private func expire(_ waiter: ReadinessWaiter) {
        guard !isReady else { return }
        waiter.expire()
        readinessWaiters.removeAll { $0 === waiter }
    }

    // MARK: Document sync

    func didOpenDocument(url: URL, lspLanguage: Language, text: String) {
        let uri = DocumentURI(url)
        guard !openDocuments.contains(uri) else { return }
        openDocuments.insert(uri)
        documentTexts[uri] = text
        let version = bumpVersion(for: uri)
        connection.send(DidOpenTextDocumentNotification(textDocument: TextDocumentItem(
            uri: uri,
            language: lspLanguage,
            version: version,
            text: text
        )))
    }

    /// Pushes the full text of a document (Silica always uses full-text sync).
    func didChangeDocument(url: URL, text: String) {
        let uri = DocumentURI(url)
        guard openDocuments.contains(uri), documentTexts[uri] != text else { return }
        documentTexts[uri] = text
        let version = bumpVersion(for: uri)
        connection.send(DidChangeTextDocumentNotification(
            textDocument: VersionedTextDocumentIdentifier(uri, version: version),
            contentChanges: [TextDocumentContentChangeEvent(text: text)]
        ))
    }

    func didCloseDocument(url: URL) {
        let uri = DocumentURI(url)
        guard openDocuments.contains(uri) else { return }
        openDocuments.remove(uri)
        documentTexts[uri] = nil
        documentVersions[uri] = nil
        connection.send(DidCloseTextDocumentNotification(textDocument: TextDocumentIdentifier(uri)))
    }

    private func bumpVersion(for uri: DocumentURI) -> Int {
        let version = (documentVersions[uri] ?? 0) + 1
        documentVersions[uri] = version
        return version
    }

    // MARK: Requests

    func definitionLocations(textDocumentURL: URL, position: Position) async throws -> [Location] {
        let response = try await connection.send(DefinitionRequest(
            textDocument: TextDocumentIdentifier(DocumentURI(textDocumentURL)),
            position: position
        ))
        switch response {
        case .locations(let locations):
            return locations
        case .locationLinks(let links):
            // Treat each link's target as a plain location; navigate to the
            // selection range when given, the full target range otherwise.
            return links.map { Location(uri: $0.targetUri, range: $0.targetSelectionRange) }
        case nil:
            return []
        }
    }

    /// Asks for completions. A server answering `null` decodes as an error;
    /// callers treat any throw here as "no completions".
    func completionItems(textDocumentURL: URL, position: Position) async throws -> [CompletionItem] {
        let response = try await connection.send(CompletionRequest(
            textDocument: TextDocumentIdentifier(DocumentURI(textDocumentURL)),
            position: position,
            context: CompletionContext(triggerKind: .invoked)
        ))
        return response.items
    }

    /// Politely shuts the server down: `shutdown` (best effort), `exit`, then
    /// closes the transport and waits for the process off the main thread.
    func shutdown() {
        guard !didTerminate else { return }
        didTerminate = true
        for waiter in readinessWaiters {
            waiter.resumeThrowing(LSPError.serverTerminated)
        }
        readinessWaiters.removeAll()
        let connection = self.connection
        let process = self.process
        let wasReady = isReady
        Task.detached(priority: .utility) {
            if wasReady {
                _ = try? await withTimeout(seconds: 1) {
                    try await connection.send(ShutdownRequest())
                }
                connection.send(ExitNotification())
            }
            // Closing the transport signals EOF; the server should exit on its own.
            connection.close()
            process.waitUntilExit()
        }
    }

    /// Called when the process died on its own.
    func handleTermination() {
        didTerminate = true
        for waiter in readinessWaiters {
            waiter.resumeThrowing(LSPError.serverTerminated)
        }
        readinessWaiters.removeAll()
    }
}

// MARK: - Readiness waiting

/// A single `waitUntilReady` caller. Guards its continuation so it is resumed
/// exactly once, no matter whether readiness, termination, or the deadline wins.
@MainActor
private final class ReadinessWaiter {
    private var continuation: CheckedContinuation<Void, Error>?
    private var started = false

    func awaitResult() async throws {
        precondition(!started, "awaitResult must be awaited once")
        started = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
        }
    }

    func resume() {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }

    func resumeThrowing(_ error: Error) {
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(throwing: error)
    }

    func expire() {
        resumeThrowing(LSPError.startupTimedOut)
    }
}

enum LSPError: Error, CustomStringConvertible {
    case serverTerminated
    case startupTimedOut
    case workspaceClosed

    var description: String {
        switch self {
        case .serverTerminated: "The language server process exited."
        case .startupTimedOut: "The language server did not answer in time."
        case .workspaceClosed: "The workspace closed before the language server started."
        }
    }
}

/// Thrown by `withTimeout` when the deadline wins.
private struct DeadlineExceeded: Error, Sendable {}

/// Runs `operation` but throws when it takes longer than `seconds`.
///
/// When the deadline wins, the operation task is cancelled. LSP requests send
/// `$/cancelRequest`; a server that ignores cancellation can delay task-group
/// teardown beyond the deadline.
func withTimeout<T: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DeadlineExceeded()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
