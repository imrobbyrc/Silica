import AppKit

/// Colors an NSTextView's text using a `SyntaxTokenizer`.
///
/// Only the foreground color attribute is touched, directly on the text storage,
/// so highlighting never marks the document dirty or adds undo steps. After an edit,
/// the whole document is re-tokenized off the main thread once typing pauses briefly;
/// meanwhile newly typed text inherits the color of the text around it.
final class SyntaxHighlighter {
    private weak var textView: NSTextView?
    private let tokenizer: any SyntaxTokenizer
    private let language: SyntaxLanguage
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var linkRanges: [NSRange] = []

    private static let pythonFromImportPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*from[ \t]+(\.*[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*|\.+)[ \t]+import[ \t]*(\([^)]*\)|[^#\n]*)"#
    )
    private static let pythonImportPattern = try! NSRegularExpression(
        pattern: #"(?m)^[ \t]*import[ \t]+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)"#
    )
    private static let pythonImportedIdentifierPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z_]\w*"#
    )

    /// Above this many UTF-16 units, highlighting is skipped entirely.
    private static let maxLength = 2_000_000
    /// Up to this size the first pass runs synchronously, so files open already colored.
    private static let synchronousLength = 100_000
    private static let editDelay: Duration = .milliseconds(120)

    init(textView: NSTextView, language: SyntaxLanguage) {
        self.textView = textView
        self.tokenizer = language.tokenizer
        self.language = language
    }

    deinit {
        pending?.cancel()
    }

    /// Highlights the current text immediately (used when a file is opened).
    func highlightNow() {
        guard let storage = textView?.textStorage, storage.length <= Self.maxLength else { return }
        if storage.length <= Self.synchronousLength {
            generation += 1
            apply(tokenizer.tokenize(snapshot(of: storage)))
        } else {
            schedule(after: .zero)
        }
    }

    func textDidChange() {
        linkRanges.removeAll(keepingCapacity: true)
        schedule(after: Self.editDelay)
    }

    /// A linkable syntax function or Python import module under this UTF-16 offset.
    func linkRange(at offset: Int) -> NSRange? {
        var low = 0
        var high = linkRanges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(linkRanges[middle]) <= offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < linkRanges.count else { return nil }
        let range = linkRanges[low]
        return range.location <= offset && offset < NSMaxRange(range) ? range : nil
    }

    private func schedule(after delay: Duration) {
        generation += 1
        let expected = generation
        let tokenizer = tokenizer
        pending?.cancel()
        pending = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled, let self, let storage = self.textView?.textStorage,
                  storage.length <= Self.maxLength else { return }

            let text = self.snapshot(of: storage)
            let tokens = await Task.detached(priority: .userInitiated) {
                tokenizer.tokenize(text)
            }.value

            guard !Task.isCancelled, expected == self.generation else { return }
            self.apply(tokens)
        }
    }

    /// An immutable copy; the storage's own string is mutable and owned by the main thread.
    private func snapshot(of storage: NSTextStorage) -> NSString {
        (storage.string as NSString).copy() as! NSString
    }

    private static func overlapsNonCode(_ candidate: NSRange, ranges: [NSRange]) -> Bool {
        var low = 0
        var high = ranges.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(ranges[middle]) <= candidate.location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < ranges.count && ranges[low].location < NSMaxRange(candidate)
    }

    private func apply(_ tokens: [SyntaxToken]) {
        guard let textView, let storage = textView.textStorage else { return }
        // Recoloring under in-progress IME composition would disturb the marked text.
        if textView.hasMarkedText() {
            schedule(after: Self.editDelay)
            return
        }

        var ranges = tokens
            .filter { if case .function = $0.kind { true } else { false } }
            .map(\.range)
        if language == .python {
            let source = storage.string as NSString
            let sourceRange = NSRange(location: 0, length: source.length)
            let nonCodeRanges = tokens
                .filter {
                    switch $0.kind {
                    case .comment, .string: true
                    default: false
                    }
                }
                .map(\.range)
                .sorted { $0.location < $1.location }
            let sourceString = source as String
            Self.pythonFromImportPattern.enumerateMatches(in: sourceString, range: sourceRange) { match, _, _ in
                guard let match else { return }
                let moduleRange = match.range(at: 1)
                if moduleRange.location != NSNotFound, moduleRange.length > 0,
                   !Self.overlapsNonCode(moduleRange, ranges: nonCodeRanges) {
                    ranges.append(moduleRange)
                }
                let namesRange = match.range(at: 2)
                guard namesRange.location != NSNotFound, namesRange.length > 0 else { return }
                Self.pythonImportedIdentifierPattern.enumerateMatches(in: sourceString, range: namesRange) { nameMatch, _, _ in
                    guard let nameMatch else { return }
                    let nameRange = nameMatch.range
                    guard source.substring(with: nameRange) != "as",
                          !Self.overlapsNonCode(nameRange, ranges: nonCodeRanges) else { return }
                    ranges.append(nameRange)
                }
            }
            Self.pythonImportPattern.enumerateMatches(in: sourceString, range: sourceRange) { match, _, _ in
                guard let match else { return }
                let range = match.range(at: 1)
                guard range.location != NSNotFound, range.length > 0,
                      !Self.overlapsNonCode(range, ranges: nonCodeRanges) else { return }
                ranges.append(range)
            }
        }
        linkRanges = ranges.sorted { $0.location < $1.location }

        let theme = EditorSettings.shared.syntaxTheme
        let length = storage.length
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: SyntaxTheme.plain, range: NSRange(location: 0, length: length))
        for token in tokens where NSMaxRange(token.range) <= length {
            storage.addAttribute(.foregroundColor, value: theme.color(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }
}
