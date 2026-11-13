import Foundation

import LanguageServerProtocol

/// Converts between Silica's UTF-16 offsets/`NSRange` and LSP `Position`s, which
/// are zero-based line + UTF-16 column pairs.
///
/// Positions that point past the end of a line or document are clamped, matching
/// the LSP guidance that out-of-range positions default to the nearest valid one.
enum LSPPositionMapper {
    /// The LSP position for a UTF-16 offset in `string`.
    static func position(atUTF16Offset offset: Int, in string: NSString) -> Position {
        let offset = min(max(offset, 0), string.length)
        var line = 0
        var lineStart = 0
        var index = 0
        while index < offset {
            let character = string.character(at: index)
            if character == 0x0A {  // \n
                line += 1
                lineStart = index + 1
            } else if character == 0x0D {  // \r not followed by \n
                let next = index + 1 < string.length ? string.character(at: index + 1) : 0
                if next != 0x0A {
                    line += 1
                    lineStart = index + 1
                }
            }
            index += 1
        }
        return Position(line: line, utf16index: offset - lineStart)
    }

    /// The UTF-16 offset for an LSP position in `string`, clamped to the document.
    static func utf16Offset(of position: Position, in string: NSString) -> Int {
        var linesToSkip = max(position.line, 0)
        var offset = 0
        while linesToSkip > 0, offset < string.length {
            let character = string.character(at: offset)
            if character == 0x0A {
                linesToSkip -= 1
            } else if character == 0x0D {
                let next = offset + 1 < string.length ? string.character(at: offset + 1) : 0
                if next != 0x0A { linesToSkip -= 1 }
            }
            offset += 1
        }
        // Walk to the end of the line (or the document) for the column.
        var column = max(position.utf16index, 0)
        while column > 0, offset < string.length {
            let character = string.character(at: offset)
            if character == 0x0A || character == 0x0D { break }
            offset += 1
            column -= 1
        }
        return offset
    }

    /// The `NSRange` for an LSP range in `string`, or `nil` if the range is
    /// inverted (ends before it starts) after clamping.
    static func nsRange(of range: Range<Position>, in string: NSString) -> NSRange? {
        let start = utf16Offset(of: range.lowerBound, in: string)
        let end = utf16Offset(of: range.upperBound, in: string)
        guard start <= end else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// The LSP range for an `NSRange` in `string`.
    static func lspRange(of nsRange: NSRange, in string: NSString) -> Range<Position> {
        let start = position(atUTF16Offset: nsRange.location, in: string)
        let end = position(atUTF16Offset: nsRange.location + nsRange.length, in: string)
        return Range(uncheckedBounds: (start, end))
    }
}
