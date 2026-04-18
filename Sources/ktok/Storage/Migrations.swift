import Foundation

/// Forward-only schema migrations. Each migration is applied in a single
/// transaction, then its version number is recorded in `schema_version`.
/// Never edit existing migrations — always append a new one.
enum Migrations {
    static let latestVersion = 1

    private static let migrations: [(version: Int, sql: String)] = [
        (1, schemaV1),
    ]

    static func run(on db: Database) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS schema_version (
              version     INTEGER PRIMARY KEY,
              applied_at  TEXT NOT NULL
            )
        """)

        let current = try currentVersion(on: db)
        for (version, sql) in migrations where version > current {
            try db.transaction {
                try db.executeScript(sql)
                try db.execute(
                    "INSERT INTO schema_version(version, applied_at) VALUES (?, ?)",
                    bind: [version, ISO8601.now()]
                )
            }
        }
    }

    private static func currentVersion(on db: Database) throws -> Int {
        let stmt = try db.prepare("SELECT COALESCE(MAX(version), 0) FROM schema_version")
        if try stmt.step() {
            return stmt.columnInt(at: 0)
        }
        return 0
    }

    private static let schemaV1 = """
    CREATE TABLE chats (
      chat_id         TEXT PRIMARY KEY,
      display_name    TEXT NOT NULL,
      my_nickname     TEXT,
      first_seen_at   TEXT NOT NULL,
      last_synced_at  TEXT
    );

    CREATE TABLE messages (
      id               INTEGER PRIMARY KEY AUTOINCREMENT,
      chat_id          TEXT NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
      sent_at          TEXT NOT NULL,
      author           TEXT NOT NULL,
      body             TEXT NOT NULL,
      kind             TEXT NOT NULL,
      raw_line         TEXT,
      dedupe_key       TEXT NOT NULL UNIQUE,
      first_synced_at  TEXT NOT NULL
    );

    CREATE INDEX idx_messages_chat_time   ON messages(chat_id, sent_at DESC);
    CREATE INDEX idx_messages_kind        ON messages(kind);
    CREATE INDEX idx_messages_author      ON messages(author);

    CREATE TABLE attachments (
      id           INTEGER PRIMARY KEY AUTOINCREMENT,
      chat_id      TEXT NOT NULL REFERENCES chats(chat_id) ON DELETE CASCADE,
      message_id   INTEGER REFERENCES messages(id) ON DELETE SET NULL,
      direction    TEXT NOT NULL,
      filename     TEXT,
      local_path   TEXT,
      sent_at      TEXT,
      size_bytes   INTEGER,
      sha256       TEXT,
      source       TEXT NOT NULL,
      recorded_at  TEXT NOT NULL
    );

    CREATE INDEX idx_attachments_chat_time ON attachments(chat_id, sent_at DESC);
    CREATE INDEX idx_attachments_source    ON attachments(source);

    CREATE TABLE sync_runs (
      id                            INTEGER PRIMARY KEY AUTOINCREMENT,
      chat_id                       TEXT NOT NULL,
      started_at                    TEXT NOT NULL,
      finished_at                   TEXT,
      dump_file_path                TEXT,
      lines_parsed                  INTEGER,
      messages_inserted             INTEGER,
      messages_skipped_duplicates   INTEGER,
      attachments_inserted          INTEGER,
      error                         TEXT
    );
    """
}

/// Centralized ISO-8601 helpers — all timestamps in the DB are UTC ISO-8601.
/// Formatters are built per-call because `DateFormatter` / `ISO8601DateFormatter`
/// are not Sendable; caching them as `static let` would violate Swift 6's
/// strict-concurrency checking. Per-call cost is ~1µs — irrelevant compared
/// to DB I/O and AX latency.
enum ISO8601 {
    private static func utcFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private static func kakaoFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    static func now() -> String {
        utcFormatter().string(from: Date())
    }

    static func format(_ date: Date) -> String {
        utcFormatter().string(from: date)
    }

    /// Parse a KakaoTalk-exported timestamp (`yyyy-MM-dd HH:mm:ss`, naive,
    /// assumed KST), return a UTC ISO-8601 string. Returns nil on parse fail.
    static func parseKakaoTimestamp(_ raw: String) -> String? {
        guard let date = kakaoFormatter().date(from: raw) else { return nil }
        return utcFormatter().string(from: date)
    }
}
