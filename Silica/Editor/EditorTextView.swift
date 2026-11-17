import AppKit

/// The editor's text view: an NSTextView that also draws indent guides.
///
/// Guides are thin vertical lines at each indentation level, drawn behind the text
/// (TextKit 2 renders text in layers above the view's own drawing). A line indented
/// by N columns gets a guide at columns 0, unit, 2·unit… below N, so the lines inside
/// a block show a guide at the column of the line that opened it. Blank lines borrow
/// their indent from the nearest non-blank lines, as VS Code does (see `blankLineIndent`),
/// so guides run through blank lines inside a block, including right after its opening
/// line, but stop where the block ends.
final class EditorTextView: NSTextView {
    /// Columns a tab advances (a setting); the paragraph style sets tab stops to match.
    static var tabWidth: Int { EditorSettings.shared.tabWidth }

    var showsIndentGuides = EditorSettings.shared.showsIndentGuides {
        didSet { needsDisplay = true }
    }

    /// How the file indents, detected from the text when it opens or reloads.
    struct Indentation: Equatable {
        var usesTabs: Bool
        /// Columns per level: 2, 4 or 8, or the tab width for tabs.
        var width: Int

        /// The text one level of indentation inserts.
        var unitString: String { usesTabs ? "\t" : String(repeating: " ", count: width) }
    }

    /// The language being edited, for comment markers and block-opening `:`.
    var language: SyntaxLanguage?
    /// Inserted by Return; matches the file (`\n` or `\r\n`).
    var lineEnding = "\n"

    private var cachedIndentation: Indentation?

    var indentation: Indentation {
        if let cachedIndentation { return cachedIndentation }
        let detected = Self.detectIndentation(in: (textStorage?.string ?? "") as NSString)
        cachedIndentation = detected
        return detected
    }

    /// Detects the indentation again; it's otherwise kept from when the file opened,
    /// as in VS Code, so editing doesn't flip it.
    func redetectIndentation() {
        cachedIndentation = nil
    }

    override func didChangeText() {
        cancelCommandHoverRequest()
        super.didChangeText()
        // Guides follow the text, so any edit can move them.
        setNeedsDisplay(visibleRect)
    }

    // MARK: Command-click (go to definition)

    /// Called with the clicked UTF-16 offset when the user ⌘-clicks; the workspace
    /// wires this up to go-to-definition. When set, ⌘-clicks don't move the caret.
    var onCommandClick: ((Int) -> Void)?
    /// Resolves the identifier under ⌘-hover; hand cursor appears only on a definition.
    var onCommandDefinitionCheck: ((Int) async -> Bool)?
    /// Returns lexical identifier candidate containing a UTF-16 offset.
    var commandLinkRangeAt: ((Int) -> NSRange?)?
    private var commandHoverRange: NSRange?
    private var commandHoverCandidateRange: NSRange?
    private var commandHoverRequestTask: Task<Void, Never>?
    private var commandHoverGeneration = 0
    private var commandTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let commandTrackingArea { removeTrackingArea(commandTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(trackingArea)
        commandTrackingArea = trackingArea
    }

    override func mouseMoved(with event: NSEvent) {
        updateCommandHover(at: event.locationInWindow, modifiers: event.modifierFlags)
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        super.cursorUpdate(with: event)
        updateCommandHover(at: event.locationInWindow, modifiers: event.modifierFlags)
    }

    override func mouseEntered(with event: NSEvent) {
        updateCommandHover(at: event.locationInWindow, modifiers: event.modifierFlags)
        super.mouseEntered(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        cancelCommandHoverRequest()
        NSCursor.arrow.set()
        super.mouseExited(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        updateCommandHover(at: event.locationInWindow, modifiers: event.modifierFlags)
        super.flagsChanged(with: event)
    }

    private func updateCommandHover(at windowPoint: NSPoint, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command),
              let offset = utf16Offset(atClick: convert(windowPoint, from: nil)),
              let range = commandLinkRangeAt?(offset),
              let resolveDefinition = onCommandDefinitionCheck else {
            cancelCommandHoverRequest()
            return
        }

        if range == commandHoverCandidateRange {
            (commandHoverRange == range ? NSCursor.pointingHand : .iBeam).set()
            return
        }

        cancelCommandHoverRequest()
        commandHoverCandidateRange = range
        commandHoverGeneration += 1
        let generation = commandHoverGeneration
        let currentText = string
        commandHoverRequestTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let hasDefinition = await resolveDefinition(offset)
            guard let self,
                  !Task.isCancelled,
                  self.commandHoverGeneration == generation,
                  self.commandHoverCandidateRange == range,
                  self.string == currentText else { return }
            self.commandHoverRequestTask = nil
            self.setCommandHoverRange(hasDefinition ? range : nil)
            (hasDefinition ? NSCursor.pointingHand : .iBeam).set()
        }
    }

    private func cancelCommandHoverRequest() {
        commandHoverGeneration += 1
        commandHoverRequestTask?.cancel()
        commandHoverRequestTask = nil
        commandHoverCandidateRange = nil
        setCommandHoverRange(nil)
        NSCursor.iBeam.set()
    }

    private func setCommandHoverRange(_ range: NSRange?) {
        guard range != commandHoverRange else { return }
        commandHoverRange = range
        setNeedsDisplay(visibleRect)
    }

    override func mouseDown(with event: NSEvent) {
        // A click moves the caret; the completion list is anchored to it.
        _ = onCompletionCommand?(.cancel)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command), let onCommandClick,
           let offset = utf16Offset(atClick: convert(event.locationInWindow, from: nil)),
           commandLinkRangeAt?(offset) != nil {
            onCommandClick(offset)
            return
        }
        super.mouseDown(with: event)
    }

    // MARK: Completion commands

    /// An editing command routed to the completion panel while it is visible.
    enum EditingCommand {
        case moveUp
        case moveDown
        case accept
        case cancel
        /// Backspace: the panel closes, the editor still performs the deletion.
        case delete
    }

    /// Toggled by ⌘Space; the text controller answers it.
    var onCompletionTrigger: (() -> Void)?
    /// Asks the completion panel to consume a command while it is visible;
    /// `true` means handled and the view skips its own behavior.
    var onCompletionCommand: ((EditingCommand) -> Bool)?

    // MARK: Word ranges

    /// The typed prefix ending at `offset`, including an empty range at word boundaries.
    /// Word characters match the coordinator's prefix rule: alphanumerics, `_`, `$`.
    func wordRange(at offset: Int) -> NSRange? {
        let text = string as NSString
        guard offset >= 0, offset <= text.length else { return nil }
        var start = offset
        while start > 0, Self.isWordCharacter(text.character(at: start - 1)) {
            start -= 1
        }
        return NSRange(location: start, length: offset - start)
    }

    static func isWordCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }

    // MARK: Completion trigger and keys

    /// ⌘Space toggles completions. Spotlight owns that shortcut system-wide and
    /// may swallow it before the app sees it; Ctrl+Space stays free for input sources.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 49 /* space */,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onCompletionTrigger?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func moveUp(_ sender: Any?) {
        if onCompletionCommand?(.moveUp) == true { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if onCompletionCommand?(.moveDown) == true { return }
        super.moveDown(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if onCompletionCommand?(.cancel) == true { return }
        super.cancelOperation(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        // The panel closes on deletion; the handler returns false so the
        // deletion itself still runs.
        _ = onCompletionCommand?(.delete)
        super.deleteBackward(sender)
    }

    /// Maps a click in view coordinates to the nearest UTF-16 insertion offset.
    func utf16Offset(atClick point: NSPoint) -> Int? {
        let offset = characterIndexForInsertion(at: point)
        return offset == NSNotFound ? nil : offset
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if let commandHoverRange {
            drawCommandHover(range: commandHoverRange, in: dirtyRect)
        }
        if showsIndentGuides {
            drawIndentGuides(in: dirtyRect)
        }
    }

    /// Draw the cue instead of mutating text storage or changing document attributes.
    private func drawCommandHover(range: NSRange, in dirtyRect: NSRect) {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              range.length > 0,
              NSMaxRange(range) <= (textStorage?.length ?? 0) else { return }
        let documentStart = layoutManager.documentRange.location
        guard let location = contentManager.location(documentStart, offsetBy: range.location),
              let fragment = layoutManager.textLayoutFragment(for: location) else { return }
        let fragmentOffset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
        let scale = window?.backingScaleFactor ?? 2
        NSColor.linkColor.setStroke()
        for line in fragment.textLineFragments {
            let lineRange = NSRange(
                location: fragmentOffset + line.characterRange.location,
                length: line.characterRange.length
            )
            let intersection = NSIntersectionRange(range, lineRange)
            guard intersection.length > 0 else { continue }
            let lineStart = intersection.location - lineRange.location
            let lineEnd = NSMaxRange(intersection) - lineRange.location
            let start = line.locationForCharacter(at: lineStart)
            let end = line.locationForCharacter(at: lineEnd)
            let x1 = textContainerOrigin.x + fragment.layoutFragmentFrame.minX + start.x
            let x2 = textContainerOrigin.x + fragment.layoutFragmentFrame.minX + end.x
            let y = textContainerOrigin.y + fragment.layoutFragmentFrame.minY
                + line.typographicBounds.maxY - 1 / scale
            let rect = NSRect(x: min(x1, x2), y: y, width: abs(x2 - x1), height: 1 / scale)
            guard rect.intersects(dirtyRect) else { continue }
            let path = NSBezierPath()
            path.lineWidth = 1 / scale
            path.move(to: NSPoint(x: x1, y: y))
            path.line(to: NSPoint(x: x2, y: y))
            path.stroke()
        }
    }

    // MARK: Gutter mask

    private var gutterMask: CALayer?

    /// Hides everything left of `minX` (in this view's coordinates): the part of the
    /// text under the line-number gutter when scrolled sideways.
    func maskOutGutter(startingAt minX: CGFloat) {
        guard let layer else { return }
        guard minX > 0 else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let mask = gutterMask ?? {
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            gutterMask = mask
            return mask
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = CGRect(x: minX, y: 0, width: max(0, bounds.width - minX), height: bounds.height)
        CATransaction.commit()
        if layer.mask !== mask { layer.mask = mask }
    }

    // MARK: Drawing

    private func drawIndentGuides(in dirtyRect: NSRect) {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager,
              let storage = textStorage, storage.length > 0,
              let font else { return }

        let text = storage.string as NSString
        let unit = indentation.width
        let charWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        let origin = textContainerOrigin
        let baseX = origin.x + (textContainer?.lineFragmentPadding ?? 0)
        let scale = window?.backingScaleFactor ?? 2
        let documentStart = layoutManager.documentRange.location
        let top = CGPoint(x: 0, y: max(0, dirtyRect.minY - origin.y))
        let start = layoutManager.textLayoutFragment(for: top)?.rangeInElement.location ?? documentStart

        SyntaxTheme.indentGuide.setFill()
        var previousIndent: Int?

        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY + origin.y <= dirtyRect.maxY else { return false }

            let offset = contentManager.offset(from: documentStart, to: fragment.rangeInElement.location)
            let indent: Int
            if let own = Self.indent(ofLineAt: offset, in: text) {
                indent = own
                previousIndent = own
            } else {
                indent = Self.blankLineIndent(
                    above: previousIndent ?? Self.indentOfNonBlankLine(before: offset, in: text),
                    below: Self.indentOfNonBlankLine(after: offset, in: text),
                    unit: unit
                )
            }

            let guides = (indent + unit - 1) / unit
            for level in 0..<guides {
                let x = (baseX + CGFloat(level * unit) * charWidth) * scale
                NSRect(x: x.rounded() / scale, y: origin.y + frame.minY, width: 1, height: frame.height).fill()
            }
            return true
        }
    }

    // MARK: Indentation

    /// One level deeper than the shallower neighbor, but no deeper than the deeper one:
    /// a blank line after `{` joins the block it opens, one between two lines of a block
    /// keeps its depth, and one after `}` before less-indented code drops out.
    private static func blankLineIndent(above: Int?, below: Int?, unit: Int) -> Int {
        guard let above, let below else { return 0 }
        if above == below { return below }
        return min(min(above, below) + unit, max(above, below))
    }

    /// Indent of the line starting at `offset` in columns, or `nil` for a blank line.
    private static func indent(ofLineAt offset: Int, in text: NSString) -> Int? {
        var column = 0
        var index = offset
        while index < text.length {
            switch text.character(at: index) {
            case 0x20: column += 1
            case 0x09: column += tabWidth - column % tabWidth
            case 0x0A, 0x0D: return nil
            default: return column
            }
            index += 1
        }
        return nil
    }

    /// Indent of the nearest non-blank line above the line starting at `offset`.
    private static func indentOfNonBlankLine(before offset: Int, in text: NSString) -> Int? {
        var lineStart = offset
        for _ in 0..<1000 {
            guard lineStart > 0 else { return nil }
            lineStart = text.lineRange(for: NSRange(location: lineStart - 1, length: 0)).location
            if let indent = indent(ofLineAt: lineStart, in: text) { return indent }
        }
        return nil
    }

    /// Indent of the nearest non-blank line below the line starting at `offset`.
    private static func indentOfNonBlankLine(after offset: Int, in text: NSString) -> Int? {
        var lineStart = NSMaxRange(text.lineRange(for: NSRange(location: offset, length: 0)))
        for _ in 0..<1000 {
            guard lineStart < text.length else { return nil }
            if let indent = indent(ofLineAt: lineStart, in: text) { return indent }
            lineStart = NSMaxRange(text.lineRange(for: NSRange(location: lineStart, length: 0)))
        }
        return nil
    }

    /// Picks the indentation from the first lines: tabs if most indented lines start
    /// with a tab, otherwise spaces with the most common step between lines (2, 4 or 8).
    private static func detectIndentation(in text: NSString) -> Indentation {
        var tabLines = 0
        var spaceLines = 0
        var steps: [Int: Int] = [:]
        var previous = 0
        var lineStart = 0
        var lines = 0
        while lineStart < text.length, lines < 2000 {
            let first = text.character(at: lineStart)
            if let indent = Self.indent(ofLineAt: lineStart, in: text) {
                if first == 0x09 { tabLines += 1 } else if first == 0x20 { spaceLines += 1 }
                let step = indent - previous
                if step > 1, step <= 8 { steps[step, default: 0] += 1 }
                previous = indent
            }
            lineStart = NSMaxRange(text.lineRange(for: NSRange(location: lineStart, length: 0)))
            lines += 1
        }
        let settings = EditorSettings.shared
        // Nothing indented yet (a new file): the style from Settings.
        if tabLines == 0 && spaceLines == 0 {
            return Indentation(usesTabs: settings.indentsWithTabs, width: settings.tabWidth)
        }
        if tabLines > spaceLines {
            return Indentation(usesTabs: true, width: tabWidth)
        }
        let width = [2, 4, 8].max { steps[$0, default: 0] < steps[$1, default: 0] }
            .flatMap { steps[$0, default: 0] > 0 ? $0 : nil } ?? settings.tabWidth
        return Indentation(usesTabs: false, width: width)
    }
}

extension NSTextView {
    /// The view-coordinate rect anchoring `range` (TextKit 2 segments); nil
    /// when the range has no laid-out geometry.
    func anchorRect(forCharacterRange range: NSRange) -> NSRect? {
        guard let layoutManager = textLayoutManager,
              let contentManager = layoutManager.textContentManager else { return nil }
        let documentStart = layoutManager.documentRange.location
        guard let start = contentManager.location(documentStart, offsetBy: range.location),
              let end = contentManager.location(start, offsetBy: max(range.length, 1)),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        layoutManager.ensureLayout(for: textRange)
        var rect: NSRect?
        layoutManager.enumerateTextSegments(
            in: textRange, type: .standard, options: [.rangeNotRequired]
        ) { _, segmentFrame, _, _ in
            rect = segmentFrame
            return false
        }
        return rect
    }
}
