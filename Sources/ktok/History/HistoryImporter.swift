import Foundation

/// Shared import logic used by `ktok import-history` and `ktok sync-history`.
/// Given a CSV path and chat identity hints, parses the file and upserts
/// messages + attachments into the DB, and records a sync_runs row.
struct HistoryImporter {
    struct Result {
        let chatId: String
        let chatName: String
        let filePath: String
        let parsedDump: ChatDumpParser.ParsedDump
        let messagesInserted: Int
        let messagesSkipped: Int
        let attachmentsInserted: Int
        let syncRunId: Int64
    }

    enum ImportError: Error, CustomStringConvertible {
        case chatNameRequired(filePath: String)
        case fileNotFound(path: String)
        case csvParseFailed(underlying: Error)
        case dbFailed(underlying: Error)

        var description: String {
            switch self {
            case .chatNameRequired(let filePath):
                return "Could not infer chat name from filename: \(filePath)"
            case .fileNotFound(let path):
                return "File does not exist: \(path)"
            case .csvParseFailed(let err):
                return "CSV parse failed: \(err)"
            case .dbFailed(let err):
                return "DB operation failed: \(err)"
            }
        }
    }

    let db: Database
    let myKakaoId: String?

    /// Parse a dump file and upsert into the DB. Messages are deduplicated
    /// by SHA-256(chat_id|sent_at|author|body); attachments only insert when
    /// their message was newly inserted this run.
    func importFile(path rawPath: String, chatNameOverride: String? = nil, chatIdOverride: String? = nil) throws -> Result {
        let path = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw ImportError.fileNotFound(path: path)
        }

        let resolvedName: String
        if let chatNameOverride, !chatNameOverride.isEmpty {
            resolvedName = ChatIdentityHash.forStorage(chatNameOverride)
        } else if let derived = ChatIdentityHash.extractChatName(fromFilename: path) {
            resolvedName = derived
        } else {
            throw ImportError.chatNameRequired(filePath: path)
        }

        let chatId = chatIdOverride ?? ChatIdentityHash.chatId(forDisplayName: resolvedName)

        let rows: [[String]]
        do {
            rows = try CSVReader.parseFile(atPath: path)
        } catch {
            throw ImportError.csvParseFailed(underlying: error)
        }

        let parser = ChatDumpParser(chatId: chatId, myKakaoId: myKakaoId)
        let parsed = parser.parse(rows: rows)

        let chatRepo = ChatRepository(db: db)
        let messageRepo = MessageRepository(db: db)
        let attachmentRepo = AttachmentRepository(db: db)
        let syncRunRepo = SyncRunRepository(db: db)

        var inserted = 0
        var skipped = 0
        var attachmentsInserted = 0
        // Start the sync_runs row in an AUTOCOMMIT statement (outside the
        // main transaction) so audit history survives even if the data
        // transaction rolls back. Previously this INSERT was inside the
        // transaction and a rollback would erase the audit row, then the
        // subsequent compensating UPDATE would silently hit 0 rows.
        let syncRunId = (try? syncRunRepo.start(chatId: chatId, dumpFilePath: path)) ?? 0
        var txError: Error?

        do {
            try db.transaction {
                try chatRepo.upsert(chatId: chatId, displayName: resolvedName, myNickname: myKakaoId)

                var keyToMessageId: [String: Int64] = [:]
                var freshlyInsertedKeys: Set<String> = []
                for message in parsed.messages {
                    let outcome = try messageRepo.insertIfNotExists(message)
                    if outcome.inserted {
                        inserted += 1
                        freshlyInsertedKeys.insert(message.dedupeKey)
                    } else {
                        skipped += 1
                    }
                    if let id = outcome.messageId {
                        keyToMessageId[message.dedupeKey] = id
                    }
                }

                let recordedAt = ISO8601.now()
                for pending in parsed.pendingAttachments where freshlyInsertedKeys.contains(pending.dedupeKey) {
                    let attachment = AttachmentRecord(
                        id: nil,
                        chatId: chatId,
                        messageId: keyToMessageId[pending.dedupeKey],
                        direction: pending.direction,
                        filename: pending.filename,
                        localPath: nil,
                        sentAt: pending.sentAt,
                        sizeBytes: nil,
                        sha256: nil,
                        source: .parsedFromDump,
                        recordedAt: recordedAt
                    )
                    _ = try attachmentRepo.insert(attachment)
                    attachmentsInserted += 1
                }

                try chatRepo.updateLastSyncedAt(chatId: chatId, at: recordedAt)
            }
        } catch {
            txError = error
        }

        // Always close out the sync_runs row so audits survive errors.
        try? syncRunRepo.finish(
            id: syncRunId,
            linesParsed: parsed.totalRowsParsed,
            messagesInserted: inserted,
            messagesSkippedDuplicates: skipped,
            attachmentsInserted: attachmentsInserted,
            error: txError.map { String(describing: $0) }
        )

        if let txError {
            throw ImportError.dbFailed(underlying: txError)
        }

        return Result(
            chatId: chatId,
            chatName: resolvedName,
            filePath: path,
            parsedDump: parsed,
            messagesInserted: inserted,
            messagesSkipped: skipped,
            attachmentsInserted: attachmentsInserted,
            syncRunId: syncRunId
        )
    }
}
