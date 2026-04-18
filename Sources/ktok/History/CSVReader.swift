import Foundation

/// RFC 4180 CSV reader with tolerance for common deviations seen in the wild.
///
/// Handles:
/// - Comma separator, double-quote `"` escape (as `""` inside quoted fields)
/// - Fields with embedded `\n` / `\r\n` when quoted
/// - UTF-8 BOM at start of file (stripped)
/// - LF or CRLF record separators
/// - A trailing record without a final newline
///
/// Does NOT handle (yet): alternative delimiters, escape chars other than `"`,
/// multi-char line endings beyond `\r\n`. None of those show up in KakaoTalk's
/// CSV export.
enum CSVReader {
    static func parseFile(atPath path: String) throws -> [[String]] {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CSVError.encoding(path: path)
        }
        return parse(text)
    }

    static func parse(_ input: String) -> [[String]] {
        // Strip UTF-8 BOM if present — showing up as U+FEFF when the file is
        // decoded as UTF-8 by Foundation.
        var scalars = input.unicodeScalars.map { $0 }
        if scalars.first?.value == 0xFEFF {
            scalars.removeFirst()
        }

        var rows: [[String]] = []
        var currentRow: [String] = []
        var field = ""

        enum State { case fieldStart, unquoted, quoted, quotedAfterQuote }
        var state: State = .fieldStart

        func endField() {
            currentRow.append(field)
            field = ""
        }
        func endRecord() {
            endField()
            rows.append(currentRow)
            currentRow = []
        }

        for scalar in scalars {
            let ch = scalar.value
            switch state {
            case .fieldStart:
                switch ch {
                case 0x22:  // "
                    state = .quoted
                case 0x2C:  // ,
                    endField()
                    // stay in fieldStart
                case 0x0A:  // \n
                    endRecord()
                    state = .fieldStart
                case 0x0D:  // \r — will be followed by \n for CRLF; just skip
                    break
                default:
                    field.unicodeScalars.append(scalar)
                    state = .unquoted
                }
            case .unquoted:
                switch ch {
                case 0x2C:  // ,
                    endField()
                    state = .fieldStart
                case 0x0A:  // \n
                    endRecord()
                    state = .fieldStart
                case 0x0D:  // \r — preamble to \n, skip; if lone CR, the \n branch handles termination
                    break
                default:
                    field.unicodeScalars.append(scalar)
                }
            case .quoted:
                if ch == 0x22 {  // "
                    state = .quotedAfterQuote
                } else {
                    field.unicodeScalars.append(scalar)
                }
            case .quotedAfterQuote:
                switch ch {
                case 0x22:  // "" — escaped quote, literal "
                    field.unicodeScalars.append(scalar)
                    state = .quoted
                case 0x2C:  // ,
                    endField()
                    state = .fieldStart
                case 0x0A:  // \n
                    endRecord()
                    state = .fieldStart
                case 0x0D:  // \r — CRLF line-end following closing quote
                    break
                default:
                    // Tolerate trailing garbage after closing quote by
                    // dropping it; real KakaoTalk exports never hit this.
                    field.unicodeScalars.append(scalar)
                    state = .unquoted
                }
            }
        }

        // Final field / record flush for files without trailing newline.
        if state != .fieldStart || !field.isEmpty || !currentRow.isEmpty {
            endRecord()
        }

        return rows
    }
}

enum CSVError: Error, CustomStringConvertible {
    case encoding(path: String)

    var description: String {
        switch self {
        case .encoding(let path):
            return "Could not decode \(path) as UTF-8"
        }
    }
}
