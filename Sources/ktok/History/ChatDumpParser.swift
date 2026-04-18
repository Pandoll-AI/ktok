import Foundation

/// Parse a KakaoTalk CSV dump into ready-to-insert Message + Attachment
/// records. Timestamps are converted KST → UTC ISO-8601. `chatId` must be
/// resolved by the caller (from ChatIdentityRegistry or chat display name).
struct ChatDumpParser {
    struct ParsedDump {
        /// Parsed messages in file order (oldest-first in most Kakao exports).
        let messages: [MessageRecord]
        /// Attachments extracted from `File:` / `Photo` / `Video` / etc. rows.
        /// `messageId` is nil here — caller fills it in after insert.
        let pendingAttachments: [PendingAttachment]
        /// Rows we could not parse (bad date, column count mismatch, etc.).
        let rejectedRows: [RejectedRow]
        let totalRowsParsed: Int
    }

    struct PendingAttachment {
        let dedupeKey: String       // link back to the message by dedupe_key
        let direction: AttachmentDirection
        let filename: String?
        let sentAt: String?         // UTC ISO-8601
    }

    struct RejectedRow {
        let lineNumber: Int
        let reason: String
        let raw: String
    }

    let chatId: String
    let myKakaoId: String?          // used to decide sent vs received for attachments

    init(chatId: String, myKakaoId: String? = nil) {
        self.chatId = chatId
        self.myKakaoId = myKakaoId
    }

    func parse(rows: [[String]]) -> ParsedDump {
        guard !rows.isEmpty else {
            return ParsedDump(messages: [], pendingAttachments: [], rejectedRows: [], totalRowsParsed: 0)
        }

        // First row is header: Date,User,Message — skip it. Tolerate minor
        // column count variance (≥3 expected).
        var dataRows = rows
        if let first = rows.first, first.count >= 3,
           first[0].lowercased().hasPrefix("date") {
            dataRows = Array(rows.dropFirst())
        }

        var messages: [MessageRecord] = []
        var pending: [PendingAttachment] = []
        var rejected: [RejectedRow] = []

        let nowISO = ISO8601.now()
        for (offset, row) in dataRows.enumerated() {
            let lineNumber = offset + 2   // +1 for 1-based, +1 for header row

            guard row.count >= 3 else {
                rejected.append(RejectedRow(
                    lineNumber: lineNumber,
                    reason: "expected ≥3 columns, got \(row.count)",
                    raw: row.joined(separator: "|")
                ))
                continue
            }

            let dateRaw = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let userRaw = row[1]
            let bodyRaw = row[2]

            // System deletion rows have blank Date AND blank User. For every
            // other row, Date is required to produce a valid sent_at.
            let sentAt: String
            if dateRaw.isEmpty {
                // Use the previous message's timestamp if available; otherwise
                // reject. This keeps system-deletion rows in chronological
                // order without inventing new times.
                if let previous = messages.last {
                    sentAt = previous.sentAt
                } else {
                    rejected.append(RejectedRow(
                        lineNumber: lineNumber,
                        reason: "blank date with no preceding message to inherit",
                        raw: "\(userRaw)|\(bodyRaw)"
                    ))
                    continue
                }
            } else {
                guard let parsed = ISO8601.parseKakaoTimestamp(dateRaw) else {
                    rejected.append(RejectedRow(
                        lineNumber: lineNumber,
                        reason: "unparseable date '\(dateRaw)'",
                        raw: "\(dateRaw)|\(userRaw)|\(bodyRaw)"
                    ))
                    continue
                }
                sentAt = parsed
            }

            let classified = MessageClassifier.classify(rawUser: userRaw, rawMessage: bodyRaw)
            // NFC-normalize everything that crosses the DB boundary. macOS
            // filesystem / iCloud / some AppleScript paths produce NFD, while
            // terminal input and SQL literals are NFC — without explicit
            // precomposition, the same message can hash to two dedupe_keys
            // across runs and break idempotency.
            let author = classified.author.precomposedStringWithCanonicalMapping
            let body = classified.body.precomposedStringWithCanonicalMapping
            let rawLine = "\(dateRaw)\t\(userRaw)\t\(bodyRaw)".precomposedStringWithCanonicalMapping
            let filename = classified.attachmentFilename?.precomposedStringWithCanonicalMapping
            let dedupeKey = DedupeKey.compute(
                chatId: chatId,
                sentAt: sentAt,
                author: author,
                body: body
            )

            messages.append(MessageRecord(
                id: nil,
                chatId: chatId,
                sentAt: sentAt,
                author: author,
                body: body,
                kind: classified.kind,
                rawLine: rawLine,
                dedupeKey: dedupeKey,
                firstSyncedAt: nowISO
            ))

            if classified.kind == .file || classified.kind == .image || classified.kind == .video || classified.kind == .voice {
                pending.append(PendingAttachment(
                    dedupeKey: dedupeKey,
                    direction: attachmentDirection(author: author),
                    filename: filename,
                    sentAt: sentAt
                ))
            }
        }

        return ParsedDump(
            messages: messages,
            pendingAttachments: pending,
            rejectedRows: rejected,
            totalRowsParsed: dataRows.count
        )
    }

    private func attachmentDirection(author: String) -> AttachmentDirection {
        guard let myKakaoId, !myKakaoId.isEmpty else { return .unknown }
        // Author is already NFC at this call site; normalize the config
        // side as well so `--my-kakao-id "Emergency Lee"` from shell (NFC)
        // matches the stored author (also NFC).
        let myNFC = myKakaoId.precomposedStringWithCanonicalMapping
        return author == myNFC ? .sent : .received
    }
}
