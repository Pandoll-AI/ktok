import ArgumentParser
import CryptoKit
import Foundation

struct MonitorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Inactive: legacy UI monitor is disabled",
        discussion: "The legacy Accessibility-based monitor is intentionally inactive. Reactivation is backlogged until the kakaotalk-db Python reader is replaced with a Swift implementation."
    )

    @Argument(help: "Chat room name to monitor")
    var chat: String

    @Option(name: .long, help: "Persona to use. Currently supported: luna")
    var persona: String = "luna"

    @Option(name: .long, help: "Optional extra sleep in seconds after each monitor poll")
    var pollInterval: Double = 0

    @Option(name: .long, help: "Codex model for reply generation")
    var model: String = "gpt-6-luna"

    @Option(name: .long, help: "Codex reasoning effort config value")
    var reasoningEffort: String = "low"

    @Option(name: .long, help: "Seconds to wait for Codex reply generation")
    var replyTimeout: Double = 20

    @Option(name: .long, help: "Seconds between monitor heartbeat events. Use 0 to disable")
    var heartbeatInterval: Double = 60

    @Option(name: .long, help: "Maximum visible messages to keep in each fixed-room snapshot")
    var snapshotLimit: Int = 8

    @Option(name: .long, help: "Restart this monitor after N consecutive read recovery failures. Use 0 to disable")
    var restartAfterReadFailures: Int = 6

    @Option(name: .long, help: "Seconds to wait before self-restarting the monitor")
    var restartDelay: Double = 1

    @Flag(name: .long, help: "Show AX traversal and monitor trace")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Enable deep window recovery for flaky AX states")
    var deepRecovery: Bool = false

    @Flag(name: .long, help: "Do not send replies; only log decisions")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Emit concise JSONL monitor events")
    var json: Bool = false

    func validate() throws {
        if chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("Chat room name is required.")
        }
        if persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("Persona name is required.")
        }
    }

    func run() throws {
        throw ValidationError("ktok monitor is inactive. Reactivation is backlogged until kakaotalk-db Python is replaced with Swift.")
    }
}

/// Persistent seen/reply state for persona reply loops (monitor and bot),
/// keyed by a per-(account, room, persona) monitor id.
enum MonitorStateStore {
    static func open() throws -> Database {
        let db = try Database(path: KtokPaths.activeDatabasePath())
        try Migrations.run(on: db)
        return db
    }

    static func ensureTables(db: Database) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS monitor_seen (
              monitor_id     TEXT NOT NULL,
              message_key    TEXT NOT NULL,
              author         TEXT,
              time_raw       TEXT,
              body           TEXT NOT NULL,
              first_seen_at  TEXT NOT NULL,
              PRIMARY KEY (monitor_id, message_key)
            )
        """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS monitor_replies (
              id           INTEGER PRIMARY KEY AUTOINCREMENT,
              monitor_id   TEXT NOT NULL,
              message_key  TEXT NOT NULL,
              reply_body   TEXT NOT NULL,
              status       TEXT NOT NULL,
              error        TEXT,
              sent_at      TEXT NOT NULL
            )
        """)
        try db.execute("CREATE INDEX IF NOT EXISTS idx_monitor_replies_monitor_time ON monitor_replies(monitor_id, sent_at DESC)")
    }

    static func monitorID(accountAlias: String, chatTitle: String, persona: String) -> String {
        "mon_\(hash("\(accountAlias)|\(chatTitle)|\(persona)").prefix(12))"
    }

    static func messageKey(_ message: TranscriptMessage) -> String {
        hash("\(message.author ?? "")|\(message.timeRaw ?? "")|\(message.body)")
    }

    static func hasSeen(db: Database, monitorID: String, messageKey: String) throws -> Bool {
        let stmt = try db.prepare("SELECT 1 FROM monitor_seen WHERE monitor_id = ? AND message_key = ? LIMIT 1")
        try stmt.bindAll([monitorID, messageKey])
        return try stmt.step()
    }

    static func rememberSeen(db: Database, monitorID: String, messages: [TranscriptMessage]) throws {
        guard !messages.isEmpty else { return }
        try db.transaction {
            let stmt = try db.prepare("""
                INSERT OR IGNORE INTO monitor_seen(monitor_id, message_key, author, time_raw, body, first_seen_at)
                VALUES (?, ?, ?, ?, ?, ?)
            """)
            for message in messages {
                try stmt.bindAll([monitorID, messageKey(message), message.author, message.timeRaw, message.body, ISO8601.now()])
                _ = try stmt.step()
                stmt.reset()
            }
        }
    }

    static func rememberSeen(db: Database, monitorID: String, message: TranscriptMessage, messageKey: String) throws {
        try db.execute("""
            INSERT OR IGNORE INTO monitor_seen(monitor_id, message_key, author, time_raw, body, first_seen_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, bind: [monitorID, messageKey, message.author, message.timeRaw, message.body, ISO8601.now()])
    }

    static func recordReply(db: Database, monitorID: String, messageKey: String, reply: String, status: String, error: String?) throws {
        try db.execute("""
            INSERT INTO monitor_replies(monitor_id, message_key, reply_body, status, error, sent_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, bind: [monitorID, messageKey, reply, status, error, ISO8601.now()])
    }

    static func recentSentBodies(db: Database, monitorID: String, limit: Int) throws -> [String] {
        let stmt = try db.prepare("""
            SELECT reply_body FROM monitor_replies
            WHERE monitor_id = ? AND status = 'sent'
            ORDER BY sent_at DESC
            LIMIT ?
        """)
        try stmt.bindAll([monitorID, limit])
        return try stmt.allRows { $0.columnText(at: 0) ?? "" }
    }

    private static func hash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
