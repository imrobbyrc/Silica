import AppKit
import Foundation
import Observation
import os
import SwiftUI

/// State for one open project window: the explorer tree and the open editor tabs.
@Observable
final class WorkspaceModel {
    let rootURL: URL
    let root: FileNode

    var selection: URL?
    /// The last file asked to be shown in the tree; `revealCount` changes on every
    /// request so the tree scrolls even when the same file is revealed twice.
    private(set) var revealedURL: URL?
    private(set) var revealCount = 0
    var isSidebarVisible = true
    /// What the sidebar shows: the file tree or Find in Project.
    var sidebarMode: SidebarMode = .explorer
    let search: ProjectSearchModel
    /// A rename or new file/folder name being typed in the tree.
    var treeEdit: TreeEdit?

    /// Text in the explorer's filter field; the tree shows only matching names.
    var treeFilter = "" {
        didSet { if treeFilter != oldValue { scheduleTreeFilter() } }
    }
    /// Project-relative paths the filtered tree shows; `nil` when not filtering.
    private(set) var treeFilterResult: TreeFilter.Result?
    /// Bumped to put the cursor in the filter field (⌥⌘J).
    var treeFilterFocusRequest = 0
    @ObservationIgnored private var treeFilterItems: [QuickOpenItem]?
    @ObservationIgnored private var treeFilterTask: Task<Void, Never>?
    private(set) var isQuickOpenVisible = false
    let quickOpen: QuickOpenModel
    private(set) var openTabs: [URL] = [] {
        didSet { scheduleSessionSave() }
    }
    private(set) var activeTab: URL? {
        didSet { scheduleSessionSave() }
    }
    private(set) var buffers: [URL: EditorBuffer] = [:]
    private(set) var gitStateRevision = 0
    private(set) var gitStatusSnapshot = GitStatusSnapshot.empty

    /// The project's terminals, in the order of their tabs. They keep running while
    /// their card is hidden.
    private(set) var terminals: [TerminalSession] = []
    /// The terminal the card shows: one of `terminals`, as long as there are any.
    private(set) var terminal: TerminalSession?
    private(set) var isTerminalVisible = false

    /// The project's window, to bring forward when a file is opened in it from outside.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var isAccessingScope: Bool
    @ObservationIgnored private let standaloneFileURL: URL?
    @ObservationIgnored private var isAccessingStandaloneFile: Bool
    @ObservationIgnored private let persistsSession: Bool
    @ObservationIgnored private var watcher: ProjectWatcher?
    @ObservationIgnored private var gitStatusRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var gitStatusGeneration = 0
    @ObservationIgnored private var terminationObserver: NSObjectProtocol?
    @ObservationIgnored private var isRestoringSession = false
    @ObservationIgnored private var sessionSaveTask: Task<Void, Never>?
    /// The project's language servers, created lazily so a project that never
    /// navigates never launches a server.
    @ObservationIgnored private(set) var lsp: LanguageServerCoordinator?

    private static let logger = Logger(subsystem: "app.silica", category: "workspace")

    var name: String { root.name }

    var activeBuffer: EditorBuffer? {
        activeTab.flatMap { buffers[$0] }
    }

    var hasUnsavedChanges: Bool {
        buffers.values.contains { $0.needsSaving }
    }

    init(rootURL: URL, standaloneFileURL: URL? = nil) {
        self.rootURL = rootURL
        self.isAccessingScope = rootURL.startAccessingSecurityScopedResource()
        self.standaloneFileURL = standaloneFileURL
        self.isAccessingStandaloneFile = standaloneFileURL?.startAccessingSecurityScopedResource() ?? false
        self.persistsSession = standaloneFileURL == nil
        self.root = FileNode(root: rootURL)
        self.quickOpen = QuickOpenModel(rootURL: rootURL)
        self.search = ProjectSearchModel(rootURL: rootURL)
        root.isExpanded = true
        root.loadChildrenIfNeeded()
        search.unsavedTexts = { [weak self] in
            guard let self else { return [:] }
            var texts: [URL: String] = [:]
            for (url, buffer) in self.buffers where buffer.isDirty && !buffer.isUntitled {
                texts[url] = buffer.textController?.textView.string
            }
            return texts
        }
        // Keep the tree and open files in step with changes made by other apps.
        watcher = ProjectWatcher(url: rootURL, onChange: { [weak self] in
            self?.refresh()
        }, onGitChange: { [weak self] in
            guard let self else { return }
            self.gitStateRevision &+= 1
            self.scheduleGitStatusRefresh()
        })
        lsp = LanguageServerCoordinator(rootURL: rootURL)
        scheduleGitStatusRefresh()
        if let standaloneFileURL {
            isSidebarVisible = false
            open(standaloneFileURL)
        } else {
            restoreSession()
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveSession() }
        }
    }

    func close() {
        saveSession()
        // A video left playing would still be heard with its window gone.
        for buffer in buffers.values { buffer.pausePlayback() }
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        watcher?.stop()
        watcher = nil
        gitStatusRefreshTask?.cancel()
        gitStatusRefreshTask = nil
        for terminal in terminals { terminal.close() }
        terminals = []
        terminal = nil
        lsp?.shutdown()
        lsp = nil
        if isAccessingStandaloneFile, let standaloneFileURL {
            standaloneFileURL.stopAccessingSecurityScopedResource()
            isAccessingStandaloneFile = false
        }
        if isAccessingScope {
            rootURL.stopAccessingSecurityScopedResource()
            isAccessingScope = false
        }
    }

    // MARK: Explorer

    func handleSelectionChange() {
        guard let url = selection else { return }
        if url.hasDirectoryPath {
            if let node = node(for: url) { toggleExpansion(of: node) }
        } else {
            open(url)
        }
    }

    func toggleExpansion(of node: FileNode) {
        withAnimation(.snappy(duration: 0.2)) { node.isExpanded.toggle() }
    }

    /// Expands or collapses the selected folder; returns `false` if nothing changed.
    func setSelectedFolderExpanded(_ expanded: Bool) -> Bool {
        guard let url = selection, url.hasDirectoryPath, let node = node(for: url),
              node.isExpanded != expanded else { return false }
        toggleExpansion(of: node)
        return true
    }

    func toggleSidebar() {
        withAnimation(.snappy) { isSidebarVisible.toggle() }
    }

    // MARK: Terminal

    /// ⌃`: shows the terminal and gives it the keyboard. From the terminal, hides it
    /// and goes back to the editor.
    func toggleTerminal() {
        if isTerminalVisible, terminal?.isFocused == true {
            hideTerminal()
        } else {
            showTerminal()
        }
    }

    func showTerminal() {
        let terminal = terminal ?? makeTerminal()
        if !isTerminalVisible {
            withAnimation(.snappy(duration: 0.2)) { isTerminalVisible = true }
        }
        terminal.view.focus()
    }

    /// Hides the card. The shells and whatever runs in them carry on.
    func hideTerminal() {
        guard isTerminalVisible else { return }
        let hadFocus = terminal?.isFocused == true
        withAnimation(.snappy(duration: 0.2)) { isTerminalVisible = false }
        if hadFocus { focusEditor() }
    }

    /// New Terminal (⌃⇧`): another shell, in a tab after the ones there are.
    func newTerminal() {
        makeTerminal()
        showTerminal()
    }

    /// Brings a terminal's tab forward and gives it the keyboard.
    func selectTerminal(_ terminal: TerminalSession) {
        guard terminals.contains(where: { $0 === terminal }) else { return }
        self.terminal = terminal
        showTerminal()
    }

    /// The terminal `offset` tabs along from the one that's showing, going round
    /// from either end to the other.
    func selectTerminal(offsetBy offset: Int) {
        let count = terminals.count
        guard count > 1, let index = terminals.firstIndex(where: { $0 === terminal }) else { return }
        selectTerminal(terminals[((index + offset) % count + count) % count])
    }

    /// Puts a terminal's tab at another place in the row (dragging it there).
    func moveTerminal(_ terminal: TerminalSession, to index: Int) {
        guard let current = terminals.firstIndex(where: { $0 === terminal }) else { return }
        let target = min(max(index, 0), terminals.count - 1)
        guard target != current else { return }
        var moved = terminals
        moved.remove(at: current)
        moved.insert(terminal, at: target)
        terminals = moved
    }

    /// Select Next Tab / Select Previous Tab: through the terminal's tabs when the
    /// terminal has the keyboard and others beside it, and the editor's otherwise.
    func selectTab(offsetBy offset: Int) {
        if terminals.count > 1, isTerminalVisible, terminal?.isFocused == true {
            selectTerminal(offsetBy: offset)
        } else {
            activateTab(offsetBy: offset)
        }
    }

    /// Whether Select Next Tab and Select Previous Tab have another tab to go to.
    var canSelectOtherTab: Bool {
        openTabs.count > 1 || (terminals.count > 1 && isTerminalVisible && terminal?.isFocused == true)
    }

    /// Ends a terminal's shell and closes its tab: the one that's showing, unless
    /// another is named. Its neighbor takes its place; without one the card goes,
    /// and the next ⌃` starts a new shell.
    func closeTerminal(_ closing: TerminalSession? = nil) {
        guard let closing = closing ?? terminal,
              let index = terminals.firstIndex(where: { $0 === closing }) else { return }
        let hadFocus = closing.isFocused
        terminals.remove(at: index)
        if closing === terminal {
            terminal = terminals.isEmpty ? nil : terminals[min(index, terminals.count - 1)]
            if let terminal {
                if hadFocus { terminal.view.focus() }
            } else {
                withAnimation(.snappy(duration: 0.2)) { isTerminalVisible = false }
                if hadFocus { focusEditor() }
            }
        }
        closing.close()
    }

    /// Starts a terminal in a new last tab, and makes it the one the card shows.
    @discardableResult
    private func makeTerminal() -> TerminalSession {
        let terminal = TerminalSession(directory: rootURL)
        // The shell was exited, with "exit" or ⌃D.
        terminal.onExit = { [weak self, weak terminal] in
            if let terminal { self?.closeTerminal(terminal) }
        }
        // Links to files open here, like Quick Open's results.
        terminal.onOpenFile = { [weak self] url, line in
            self?.open(url)
            self?.reveal(url)
            if let line { self?.goToLine(line) }
        }
        terminals.append(terminal)
        self.terminal = terminal
        return terminal
    }

    private func focusEditor() {
        if let textView = activeBuffer?.textController?.textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    // MARK: Sidebar modes

    enum SidebarMode {
        case explorer, search
    }

    func showExplorer() {
        if !isSidebarVisible { toggleSidebar() }
        sidebarMode = .explorer
    }

    /// Find in Project: shows the search sidebar and focuses its field.
    func showSearch() {
        if !isSidebarVisible { toggleSidebar() }
        sidebarMode = .search
        search.focusRequest += 1
    }

    /// Opens a search result with the match selected.
    func openSearchMatch(_ url: URL, range: NSRange) {
        open(url)
        guard let buffer = buffers[url] else { return }
        if buffer.isShowingPreview { buffer.setShowingPreview(false) }
        // Once the editor for the file is in the window.
        DispatchQueue.main.async {
            buffer.textController?.reveal(range)
        }
    }

    // MARK: Go to Definition

    /// Go to Definition (⌘-click or F12): asks the file's language server for the
    /// definition of the symbol at `offset` (default: the caret) and opens it.
    /// Servers are started on demand; if none is installed for the language, a
    /// dialog says so.
    /// Shows a diagnostics range from the Problems popover: leaves any Git
    /// preview, then selects and scrolls to the range.
    func revealDiagnostic(_ diagnostic: LSPDiagnostic, in buffer: EditorBuffer) {
        guard let controller = buffer.textController else { return }
        let text = controller.textView.string as NSString
        if buffer.isShowingPreview {
            buffer.setShowingPreview(false)
        }
        let range = LSPPositionMapper.nsRange(of: diagnostic.range, in: text)
            ?? NSRange(location: 0, length: 0)
        controller.reveal(range)
    }

    func goToDefinition(at offset: Int? = nil, in buffer: EditorBuffer? = nil) {
        guard let buffer = buffer ?? activeBuffer,
              let controller = buffer.textController,
              !buffer.isUntitled else { return }
        let cursor = offset ?? controller.cursorLocation
        let text = controller.textView.string
        let language = SyntaxLanguage(url: buffer.url)
        let sourceURL = buffer.url
        Task { [weak self, weak buffer] in
            guard let self, let buffer, let lsp else { return }
            let outcome = await lsp.definition(in: buffer, atUTF16Offset: cursor, currentText: text)
            guard buffer.url == sourceURL, buffers[sourceURL] === buffer,
                  buffer.textController?.textView.string == text else { return }
            switch outcome {
            case .definition(let target):
                navigate(toDefinition: target, from: buffer)
            case .unavailable(let message):
                showAlert(
                    "No \(language?.displayName ?? "") language server",
                    info: message
                )
            case .noDefinition:
                Self.logger.info("Go to Definition returned no result for \(sourceURL.path, privacy: .public)")
            case .failed(let message):
                Self.logger.error("Go to Definition failed: \(message, privacy: .public)")
            }
        }
    }

    /// Reveals same-file definitions in their source buffer; other files open in
    /// an adjacent tab (reusing an existing tab). Range resolves against current
    /// text, including unsaved edits, and is clamped if it has drifted.
    private func navigate(toDefinition target: LSPDefinitionTarget, from sourceBuffer: EditorBuffer) {
        let destinationURL = target.navigationURL(from: sourceBuffer.url)
        let sameFile = destinationURL == sourceBuffer.url
        let targetText = sameFile
            ? sourceBuffer.textController?.textView.string
            : buffers[target.url]?.textController?.textView.string
                ?? (try? String(contentsOf: target.url, encoding: .utf8))
        let range: NSRange
        if let targetText {
            range = LSPPositionMapper.nsRange(of: target.range, in: targetText as NSString)
                ?? NSRange(location: 0, length: 0)
        } else {
            range = NSRange(location: 0, length: 0)
        }
        openSearchMatch(destinationURL, range: range)
    }

    // MARK: Quick Open

    func toggleQuickOpen() {
        if isQuickOpenVisible {
            hideQuickOpen()
        } else {
            showQuickOpen(query: "")
        }
    }

    /// Go to Line (⌘L): Quick Open with ":" typed, as in VS Code.
    func showGoToLine() {
        guard activeBuffer?.textController != nil else { return }
        showQuickOpen(query: ":")
    }

    private func showQuickOpen(query: String) {
        quickOpen.prepareForPresentation(activeFile: activeTab, query: query)
        if !isQuickOpenVisible {
            withAnimation(.snappy(duration: 0.18)) { isQuickOpenVisible = true }
        }
    }

    /// Lines in the active file, for the Go to Line prompt.
    var activeLineCount: Int? {
        activeBuffer?.textController?.lineCount
    }

    func goToLineFromQuickOpen(_ line: Int) {
        hideQuickOpen()
        goToLine(line)
    }

    private func goToLine(_ line: Int) {
        guard let buffer = activeBuffer, let controller = buffer.textController else { return }
        if buffer.isShowingPreview { buffer.setShowingPreview(false) }
        DispatchQueue.main.async { controller.goToLine(line) }
    }

    func hideQuickOpen() {
        guard isQuickOpenVisible else { return }
        withAnimation(.snappy(duration: 0.18)) { isQuickOpenVisible = false }
        // Give typing focus back to the editor.
        if let textView = activeBuffer?.textController?.textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    /// Opens a Quick Open result; "name:42" also jumps to line 42.
    func openFromQuickOpen(_ url: URL, line: Int? = nil) {
        hideQuickOpen()
        open(url)
        reveal(url)
        if let line { goToLine(line) }
    }

    /// Expands the folders above `url` so its row exists, selects it and asks the
    /// tree to scroll to it.
    func reveal(_ url: URL) {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return }
        var current = root
        for name in components.dropFirst(rootComponents.count).dropLast() {
            var next = current.children?.first { $0.name == name }
            if next == nil {
                // The folder may have appeared since the tree last read the disk.
                current.reload()
                next = current.children?.first { $0.name == name }
            }
            guard let folder = next, folder.isDirectory else { return }
            if !folder.isExpanded { folder.isExpanded = true }
            current = folder
        }
        if current.children?.contains(where: { $0.url == url }) == false {
            current.reload()
        }
        selection = url
        revealedURL = url
        revealCount += 1
    }

    /// Whether `url` is inside the project folder, where the tree can show it. A
    /// tab can be outside it after Save As.
    func contains(_ url: URL) -> Bool {
        url.isFileURL && url.standardizedFileURL.pathComponents.dropLast()
            .starts(with: rootURL.standardizedFileURL.pathComponents)
    }

    /// Reveal in Explorer, from a tab's menu: `reveal`, after bringing the tree
    /// into view and clearing a filter that hides the file.
    func revealInTree(_ url: URL) {
        // The tree's selection is the active tab, and the tree isn't there to
        // open what's selected in it while the sidebar is hidden.
        activate(url)
        showExplorer()
        if isFilteringTree, treeFilterResult?.visiblePaths.contains(relativePath(of: url)) != true {
            treeFilter = ""
        }
        reveal(url)
    }

    /// Re-reads the tree and checks open files against the disk.
    func refresh() {
        root.reload()
        FolderIcons.shared.reload()
        syncOpenFilesWithDisk()
        search.refresh()
        scheduleGitStatusRefresh()
        // Files may have come or gone: filter a fresh list.
        treeFilterItems = nil
        if treeFilterResult != nil { scheduleTreeFilter(after: .milliseconds(300)) }
    }

    private func scheduleGitStatusRefresh() {
        gitStatusGeneration &+= 1
        let generation = gitStatusGeneration
        let rootURL = self.rootURL
        gitStatusRefreshTask?.cancel()
        gitStatusRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let snapshot = await GitDiffService.status(rootURL: rootURL)
            guard let self, !Task.isCancelled, self.gitStatusGeneration == generation else { return }
            self.gitStatusSnapshot = snapshot
        }
    }

    // MARK: Tree filter

    var isFilteringTree: Bool {
        !treeFilter.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Filter Files (⌥⌘J): shows the explorer and focuses its filter field.
    func focusTreeFilter() {
        showExplorer()
        treeFilterFocusRequest += 1
    }

    private func scheduleTreeFilter(after delay: Duration = .milliseconds(120)) {
        treeFilterTask?.cancel()
        let query = treeFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            treeFilterResult = nil
            return
        }
        let root = rootURL
        let cached = treeFilterItems
        treeFilterTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let (items, result) = await Task.detached(priority: .userInitiated) {
                let items = cached ?? ProjectFileIndex.scan(root: root)
                return (items, TreeFilter.filter(items, by: query))
            }.value
            guard let self, !Task.isCancelled else { return }
            self.treeFilterItems = items
            self.loadFolders(in: result.visiblePaths)
            self.treeFilterResult = result
        }
    }

    /// Reads the folders a filtered tree passes through, without expanding them, so
    /// clearing the filter brings back the tree as it was.
    private func loadFolders(in paths: Set<String>) {
        for path in paths.sorted(by: { $0.count < $1.count }) {
            var current = root
            for name in path.split(separator: "/") {
                current.loadChildrenIfNeeded()
                guard let next = current.children?.first(where: { $0.name == name }) else { break }
                current = next
            }
            if current.isDirectory { current.loadChildrenIfNeeded() }
        }
    }

    private func syncOpenFilesWithDisk() {
        for url in openTabs {
            guard let buffer = buffers[url], buffer.syncWithDisk() else { continue }
            // An image or other non-text file changed: read it again.
            lsp?.documentDidClose(url: url)
            buffers[url] = makeBuffer(for: url)
        }
    }

    func collapseAll() {
        root.collapseAll()
    }

    func relativePath(of url: URL) -> String {
        let rootPath = rootURL.path(percentEncoded: false).trimmingTrailingSlash
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func node(for url: URL) -> FileNode? {
        let rootComponents = rootURL.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { return nil }
        var current = root
        for name in components.dropFirst(rootComponents.count) {
            guard let next = current.children?.first(where: { $0.name == name }) else { return nil }
            current = next
        }
        return current
    }

    // MARK: Tabs

    func open(_ url: URL) {
        if buffers[url] == nil {
            buffers[url] = makeBuffer(for: url)
        }
        if !openTabs.contains(url) {
            // Keep the source tab and place newly opened targets beside it.
            if let active = activeTab, let index = openTabs.firstIndex(of: active) {
                openTabs.insert(url, at: index + 1)
            } else {
                openTabs.append(url)
            }
        }
        activate(url)
    }

    private func makeBuffer(for url: URL) -> EditorBuffer {
        let buffer = EditorBuffer(url: url)
        buffer.projectURL = rootURL
        // Links in a preview open other project files here, like Quick Open.
        buffer.openFile = { [weak self] target in
            self?.open(target)
            self?.reveal(target)
        }
        if let controller = buffer.textController {
            // Tell the language server about edits; debounced by the coordinator.
            controller.textDidChangeHandler = { [weak self, weak buffer] in
                guard let buffer else { return }
                buffer.noteTextDidChange()
                self?.lsp?.documentDidChange(buffer)
            }
            // ⌘-click goes to definition.
            controller.textView.onCommandClick = { [weak self, weak buffer] offset in
                guard let buffer else { return }
                self?.goToDefinition(at: offset, in: buffer)
            }
            controller.textView.onCommandDefinitionCheck = { [weak self, weak buffer] offset in
                guard let self, let buffer, !buffer.isUntitled,
                      let controller = buffer.textController,
                      let lsp = self.lsp else { return false }
                let outcome = await lsp.definition(
                    in: buffer,
                    atUTF16Offset: offset,
                    currentText: controller.textView.string
                )
                if case .definition = outcome { return true }
                return false
            }
            // ⌘Space completion candidates at a UTF-16 offset.
            controller.completionProvider = { [weak self, weak buffer] offset in
                guard let self, let buffer, !buffer.isUntitled,
                      let controller = buffer.textController else { return [] }
                return await self.lsp?.completions(in: buffer, atUTF16Offset: offset,
                                                   currentText: controller.textView.string) ?? []
            }
        }
        // Announce the file to its language server (no-op for unmapped languages;
        // Command-hover requests a definition before showing the hand cursor).
        lsp?.documentDidOpen(buffer)
        return buffer
    }

    func activate(_ url: URL) {
        activeTab = url
        // An untitled file has no row in the tree or place in Quick Open.
        if url.isUntitled {
            selection = nil
            return
        }
        quickOpen.noteOpened(url)
        if selection != url {
            selection = url
        }
    }

    /// Select Next Tab / Select Previous Tab: the tab `offset` places along the bar from the
    /// active one, going round from either end to the other.
    func activateTab(offsetBy offset: Int) {
        let count = openTabs.count
        guard count > 1, let activeTab, let index = openTabs.firstIndex(of: activeTab) else { return }
        activate(openTabs[((index + offset) % count + count) % count])
    }

    /// New File (⌘N): an empty "Untitled-N" tab, saved somewhere only when asked.
    func newUntitledFile() {
        let taken = Set(openTabs.filter(\.isUntitled).map(\.lastPathComponent))
        var number = 1
        while taken.contains("Untitled-\(number)") { number += 1 }
        let buffer = EditorBuffer(untitledName: "Untitled-\(number)")
        buffers[buffer.url] = buffer
        if let active = activeTab, let index = openTabs.firstIndex(of: active) {
            openTabs.insert(buffer.url, at: index + 1)
        } else {
            openTabs.append(buffer.url)
        }
        activate(buffer.url)
    }

    /// Puts a tab at another place in the tab bar (dragging it there).
    func moveTab(_ url: URL, to index: Int) {
        guard let current = openTabs.firstIndex(of: url) else { return }
        let target = min(max(index, 0), openTabs.count - 1)
        guard target != current else { return }
        var tabs = openTabs
        tabs.remove(at: current)
        tabs.insert(url, at: target)
        openTabs = tabs
    }

    func closeActiveTab() {
        if let activeTab { closeTab(activeTab) }
    }

    func closeOtherTabs(than url: URL) {
        for other in openTabs where other != url {
            closeTab(other)
        }
    }

    func closeTab(_ url: URL) {
        guard let index = openTabs.firstIndex(of: url) else { return }
        if let buffer = buffers[url], buffer.needsSaving, !confirmDiscardOrSave(buffer) {
            return
        }

        openTabs.remove(at: index)
        buffers[url] = nil
        lsp?.documentDidClose(url: url)

        if activeTab == url {
            if openTabs.isEmpty {
                activeTab = nil
                selection = nil
            } else {
                activate(openTabs[min(index, openTabs.count - 1)])
            }
        }
    }

    // MARK: File operations

    enum TreeEdit: Equatable {
        case rename(URL)
        case create(in: URL, isDirectory: Bool)
    }

    /// Starts naming a new file or folder in the tree: inside the selected folder,
    /// next to the selected file, or at the top of the project.
    func beginNewItem(isDirectory: Bool, in folder: URL? = nil) {
        let target = folder ?? selection.map { $0.hasDirectoryPath ? $0 : $0.deletingLastPathComponent() } ?? rootURL
        let node = node(for: target) ?? root
        if !node.isExpanded { node.isExpanded = true }
        showExplorer()
        treeEdit = .create(in: node.url, isDirectory: isDirectory)
    }

    func beginRename(_ url: URL) {
        showExplorer()
        treeEdit = .rename(url)
    }

    func cancelTreeEdit() {
        treeEdit = nil
    }

    /// Creates the file or folder named in the tree. A name with slashes creates the
    /// folders in between, as in VS Code.
    func createItem(named rawName: String, in folder: URL, isDirectory: Bool) {
        treeEdit = nil
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let url = Self.normalized(folder.appending(path: name), isDirectory: isDirectory)
        guard !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            showAlert("“\(url.lastPathComponent)” already exists.", info: "Choose a different name.")
            return
        }
        do {
            let fileManager = FileManager.default
            if isDirectory {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        refresh()
        reveal(url)
        if !isDirectory { open(url) }
    }

    /// Renames in place; open tabs for the item (or anything inside a renamed folder)
    /// follow it, keeping their edits.
    func rename(_ url: URL, to rawName: String) {
        treeEdit = nil
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        guard !name.contains("/"), !name.contains(":") else {
            showAlert("“\(name)” can’t be used as a name.", info: "Names can’t contain “/” or “:”.")
            return
        }
        let isDirectory = url.hasDirectoryPath
        let destination = Self.normalized(url.deletingLastPathComponent().appending(path: name), isDirectory: isDirectory)
        // A case-only change is the same file on a case-insensitive disk.
        let isCaseChange = name.lowercased() == url.lastPathComponent.lowercased()
        guard isCaseChange || !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            showAlert("“\(name)” already exists.", info: "Choose a different name.")
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: destination)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        retargetBuffers(from: url, to: destination)
        refresh()
        reveal(destination)
    }

    /// Copies the item next to itself as "name copy", like Finder.
    func duplicate(_ url: URL) {
        let isDirectory = url.hasDirectoryPath
        let folder = url.deletingLastPathComponent()
        let ext = isDirectory ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var copy: URL
        var number = 1
        repeat {
            let suffix = number == 1 ? " copy" : " copy \(number)"
            let name = base + suffix + (ext.isEmpty ? "" : "." + ext)
            copy = Self.normalized(folder.appending(path: name), isDirectory: isDirectory)
            number += 1
        } while FileManager.default.fileExists(atPath: copy.path(percentEncoded: false))
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        refresh()
        reveal(copy)
    }

    /// Moves the item to the Trash. Unedited tabs for it close; edited ones stay
    /// open, marked as deleted, so nothing typed is lost.
    func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        for tab in openTabs where Self.url(tab, isInside: url) && buffers[tab]?.isDirty != true {
            closeTab(tab)
        }
        if let selection, Self.url(selection, isInside: url) { self.selection = nil }
        refresh()
    }

    /// Save As (⇧⌘S): writes the text to a new file, which takes the tab's place. The
    /// original file keeps what was last saved.
    func saveActiveAs() {
        guard let buffer = activeBuffer, buffer.textController != nil,
              let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        let panel = savePanel(for: buffer)
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.save(buffer, as: url)
        }
    }

    /// Starts in the file's folder, or the project for an untitled file.
    private func savePanel(for buffer: EditorBuffer) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.directoryURL = buffer.isUntitled ? rootURL : buffer.url.deletingLastPathComponent()
        panel.nameFieldStringValue = buffer.name
        panel.canCreateDirectories = true
        return panel
    }

    /// The second half of Save As, once a destination is chosen. Returns `true` if
    /// the file was written.
    @discardableResult
    func save(_ buffer: EditorBuffer, as url: URL) -> Bool {
        let destination = Self.normalized(url, isDirectory: false)
        let source = buffer.url
        guard destination != source else {
            return save(buffer)
        }
        do {
            try buffer.write(to: destination)
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        // A tab already open on the destination now shows stale text; drop it.
        if buffers[destination] != nil {
            openTabs.removeAll { $0 == destination }
            lsp?.documentDidClose(url: destination)
            buffers[destination] = nil
        }
        buffers[source] = nil
        lsp?.documentDidClose(url: source)
        buffers[destination] = makeBuffer(for: destination)
        if let index = openTabs.firstIndex(of: source) {
            openTabs[index] = destination
        } else {
            openTabs.append(destination)
        }
        activate(destination)
        refresh()
        reveal(destination)
        return true
    }

    /// Points tabs at their new location after a rename.
    private func retargetBuffers(from old: URL, to new: URL) {
        let oldPath = old.path(percentEncoded: false).trimmingTrailingSlash
        let newPath = new.path(percentEncoded: false).trimmingTrailingSlash
        func moved(_ url: URL) -> URL? {
            let path = url.path(percentEncoded: false)
            guard path == oldPath || path.hasPrefix(oldPath + "/") else { return nil }
            return Self.normalized(URL(filePath: newPath + path.dropFirst(oldPath.count)), isDirectory: url.hasDirectoryPath)
        }
        for (url, buffer) in buffers {
            guard let target = moved(url) else { continue }
            buffers[url] = nil
            buffers[target] = buffer
            buffer.move(to: target)
            // The server sees a rename as closing the old file and opening the new one.
            lsp?.documentDidClose(url: url)
            lsp?.documentDidOpen(buffer)
        }
        openTabs = openTabs.map { moved($0) ?? $0 }
        if let activeTab, let target = moved(activeTab) { self.activeTab = target }
        if let selection, let target = moved(selection) { self.selection = target }
        quickOpen.noteMoved { moved($0) }
    }

    /// The tree's form of a URL: a plain file path, with a trailing slash for folders.
    private static func normalized(_ url: URL, isDirectory: Bool) -> URL {
        // Not `standardizedFileURL`: it turns /private/tmp into /tmp, and the tree keeps
        // paths as listed.
        URL(filePath: url.path(percentEncoded: false).trimmingTrailingSlash,
            directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    private static func url(_ url: URL, isInside container: URL) -> Bool {
        let path = url.path(percentEncoded: false).trimmingTrailingSlash
        let containerPath = container.path(percentEncoded: false).trimmingTrailingSlash
        return path == containerPath || path.hasPrefix(containerPath + "/")
    }

    private func showAlert(_ message: String, info: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = info
        alert.runModal()
    }

    // MARK: Session

    /// Reopens the tabs the project had last time, with their cursor and scroll
    /// positions (unless turned off in Settings).
    private func restoreSession() {
        guard EditorSettings.shared.restoresTabs,
              let session = ProjectSessionStore.session(for: rootURL) else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }

        isSidebarVisible = session.isSidebarVisible
        for tab in session.tabs {
            let url = sessionURL(for: tab.path)
            var isDirectory: ObjCBool = false
            guard !openTabs.contains(url),
                  FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let buffer = makeBuffer(for: url)
            buffers[url] = buffer
            openTabs.append(url)
            buffer.textController?.restorePosition(cursor: tab.cursor, topLine: tab.topLine)
        }
        let active = session.activeTab.map(sessionURL(for:)).flatMap { openTabs.contains($0) ? $0 : nil } ?? openTabs.first
        if let active {
            activate(active)
            reveal(active)
        }
    }

    /// Remembers the open tabs; called on changes (batched), on close and on quit.
    func saveSession() {
        guard persistsSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = nil
        // Untitled tabs have nothing on disk to reopen.
        let tabs = openTabs.filter { !$0.isUntitled }.map { url in
            let controller = buffers[url]?.textController
            return ProjectSession.Tab(
                path: relativePath(of: url),
                cursor: controller?.cursorLocation,
                topLine: controller?.savedTopLine
            )
        }
        let session = ProjectSession(
            tabs: tabs,
            activeTab: activeTab.flatMap { $0.isUntitled ? nil : relativePath(of: $0) },
            isSidebarVisible: isSidebarVisible,
            savedAt: .now
        )
        ProjectSessionStore.save(session, for: rootURL)
    }

    private func scheduleSessionSave() {
        guard persistsSession, !isRestoringSession else { return }
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSession()
        }
    }

    /// A saved path: relative to the project, or absolute.
    private func sessionURL(for path: String) -> URL {
        let absolute = path.hasPrefix("/") ? path : rootURL.path(percentEncoded: false).trimmingTrailingSlash + "/" + path
        return URL(filePath: absolute, directoryHint: .notDirectory)
    }

    // MARK: Saving

    func saveActive() {
        guard let buffer = activeBuffer else { return }
        if buffer.isUntitled {
            saveActiveAs()
        } else {
            save(buffer)
        }
    }

    /// Saves every edited file. Untitled ones are left for their own Save, since each
    /// needs a name.
    func saveAll() {
        for buffer in buffers.values where buffer.isDirty && !buffer.isUntitled {
            save(buffer)
        }
    }

    @discardableResult
    private func save(_ buffer: EditorBuffer) -> Bool {
        // Untitled: ask where, in a panel of its own (this runs inside other prompts).
        if buffer.isUntitled {
            let panel = savePanel(for: buffer)
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            return save(buffer, as: url)
        }
        if case .modified = buffer.diskChange(), !confirmOverwrite(buffer) {
            return false
        }
        do {
            try buffer.save()
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    /// The file changed on disk while it had unsaved edits here. Returns `true` to
    /// write Silica's version over it.
    private func confirmOverwrite(_ buffer: EditorBuffer) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(buffer.name)” was changed by another app."
        alert.informativeText = "Saving replaces those changes with yours. Revert discards your unsaved edits and shows the file as it is on disk (you can undo it)."
        alert.addButton(withTitle: "Save Anyway")
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            buffer.revertToDisk()
            return false
        default:
            return false
        }
    }

    /// Returns `true` if the tab may be closed.
    private func confirmDiscardOrSave(_ buffer: EditorBuffer) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to “\(buffer.name)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        addDontSaveButton(to: alert)
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(buffer)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    // MARK: Closing the window

    /// Edited files, in tab order.
    var unsavedBuffers: [EditorBuffer] {
        openTabs.compactMap { buffers[$0] }.filter(\.needsSaving)
    }

    /// Asks, in a sheet on `window`, whether to save edited files before the window
    /// closes or the app quits. `completion(true)` means go ahead: everything was
    /// saved, or the user chose not to save.
    func confirmClosing(in window: NSWindow, completion: @escaping (Bool) -> Void) {
        let unsaved = unsavedBuffers
        guard !unsaved.isEmpty else {
            completion(true)
            return
        }
        hideQuickOpen()

        let alert = NSAlert()
        if unsaved.count == 1 {
            alert.messageText = "Do you want to save the changes you made to “\(unsaved[0].name)”?"
            alert.informativeText = "Your changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save")
        } else {
            alert.messageText = "Do you want to save the changes you made to \(unsaved.count) files in “\(name)”?"
            let names = unsaved.prefix(5).map(\.name).formatted(.list(type: .and))
            let more = unsaved.count > 5 ? " and \(unsaved.count - 5) more" : ""
            alert.informativeText = "\(names)\(more)\n\nYour changes will be lost if you don’t save them."
            alert.addButton(withTitle: "Save All")
        }
        addDontSaveButton(to: alert)
        alert.addButton(withTitle: "Cancel")

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return completion(true) }
            switch response {
            case .alertFirstButtonReturn:
                // Stop at the first file that fails to save (or whose save is cancelled).
                let saved = unsaved.allSatisfy { !$0.needsSaving || self.save($0) }
                completion(saved)
            case .alertSecondButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    private func addDontSaveButton(to alert: NSAlert) {
        let button = alert.addButton(withTitle: "Don’t Save")
        button.keyEquivalent = "d"
        button.keyEquivalentModifierMask = .command
    }
}
