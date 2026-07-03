import ApplicationServices.HIServices
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

    static func scan(window: UIElement, filename: String?) -> ScanResult {
        scanVisibleCandidates(window: window, filename: filename, limit: 1)
    }

    static func scanAll(window: UIElement, filename: String? = nil) -> ScanResult {
        scanVisibleCandidates(window: window, filename: filename, limit: nil)
    }

    /// Native Accessibility scan of a chat window's message table.
    ///
    /// Mirrors the previous single-shot AppleScript (`table 1 of scroll area 1
    /// of window`, per-row `value of every static text` + `description of every
    /// button`) but stays in-process, so it costs a handful of AX reads instead
    /// of a ~10s osascript round-trip. `rowIndex` is the 0-based top-down table
    /// position — identical to the AppleScript's `(ri - 1)` — so `attachmentID`
    /// stays stable across `ktok read` and `ktok download-file`.
    private static func scanVisibleCandidates(window: UIElement, filename: String?, limit: Int?) -> ScanResult {
        guard let table = locateTable(in: window) else {
            return ScanResult(candidates: [], axError: "native_no_table")
        }
        let rows = table.children.filter { $0.role == kAXRowRole }
        if rows.isEmpty {
            return ScanResult(candidates: [], axError: "native_no_rows")
        }

        var result: [Candidate] = []
        // Walk bottom-up (newest first) so `limit` keeps the most recent rows,
        // while rowIndex records the true top-down position.
        for rowIndex in stride(from: rows.count - 1, through: 0, by: -1) {
            let row = rows[rowIndex]
            let cell = row.children.first { $0.role == kAXCellRole } ?? row
            // Attachment metadata (filename static texts, Save/Open buttons)
            // sits shallow inside the cell, so bound the BFS to keep the whole
            // scan cheap even in rooms with dozens of rows.
            let vals = cell.findAll(role: kAXStaticTextRole, limit: 16, maxNodes: 80)
                .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let buttonDescriptions = cell.findAll(role: kAXButtonRole, limit: 10, maxNodes: 80)
                .compactMap { $0.axDescription?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if let candidate = detectCandidate(
                rowIndex: rowIndex,
                vals: vals,
                buttonDescriptions: buttonDescriptions,
                filename: filename
            ) {
                result.append(candidate)
                if let limit, result.count >= limit {
                    break // rows are already newest-first
                }
            }
        }
        return ScanResult(candidates: result, axError: nil)
    }

    /// Resolves the message table: `window → first scroll area → first table`,
    /// matching AppleScript `table 1 of scroll area 1 of window`. Falls back to
    /// a bounded descendant search if the direct-child shape differs.
    private static func locateTable(in window: UIElement) -> UIElement? {
        var scroll = window.children.first(where: { $0.role == kAXScrollAreaRole })
        if scroll == nil {
            scroll = window.findFirst(where: { $0.role == kAXScrollAreaRole })
        }
        if let scroll {
            if let table = scroll.children.first(where: { $0.role == kAXTableRole }) {
                return table
            }
            if let table = scroll.findFirst(where: { $0.role == kAXTableRole }) {
                return table
            }
        }
        return window.findFirst(where: { $0.role == kAXTableRole })
    }

    /// Shared attachment detection over one row's static-text values and button
    /// descriptions. Unchanged from the previous AppleScript-fed logic.
    static func detectCandidate(
        rowIndex: Int,
        vals: [String],
        buttonDescriptions: [String],
        filename: String?
    ) -> Candidate? {
        let detectedFilename = vals.first(where: { FileExtensionMatcher.containsKnownExtension($0) })
        let timeRaw = vals.first(where: { ChatTextNormalizer.isTimeLikeValue($0) })
        let author = inferAuthor(from: vals, matchedFilename: detectedFilename, timeRaw: timeRaw)

        if let filename, !filename.isEmpty {
            guard let value = vals.first(where: { $0.contains(filename) }) else {
                return nil
            }
            return Candidate(
                rowIndex: rowIndex,
                value: value,
                reason: .filename,
                filename: detectedFilename ?? value,
                author: author,
                timeRaw: timeRaw
            )
        }

        if let extVal = detectedFilename {
            return Candidate(
                rowIndex: rowIndex,
                value: extVal,
                reason: .extension,
                filename: extVal,
                author: author,
                timeRaw: timeRaw
            )
        }

        if let markerVal = vals.first(where: { FileExtensionMatcher.containsSaveMarker($0) })
            ?? buttonDescriptions.first(where: { FileExtensionMatcher.containsSaveMarker($0) }) {
            return Candidate(
                rowIndex: rowIndex,
                value: markerVal,
                reason: .marker,
                filename: nil,
                author: author,
                timeRaw: timeRaw
            )
        }

        return nil
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
