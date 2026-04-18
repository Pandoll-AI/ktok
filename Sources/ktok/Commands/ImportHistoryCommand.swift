import ArgumentParser
import Foundation

struct ImportHistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-history",
        abstract: "Import a KakaoTalk CSV chat export into the ktok database",
        discussion: """
            Parse a previously-downloaded KakaoTalk CSV (the "Save as a text
            file" export) and upsert its messages and attachments into the
            local SQLite database at
            ~/Library/Application Support/ktok/ktok.db.

            If --chat-name is omitted, ktok tries to extract it from the
            filename pattern 'KakaoTalk_Chat_<name>_<timestamp>.csv'. The
            chat_id is derived deterministically from the name (SHA-256
            prefix) so re-importing the same chat upserts into the same row.

            Messages are deduplicated by SHA-256(chat_id | sent_at | author |
            body) — running import twice on the same file is a no-op.

            Examples:
              ktok import-history ~/Downloads/KakaoTalk_Chat_abc_*.csv
              ktok import-history file.csv --chat-name "친구방" --my-kakao-id "내ID"
              ktok import-history file.csv --json
            """
    )

    @Argument(help: "Path to the KakaoTalk CSV export")
    var filePath: String

    @Option(name: .customLong("chat-name"), help: "Chat display name (if omitted, derived from filename)")
    var chatName: String?

    @Option(name: .customLong("chat-id"), help: "Explicit chat_id to reuse (else derived from chat-name)")
    var chatId: String?

    @Option(name: .customLong("my-kakao-id"), help: "Your own KakaoTalk display name — used to tag attachment direction")
    var myKakaoId: String?

    @Flag(name: .long, help: "Emit a single JSON object to stdout")
    var json: Bool = false

    func validate() throws {
        if filePath.isEmpty {
            throw ValidationError("File path is required.")
        }
    }

    func run() throws {
        let start = Date()

        let db: Database
        do {
            db = try Database(path: Database.defaultPath())
            try Migrations.run(on: db)
        } catch {
            emitError(code: "DB_INIT_FAILED", message: String(describing: error), start: start)
            throw ExitCode.failure
        }

        let importer = HistoryImporter(db: db, myKakaoId: myKakaoId)
        let result: HistoryImporter.Result
        do {
            result = try importer.importFile(path: filePath, chatNameOverride: chatName, chatIdOverride: chatId)
        } catch let err as HistoryImporter.ImportError {
            switch err {
            case .fileNotFound:
                emitError(code: "FILE_NOT_FOUND", message: err.description, start: start)
            case .chatNameRequired:
                emitError(code: "CHAT_NAME_REQUIRED", message: err.description, hint: "Pass --chat-name \"채팅방이름\".", start: start)
            case .csvParseFailed:
                emitError(code: "CSV_PARSE_FAILED", message: err.description, start: start)
            case .dbFailed:
                emitError(code: "IMPORT_FAILED", message: err.description, start: start)
            }
            throw ExitCode.failure
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        emitSuccess(result: result, latencyMs: latencyMs)
    }

    // MARK: - Output

    private func emitSuccess(result: HistoryImporter.Result, latencyMs: Int) {
        let chatName = result.chatName
        let chatId = result.chatId
        let filePath = result.filePath
        let parsed = result.parsedDump
        let inserted = result.messagesInserted
        let skipped = result.messagesSkipped
        let attachmentsInserted = result.attachmentsInserted
        let syncRunId = result.syncRunId
        if json {
            let result: [String: Any] = [
                "ok": true,
                "chat_id": chatId,
                "chat_name": chatName,
                "file": filePath,
                "lines_parsed": parsed.totalRowsParsed,
                "messages_inserted": inserted,
                "messages_skipped_duplicates": skipped,
                "attachments_inserted": attachmentsInserted,
                "rejected_rows": parsed.rejectedRows.count,
                "rejected_samples": parsed.rejectedRows.prefix(5).map {
                    ["line": $0.lineNumber, "reason": $0.reason, "raw": $0.raw] as [String: Any]
                },
                "sync_run_id": syncRunId,
                "db_path": Database.defaultPath(),
                "meta": ["latency_ms": latencyMs],
            ]
            printJSON(result)
        } else {
            print("✓ Imported: \(filePath)")
            print("  chat: '\(chatName)'  (chat_id=\(chatId))")
            print("  lines parsed: \(parsed.totalRowsParsed)")
            print("  messages inserted: \(inserted) (skipped duplicates: \(skipped))")
            print("  attachments inserted: \(attachmentsInserted)")
            if !parsed.rejectedRows.isEmpty {
                print("  ⚠️  rejected rows: \(parsed.rejectedRows.count) — first sample:")
                for sample in parsed.rejectedRows.prefix(3) {
                    print("     line \(sample.lineNumber): \(sample.reason)")
                }
            }
            print("  db: \(Database.defaultPath())  sync_run_id=\(syncRunId)")
        }
    }

    private func emitError(code: String, message: String, hint: String = "", start: Date) {
        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        if json {
            let result: [String: Any] = [
                "ok": false,
                "error": [
                    "code": code,
                    "message": message,
                    "hint": hint,
                ],
                "meta": ["latency_ms": latencyMs],
            ]
            printJSON(result)
        } else {
            print("[\(code)] \(message)\(hint.isEmpty ? "" : " — \(hint)")")
        }
    }

    private func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]),
              let text = String(data: data, encoding: .utf8)
        else {
            print("{}")
            return
        }
        print(text)
    }
}
