import Foundation

/// Scans the KakaoTalk chat's AX tree in one batched AppleScript call and
/// returns candidate file-attachment rows.
///
/// Mirrors the Python MCP's `_find_file_elements_ax`:
/// fetches every row's text+button-description list in a single osascript
/// round-trip (~6 s for 50+ rows, vs ~30 s for per-element JXA walks). Python
/// then filters in-process; we do the same in Swift.
enum AttachmentScanner {
    struct Candidate {
        enum Reason: String {
            case filename
            case marker
            case `extension`
        }

        let rowIndex: Int
        let value: String   // matched static-text value (for row lookup by JXA)
        let reason: Reason
    }

    struct ScanResult {
        let candidates: [Candidate]
        let axError: String?
    }

    static func scan(chat: String, filename: String?) -> ScanResult {
        let script = """
        on run argv
          set chatName to (item 1 of argv)
          tell application "System Events"
            tell process "KakaoTalk"
              set chatWin to window chatName
              set sa to scroll area 1 of chatWin
              set tbl to table 1 of sa
              set rowCount to count of rows of tbl
              set output to ""
              repeat with ri from rowCount to 1 by -1
                try
                  set r to row ri of tbl
                  set c to UI element 1 of r
                  set vals to value of every static text of c
                  set btns to description of every button of c
                  set AppleScript's text item delimiters to "\\t"
                  set vLine to (vals as text)
                  set bLine to (btns as text)
                  set AppleScript's text item delimiters to ""
                  set output to output & ((ri - 1) as text) & "|" & vLine & "|" & bLine & linefeed
                end try
              end repeat
              return output
            end tell
          end tell
        end run
        """

        let output = AppleScriptRunner.runAppleScript(script, argv: [chat], timeoutSec: 25.0)
        if output.returncode != 0 {
            let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = err.count > 200 ? String(err.prefix(200)) : err
            return ScanResult(candidates: [], axError: "as_rc=\(output.returncode) err=\(short)")
        }
        let text = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return ScanResult(candidates: [], axError: "as_empty")
        }

        let candidates = parse(text: text, filename: filename)
        return ScanResult(candidates: candidates, axError: nil)
    }

    private static func parse(text: String, filename: String?) -> [Candidate] {
        var result: [Candidate] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let rowIndex = Int(parts[0]) else { continue }
            let valsString = String(parts[1])
            let vals = valsString.split(separator: "\t", omittingEmptySubsequences: true).map(String.init)
            // parts[2] holds tab-joined button descriptions; unused here because
            // SavePressor re-queries buttons by JXA inside the target row. Keep
            // the AppleScript emitting them so we can surface them in future debug paths.

            var matched: Candidate?
            if let filename, !filename.isEmpty {
                if valsString.contains(filename) {
                    let value = vals.first(where: { $0.contains(filename) }) ?? filename
                    matched = Candidate(rowIndex: rowIndex, value: value, reason: .filename)
                }
            } else {
                if let markerVal = vals.first(where: { FileExtensionMatcher.containsSaveMarker($0) }) {
                    matched = Candidate(rowIndex: rowIndex, value: markerVal, reason: .marker)
                } else if let extVal = vals.first(where: { FileExtensionMatcher.containsKnownExtension($0) }) {
                    matched = Candidate(rowIndex: rowIndex, value: extVal, reason: .extension)
                }
            }

            if let matched {
                result.append(matched)
                break // rows are already newest-first
            }
        }
        return result
    }
}
