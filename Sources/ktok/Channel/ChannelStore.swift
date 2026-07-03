import CryptoKit
import Foundation

struct ChannelChat: Encodable {
    let chatID: String
    let title: String
    let lastMessage: String?
    let isMonitored: Bool
    let mode: String
    let priority: Int
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case title
        case lastMessage = "last_message"
        case isMonitored = "is_monitored"
        case mode
        case priority
        case updatedAt = "updated_at"
    }
}

struct ChannelPollResult: Encodable {
    let chatID: String
    let title: String
    let fetchedAt: String
    let scannedMessages: Int
    let insertedMessages: Int
    let queuedMessages: Int
    let lastMessageKey: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case title
        case fetchedAt = "fetched_at"
        case scannedMessages = "scanned_messages"
        case insertedMessages = "inserted_messages"
        case queuedMessages = "queued_messages"
        case lastMessageKey = "last_message_key"
    }
}

struct ChannelStatus: Encodable {
    let dbPath: String
    let chatCount: Int
    let monitoredCount: Int
    let pendingQueueCount: Int
    let lastActivityAt: String?
    let nextIntervalSeconds: Int

    enum CodingKeys: String, CodingKey {
        case dbPath = "db_path"
        case chatCount = "chat_count"
        case monitoredCount = "monitored_count"
        case pendingQueueCount = "pending_queue_count"
        case lastActivityAt = "last_activity_at"
        case nextIntervalSeconds = "next_interval_seconds"
    }
}

struct ChannelQueueItem: Encodable {
    let id: Int64
    let messageKey: String
    let chatID: String
    let title: String?
    let author: String?
    let body: String?
    let status: String
    let priority: Int
    let attempts: Int
    let availableAt: String
    let claimedAt: String?
    let claimedBy: String?
    let leaseExpiresAt: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case messageKey = "message_key"
        case chatID = "chat_id"
        case title
        case author
        case body
        case status
        case priority
        case attempts
        case availableAt = "available_at"
        case claimedAt = "claimed_at"
        case claimedBy = "claimed_by"
        case leaseExpiresAt = "lease_expires_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

final class ChannelStore {
    static let defaultChatMapTTLSeconds = 3600

    let db: Database
    let dbPath: String

    init(path: String? = nil) throws {
        let channelDir = KtokPaths.home.appendingPathComponent("channel", isDirectory: true)
        try FileManager.default.createDirectory(at: channelDir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: channelDir.path)
        self.dbPath = path ?? channelDir.appendingPathComponent("channel.sqlite").path
        self.db = try Database(path: dbPath)
        try migrate()
        secureStoragePermissions()
    }

    func migrate() throws {
        try db.executeScript("""
        CREATE TABLE IF NOT EXISTS channel_chats (
          chat_id                  TEXT PRIMARY KEY,
          title                    TEXT NOT NULL,
          last_message             TEXT,
          first_seen_at            TEXT NOT NULL,
          updated_at               TEXT NOT NULL,
          last_chat_map_refresh_at TEXT,
          last_history_sync_at     TEXT,
          last_seen_message_key    TEXT,
          last_seen_at             TEXT,
          is_monitored             INTEGER NOT NULL DEFAULT 0,
          mode                     TEXT NOT NULL DEFAULT 'observe_only',
          priority                 INTEGER NOT NULL DEFAULT 100
        );

        CREATE INDEX IF NOT EXISTS idx_channel_chats_title ON channel_chats(title);
        CREATE INDEX IF NOT EXISTS idx_channel_chats_monitored ON channel_chats(is_monitored, priority, title);

        CREATE TABLE IF NOT EXISTS channel_messages (
          message_key  TEXT PRIMARY KEY,
          chat_id      TEXT NOT NULL REFERENCES channel_chats(chat_id) ON DELETE CASCADE,
          author       TEXT NOT NULL,
          body         TEXT NOT NULL,
          time_raw     TEXT,
          direction    TEXT NOT NULL,
          detected_at  TEXT NOT NULL,
          raw_json     TEXT
        );

        CREATE INDEX IF NOT EXISTS idx_channel_messages_chat_detected ON channel_messages(chat_id, detected_at DESC);

        CREATE TABLE IF NOT EXISTS channel_inbox_queue (
          id            INTEGER PRIMARY KEY AUTOINCREMENT,
          message_key   TEXT NOT NULL UNIQUE REFERENCES channel_messages(message_key) ON DELETE CASCADE,
          chat_id       TEXT NOT NULL,
          status        TEXT NOT NULL DEFAULT 'pending',
          priority      INTEGER NOT NULL DEFAULT 100,
          available_at  TEXT NOT NULL,
          claimed_at    TEXT,
          claimed_by    TEXT,
          lease_expires_at TEXT,
          attempts      INTEGER NOT NULL DEFAULT 0,
          created_at    TEXT NOT NULL,
          updated_at    TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_channel_queue_status ON channel_inbox_queue(status, available_at, priority, id);

        CREATE TABLE IF NOT EXISTS channel_locks (
          lock_key    TEXT PRIMARY KEY,
          owner       TEXT NOT NULL,
          expires_at  TEXT NOT NULL
        );
        """)
        _ = try? db.execute("ALTER TABLE channel_inbox_queue ADD COLUMN lease_expires_at TEXT")
        try db.execute("CREATE INDEX IF NOT EXISTS idx_channel_queue_lease ON channel_inbox_queue(status, lease_expires_at, priority, id)")
    }

    func upsertChats(_ chats: [ChatListEntry], refreshedAt: String = ISO8601.now()) throws {
        try db.transaction {
            let stmt = try db.prepare("""
                INSERT INTO channel_chats(chat_id, title, last_message, first_seen_at, updated_at, last_chat_map_refresh_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(chat_id) DO UPDATE SET
                  title=excluded.title,
                  last_message=excluded.last_message,
                  updated_at=excluded.updated_at,
                  last_chat_map_refresh_at=excluded.last_chat_map_refresh_at
            """)
            for chat in chats {
                guard let chatID = chat.chatID, !chatID.isEmpty else { continue }
                try stmt.bindAll([chatID, chat.title, chat.lastMessage, refreshedAt, refreshedAt, refreshedAt])
                _ = try stmt.step()
                stmt.reset()
            }
        }
    }

    func markMonitored(title: String?, chatID: String?, mode: String, priority: Int) throws -> ChannelChat {
        let chat = try resolveChat(exactTitle: title, chatID: chatID)
        let now = ISO8601.now()
        try db.execute(
            "UPDATE channel_chats SET is_monitored=1, mode=?, priority=?, updated_at=? WHERE chat_id=?",
            bind: [mode, priority, now, chat.chatID]
        )
        return try resolveChat(exactTitle: nil, chatID: chat.chatID)
    }

    func unmonitor(title: String?, chatID: String?) throws -> ChannelChat {
        let chat = try resolveChat(exactTitle: title, chatID: chatID)
        let now = ISO8601.now()
        try db.execute(
            "UPDATE channel_chats SET is_monitored=0, updated_at=? WHERE chat_id=?",
            bind: [now, chat.chatID]
        )
        return try resolveChat(exactTitle: nil, chatID: chat.chatID)
    }

    func listChats(monitoredOnly: Bool = false) throws -> [ChannelChat] {
        let sql = """
            SELECT chat_id, title, last_message, is_monitored, mode, priority, updated_at
            FROM channel_chats
            \(monitoredOnly ? "WHERE is_monitored=1" : "")
            ORDER BY is_monitored DESC, priority ASC, title COLLATE NOCASE ASC
        """
        let stmt = try db.prepare(sql)
        return try stmt.allRows { row in
            ChannelChat(
                chatID: row.columnText(at: 0) ?? "",
                title: row.columnText(at: 1) ?? "",
                lastMessage: row.columnText(at: 2),
                isMonitored: row.columnInt(at: 3) != 0,
                mode: row.columnText(at: 4) ?? "observe_only",
                priority: row.columnInt(at: 5),
                updatedAt: row.columnText(at: 6) ?? ""
            )
        }
    }

    func monitoredChats() throws -> [ChannelChat] {
        try listChats(monitoredOnly: true)
    }

    func chatIDsForTitle(_ title: String) throws -> [String] {
        let stmt = try db.prepare("SELECT chat_id FROM channel_chats WHERE title=? ORDER BY chat_id ASC")
        try stmt.bindAll([title])
        return try stmt.allRows { $0.columnText(at: 0) ?? "" }.filter { !$0.isEmpty }
    }

    func resolveChat(exactTitle: String?, chatID: String?) throws -> ChannelChat {
        if let chatID, !chatID.isEmpty {
            let stmt = try db.prepare("""
                SELECT chat_id, title, last_message, is_monitored, mode, priority, updated_at
                FROM channel_chats WHERE chat_id=?
            """)
            try stmt.bindAll([chatID])
            if try stmt.step() {
                return rowToChat(stmt)
            }
            throw ChannelError.chatNotFound("chat_id '\(chatID)' not found; run `ktok channel refresh-chats` first")
        }

        guard let exactTitle, !exactTitle.isEmpty else {
            throw ChannelError.chatNotFound("provide --title or --chat-id")
        }
        let stmt = try db.prepare("""
            SELECT chat_id, title, last_message, is_monitored, mode, priority, updated_at
            FROM channel_chats WHERE title=? ORDER BY updated_at DESC
        """)
        try stmt.bindAll([exactTitle])
        let rows = try stmt.allRows { rowToChat($0) }
        if rows.isEmpty {
            throw ChannelError.chatNotFound("exact title '\(exactTitle)' not found; run `ktok channel refresh-chats` first")
        }
        if rows.count > 1 {
            let ids = rows.map(\.chatID).joined(separator: ", ")
            throw ChannelError.ambiguousTitle("duplicate title '\(exactTitle)' has chat_ids: \(ids)")
        }
        return rows[0]
    }

    func insertSnapshot(chat: ChannelChat, snapshot: TranscriptSnapshot, enqueueMine: Bool = false) throws -> ChannelPollResult {
        let detectedAt = ISO8601.format(snapshot.fetchedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var inserted = 0
        var queued = 0
        var lastKey: String?
        try db.transaction {
            var occurrenceByBaseKey: [String: Int] = [:]
            for message in snapshot.messages {
                let author = message.author ?? "(me)"
                let baseKey = messageKeyBase(chatID: chat.chatID, message: message)
                let occurrence = occurrenceByBaseKey[baseKey, default: 0]
                occurrenceByBaseKey[baseKey] = occurrence + 1
                let key = messageKey(baseKey: baseKey, occurrence: occurrence)
                lastKey = key
                let rawData = try encoder.encode(message)
                let rawJSON = String(data: rawData, encoding: .utf8)
                let direction = author == "(me)" ? "outbound" : "inbound"
                let changes = try db.execute(
                    """
                    INSERT OR IGNORE INTO channel_messages(message_key, chat_id, author, body, time_raw, direction, detected_at, raw_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bind: [key, chat.chatID, author, message.body, message.timeRaw, direction, detectedAt, rawJSON]
                )
                if changes > 0 {
                    inserted += 1
                    if direction == "inbound" || enqueueMine {
                        let qChanges = try db.execute(
                            """
                            INSERT OR IGNORE INTO channel_inbox_queue(message_key, chat_id, status, priority, available_at, created_at, updated_at)
                            VALUES (?, ?, 'pending', ?, ?, ?, ?)
                            """,
                            bind: [key, chat.chatID, chat.priority, detectedAt, detectedAt, detectedAt]
                        )
                        if qChanges > 0 { queued += 1 }
                    }
                }
            }
            try db.execute(
                "UPDATE channel_chats SET last_seen_message_key=?, last_seen_at=?, updated_at=? WHERE chat_id=?",
                bind: [lastKey, detectedAt, detectedAt, chat.chatID]
            )
        }
        return ChannelPollResult(
            chatID: chat.chatID,
            title: chat.title,
            fetchedAt: detectedAt,
            scannedMessages: snapshot.messages.count,
            insertedMessages: inserted,
            queuedMessages: queued,
            lastMessageKey: lastKey
        )
    }

    func status(now: Date = Date()) throws -> ChannelStatus {
        let chatCount = try scalarInt("SELECT COUNT(*) FROM channel_chats")
        let monitored = try scalarInt("SELECT COUNT(*) FROM channel_chats WHERE is_monitored=1")
        let pending = try scalarInt("SELECT COUNT(*) FROM channel_inbox_queue WHERE status='pending'")
        let last = try scalarText("SELECT MAX(detected_at) FROM channel_messages")
        return ChannelStatus(
            dbPath: dbPath,
            chatCount: chatCount,
            monitoredCount: monitored,
            pendingQueueCount: pending,
            lastActivityAt: last,
            nextIntervalSeconds: ChannelSchedule.nextIntervalSeconds(now: now, lastActivityAtISO: last)
        )
    }

    func listQueue(status: String? = nil, limit: Int = 20) throws -> [ChannelQueueItem] {
        let capped = max(1, min(limit, 200))
        let stmt: Statement
        if let status, !status.isEmpty {
            stmt = try db.prepare("""
                SELECT q.id, q.message_key, q.chat_id, c.title, m.author, m.body,
                       q.status, q.priority, q.attempts, q.available_at, q.claimed_at,
                       q.claimed_by, q.lease_expires_at, q.created_at, q.updated_at
                FROM channel_inbox_queue q
                LEFT JOIN channel_messages m ON m.message_key=q.message_key
                LEFT JOIN channel_chats c ON c.chat_id=q.chat_id
                WHERE q.status=?
                ORDER BY q.priority ASC, q.id ASC
                LIMIT ?
            """)
            try stmt.bindAll([status, capped])
        } else {
            stmt = try db.prepare("""
                SELECT q.id, q.message_key, q.chat_id, c.title, m.author, m.body,
                       q.status, q.priority, q.attempts, q.available_at, q.claimed_at,
                       q.claimed_by, q.lease_expires_at, q.created_at, q.updated_at
                FROM channel_inbox_queue q
                LEFT JOIN channel_messages m ON m.message_key=q.message_key
                LEFT JOIN channel_chats c ON c.chat_id=q.chat_id
                ORDER BY q.status='pending' DESC, q.priority ASC, q.id ASC
                LIMIT ?
            """)
            try stmt.bindAll([capped])
        }
        return try stmt.allRows { rowToQueueItem($0) }
    }

    func claimQueue(worker: String, limit: Int = 1, leaseSeconds: Int = 300) throws -> [ChannelQueueItem] {
        let capped = max(1, min(limit, 50))
        let nowDate = Date()
        let now = ISO8601.format(nowDate)
        let leaseExpiresAt = ISO8601.format(nowDate.addingTimeInterval(TimeInterval(max(1, leaseSeconds))))
        let owner = worker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "ktok-channel-worker" : worker
        let ids = try db.transaction { () -> [Int64] in
            let select = try db.prepare("""
                SELECT id FROM channel_inbox_queue
                WHERE (status='pending' AND available_at <= ?)
                   OR (status='claimed' AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?)
                ORDER BY priority ASC, id ASC
                LIMIT ?
            """)
            try select.bindAll([now, now, capped])
            let ids = try select.allRows { $0.columnInt64(at: 0) }
            let update = try db.prepare("""
                UPDATE channel_inbox_queue
                SET status='claimed', claimed_at=?, claimed_by=?, lease_expires_at=?, attempts=attempts+1, updated_at=?
                WHERE id=? AND (
                  (status='pending' AND available_at <= ?)
                  OR (status='claimed' AND lease_expires_at IS NOT NULL AND lease_expires_at <= ?)
                )
            """)
            for id in ids {
                try update.bindAll([now, owner, leaseExpiresAt, now, id, now, now])
                _ = try update.step()
                update.reset()
            }
            return ids
        }
        return try queueItems(ids: ids)
    }

    func completeQueue(id: Int64, worker: String? = nil) throws -> ChannelQueueItem? {
        let now = ISO8601.now()
        let owner = worker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let changes: Int32
        if let owner, !owner.isEmpty {
            changes = try db.execute(
                "UPDATE channel_inbox_queue SET status='completed', lease_expires_at=NULL, updated_at=? WHERE id=? AND status='claimed' AND claimed_by=?",
                bind: [now, id, owner]
            )
        } else {
            changes = try db.execute(
                "UPDATE channel_inbox_queue SET status='completed', lease_expires_at=NULL, updated_at=? WHERE id=? AND status='claimed' AND claimed_by IS NULL",
                bind: [now, id]
            )
        }
        guard changes > 0 else { return nil }
        return try queueItem(id: id)
    }

    func failQueue(id: Int64, retry: Bool, delaySeconds: Int = 60, worker: String? = nil) throws -> ChannelQueueItem? {
        let now = Date()
        let nowText = ISO8601.format(now)
        let status = retry ? "pending" : "failed"
        let availableAt = retry ? ISO8601.format(now.addingTimeInterval(TimeInterval(max(0, delaySeconds)))) : nowText
        let owner = worker?.trimmingCharacters(in: .whitespacesAndNewlines)
        let changes: Int32
        if let owner, !owner.isEmpty {
            changes = try db.execute(
                "UPDATE channel_inbox_queue SET status=?, available_at=?, claimed_at=NULL, claimed_by=NULL, lease_expires_at=NULL, updated_at=? WHERE id=? AND status='claimed' AND claimed_by=?",
                bind: [status, availableAt, nowText, id, owner]
            )
        } else {
            changes = try db.execute(
                "UPDATE channel_inbox_queue SET status=?, available_at=?, claimed_at=NULL, claimed_by=NULL, lease_expires_at=NULL, updated_at=? WHERE id=? AND status='claimed' AND claimed_by IS NULL",
                bind: [status, availableAt, nowText, id]
            )
        }
        guard changes > 0 else { return nil }
        return try queueItem(id: id)
    }

    func enqueueTestMessage(chat: ChannelChat, author: String, body: String) throws -> ChannelQueueItem? {
        let now = ISO8601.now()
        let composite = "test|\(chat.chatID)|\(author)|\(body)|\(now)"
        let digest = SHA256.hash(data: Data(composite.utf8)).map { String(format: "%02x", $0) }.joined()
        let raw: [String: Any] = ["source": "ktok channel queue add-test", "author": author, "body": body, "detected_at": now]
        let rawData = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes])
        let rawJSON = String(data: rawData, encoding: .utf8)
        try db.transaction {
            try db.execute(
                "INSERT OR IGNORE INTO channel_messages(message_key, chat_id, author, body, time_raw, direction, detected_at, raw_json) VALUES (?, ?, ?, ?, ?, 'inbound', ?, ?)",
                bind: [digest, chat.chatID, author, body, nil, now, rawJSON]
            )
            try db.execute(
                "INSERT OR IGNORE INTO channel_inbox_queue(message_key, chat_id, status, priority, available_at, created_at, updated_at) VALUES (?, ?, 'pending', ?, ?, ?, ?)",
                bind: [digest, chat.chatID, chat.priority, now, now, now]
            )
        }
        return try queueItem(messageKey: digest)
    }

    func chatMapObject(updatedAt: String = ISO8601.now()) throws -> [String: Any] {
        let chats = try listChats()
        var exact: [String: String] = [:]
        var duplicates: [String: [String]] = [:]
        for chat in chats {
            if let existing = exact[chat.title] {
                exact.removeValue(forKey: chat.title)
                duplicates[chat.title] = [existing, chat.chatID]
            } else if duplicates[chat.title] != nil {
                duplicates[chat.title, default: []].append(chat.chatID)
            } else {
                exact[chat.title] = chat.chatID
            }
        }
        var object: [String: Any] = [
            "source": "ktok channel refresh-chats",
            "updated_at": updatedAt,
            "ttl_seconds": Self.defaultChatMapTTLSeconds,
            "matching_policy": "Use exact title match first; if duplicate titles exist, require disambiguation; prefer chat_id for sending when known.",
            "indexes": [
                "exact_title_to_chat_id": exact,
                "duplicate_title_to_chat_ids": duplicates,
            ],
            "chats": chats.map { [
                "title": $0.title,
                "chat_id": $0.chatID,
                "last_message": $0.lastMessage as Any,
                "is_monitored": $0.isMonitored,
                "mode": $0.mode,
                "priority": $0.priority,
            ] },
        ]
        // The self-chat title is user-specific and never hardcoded. Set it via
        // KTOK_SELF_CHAT to include a `self_chat` index entry.
        if let selfTitle = ProcessInfo.processInfo.environment["KTOK_SELF_CHAT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !selfTitle.isEmpty {
            object["self_chat"] = ["title": selfTitle, "chat_id": exact[selfTitle] as Any]
        }
        return object
    }

    func writeChatMapJSON(to path: URL? = nil) throws -> URL {
        let url = path ?? KtokPaths.home.appendingPathComponent("chat-id-map.json")
        let object = try chatMapObject()
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func rowToChat(_ row: Statement) -> ChannelChat {
        ChannelChat(
            chatID: row.columnText(at: 0) ?? "",
            title: row.columnText(at: 1) ?? "",
            lastMessage: row.columnText(at: 2),
            isMonitored: row.columnInt(at: 3) != 0,
            mode: row.columnText(at: 4) ?? "observe_only",
            priority: row.columnInt(at: 5),
            updatedAt: row.columnText(at: 6) ?? ""
        )
    }

    private func rowToQueueItem(_ row: Statement) -> ChannelQueueItem {
        ChannelQueueItem(
            id: row.columnInt64(at: 0),
            messageKey: row.columnText(at: 1) ?? "",
            chatID: row.columnText(at: 2) ?? "",
            title: row.columnText(at: 3),
            author: row.columnText(at: 4),
            body: row.columnText(at: 5),
            status: row.columnText(at: 6) ?? "",
            priority: row.columnInt(at: 7),
            attempts: row.columnInt(at: 8),
            availableAt: row.columnText(at: 9) ?? "",
            claimedAt: row.columnText(at: 10),
            claimedBy: row.columnText(at: 11),
            leaseExpiresAt: row.columnText(at: 12),
            createdAt: row.columnText(at: 13) ?? "",
            updatedAt: row.columnText(at: 14) ?? ""
        )
    }

    private func queueItem(id: Int64) throws -> ChannelQueueItem? {
        try queueItems(ids: [id]).first
    }

    private func queueItem(messageKey: String) throws -> ChannelQueueItem? {
        let stmt = try db.prepare("""
            SELECT q.id, q.message_key, q.chat_id, c.title, m.author, m.body,
                   q.status, q.priority, q.attempts, q.available_at, q.claimed_at,
                   q.claimed_by, q.lease_expires_at, q.created_at, q.updated_at
            FROM channel_inbox_queue q
            LEFT JOIN channel_messages m ON m.message_key=q.message_key
            LEFT JOIN channel_chats c ON c.chat_id=q.chat_id
            WHERE q.message_key=?
        """)
        try stmt.bindAll([messageKey])
        return try stmt.step() ? rowToQueueItem(stmt) : nil
    }

    private func queueItems(ids: [Int64]) throws -> [ChannelQueueItem] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let stmt = try db.prepare("""
            SELECT q.id, q.message_key, q.chat_id, c.title, m.author, m.body,
                   q.status, q.priority, q.attempts, q.available_at, q.claimed_at,
                   q.claimed_by, q.lease_expires_at, q.created_at, q.updated_at
            FROM channel_inbox_queue q
            LEFT JOIN channel_messages m ON m.message_key=q.message_key
            LEFT JOIN channel_chats c ON c.chat_id=q.chat_id
            WHERE q.id IN (\(placeholders))
            ORDER BY q.id ASC
        """)
        try stmt.bindAll(ids.map { $0 as Any })
        return try stmt.allRows { rowToQueueItem($0) }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let stmt = try db.prepare(sql)
        return try stmt.step() ? stmt.columnInt(at: 0) : 0
    }

    private func scalarText(_ sql: String) throws -> String? {
        let stmt = try db.prepare(sql)
        return try stmt.step() ? stmt.columnText(at: 0) : nil
    }

    private func messageKeyBase(chatID: String, message: TranscriptMessage) -> String {
        let composite = "\(chatID)|\(message.author ?? "(me)")|\(message.timeRaw ?? "")|\(message.body)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func messageKey(baseKey: String, occurrence: Int) -> String {
        let composite = "\(baseKey)|occurrence=\(occurrence)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func secureStoragePermissions() {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let path = dbPath + suffix
            if fm.fileExists(atPath: path) {
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
    }
}

enum ChannelError: Error, CustomStringConvertible {
    case chatNotFound(String)
    case ambiguousTitle(String)

    var description: String {
        switch self {
        case let .chatNotFound(message), let .ambiguousTitle(message):
            return message
        }
    }
}

enum ChannelSchedule {
    static func nextIntervalSeconds(now: Date = Date(), lastActivityAtISO: String?) -> Int {
        if let lastActivityAtISO,
           let last = parseISO(lastActivityAtISO),
           now.timeIntervalSince(last) <= 300
        {
            return 5
        }

        let calendar = Calendar(identifier: .gregorian)
        let comps = calendar.dateComponents(in: TimeZone(identifier: "Asia/Seoul") ?? .current, from: now)
        let weekday = comps.weekday ?? 1 // 1 Sunday ... 7 Saturday
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let minutes = hour * 60 + minute

        if minutes >= 2 * 60 && minutes < 5 * 60 {
            return 15 * 60
        }
        if weekday >= 2 && weekday <= 6 && minutes >= 8 * 60 && minutes < 15 * 60 {
            return 15
        }
        return 3 * 60
    }

    private static func parseISO(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: text) { return date }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
