import CryptoKit
import Foundation

/// Scans the KakaoTalk chat's AX tree in one batched AppleScript call and
/// returns candidate file-attachment rows.
///
/// Mirrors the Python MCP's `_find_file_elements_ax`:
/// fetches every row's text+button-description list in a single osascript
/// round-trip (~6 s for 50+ rows, vs ~30 s for per-element JXA walks). Python
/// then filters in-process; we do the same in Swift.
enum AttachmentScanner {
    struct Candidate: Sendable {
        enum Reason: String, Sendable {
            case filename
            case marker
            case `extension`
        }

        let rowIndex: Int
        let value: String   // matched static-text value (for row lookup by JXA)
        let reason: Reason
        let filename: String?
        let author: String?
        let timeRaw: String?

        func attachmentID(chat: String) -> String {
            let parts = [
                chat,
                timeRaw ?? "",
                author ?? "",
                value,
                String(rowIndex),
            ]
            let digest = SHA256.hash(data: Data(parts.joined(separator: "|").utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return "att_\(hex.prefix(16))"
        }
    }

    struct ScanResult: Sendable {
        let candidates: [Candidate]
        let axError: String?
    }

    static func scan(chat: String, filename: String?) -> ScanResult {
        scanVisibleCandidates(chat: chat, filename: filename, limit: 1)
    }

    static func scanAll(chat: String, filename: String? = nil) -> ScanResult {
        scanVisibleCandidates(chat: chat, filename: filename, limit: nil)
    }

    private static func scanVisibleCandidates(chat: String, filename: String?, limit: Int?) -> ScanResult {
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

        let candidates = parse(text: text, filename: filename, limit: limit)
        return ScanResult(candidates: candidates, axError: nil)
    }

    static func parse(text: String, filename: String?, limit: Int? = nil) -> [Candidate] {
        var result: [Candidate] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let rowIndex = Int(parts[0]) else { continue }
            let valsString = String(parts[1])
            let vals = valsString.split(separator: "\t", omittingEmptySubsequences: true).map(String.init)
            let buttonDescriptions = String(parts[2])
                .split(separator: "\t", omittingEmptySubsequences: true)
                .map(String.init)
            // SavePressor re-queries the target row by row_index; button text is
            // only used here to detect file bubbles whose filename is not visible.

            var matched: Candidate?
            let detectedFilename = vals.first(where: { FileExtensionMatcher.containsKnownExtension($0) })
            let timeRaw = vals.first(where: { ChatTextNormalizer.isTimeLikeValue($0) })
            let author = inferAuthor(from: vals, matchedFilename: detectedFilename, timeRaw: timeRaw)
            if let filename, !filename.isEmpty {
                if valsString.contains(filename) {
                    let value = vals.first(where: { $0.contains(filename) }) ?? filename
                    matched = Candidate(
                        rowIndex: rowIndex,
                        value: value,
                        reason: .filename,
                        filename: detectedFilename ?? value,
                        author: author,
                        timeRaw: timeRaw
                    )
                }
            } else {
                if let extVal = detectedFilename {
                    matched = Candidate(
                        rowIndex: rowIndex,
                        value: extVal,
                        reason: .extension,
                        filename: extVal,
                        author: author,
                        timeRaw: timeRaw
                    )
                } else if let markerVal = vals.first(where: { FileExtensionMatcher.containsSaveMarker($0) })
                    ?? buttonDescriptions.first(where: { FileExtensionMatcher.containsSaveMarker($0) }) {
                    matched = Candidate(
                        rowIndex: rowIndex,
                        value: markerVal,
                        reason: .marker,
                        filename: nil,
                        author: author,
                        timeRaw: timeRaw
                    )
                }
            }

            if let matched {
                result.append(matched)
                if let limit, result.count >= limit {
                    break // rows are already newest-first
                }
            }
        }
        return result
    }

    private static func inferAuthor(from values: [String], matchedFilename: String?, timeRaw: String?) -> String? {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed == matchedFilename || trimmed == timeRaw { continue }
            if FileExtensionMatcher.containsKnownExtension(trimmed) { continue }
            if FileExtensionMatcher.containsSaveMarker(trimmed) { continue }
            if ChatTextNormalizer.isTimeLikeValue(trimmed) || ChatTextNormalizer.isUnreadCountLike(trimmed) { continue }
            if isAttachmentMetadata(trimmed) { continue }
            return trimmed
        }
        return nil
    }

    private static func isAttachmentMetadata(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        if normalized == "file" || normalized == "image" || normalized == "photo" { return true }
        if normalized == "파일" || normalized == "사진" || normalized == "첨부파일" { return true }

        let sizePattern = #"(?i)^\d+(?:\.\d+)?\s?(bytes?|kb|mb|gb|tb|b|kib|mib|gib|바이트)$"#
        return normalized.range(of: sizePattern, options: .regularExpression) != nil
    }
}
