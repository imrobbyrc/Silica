import AppKit

/// The completion popup: a thin, non-activating panel floating under the caret
/// while the editor keeps keyboard focus. Rows are driven by the text view's
/// key handling (`EditorTextView.onCompletionCommand`).
@MainActor
final class CompletionPanel: NSObject {
    private let panel: NSPanel
    private let tableView: NSTableView
    private let box: NSBox

    private var items: [LSPCompletionItem] = []
    private var selectedIndex = 0
    private var onAccept: ((LSPCompletionItem) -> Void)?

    static let rowHeight: CGFloat = 22
    static let maxVisibleRows = 8
    static let width: CGFloat = 360

    var isVisible: Bool { panel.isVisible }

    init(onAccept: @escaping (LSPCompletionItem) -> Void) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 176),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Code completions")

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = .zero
        tableView.backgroundColor = .clear
        tableView.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("completion"))
        tableView.addTableColumn(column)
        tableView.setAccessibilityElement(true)
        tableView.setAccessibilityRole(.list)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay

        box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 1
        box.cornerRadius = 8
        box.fillColor = .windowBackgroundColor
        box.contentViewMargins = .zero
        box.contentView = scrollView
        panel.contentView = box
        super.init()
        tableView.dataSource = self
        tableView.delegate = self
        self.onAccept = onAccept
    }

    /// Shows `items` under `wordRange` (in the text view's coordinates),
    /// flipping above the caret when there is no room below.
    func show(items: [LSPCompletionItem], wordRange: NSRange, in textView: NSTextView) {
        self.items = items
        selectedIndex = 0
        tableView.reloadData()
        if !items.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }

        let rows = min(items.count, Self.maxVisibleRows)
        let height = CGFloat(rows) * Self.rowHeight + 2
        panel.setContentSize(NSSize(width: Self.width, height: height))

        guard let window = textView.window else {
            close()
            return
        }
        guard let anchor = textView.anchorRect(forCharacterRange: wordRange) else {
            close()
            return
        }
        let tokenRect = textView.convert(anchor, to: nil)
        let screenRect = window.convertToScreen(tokenRect)
        let screen = NSScreen.screens.first { $0.frame.contains(screenRect.origin) }
            ?? window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        var origin = NSPoint(x: screenRect.minX, y: screenRect.minY - height - 4)
        if origin.y < visible.minY {
            origin.y = screenRect.maxY + 4
        }
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - Self.width - 8))
        panel.setFrameOrigin(origin)
        panel.orderFront(nil)
        tableView.scrollRowToVisible(0)
    }

    func close() {
        panel.orderOut(nil)
        items = []
        selectedIndex = 0
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
        tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(selectedIndex)
    }

    func acceptSelected() {
        guard items.indices.contains(selectedIndex) else {
            close()
            return
        }
        onAccept?(items[selectedIndex])
    }
}

extension CompletionPanel: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

extension CompletionPanel: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let cell = NSStackView()
        cell.orientation = .horizontal
        cell.alignment = .centerY
        cell.spacing = 6
        cell.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        let label = NSTextField(labelWithString: item.label)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addArrangedSubview(label)

        if let kindName = item.kindName {
            let kind = NSTextField(labelWithString: kindName)
            kind.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            kind.textColor = .secondaryLabelColor
            cell.addArrangedSubview(kind)
        }

        if let detail = item.detail, !detail.isEmpty {
            let detailField = NSTextField(labelWithString: detail.replacingOccurrences(of: "\n", with: " "))
            detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            detailField.textColor = .tertiaryLabelColor
            detailField.lineBreakMode = .byTruncatingTail
            detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            detailField.setContentHuggingPriority(.defaultLow, for: .horizontal)
            cell.addArrangedSubview(detailField)
        }

        cell.translatesAutoresizingMaskIntoConstraints = false
        cell.setAccessibilityElement(true)
        cell.setAccessibilityRole(.row)
        let kindText = item.kindName.map { " \($0)" } ?? ""
        cell.setAccessibilityLabel("\(item.label)\(kindText)")
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectedIndex = tableView.selectedRow >= 0 ? tableView.selectedRow : 0
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        Self.rowHeight
    }
}
