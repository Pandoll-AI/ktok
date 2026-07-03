import AppKit
import ArgumentParser
import Foundation

struct DownloadFileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "download-file",
        abstract: "Download a file attachment from a chat",
        discussion: """
            Locate a file attachment in the chat window, press its Save button,
            drive the Save panel if one opens, and wait for the downloaded file
            to land. Use --filename for targeted downloads, or omit it to grab
            the newest visible attachment.

            Examples:
              ktok download-file "친구" --filename report.pdf
              ktok download-file "팀방" --attachment-id att_abc123 --save-dir /tmp/attachments
              ktok download-file "팀방" --save-dir /tmp/attachments --max-scroll 12
              ktok download-file "친구" --filename report.pdf --json
            """
    )

    @Argument(help: "Name of the chat or friend")
    var recipient: String

    @Option(name: .customLong("filename"), help: "Target filename (substring match). Omit to grab the newest attachment.")
    var filename: String?

    @Option(name: .customLong("attachment-id"), help: "Attachment id from ktok read --json / ktok watch --json.")
    var attachmentID: String?

    @Option(name: .customLong("save-dir"), help: "Directory to save the file into. Defaults to room-scoped attachments path with --attachment-id, otherwise ~/.ktok/accounts/<alias>/downloads.")
    var saveDir: String?

    @Option(name: .customLong("max-scroll"), help: "Max number of scroll-up attempts when searching (0-30, default 8).")
    var maxScroll: Int = 8

    @Option(name: .customLong("stable-timeout-sec"), help: "Seconds to wait for the downloaded file to stabilize (1-300, default 20).")
    var stableTimeoutSec: Double = 20.0

    @Flag(name: .long, help: "Emit a single JSON object to stdout instead of human text.")
    var json: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Disable AX path cache for this run")
    var noCache: Bool = false

    @Flag(name: [.short, .long], help: "Keep chat and list windows open after downloading")
    var keepWindow: Bool = false

    @Flag(name: .long, help: "Enable deep window recovery when fast window detection fails")
    var deepRecovery: Bool = false

    @Flag(name: .long, help: "Block execution and return CONFIRMATION_REQUIRED (for MCP confirm flow)")
    var confirm: Bool = false

    func validate() throws {
        if recipient.isEmpty {
            throw ValidationError("Recipient (chat) is required.")
        }
    }

    func run() throws {
        let start = Date()

        if confirm {
            emitError(
                code: "CONFIRMATION_REQUIRED",
                message: "ktok download-file blocked because --confirm is set",
                hint: "Ask user for explicit approval, then re-run without --confirm.",
                latencyMs: 0
            )
            throw ExitCode.failure
        }

        let activeAlias: String
        let defaultAccountDownloads: String
        do {
            guard let alias = KtokPaths.activeAccountAlias() else {
                throw KtokStorageError.accountUnknown
            }
            activeAlias = alias
            defaultAccountDownloads = try KtokPaths.activeDownloadsPath()
        } catch {
            emitError(
                code: "ACCOUNT_UNKNOWN",
                message: String(describing: error),
                hint: "Run 'ktok login <alias>' or 'ktok assume <alias>' first.",
                latencyMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            throw ExitCode.failure
        }

        let clampedMaxScroll = max(0, min(30, maxScroll))
        let clampedStableTimeout = max(1.0, min(300.0, stableTimeoutSec))

        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao: KakaoTalkApp
        do {
            kakao = try KakaoTalkApp()
        } catch {
            emitError(
                code: "KAKAO_WINDOW_UNAVAILABLE",
                message: "Failed to attach to KakaoTalk: \(error)",
                hint: "Open KakaoTalk and retry (or pass --deep-recovery).",
                latencyMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            throw ExitCode.failure
        }

        let resolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            useCache: !noCache,
            deepRecoveryEnabled: deepRecovery
        )

        let resolution: ChatWindowResolution
        let windowTitle: String
        do {
            resolution = try resolver.resolve(query: recipient)
            windowTitle = resolution.window.title ?? recipient
            if !json {
                print("Found chat window: '\(windowTitle)'")
            }
        } catch {
            emitError(
                code: "CHAT_NOT_FOUND",
                message: "Failed to open chat: \(error)",
                hint: "Verify chat name and visibility in KakaoTalk.",
                latencyMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            throw ExitCode.failure
        }

        // Close the chat (and chat-list) windows the resolver just opened when
        // we exit this function — success or error — unless --keep-window.
        // defer runs even when run() throws ExitCode.failure below.
        defer {
            closeWindowsIfNeeded(
                resolution: resolution,
                kakao: kakao,
                resolver: resolver,
                runner: runner
            )
        }

        kakao.activate()
        Thread.sleep(forTimeInterval: 0.4)

        var scrollAttempts = 0
        var lastAXError: String?
        var candidatesSeen = 0
        var targetCandidate: AttachmentScanner.Candidate?
        let requestedAttachmentID = attachmentID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasRequestedAttachmentID = requestedAttachmentID?.isEmpty == false

        for attempt in 0...clampedMaxScroll {
            let scan = hasRequestedAttachmentID
                ? AttachmentScanner.scanAll(window: resolution.window)
                : AttachmentScanner.scan(window: resolution.window, filename: filename)
            if let err = scan.axError {
                lastAXError = err
            }
            candidatesSeen = max(candidatesSeen, scan.candidates.count)
            let chosen: AttachmentScanner.Candidate?
            if let requestedAttachmentID, !requestedAttachmentID.isEmpty {
                chosen = scan.candidates.first { $0.attachmentID(chat: windowTitle) == requestedAttachmentID }
            } else {
                chosen = scan.candidates.first
            }
            if let chosen {
                targetCandidate = chosen
                break
            }
            if attempt < clampedMaxScroll {
                if ScrollEvents.scrollChatArea(direction: .up, amount: 6) {
                    scrollAttempts += 1
                    Thread.sleep(forTimeInterval: 0.6)
                } else {
                    break
                }
            }
        }

        guard let target = targetCandidate else {
            let hint: String
            if let requestedAttachmentID, !requestedAttachmentID.isEmpty {
                hint = "Attachment '\(requestedAttachmentID)' not found after \(scrollAttempts) scroll(s). Re-run ktok read --json to refresh visible attachment ids, or increase --max-scroll."
            } else if let filename, !filename.isEmpty {
                hint = "File '\(filename)' not found after \(scrollAttempts) scroll(s). The file may be further up in chat history or already expired."
            } else {
                hint = "No file attachments detected in the visible chat area."
            }
            emitNoFileFound(
                chat: windowTitle,
                scrollAttempts: scrollAttempts,
                candidatesSeen: candidatesSeen,
                axError: lastAXError,
                hint: hint,
                requestedAttachmentID: requestedAttachmentID,
                latencyMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            throw ExitCode.failure
        }

        let trimmedSaveDir = saveDir?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitSaveDir = trimmedSaveDir?.isEmpty == false ? trimmedSaveDir : nil
        let selectedSaveDir = explicitSaveDir
            ?? (hasRequestedAttachmentID
                ? KtokWorkspaceStore.attachmentDirectory(
                    accountAlias: activeAlias,
                    chatTitle: windowTitle,
                    attachmentID: target.attachmentID(chat: windowTitle)
                ).path
                : defaultAccountDownloads)
        let expandedSaveDir = URL(fileURLWithPath: (selectedSaveDir as NSString).expandingTildeInPath).standardizedFileURL.path
        let defaultDownloads = URL(fileURLWithPath: ("~/Downloads" as NSString).expandingTildeInPath).standardizedFileURL.path
        do {
            try FileManager.default.createDirectory(atPath: expandedSaveDir, withIntermediateDirectories: true)
        } catch {
            emitError(
                code: "INVALID_ARGUMENT",
                message: "Cannot create save_dir: \(error)",
                hint: "Check directory path and permissions.",
                latencyMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            throw ExitCode.failure
        }

        // Snapshot watched directories BEFORE pressing Save so we can diff.
        var watchedDirs: [String] = [expandedSaveDir]
        if expandedSaveDir != defaultDownloads,
           FileManager.default.fileExists(atPath: defaultDownloads) {
            watchedDirs.append(defaultDownloads)
        }
        var baseline: [String: DirectoryWatcher.Snapshot] = [:]
        for dir in watchedDirs {
            baseline[dir] = DirectoryWatcher.snapshot(dir)
        }

        // Press Save via JXA row_index fast path.
        let pressOutcome = SavePressor.press(
            chat: windowTitle,
            targetValue: target.value,
            rowIndex: target.rowIndex
        )
        let saveDebug = pressOutcome.debug

        if !pressOutcome.pressed {
            // No coord fallback in Swift yet — the Python path only triggers
            // when a direct Save button is on-screen, rare for file bubbles.
            emitError(
                code: "SAVE_BUTTON_FAILED",
                message: "Could not click Save button for file in chat",
                hint: "No Save/Save As button found in file bubble. Debug: \(saveDebug)",
                latencyMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            throw ExitCode.failure
        }

        Thread.sleep(forTimeInterval: 1.5)
        let dialog1 = DialogHandler.handle(chat: windowTitle)
        if dialog1 == .friend {
            Thread.sleep(forTimeInterval: 2.0)
            let dialog2 = DialogHandler.handle(chat: windowTitle)
            if dialog2 == .expired {
                emitError(
                    code: "FILE_EXPIRED",
                    message: "File has been permanently deleted from the server (expired)",
                    hint: "KakaoTalk files expire after ~2 weeks if not downloaded.",
                    latencyMs: Int(Date().timeIntervalSince(start) * 1000)
                )
                throw ExitCode.failure
            }
        } else if dialog1 == .expired {
            emitError(
                code: "FILE_EXPIRED",
                message: "File has been permanently deleted from the server (expired)",
                hint: "KakaoTalk files expire after ~2 weeks if not downloaded.",
                latencyMs: Int(Date().timeIntervalSince(start) * 1000)
            )
            throw ExitCode.failure
        }
        Thread.sleep(forTimeInterval: 1.0)

        let panelShown = SavePanelDriver.waitForSavePanel(timeoutSec: 3.0)
        var savePanelOverridden = false
        if panelShown {
            let clicked = SavePanelDriver.clickDownloadButton()
            if !clicked {
                if expandedSaveDir != defaultDownloads {
                    let (ok, _) = SavePanelDriver.overridePath(expandedSaveDir)
                    savePanelOverridden = ok
                    if !ok {
                        SavePanelDriver.acceptDefault()
                    }
                } else {
                    SavePanelDriver.acceptDefault()
                }
            }
        }

        var downloadedFile = DirectoryWatcher.waitForNewStableFile(
            dirs: watchedDirs,
            baseline: baseline,
            timeoutSec: clampedStableTimeout
        )

        // If the file landed in ~/Downloads but the user wanted save_dir, move it.
        if let landed = downloadedFile,
           expandedSaveDir != defaultDownloads,
           URL(fileURLWithPath: landed).deletingLastPathComponent().path != expandedSaveDir,
           !savePanelOverridden {
            downloadedFile = DirectoryWatcher.relocateIfNeeded(landed, preferredDir: expandedSaveDir)
        }

        let latencyMs = Int(Date().timeIntervalSince(start) * 1000)
        let targetObject = targetJSON(target)
        let status = downloadedFile == nil ? "download_not_observed" : "downloaded"
        let workspaceEvent = KtokWorkspaceStore.recordDownload(
            chatTitle: windowTitle,
            attachmentID: target.attachmentID(chat: windowTitle),
            candidateValue: target.value,
            target: targetObject,
            downloadedFile: downloadedFile,
            saveDir: expandedSaveDir,
            watchedDirs: watchedDirs,
            status: status
        )
        emitSuccess(
            chat: windowTitle,
            downloadedFile: downloadedFile,
            target: target,
            targetObject: targetObject,
            scrollAttempts: scrollAttempts,
            savePanelShown: panelShown,
            savePanelOverridden: savePanelOverridden,
            saveDebug: saveDebug,
            watchedDirs: watchedDirs,
            filename: filename,
            requestedAttachmentID: requestedAttachmentID,
            saveDir: expandedSaveDir,
            workspaceEvent: workspaceEvent,
            latencyMs: latencyMs
        )

        if downloadedFile == nil {
            throw ExitCode.failure
        }
    }

    // MARK: - Output

    private func emitSuccess(
        chat: String,
        downloadedFile: String?,
        target: AttachmentScanner.Candidate,
        targetObject: [String: Any],
        scrollAttempts: Int,
        savePanelShown: Bool,
        savePanelOverridden: Bool,
        saveDebug: String,
        watchedDirs: [String],
        filename: String?,
        requestedAttachmentID: String?,
        saveDir: String,
        workspaceEvent: WorkspaceWriteResult?,
        latencyMs: Int
    ) {
        if json {
            let status = downloadedFile == nil ? "download_not_observed" : "downloaded"
            var result: [String: Any] = [
                "ok": downloadedFile != nil,
                "chat": chat,
                "attachment_id": target.attachmentID(chat: chat),
                "candidate_value": target.value,
                "downloaded_file": downloadedFile.map { $0 as Any } ?? NSNull(),
                "save_dir": saveDir,
                "status": status,
                "target": targetObject,
                "scroll_attempts": scrollAttempts,
                "save_panel_shown": savePanelShown,
                "save_panel_overridden": savePanelOverridden,
                "save_debug": saveDebug,
                "watched_dirs": watchedDirs,
                "meta": ["latency_ms": latencyMs],
            ]
            if let filename, !filename.isEmpty {
                result["target_filename"] = filename
            }
            if let requestedAttachmentID, !requestedAttachmentID.isEmpty {
                result["requested_attachment_id"] = requestedAttachmentID
            }
            if let workspaceEvent {
                result["workspace_event_path"] = workspaceEvent.eventPath.map { $0 as Any } ?? NSNull()
                result["workspace_event_paths"] = workspaceEvent.eventPaths
            }
            if downloadedFile == nil {
                result["error"] = [
                    "code": "DOWNLOAD_NOT_OBSERVED",
                    "message": "Save menu was clicked but no new stable file appeared",
                    "hint": "The file may still be downloading (raise --stable-timeout-sec), or KakaoTalk saved it to a different directory. Watched: \(watchedDirs)",
                ]
            }
            printJSON(result)
        } else {
            if let downloadedFile {
                print("✓ Downloaded: \(downloadedFile)")
                print("  attachment_id: \(target.attachmentID(chat: chat))")
            } else {
                let effectiveTimeout = max(1.0, min(300.0, stableTimeoutSec))
                print("⚠️  Save was pressed but no new stable file appeared within \(Int(effectiveTimeout))s.")
                print("   Watched: \(watchedDirs)")
            }
        }
    }

    private func targetJSON(_ target: AttachmentScanner.Candidate) -> [String: Any] {
        [
            "role": "AXStaticText",
            "title": "",
            "value": target.value,
            "desc": "text",
            "reason": target.reason.rawValue,
            "row_index": target.rowIndex,
            "filename": target.filename.map { $0 as Any } ?? NSNull(),
            "author": target.author.map { $0 as Any } ?? NSNull(),
            "time_raw": target.timeRaw.map { $0 as Any } ?? NSNull(),
        ]
    }

    private func emitNoFileFound(
        chat: String,
        scrollAttempts: Int,
        candidatesSeen: Int,
        axError: String?,
        hint: String,
        requestedAttachmentID: String?,
        latencyMs: Int
    ) {
        if json {
            var result: [String: Any] = [
                "ok": false,
                "error": [
                    "code": "NO_FILE_FOUND",
                    "message": "Could not locate a file attachment in the chat",
                    "hint": hint,
                    "ax_error": axError.map { $0 as Any } ?? NSNull(),
                ],
                "chat": chat,
                "scroll_attempts": scrollAttempts,
                "candidates_seen": candidatesSeen,
                "meta": ["latency_ms": latencyMs],
            ]
            if let requestedAttachmentID, !requestedAttachmentID.isEmpty {
                result["requested_attachment_id"] = requestedAttachmentID
            }
            printJSON(result)
        } else {
            print("[NO_FILE_FOUND] \(hint)")
        }
    }

    private func emitError(code: String, message: String, hint: String, latencyMs: Int) {
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
            print("[\(code)] \(message) — \(hint)")
        }
    }

    private func closeWindowsIfNeeded(
        resolution: ChatWindowResolution,
        kakao: KakaoTalkApp,
        resolver: ChatWindowResolver,
        runner: AXActionRunner
    ) {
        guard !keepWindow else {
            runner.log("download-file: keep-window enabled; skipping auto-close")
            return
        }

        if resolver.closeWindow(resolution.window) {
            if !json { print("✓ Chat window closed.") }
        } else {
            runner.log("download-file: close window could not be verified")
        }

        if let listWindow = kakao.chatListWindow,
           !areSameAXElement(listWindow, resolution.window) {
            if resolver.closeWindow(listWindow) {
                runner.log("download-file: chat list window closed")
            } else {
                runner.log("download-file: chat list window could not be verified")
            }
        }
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }

    private func printJSON(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            print("{}")
            return
        }
        print(string)
    }
}
