import ArgumentParser
import Foundation

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Query the local ktok message database",
        discussion: """
            Search messages and attachments stored by `ktok sync-history` or
            `ktok import-history`. Filter by chat, time range, kind, author,
            or free-text body search. Defaults to newest-first, capped at 50.

            Examples:
              ktok history "채팅방"
              ktok history "채팅방" --since 2026-04-01 --kind file
              ktok history "채팅방" --author "홍길동" --query "회의"
              ktok history --attachments --kind file --since 2026-04-10 --json
            """
    )

    @Argument(help: "Chat display name (optional — omit to search across all chats)")
    var chatName: String?

    @Option(name: .customLong("since"), help: "ISO-8601 date/datetime lower bound (inclusive)")
    var since: String?

    @Option(name: .customLong("until"), help: "ISO-8601 date/datetime upper bound (inclusive)")
    var until: String?

    @Option(name: .customLong("kind"), parsing: .upToNextOption, help: "Filter by message kind(s): text, image, file, voice, video, emoticon, system, other")
    var kinds: [String] = []

    @Option(name: .customLong("author"), parsing: .upToNextOption, help: "Filter by author name(s)")
    var authors: [String] = []

    @Option(name: .customLong("query"), help: "Substring search on message body (or filename if --attachments)")
    var textQuery: String?

    @Option(name: .customLong("limit"), help: "Max rows to return (1-5000, default 50)")
    var limit: Int = 50

    @Flag(name: .long, help: "Query the attachments table instead of messages")
    var attachments: Bool = false

    @Flag(name: .customLong("oldest-first"), help: "Return oldest rows first instead of newest")
    var oldestFirst: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of a human-readable table")
    var json: Bool = false

    func run() throws {
        let bounded = max(1, min(5000, limit))

        let db: Database
        do {
            db = try Database(path: KtokPaths.activeDatabasePath())
            try Migrations.run(on: db)
        } catch {
            emitError(code: "DB_INIT_FAILED", message: String(describing: error))
            throw ExitCode.failure
        }

        var query = HistoryQuery()
        query.chatName = (chatName?.isEmpty ?? true) ? nil : ChatIdentityHash.forStorage(chatName!)
        query.since = normalizeISOBound(since, endOfDay: false)
        query.until = normalizeISOBound(until, endOfDay: true)
        query.kinds = kinds.isEmpty ? nil : kinds
        // Normalize authors + textQuery to NFC to match stored values.
        // Shell / MCP-delivered Korean may arrive as NFD, while DB is NFC.
        query.authors = authors.isEmpty ? nil : authors.map(ChatIdentityHash.forStorage)
        query.textQuery = textQuery.map(ChatIdentityHash.forStorage)
        query.limit = bounded
        query.order = oldestFirst ? .ascending : .descending

        if attachments {
            let repo = AttachmentRepository(db: db)
            let rows = try repo.search(query)
            emitAttachments(rows)
        } else {
            let repo = MessageRepository(db: db)
            let rows = try repo.search(query)
            emitMessages(rows)
        }
    }

    /// Accept both full ISO-8601 and shorthand `YYYY-MM-DD`. For `--since`,
    /// a bare date resolves to `00:00:00Z`; for `--until`, to `23:59:59Z`.
    private func normalizeISOBound(_ raw: String?, endOfDay: Bool) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.contains("T") || raw.contains("Z") {
            return raw
        }
        return raw + (endOfDay ? "T23:59:59Z" : "T00:00:00Z")
    }

    // MARK: - Output

    private func emitMessages(_ rows: [MessageRecord]) {
        if json {
            let out: [String: Any] = [
                "ok": true,
                "count": rows.count,
                "messages": rows.map { row in
                    [
                        "chat_id": row.chatId,
                        "sent_at": row.sentAt,
                        "author": row.author,
                        "kind": row.kind.rawValue,
                        "body": row.body,
                    ] as [String: Any]
                },
            ]
            printJSON(out)
        } else {
            for row in rows {
                let kindTag = row.kind == .text ? "" : "[\(row.kind.rawValue)] "
                let preview = row.body
                    .replacingOccurrences(of: "\n", with: " ↵ ")
                    .prefix(140)
                print("\(row.sentAt)  \(row.author.padding(toLength: 20, withPad: " ", startingAt: 0))  \(kindTag)\(preview)")
            }
            print("— \(rows.count) row(s)")
        }
    }

    private func emitAttachments(_ rows: [AttachmentRecord]) {
        if json {
            let out: [String: Any] = [
                "ok": true,
                "count": rows.count,
                "attachments": rows.map { row in
                    [
                        "chat_id": row.chatId,
                        "sent_at": row.sentAt as Any,
                        "direction": row.direction.rawValue,
                        "filename": row.filename as Any,
                        "local_path": row.localPath as Any,
                        "source": row.source.rawValue,
                    ] as [String: Any]
                },
            ]
            printJSON(out)
        } else {
            for row in rows {
                let ts = row.sentAt ?? "-"
                let direction = row.direction.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
                let filename = row.filename ?? "(no filename)"
                print("\(ts)  \(direction)  \(filename)")
            }
            print("— \(rows.count) attachment(s)")
        }
    }

    private func emitError(code: String, message: String) {
        if json {
            let out: [String: Any] = [
                "ok": false,
                "error": ["code": code, "message": message],
            ]
            printJSON(out)
        } else {
            print("[\(code)] \(message)")
        }
    }

    private func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            print("{}")
            return
        }
        print(text)
    }
}
