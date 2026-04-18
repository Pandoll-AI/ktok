import ArgumentParser
import Foundation

struct SyncHistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-history",
        abstract: "Download full chat history via AX and upsert into the ktok database",
        discussion: """
            Drives KakaoTalk's "Save as a text file" flow end-to-end:
              1. Opens the chat (via ChatWindowResolver)
              2. ChatSettingsNavigator.runExportFlow:
                 hamburger → Chatroom Settings → Manage Chats tab → Save
                 as a text file → Save button in NSSavePanel
              3. DirectoryWatcher waits for CSV to land in ~/Downloads
              4. Dismisses the "Successfully exported" confirmation dialog
              5. Relocates to --save-dir if different
              6. Parses + upserts into the local SQLite DB

            Dedup is SHA-256(chat_id|sent_at|author|body), so re-running is
            idempotent — same data exits with 0 new inserts.

            Examples:
              ktok sync-history "채팅방"
              ktok sync-history "Emergency Lee" --my-kakao-id "Emergency Lee" --json
              ktok sync-history "팀방" --save-dir /tmp/ktok/dumps --trace-ax
            """
    )

    @Argument(help: "Name of the chat to export")
    var chatName: String

    @Option(name: .customLong("save-dir"), help: "Directory for the CSV dump (default: /tmp/ktok/dumps)")
    var saveDir: String = "/tmp/ktok/dumps"

    @Option(name: .customLong("my-kakao-id"), help: "Your own KakaoTalk display name — tags attachment direction")
    var myKakaoId: String?

    @Option(name: .customLong("save-panel-timeout"), help: "Seconds to wait for the Save panel (default 6)")
    var savePanelTimeout: Double = 6.0

    @Option(name: .customLong("stable-timeout-sec"), help: "Seconds to wait for CSV to stabilize (default 40)")
    var stableTimeoutSec: Double = 40.0

    @Flag(name: .long, help: "Emit a single JSON object to stdout")
    var json: Bool = false

    @Flag(name: .long, help: "Include AX traversal tracing in output")
    var traceAX: Bool = false

    @Flag(name: [.short, .long], help: "Keep chat window open after sync")
    var keepWindow: Bool = false

    @Flag(name: .long, help: "Enable deep window recovery for flaky AX states")
    var deepRecovery: Bool = false

    @Flag(name: .long, help: "Block execution, return CONFIRMATION_REQUIRED (MCP confirm flow)")
    var confirm: Bool = false

    @Flag(name: .customLong("no-dismiss-dialog"), help: "Debug only: skip AX press on the 'Successfully exported' OK dialog.")
    var noDismissDialog: Bool = false

    @Flag(name: .customLong("skip-save-press"), help: "Debug only: stop before pressing Save in NSSavePanel — user must click Save manually.")
    var skipSavePress: Bool = false

    @Flag(name: .customLong("stop-before-save-as-text"), help: "Debug only: stop after reaching the Manage Chats tab but BEFORE pressing 'Save as a text file'. User manually clicks Save-as-text. Isolates whether a beep originates from our save-as-text AXPress.")
    var stopBeforeSaveAsText: Bool = false

    @Flag(name: .customLong("debug-slow"), help: "Debug only: insert 2-second pauses between each AX step so a human can follow the flow + verify whether 'Cannot complete' errors resolve with longer idle time before the press.")
    var debugSlow: Bool = false

    func validate() throws {
        if chatName.isEmpty {
            throw ValidationError("Chat name is required.")
        }
    }

    func run() throws {
        let start = Date()

        // --- Preconditions ---
        if confirm {
            emitError(code: "CONFIRMATION_REQUIRED",
                      message: "ktok sync-history blocked because --confirm is set",
                      hint: "Ask user for explicit approval, then re-run without --confirm.",
                      start: start)
            throw ExitCode.failure
        }
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        // --- Setup: save dir, AX runner, KakaoTalk, chat resolver ---
        let expandedSaveDir = URL(fileURLWithPath: (saveDir as NSString).expandingTildeInPath).standardizedFileURL.path
        let downloadsDir = URL(fileURLWithPath: ("~/Downloads" as NSString).expandingTildeInPath).standardizedFileURL.path
        try? FileManager.default.createDirectory(atPath: expandedSaveDir, withIntermediateDirectories: true)

        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao: KakaoTalkApp
        do {
            kakao = try KakaoTalkApp()
        } catch {
            emitError(code: "KAKAO_WINDOW_UNAVAILABLE", message: "Failed to attach to KakaoTalk: \(error)", start: start)
            throw ExitCode.failure
        }

        let resolver = ChatWindowResolver(kakao: kakao, runner: runner, useCache: true, deepRecoveryEnabled: deepRecovery)
        let resolution: ChatWindowResolution
        do {
            resolution = try resolver.resolve(query: chatName)
        } catch {
            emitError(code: "CHAT_NOT_FOUND", message: "\(error)", start: start)
            throw ExitCode.failure
        }
        let resolvedWindowTitle = resolution.window.title ?? chatName
        defer { if !keepWindow { _ = resolver.closeWindow(resolution.window) } }

        kakao.activate()
        Thread.sleep(forTimeInterval: 0.4)

        // --- Snapshot watched dirs BEFORE triggering the export ---
        // KakaoTalk always saves to ~/Downloads regardless of --save-dir.
        // Relocation is handled post-landing. We watch both dirs so a user
        // who configures an alternative --save-dir doesn't miss files that
        // land in Downloads first.
        let watchedDirs = (expandedSaveDir != downloadsDir && FileManager.default.fileExists(atPath: downloadsDir))
            ? [expandedSaveDir, downloadsDir]
            : [expandedSaveDir]
        let baseline = Dictionary(uniqueKeysWithValues: watchedDirs.map { ($0, DirectoryWatcher.snapshot($0)) })

        // --- Drive the AX export flow (single call) ---
        let navigator = ChatSettingsNavigator(
            kakao: kakao,
            runner: runner,
            interStepDelay: debugSlow ? 2.0 : 0.0
        )
        do {
            try navigator.runExportFlow(
                chatWindow: resolution.window,
                skipSavePress: skipSavePress,
                stopBeforeSaveAsText: stopBeforeSaveAsText
            )
        } catch let err as ChatSettingsNavigatorError {
            emitError(code: axErrorCode(for: err), message: err.description, start: start)
            throw ExitCode.failure
        } catch {
            emitError(code: "AX_EXPORT_FLOW_FAILED", message: String(describing: error), start: start)
            throw ExitCode.failure
        }

        // --- Wait for the CSV to land ---
        let clampedStable = max(1.0, min(300.0, stableTimeoutSec))
        guard let dumpPath = DirectoryWatcher.waitForNewStableFile(dirs: watchedDirs, baseline: baseline, timeoutSec: clampedStable) else {
            emitError(code: "DUMP_NOT_OBSERVED",
                      message: "Save flow completed but no new stable CSV appeared within \(Int(clampedStable))s",
                      hint: "Watched: \(watchedDirs). Raise --stable-timeout-sec.",
                      start: start)
            throw ExitCode.failure
        }

        // --- Dismiss the "Successfully exported" dialog (unless skipped) ---
        if !noDismissDialog {
            _ = navigator.dismissExportDoneDialog()
        }

        // --- Relocate + import ---
        let finalPath = (expandedSaveDir == downloadsDir)
            ? dumpPath
            : DirectoryWatcher.relocateIfNeeded(dumpPath, preferredDir: expandedSaveDir)

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
            result = try importer.importFile(path: finalPath, chatNameOverride: resolvedWindowTitle)
        } catch {
            emitError(code: "IMPORT_FAILED", message: String(describing: error), start: start)
            throw ExitCode.failure
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        emitSuccess(result: result, latencyMs: latencyMs)
    }

    private func axErrorCode(for err: ChatSettingsNavigatorError) -> String {
        switch err {
        case .hamburgerNotFound:                return "AX_HAMBURGER_FAILED"
        case .chatroomSettingsMenuItemNotFound: return "AX_SETTINGS_MENU_FAILED"
        case .settingsPanelNeverAppeared:       return "AX_SETTINGS_PANEL_FAILED"
        case .manageChatsNotFound:              return "AX_MANAGE_CHATS_FAILED"
        case .saveButtonNotFound:               return "AX_SAVE_BUTTON_FAILED"
        }
    }

    // MARK: - Output

    private func emitSuccess(result: HistoryImporter.Result, latencyMs: Int) {
        if json {
            let payload: [String: Any] = [
                "ok": true,
                "chat_id": result.chatId,
                "chat_name": result.chatName,
                "dump_file": result.filePath,
                "lines_parsed": result.parsedDump.totalRowsParsed,
                "messages_inserted": result.messagesInserted,
                "messages_skipped_duplicates": result.messagesSkipped,
                "attachments_inserted": result.attachmentsInserted,
                "rejected_rows": result.parsedDump.rejectedRows.count,
                "sync_run_id": result.syncRunId,
                "db_path": Database.defaultPath(),
                "meta": ["latency_ms": latencyMs],
            ]
            printJSON(payload)
        } else {
            print("✓ Synced chat '\(result.chatName)' (chat_id=\(result.chatId))")
            print("  dump:     \(result.filePath)")
            print("  parsed:   \(result.parsedDump.totalRowsParsed) rows")
            print("  inserted: \(result.messagesInserted) messages (skipped dupes: \(result.messagesSkipped)), \(result.attachmentsInserted) attachments")
            print("  db:       \(Database.defaultPath())  sync_run_id=\(result.syncRunId)")
        }
    }

    private func emitError(code: String, message: String, hint: String = "", start: Date) {
        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        if json {
            let payload: [String: Any] = [
                "ok": false,
                "error": ["code": code, "message": message, "hint": hint],
                "meta": ["latency_ms": latencyMs],
            ]
            printJSON(payload)
        } else {
            print("[\(code)] \(message)\(hint.isEmpty ? "" : " — \(hint)")")
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
