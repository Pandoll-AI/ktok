import Foundation

// MARK: - Chats

struct ChatRepository {
    let db: Database

    /// INSERT OR IGNORE by chat_id; updates display_name if already present.
    func upsert(chatId: String, displayName: String, myNickname: String? = nil) throws {
        try db.execute("""
            INSERT INTO chats(chat_id, display_name, my_nickname, first_seen_at, last_synced_at)
            VALUES (?, ?, ?, ?, NULL)
            ON CONFLICT(chat_id) DO UPDATE SET
              display_name = excluded.display_name,
              my_nickname  = COALESCE(excluded.my_nickname, chats.my_nickname)
        """, bind: [chatId, displayName, myNickname, ISO8601.now()])
    }

    func updateLastSyncedAt(chatId: String, at iso: String) throws {
        try db.execute(
            "UPDATE chats SET last_synced_at = ? WHERE chat_id = ?",
            bind: [iso, chatId]
        )
    }

    func get(chatId: String) throws -> ChatRecord? {
        let stmt = try db.prepare("""
            SELECT chat_id, display_name, my_nickname, first_seen_at, last_synced_at
            FROM chats WHERE chat_id = ?
        """)
        try stmt.bindAll([chatId])
        guard try stmt.step() else { return nil }
        return ChatRecord(
            chatId: stmt.columnText(at: 0) ?? "",
            displayName: stmt.columnText(at: 1) ?? "",
            myNickname: stmt.columnText(at: 2),
            firstSeenAt: stmt.columnText(at: 3) ?? "",
            lastSyncedAt: stmt.columnText(at: 4)
        )
    }

    func findByDisplayName(_ name: String) throws -> ChatRecord? {
        let stmt = try db.prepare("""
            SELECT chat_id, display_name, my_nickname, first_seen_at, last_synced_at
            FROM chats WHERE display_name = ? ORDER BY last_synced_at DESC LIMIT 1
        """)
        try stmt.bindAll([name])
        guard try stmt.step() else { return nil }
        return ChatRecord(
            chatId: stmt.columnText(at: 0) ?? "",
            displayName: stmt.columnText(at: 1) ?? "",
            myNickname: stmt.columnText(at: 2),
            firstSeenAt: stmt.columnText(at: 3) ?? "",
            lastSyncedAt: stmt.columnText(at: 4)
        )
    }
}

// MARK: - Messages

struct MessageRepository {
    let db: Database

    /// INSERT OR IGNORE — returns true if a new row was inserted, false if
    /// the `dedupe_key` already existed.
    func insertIfNotExists(_ message: MessageRecord) throws -> (inserted: Bool, messageId: Int64?) {
        try db.execute("""
            INSERT OR IGNORE INTO messages
              (chat_id, sent_at, author, body, kind, raw_line, dedupe_key, first_synced_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, bind: [
            message.chatId,
            message.sentAt,
            message.author,
            message.body,
            message.kind.rawValue,
            message.rawLine,
            message.dedupeKey,
            message.firstSyncedAt,
        ])

        if db.changes() > 0 {
            return (true, db.lastInsertRowId())
        }
        // Row already existed — look up its id so attachments can link to it.
        let stmt = try db.prepare("SELECT id FROM messages WHERE dedupe_key = ?")
        try stmt.bindAll([message.dedupeKey])
        if try stmt.step() {
            return (false, stmt.columnInt64(at: 0))
        }
        return (false, nil)
    }

    func search(_ query: HistoryQuery) throws -> [MessageRecord] {
        var clauses: [String] = []
        var binds: [Any?] = []

        if let chatId = query.chatId {
            clauses.append("m.chat_id = ?")
            binds.append(chatId)
        }
        if let chatName = query.chatName {
            clauses.append("c.display_name = ?")
            binds.append(chatName)
        }
        if let since = query.since {
            clauses.append("m.sent_at >= ?")
            binds.append(since)
        }
        if let until = query.until {
            clauses.append("m.sent_at <= ?")
            binds.append(until)
        }
        if let kinds = query.kinds, !kinds.isEmpty {
            let placeholders = Array(repeating: "?", count: kinds.count).joined(separator: ",")
            clauses.append("m.kind IN (\(placeholders))")
            binds.append(contentsOf: kinds.map { $0 as Any? })
        }
        if let authors = query.authors, !authors.isEmpty {
            let placeholders = Array(repeating: "?", count: authors.count).joined(separator: ",")
            clauses.append("m.author IN (\(placeholders))")
            binds.append(contentsOf: authors.map { $0 as Any? })
        }
        if let textQuery = query.textQuery, !textQuery.isEmpty {
            clauses.append("m.body LIKE ?")
            binds.append("%\(textQuery)%")
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        let orderSQL = query.order == .descending ? "DESC" : "ASC"
        let sql = """
            SELECT m.id, m.chat_id, m.sent_at, m.author, m.body, m.kind, m.raw_line, m.dedupe_key, m.first_synced_at
            FROM messages m
            JOIN chats c ON c.chat_id = m.chat_id
            \(whereSQL)
            ORDER BY m.sent_at \(orderSQL)
            LIMIT ?
        """
        binds.append(query.limit)

        let stmt = try db.prepare(sql)
        try stmt.bindAll(binds)
        return try stmt.allRows { s in
            MessageRecord(
                id: s.columnInt64(at: 0),
                chatId: s.columnText(at: 1) ?? "",
                sentAt: s.columnText(at: 2) ?? "",
                author: s.columnText(at: 3) ?? "",
                body: s.columnText(at: 4) ?? "",
                kind: MessageKind(rawValue: s.columnText(at: 5) ?? "") ?? .other,
                rawLine: s.columnText(at: 6),
                dedupeKey: s.columnText(at: 7) ?? "",
                firstSyncedAt: s.columnText(at: 8) ?? ""
            )
        }
    }

    func count(chatId: String) throws -> Int {
        let stmt = try db.prepare("SELECT COUNT(*) FROM messages WHERE chat_id = ?")
        try stmt.bindAll([chatId])
        _ = try stmt.step()
        return stmt.columnInt(at: 0)
    }
}

// MARK: - Attachments

struct AttachmentRepository {
    let db: Database

    @discardableResult
    func insert(_ attachment: AttachmentRecord) throws -> Int64 {
        try db.execute("""
            INSERT INTO attachments
              (chat_id, message_id, direction, filename, local_path, sent_at,
               size_bytes, sha256, source, recorded_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, bind: [
            attachment.chatId,
            attachment.messageId,
            attachment.direction.rawValue,
            attachment.filename,
            attachment.localPath,
            attachment.sentAt,
            attachment.sizeBytes,
            attachment.sha256,
            attachment.source.rawValue,
            attachment.recordedAt,
        ])
        return db.lastInsertRowId()
    }

    func search(_ query: HistoryQuery) throws -> [AttachmentRecord] {
        var clauses: [String] = []
        var binds: [Any?] = []

        if let chatId = query.chatId {
            clauses.append("a.chat_id = ?")
            binds.append(chatId)
        }
        if let chatName = query.chatName {
            clauses.append("c.display_name = ?")
            binds.append(chatName)
        }
        if let since = query.since {
            clauses.append("a.sent_at >= ?")
            binds.append(since)
        }
        if let until = query.until {
            clauses.append("a.sent_at <= ?")
            binds.append(until)
        }
        if let textQuery = query.textQuery, !textQuery.isEmpty {
            clauses.append("a.filename LIKE ?")
            binds.append("%\(textQuery)%")
        }

        let whereSQL = clauses.isEmpty ? "" : "WHERE \(clauses.joined(separator: " AND "))"
        let orderSQL = query.order == .descending ? "DESC" : "ASC"
        let sql = """
            SELECT a.id, a.chat_id, a.message_id, a.direction, a.filename, a.local_path,
                   a.sent_at, a.size_bytes, a.sha256, a.source, a.recorded_at
            FROM attachments a
            JOIN chats c ON c.chat_id = a.chat_id
            \(whereSQL)
            ORDER BY a.sent_at \(orderSQL)
            LIMIT ?
        """
        binds.append(query.limit)

        let stmt = try db.prepare(sql)
        try stmt.bindAll(binds)
        return try stmt.allRows { s in
            AttachmentRecord(
                id: s.columnInt64(at: 0),
                chatId: s.columnText(at: 1) ?? "",
                messageId: s.columnIsNull(at: 2) ? nil : s.columnInt64(at: 2),
                direction: AttachmentDirection(rawValue: s.columnText(at: 3) ?? "") ?? .unknown,
                filename: s.columnText(at: 4),
                localPath: s.columnText(at: 5),
                sentAt: s.columnText(at: 6),
                sizeBytes: s.columnIsNull(at: 7) ? nil : s.columnInt64(at: 7),
                sha256: s.columnText(at: 8),
                source: AttachmentSource(rawValue: s.columnText(at: 9) ?? "") ?? .manual,
                recordedAt: s.columnText(at: 10) ?? ""
            )
        }
    }
}

// MARK: - Sync Runs

struct SyncRunRepository {
    let db: Database

    @discardableResult
    func start(chatId: String, dumpFilePath: String?) throws -> Int64 {
        try db.execute("""
            INSERT INTO sync_runs(chat_id, started_at, dump_file_path)
            VALUES (?, ?, ?)
        """, bind: [chatId, ISO8601.now(), dumpFilePath])
        return db.lastInsertRowId()
    }

    func finish(
        id: Int64,
        linesParsed: Int?,
        messagesInserted: Int?,
        messagesSkippedDuplicates: Int?,
        attachmentsInserted: Int?,
        error: String?
    ) throws {
        try db.execute("""
            UPDATE sync_runs
            SET finished_at = ?, lines_parsed = ?, messages_inserted = ?,
                messages_skipped_duplicates = ?, attachments_inserted = ?, error = ?
            WHERE id = ?
        """, bind: [
            ISO8601.now(),
            linesParsed,
            messagesInserted,
            messagesSkippedDuplicates,
            attachmentsInserted,
            error,
            id,
        ])
    }
}

// MARK: - Search query

struct HistoryQuery {
    var chatId: String?
    var chatName: String?
    var since: String?
    var until: String?
    var kinds: [String]?
    var authors: [String]?
    var textQuery: String?
    var limit: Int = 100
    var order: Order = .descending

    enum Order {
        case ascending
        case descending
    }
}
