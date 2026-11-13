import Foundation

import LanguageServerProtocol

/// Maps a `SyntaxLanguage` to the language server that can serve it, and finds
/// that server on disk.
///
/// Servers are never downloaded or installed by Silica. If the server a language
/// needs is not installed, navigation for that language reports what is missing
/// instead of failing silently.
enum LanguageServerRegistry {
    struct ServerSpec {
        /// Human-readable server name for status messages.
        let displayName: String
        /// Executable to look up (e.g. via `xcrun --find` or the login-shell PATH).
        let executableName: String
        /// Arguments always passed to the server.
        let arguments: [String]
        /// The LSP `Language` to report in `textDocument/didOpen`.
        let lspLanguage: Language
    }

    /// The language server mapped for `language`, if Silica supports it yet.
    static func spec(for language: SyntaxLanguage) -> ServerSpec? {
        switch language {
        case .swift:
            ServerSpec(
                displayName: "sourcekit-lsp",
                executableName: "sourcekit-lsp",
                arguments: [],
                lspLanguage: .swift
            )
        case .python:
            ServerSpec(
                displayName: "pyright-langserver",
                executableName: "pyright-langserver",
                arguments: ["--stdio"],
                lspLanguage: .python
            )
        case .javascript, .typescript:
            ServerSpec(
                displayName: "typescript-language-server",
                executableName: "typescript-language-server",
                arguments: ["--stdio"],
                lspLanguage: language == .typescript ? .typeScript : .javaScript
            )
        default:
            nil
        }
    }

    /// Where Silica looked for a server and what it found; `message` explains how
    /// to install the server when it was not found.
    enum Availability {
        case available(executable: URL, arguments: [String])
        case unavailable(message: String)
    }

    private static var availabilityCache: [SyntaxLanguage: Availability] = [:]
    private static var loginPathCache: String?

    /// Resolves the server for `language`, caching the result per language so
    /// repeated navigation requests do not re-run the shell.
    static func availability(for language: SyntaxLanguage) async -> Availability {
        if let cached = availabilityCache[language] { return cached }
        let result = await resolveAvailability(for: language)
        availabilityCache[language] = result
        return result
    }

    private static func resolveAvailability(for language: SyntaxLanguage) async -> Availability {
        guard let spec = spec(for: language) else {
            return .unavailable(message: "Silica has no language server mapped for \(language.rawValue) files.")
        }

        // Testing override: run a specific executable instead of the mapped server.
        // Value: "<executable path> [args…]" (space-separated).
        let overrideKey = "SILICA_LSP_\(language.rawValue.uppercased())_EXEC"
        if let override = ProcessInfo.processInfo.environment[overrideKey], !override.isEmpty {
            let parts = override.split(separator: " ").map(String.init)
            guard let first = parts.first else {
                return .unavailable(message: "\(overrideKey) is empty.")
            }
            return .available(executable: URL(filePath: first), arguments: Array(parts.dropFirst()))
        }

        // sourcekit-lsp ships with the active toolchain; find it with xcrun first.
        if spec.executableName == "sourcekit-lsp" {
            if let line = await runCommand("/bin/xcrun", ["--find", "sourcekit-lsp"]),
               FileManager.default.isExecutableFile(atPath: line) {
                return .available(executable: URL(filePath: line), arguments: [])
            }
            let bundled = URL(filePath: "/usr/bin/sourcekit-lsp")
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return .available(executable: bundled, arguments: [])
            }
            return .unavailable(message: """
                sourcekit-lsp was not found. It ships with Xcode — make sure the \
                Xcode command line tools are selected (`xcode-select -p`).
                """)
        }

        let path = await loginPath()
        if let url = executable(named: spec.executableName, path: path) {
            return .available(executable: url, arguments: spec.arguments)
        }
        return .unavailable(message: """
            \(spec.displayName) was not found on this Mac. Silica does not install \
            language servers; install it yourself (e.g. `npm install -g \(spec.executableName)`) \
            and make sure it is on the PATH of your login shell.
            """)
    }

    /// Runs a command and returns its trimmed output, if it succeeded.
    private static func runCommand(_ executablePath: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.silica.lsp-lookup")
            queue.async {
                let process = Foundation.Process()
                process.executableURL = URL(filePath: executablePath)
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                let line = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (line?.isEmpty ?? true) ? nil : line)
            }
        }
    }

    /// Searches PATH directly; shell interpolation breaks when a directory contains spaces.
    static func executable(named name: String, path: String) -> URL? {
        for directory in path.split(separator: ":") {
            let candidate = URL(filePath: String(directory)).appending(component: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Prefers a project-local uv/venv environment for Python so Pyright resolves
    /// imports from the project's installed dependencies without project config.
    /// shortcut: only a workspace-root `.venv` is auto-selected; add interpreter discovery for other layouts.
    static func environmentPath(for language: SyntaxLanguage, workspaceURL: URL, loginPath: String) -> String {
        guard language == .python else { return loginPath }
        let binURL = workspaceURL.appending(path: ".venv/bin", directoryHint: .isDirectory)
        let interpreterURL = binURL.appending(component: "python")
        guard FileManager.default.isExecutableFile(atPath: interpreterURL.path) else { return loginPath }
        var components = loginPath.split(separator: ":").map(String.init)
        components.removeAll { $0 == binURL.path }
        components.insert(binURL.path, at: 0)
        return components.joined(separator: ":")
    }

    /// The PATH of a login shell, cached for the app's lifetime. Falls back to the
    /// current environment's PATH plus the common install locations.
    static func loginPath() async -> String {
        if let cached = loginPathCache { return cached }
        let base = await runCommand("/bin/zsh", ["-l", "-c", "echo $PATH"])
            ?? ProcessInfo.processInfo.environment["PATH"]
            ?? "/usr/bin:/bin"
        var components = base.split(separator: ":").map(String.init)
        for fallback in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        where !components.contains(fallback) {
            components.append(fallback)
        }
        let joined = components.joined(separator: ":")
        loginPathCache = joined
        return joined
    }
}
