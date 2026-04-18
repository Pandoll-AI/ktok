import ArgumentParser
import Foundation

struct SyncHistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-history",
        abstract: "Download full chat history via AX and upsert into the ktok database",
        discussion: """
            Drives KakaoTalk's "Save as a text file" flow:
              1. Opens the chat
              2. Clicks the hamburger in the chat window's top-right
              3. Clicks "Manage Chats" in the left panel
              4. Clicks "Save as a text file"
              5. Overrides the Save panel's destination to --save-dir
              6. Waits for the CSV to land, then parses + upserts

            Messages are deduplicated by SHA-256(chat_id|sent_at|author|body),
            so running sync-history repeatedly is safe — only new messages
            are inserted. Attachments only record on fresh insert.

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

    func validate() throws {
        if chatName.isEmpty {
            throw ValidationError("Chat name is required.")
        }
    }

    func run() throws {
        let start = Date()

        if confirm {
            emitError(
                code: "CONFIRMATION_REQUIRED",
                message: "ktok sync-history blocked because --confirm is set",
                hint: "Ask user for explicit approval, then re-run without --confirm.",
                start: start
            )
            throw ExitCode.failure
        }

        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        // Expand save-dir and ensure it exists before the Save panel lands.
        let expandedSaveDir = URL(fileURLWithPath: (saveDir as NSString).expandingTildeInPath).standardizedFileURL.path
        do {
            try FileManager.default.createDirectory(atPath: expandedSaveDir, withIntermediateDirectories: true)
        } catch {
            emitError(code: "INVALID_ARGUMENT", message: "Cannot create save-dir: \(error)", start: start)
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao: KakaoTalkApp
        do {
            kakao = try KakaoTalkApp()
        } catch {
            emitError(code: "KAKAO_WINDOW_UNAVAILABLE", message: "Failed to attach to KakaoTalk: \(error)", start: start)
            throw ExitCode.failure
        }

        let resolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            useCache: true,
            deepRecoveryEnabled: deepRecovery
        )

        let resolution: ChatWindowResolution
        let resolvedWindowTitle: String
        do {
            resolution = try resolver.resolve(query: chatName)
            resolvedWindowTitle = resolution.window.title ?? chatName
            runner.log("sync-history: chat window resolved title='\(resolvedWindowTitle)'")
        } catch {
            emitError(code: "CHAT_NOT_FOUND", message: "\(error)", start: start)
            throw ExitCode.failure
        }

        defer {
            if !keepWindow {
                _ = resolver.closeWindow(resolution.window)
            }
        }

        kakao.activate()
        Thread.sleep(forTimeInterval: 0.4)

        let navigator = ChatSettingsNavigator(kakao: kakao, runner: runner)

        // Snapshot the save-dir before pressing Save so DirectoryWatcher can
        // identify the newly-landed CSV. We watch BOTH the explicit save-dir
        // and ~/Downloads because KakaoTalk sometimes ignores the Cmd+Shift+G
        // override and falls back to its default path.
        let defaultDownloads = URL(fileURLWithPath: ("~/Downloads" as NSString).expandingTildeInPath).standardizedFileURL.path
        var watchedDirs: [String] = [expandedSaveDir]
        if expandedSaveDir != defaultDownloads,
           FileManager.default.fileExists(atPath: defaultDownloads) {
            watchedDirs.append(defaultDownloads)
        }
        var baseline: [String: DirectoryWatcher.Snapshot] = [:]
        for dir in watchedDirs {
            baseline[dir] = DirectoryWatcher.snapshot(dir)
        }

        // Drive the three-step UI path. Any step failure aborts with a code.
        let settingsRoot: UIElement
        do {
            settingsRoot = try navigator.openChatSettings(in: resolution.window)
        } catch let err as ChatSettingsNavigatorError {
            emitError(code: "AX_HAMBURGER_FAILED", message: err.description, start: start)
            throw ExitCode.failure
        } catch {
            emitError(code: "AX_HAMBURGER_FAILED", message: String(describing: error), start: start)
            throw ExitCode.failure
        }

        do {
            try navigator.clickManageChatsAndSaveAsText(in: settingsRoot, chatWindow: resolution.window)
        } catch let err as ChatSettingsNavigatorError {
            emitError(code: "AX_SAVE_BUTTON_FAILED", message: err.description, start: start)
            throw ExitCode.failure
        } catch {
            emitError(code: "AX_SAVE_BUTTON_FAILED", message: String(describing: error), start: start)
            throw ExitCode.failure
        }

        // DIAGNOSTIC: after pressing Save-as-text, KakaoTalk's actual
        // behavior is to save directly to ~/Downloads without opening an
        // NSSavePanel, then show a "successfully exported" confirmation
        // dialog. The previous keystroke-based `overridePath` / `acceptDefault`
        // calls were firing Cmd+Shift+G + Cmd+A + Cmd+V + Return + Return
        // AT that confirmation dialog, producing rejected-keystroke dings.
        //
        // New policy: don't fire any keystrokes. Just wait for the file to
        // land; the confirmation dialog is dismissed explicitly below after
        // the file stabilizes (via AX AXPress on its OK button, not keys).
        runner.log("sync-history: skipping NSSavePanel keystrokes — KakaoTalk saves silently to ~/Downloads")
        let panelShown = false
        let savePanelOverridden = false

        // Wait for new stable CSV.
        let clampedStable = max(1.0, min(300.0, stableTimeoutSec))
        let downloadedFile = DirectoryWatcher.waitForNewStableFile(
            dirs: watchedDirs,
            baseline: baseline,
            timeoutSec: clampedStable
        )

        // Dismiss the "Successfully exported your chat history" confirmation
        // dialog via AX AXPress on its OK button. Using AXPress (not
        // keystroke) avoids the system-beep that fires when keys are sent
        // to a dialog that isn't accepting them yet.
        _ = ExportDoneDialogDismisser.dismiss(kakao: kakao, runner: runner)

        guard let dumpPath = downloadedFile else {
            emitError(
                code: "DUMP_NOT_OBSERVED",
                message: "Save flow completed but no new stable CSV appeared within \(Int(clampedStable))s",
                hint: "Watched: \(watchedDirs). Raise --stable-timeout-sec or check Save panel manually.",
                start: start
            )
            throw ExitCode.failure
        }

        // Relocate to save-dir if it landed in ~/Downloads and user wanted elsewhere.
        var finalPath = dumpPath
        if expandedSaveDir != defaultDownloads,
           URL(fileURLWithPath: dumpPath).deletingLastPathComponent().path != expandedSaveDir,
           !savePanelOverridden {
            finalPath = DirectoryWatcher.relocateIfNeeded(dumpPath, preferredDir: expandedSaveDir)
        }

        runner.log("sync-history: dump saved at \(finalPath)")

        // Parse + upsert via the shared HistoryImporter.
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
        emitSuccess(result: result, savePanelOverridden: savePanelOverridden, panelShown: panelShown, latencyMs: latencyMs)
    }

    // MARK: - Output

    private func emitSuccess(result: HistoryImporter.Result, savePanelOverridden: Bool, panelShown: Bool, latencyMs: Int) {
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
                "save_panel_shown": panelShown,
                "save_panel_overridden": savePanelOverridden,
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
