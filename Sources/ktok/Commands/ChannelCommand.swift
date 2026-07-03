import ArgumentParser
import AppKit
import Foundation

struct ChannelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "channel",
        abstract: "KakaoTalk channel runtime: chat map, queue, polling, and daemon helpers",
        discussion: """
        Channel runtime separates lightweight KakaoTalk polling from Hermes message processing.
        It stores durable state in ~/.ktok/channel/channel.sqlite and exports a stale-aware
        chat_id map to ~/.ktok/chat-id-map.json.
        """,
        subcommands: [
            ChannelRefreshChatsCommand.self,
            ChannelStatusCommand.self,
            ChannelMonitorCommand.self,
            ChannelQueueCommand.self,
            ChannelPollOnceCommand.self,
            ChannelDaemonCommand.self,
            ChannelInstallDaemonCommand.self,
        ],
        defaultSubcommand: ChannelStatusCommand.self
    )
}

struct ChannelRefreshChatsCommand: ParsableCommand {
    private struct LegacyRoomsFile: Decodable {
        let records: [LegacyRoomRecord]
    }

    private struct LegacyRoomRecord: Decodable {
        let chatID: String
        let displayName: String
        let lastPreviewNormalized: String?

        enum CodingKeys: String, CodingKey {
            case chatID
            case displayName
            case lastPreviewNormalized
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "refresh-chats",
        abstract: "Refresh all current KakaoTalk chat IDs into the channel store"
    )

    @Option(name: .shortAndLong, help: "Maximum number of chats to scan. Default: 80. Use a higher value for a deeper refresh.")
    var limit: Int = 80

    @Option(name: .long, help: "Cache TTL in seconds. Default: 3600.")
    var ttlSeconds: Int = ChannelStore.defaultChatMapTTLSeconds

    @Flag(name: .long, help: "Force refresh even if the exported chat map is fresh")
    var force: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let store = try ChannelStore()
        let mapURL = KtokPaths.home.appendingPathComponent("chat-id-map.json")
        if !force, isFresh(mapURL: mapURL, ttlSeconds: ttlSeconds) {
            let status = try store.status()
            emit([
                "refreshed": false,
                "reason": "fresh",
                "path": mapURL.path,
                "db_path": store.dbPath,
                "chat_count": status.chatCount,
                "monitored_count": status.monitoredCount,
            ])
            return
        }

        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: traceAX)
        let chatWindowResolver = ChatWindowResolver(kakao: kakao, runner: runner)
        let windowsBefore = kakao.windows

        let mainWindow: UIElement
        let autoOpenedWindow: Bool
        if let fallback = kakao.ensureMainWindow(timeout: 5.0, trace: { runner.log($0) }) {
            mainWindow = fallback
            autoOpenedWindow = !windowsBefore.contains(where: { CFEqual($0.axElement, fallback.axElement) })
        } else {
            throw ChannelError.chatNotFound("Could not find a usable KakaoTalk chat list window")
        }
        defer {
            if autoOpenedWindow {
                _ = chatWindowResolver.closeWindow(mainWindow)
            }
        }

        if ensureKakaoFrontmost(kakao: kakao, runner: runner, label: "channel refresh Cmd+2 pre-scan") {
            runner.pressCommandNumber(2)
            Thread.sleep(forTimeInterval: 0.25)
        } else {
            runner.log("channel refresh: Cmd+2 pre-scan skipped because KakaoTalk is not frontmost")
        }

        let scanner = ChatListScanner()
        let snapshots = scanner.scan(in: mainWindow, limit: limit, trace: { runner.log($0) })

        let registry = ChatIdentityRegistryStore.shared
        let account = ChatAccountContext.active()
        let assignedIDs = registry.assignChatIDs(
            for: snapshots.map(\.discovery),
            account: account,
            trigger: .manualChatsCommand
        )
        var chats = zip(snapshots, assignedIDs).map { snapshot, chatID in
            ChatListEntry(
                title: snapshot.discovery.title,
                chatID: chatID.isEmpty ? nil : chatID,
                lastMessage: snapshot.discovery.lastMessage
            )
        }
        if chats.filter({ $0.chatID != nil }).isEmpty, let fallbackChats = loadLegacyRoomRegistry(account: account), !fallbackChats.isEmpty {
            chats = fallbackChats
        }
        try store.upsertChats(chats)
        let exported = try store.writeChatMapJSON(to: mapURL)
        emit([
            "refreshed": true,
            "path": exported.path,
            "db_path": store.dbPath,
            "chat_count": chats.filter { $0.chatID != nil }.count,
            "scanned_count": chats.count,
        ])
    }

    private func loadLegacyRoomRegistry(account: ChatAccountContext) -> [ChatListEntry]? {
        let alias = account.alias ?? "unknown"
        let url = KtokPaths.rooms(alias: alias)
        guard let data = try? Data(contentsOf: url),
              let rooms = try? JSONDecoder().decode(LegacyRoomsFile.self, from: data)
        else { return nil }
        return rooms.records.map { room in
            ChatListEntry(
                title: room.displayName,
                chatID: room.chatID,
                lastMessage: room.lastPreviewNormalized
            )
        }
    }

    private func isFresh(mapURL: URL, ttlSeconds: Int) -> Bool {
        guard ttlSeconds > 0,
              let data = try? Data(contentsOf: mapURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let updatedAt = object["updated_at"] as? String
        else { return false }

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: updatedAt) ?? {
            f.formatOptions = [.withInternetDateTime]
            return f.date(from: updatedAt)
        }()
        guard let date else { return false }
        return Date().timeIntervalSince(date) < Double(ttlSeconds)
    }

    private func emit(_ object: [String: Any]) {
        if json {
            KtokWorkspaceStore.printJSON(object)
            return
        }
        print("channel refresh: \((object["refreshed"] as? Bool) == true ? "refreshed" : "fresh")")
        print("chat_count: \(object["chat_count"] ?? 0)")
        print("path: \(object["path"] ?? "")")
        print("db_path: \(object["db_path"] ?? "")")
    }
}

struct ChannelStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show channel runtime status")

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let status = try ChannelStore().status()
        if json {
            try printJSON(status)
            return
        }
        print("db_path: \(status.dbPath)")
        print("chats: \(status.chatCount)")
        print("monitored: \(status.monitoredCount)")
        print("pending_queue: \(status.pendingQueueCount)")
        print("last_activity_at: \(status.lastActivityAt ?? "none")")
        print("next_interval_seconds: \(status.nextIntervalSeconds)")
    }
}

struct ChannelMonitorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Manage monitored KakaoTalk chats",
        subcommands: [
            ChannelMonitorAddCommand.self,
            ChannelMonitorRemoveCommand.self,
            ChannelMonitorListCommand.self,
        ],
        defaultSubcommand: ChannelMonitorListCommand.self
    )
}

struct ChannelMonitorAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Mark an exact chat as monitored")

    @Option(name: .long, help: "Exact chat title")
    var title: String?

    @Option(name: .customLong("chat-id"), help: "Chat ID")
    var chatID: String?

    @Option(name: .long, help: "Mode: observe_only, notify_user, assistant_allowed, self_control")
    var mode: String = "observe_only"

    @Option(name: .long, help: "Lower number is higher priority")
    var priority: Int = 100

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let chat = try ChannelStore().markMonitored(title: title, chatID: chatID, mode: mode, priority: priority)
        try emitChat(chat, json: json)
    }
}

struct ChannelMonitorRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Stop monitoring a chat")

    @Option(name: .long, help: "Exact chat title")
    var title: String?

    @Option(name: .customLong("chat-id"), help: "Chat ID")
    var chatID: String?

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let chat = try ChannelStore().unmonitor(title: title, chatID: chatID)
        try emitChat(chat, json: json)
    }
}

struct ChannelMonitorListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List monitored chats")

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let chats = try ChannelStore().monitoredChats()
        if json {
            try printJSON(chats)
            return
        }
        if chats.isEmpty {
            print("No monitored chats. Add one with: ktok channel monitor add --title '채팅방'")
            return
        }
        for chat in chats {
            print("\(chat.title)  \(chat.chatID)  mode=\(chat.mode) priority=\(chat.priority)")
        }
    }
}

struct ChannelQueueCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "queue",
        abstract: "Inspect and operate the channel inbox queue",
        subcommands: [
            ChannelQueueListCommand.self,
            ChannelQueueClaimCommand.self,
            ChannelQueueCompleteCommand.self,
            ChannelQueueFailCommand.self,
            ChannelQueueAddTestCommand.self,
        ],
        defaultSubcommand: ChannelQueueListCommand.self
    )
}

struct ChannelQueueListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List queue items")

    @Option(name: .long, help: "Filter by status: pending, claimed, completed, failed")
    var status: String?

    @Option(name: .shortAndLong, help: "Maximum rows to return")
    var limit: Int = 20

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let items = try ChannelStore().listQueue(status: status, limit: limit)
        try emitQueueItems(items, json: json)
    }
}

struct ChannelQueueClaimCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "claim", abstract: "Claim pending queue items for a worker")

    @Option(name: .long, help: "Worker name")
    var worker: String = "ktok-channel-worker"

    @Option(name: .shortAndLong, help: "Maximum rows to claim")
    var limit: Int = 1

    @Option(name: .long, help: "Seconds before an uncompleted claimed item can be reclaimed")
    var leaseSeconds: Int = 300

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let items = try ChannelStore().claimQueue(worker: worker, limit: limit, leaseSeconds: leaseSeconds)
        try emitQueueItems(items, json: json)
    }
}

struct ChannelQueueCompleteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "complete", abstract: "Mark a claimed queue item completed")

    @Argument(help: "Queue item id")
    var id: Int64

    @Option(name: .long, help: "Require this claimed_by worker before completing")
    var worker: String?

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        if let item = try ChannelStore().completeQueue(id: id, worker: worker) {
            try emitQueueItems([item], json: json)
        } else {
            throw ChannelError.chatNotFound("queue id '\(id)' is not claimed or worker does not match")
        }
    }
}

struct ChannelQueueFailCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fail", abstract: "Mark a queue item failed, or requeue it with delay")

    @Argument(help: "Queue item id")
    var id: Int64

    @Flag(name: .long, help: "Return item to pending instead of failed")
    var retry: Bool = false

    @Option(name: .long, help: "Delay before retry becomes available")
    var delaySeconds: Int = 60

    @Option(name: .long, help: "Require this claimed_by worker before failing")
    var worker: String?

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        if let item = try ChannelStore().failQueue(id: id, retry: retry, delaySeconds: delaySeconds, worker: worker) {
            try emitQueueItems([item], json: json)
        } else {
            throw ChannelError.chatNotFound("queue id '\(id)' is not claimed or worker does not match")
        }
    }
}

struct ChannelQueueAddTestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-test",
        abstract: "Add a local-only test queue item without sending or reading KakaoTalk"
    )

    @Option(name: .long, help: "Exact chat title")
    var title: String?

    @Option(name: .customLong("chat-id"), help: "Chat ID")
    var chatID: String?

    @Option(name: .long, help: "Synthetic author")
    var author: String = "ktok-test"

    @Option(name: .long, help: "Synthetic body")
    var body: String = "ktok channel queue verification"

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let store = try ChannelStore()
        let chat = try store.resolveChat(exactTitle: title, chatID: chatID)
        if let item = try store.enqueueTestMessage(chat: chat, author: author, body: body) {
            try emitQueueItems([item], json: json)
        } else {
            throw ChannelError.chatNotFound("failed to create test queue item")
        }
    }
}

struct ChannelPollOnceCommand: ParsableCommand {
    private struct PollError: Encodable {
        let chatID: String
        let title: String
        let error: String

        enum CodingKeys: String, CodingKey {
            case chatID = "chat_id"
            case title
            case error
        }
    }

    private struct PollResponse: Encodable {
        let ok: Bool
        let results: [ChannelPollResult]
        let errors: [PollError]
    }

    static let configuration = CommandConfiguration(commandName: "poll-once", abstract: "Read recent messages and enqueue new inbound messages")

    @Option(name: .long, help: "Exact chat title. Omit with --all-monitored.")
    var title: String?

    @Option(name: .customLong("chat-id"), help: "Chat ID. Omit with --all-monitored.")
    var chatID: String?

    @Flag(name: .long, help: "Poll all monitored chats")
    var allMonitored: Bool = false

    @Option(name: .shortAndLong, help: "Recent message limit per chat")
    var limit: Int = 40

    @Flag(name: .long, help: "Also enqueue my own messages; useful only for self-chat tests")
    var enqueueMine: Bool = false

    @Flag(name: .long, help: "Keep auto-opened chat window after polling")
    var keepWindow: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let store = try ChannelStore()
        let chats: [ChannelChat]
        if allMonitored {
            chats = try store.monitoredChats()
        } else {
            chats = [try store.resolveChat(exactTitle: title, chatID: chatID)]
        }
        guard !chats.isEmpty else {
            if json { KtokWorkspaceStore.printJSON(["ok": true, "results": []]) }
            else { print("No chats to poll.") }
            return
        }

        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: traceAX)
        let resolver = ChatWindowResolver(kakao: kakao, runner: runner, deepRecoveryEnabled: true)
        let reader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner)
        var results: [ChannelPollResult] = []
        var errors: [PollError] = []

        for chat in chats {
            do {
                let idsForTitle = try store.chatIDsForTitle(chat.title)
                if idsForTitle.count > 1 {
                    throw ChannelError.ambiguousTitle("polling by title '\(chat.title)' is ambiguous for chat_ids: \(idsForTitle.joined(separator: ", ")); open the target chat explicitly or implement chat_id-based window resolution first")
                }
                let resolution = try resolver.resolve(query: chat.title)
                defer {
                    if resolution.openedNewWindow && !keepWindow {
                        _ = resolver.closeWindow(resolution.window)
                    }
                }
                let snapshot = try reader.readSnapshot(from: resolution.window, fallbackChatTitle: chat.title, limit: limit)
                let result = try store.insertSnapshot(chat: chat, snapshot: snapshot, enqueueMine: enqueueMine)
                results.append(result)
            } catch {
                let message = String(describing: error)
                let hint: String
                if message.contains("SEARCH_MISS") {
                    hint = "KakaoTalk search field was not exposed. Open the Chats tab/window or an existing target chat once, then retry; queue commands remain usable."
                } else {
                    hint = message
                }
                errors.append(PollError(chatID: chat.chatID, title: chat.title, error: hint))
            }
        }

        if json {
            try printJSON(PollResponse(ok: errors.isEmpty, results: results, errors: errors))
            return
        }
        for result in results {
            print("\(result.title) (\(result.chatID)): scanned=\(result.scannedMessages) inserted=\(result.insertedMessages) queued=\(result.queuedMessages)")
        }
        for error in errors {
            print("\(error.title) (\(error.chatID)): poll failed: \(error.error)")
        }
        if !errors.isEmpty {
            throw ExitCode.failure
        }
    }
}

struct ChannelDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run the adaptive channel polling loop",
        discussion: "This daemon only detects/enqueues messages. It does not call Hermes or send replies. Stop with Ctrl-C."
    )

    @Flag(name: .long, help: "Emit JSON status lines")
    var json: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Option(name: .long, help: "Maximum loop count for testing. Omit to run forever.")
    var maxLoops: Int?

    func run() throws {
        var loops = 0
        while true {
            loops += 1
            do {
                var poll = ChannelPollOnceCommand()
                poll.allMonitored = true
                poll.json = json
                poll.traceAX = traceAX
                try poll.run()
            } catch {
                if json {
                    KtokWorkspaceStore.printJSON(["ok": false, "error": String(describing: error), "loop": loops])
                } else {
                    print("channel daemon poll failed: \(error)")
                }
            }

            if let maxLoops, loops >= maxLoops { break }
            let status = try ChannelStore().status()
            if json {
                KtokWorkspaceStore.printJSON(["event": "sleep", "seconds": status.nextIntervalSeconds])
            } else {
                print("sleeping \(status.nextIntervalSeconds)s")
            }
            Thread.sleep(forTimeInterval: TimeInterval(status.nextIntervalSeconds))
        }
    }
}

/// Helpers for generating LaunchAgent plists without hardcoding developer paths.
enum LaunchAgentSupport {
    /// Path to the currently-running ktok binary (resolved), so the LaunchAgent
    /// points at whatever the user installed. Falls back to a neutral default.
    static func defaultBinaryPath() -> String {
        if let exe = Bundle.main.executablePath, !exe.isEmpty {
            return URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
        }
        if let arg0 = CommandLine.arguments.first, arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0).resolvingSymlinksInPath().path
        }
        return "/usr/local/bin/ktok"
    }

    /// A PATH value that includes the binary's own directory plus the standard
    /// system/homebrew locations. No developer-specific directories.
    static func pathEnvValue(forBinary binary: String?) -> String {
        var entries: [String] = []
        if let binary, binary.hasPrefix("/") {
            let dir = URL(fileURLWithPath: binary).deletingLastPathComponent().path
            if !dir.isEmpty { entries.append(dir) }
        }
        entries.append(contentsOf: ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    static func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func plist(label: String, arguments: [String], workingDirectory: String, standardOutPath: String, standardErrorPath: String) -> String {
        let escapedArguments = arguments.map { "        <string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
        let launchPath = pathEnvValue(forBinary: arguments.first)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(xmlEscape(label))</string>
            <key>ProgramArguments</key>
            <array>
        \(escapedArguments)
            </array>
            <key>WorkingDirectory</key>
            <string>\(xmlEscape(workingDirectory))</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(standardOutPath))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(standardErrorPath))</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(xmlEscape(launchPath))</string>
            </dict>
        </dict>
        </plist>
        """
    }

    @discardableResult
    static func runLaunchctl(_ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            return "launchctl \(args.joined(separator: " ")) exit=\(process.terminationStatus) \(out)\n"
        } catch {
            return "launchctl \(args.joined(separator: " ")) error=\(error)\n"
        }
    }
}

struct ChannelInstallDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-daemon",
        abstract: "Install a macOS LaunchAgent for the channel polling daemon",
        discussion: "Writes ~/Library/LaunchAgents/<label>.plist. Use --load to bootstrap it into the current Aqua GUI session."
    )

    @Option(name: .long, help: "LaunchAgent label")
    var label: String = "com.ktok.channel"

    @Option(name: .long, help: "Path to ktok binary (defaults to the running executable)")
    var binary: String = LaunchAgentSupport.defaultBinaryPath()

    @Flag(name: .long, help: "Enable AX trace logs in the daemon")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Immediately bootstrap/kickstart the LaunchAgent after writing the plist")
    var load: Bool = false

    @Flag(name: .long, help: "Print the plist without writing or loading it")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents")
        let channelDir = home.appendingPathComponent(".ktok/channel")
        let logsDir = channelDir.appendingPathComponent("logs")
        let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")
        let stdoutURL = logsDir.appendingPathComponent("daemon.out.log")
        let stderrURL = logsDir.appendingPathComponent("daemon.err.log")

        var arguments = [binary, "channel", "daemon", "--json"]
        if traceAX {
            arguments.append("--trace-ax")
        }

        let plist = launchAgentPlist(
            label: label,
            arguments: arguments,
            workingDirectory: home.path,
            standardOutPath: stdoutURL.path,
            standardErrorPath: stderrURL.path
        )

        if dryRun {
            print(plist)
            return
        }

        try fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: channelDir.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDir.path)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)

        var loaded = false
        var loadOutput = ""
        if load {
            let bootout = runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
            loadOutput += bootout
            let bootstrap = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            loadOutput += bootstrap
            let kickstart = runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
            loadOutput += kickstart
            loaded = bootstrap.contains("exit=0") || kickstart.contains("exit=0")
        }

        if json {
            KtokWorkspaceStore.printJSON([
                "ok": true,
                "label": label,
                "plist": plistURL.path,
                "stdout": stdoutURL.path,
                "stderr": stderrURL.path,
                "loaded": loaded,
                "load_output": loadOutput.trimmingCharacters(in: .whitespacesAndNewlines),
            ])
            return
        }

        print("installed: \(plistURL.path)")
        print("stdout: \(stdoutURL.path)")
        print("stderr: \(stderrURL.path)")
        if load {
            print(loadOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            print("not loaded; run with --load to bootstrap into gui/\(getuid())")
        }
    }

    private func launchAgentPlist(
        label: String,
        arguments: [String],
        workingDirectory: String,
        standardOutPath: String,
        standardErrorPath: String
    ) -> String {
        let escapedArguments = arguments.map { "        <string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
        let launchPath = LaunchAgentSupport.pathEnvValue(forBinary: arguments.first)
        return """
        <?xml version=\"1.0\" encoding=\"UTF-8\"?>
        <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">
        <plist version=\"1.0\">
        <dict>
            <key>Label</key>
            <string>\(xmlEscape(label))</string>
            <key>ProgramArguments</key>
            <array>
        \(escapedArguments)
            </array>
            <key>WorkingDirectory</key>
            <string>\(xmlEscape(workingDirectory))</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(standardOutPath))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(standardErrorPath))</string>
            <key>EnvironmentVariables</key>
            <dict>
                <key>PATH</key>
                <string>\(xmlEscape(launchPath))</string>
            </dict>
        </dict>
        </plist>
        """
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func runLaunchctl(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return "launchctl \(arguments.joined(separator: " ")) exit=\(process.terminationStatus) \(output)\n"
        } catch {
            return "launchctl \(arguments.joined(separator: " ")) failed: \(error)\n"
        }
    }
}

private func ensureKakaoFrontmost(kakao: KakaoTalkApp, runner: AXActionRunner, label: String) -> Bool {
    let before = NSWorkspace.shared.frontmostApplication
    runner.log("\(label): frontmost before bundle='\(before?.bundleIdentifier ?? "")' pid=\(before?.processIdentifier ?? -1)")
    kakao.activate()
    let expectedPID = KakaoTalkApp.runningApplication?.processIdentifier
    let becameFrontmost = runner.waitUntil(label: "\(label) frontmost", timeout: 0.6, pollInterval: 0.06, evaluateAfterTimeout: true) {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
        return frontmost.bundleIdentifier == KakaoTalkApp.bundleIdentifier || frontmost.processIdentifier == expectedPID
    }
    let after = NSWorkspace.shared.frontmostApplication
    runner.log("\(label): frontmost after bundle='\(after?.bundleIdentifier ?? "")' pid=\(after?.processIdentifier ?? -1) ok=\(becameFrontmost)")
    return becameFrontmost
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
}

private func emitChat(_ chat: ChannelChat, json: Bool) throws {
    if json {
        try printJSON(chat)
        return
    }
    print("\(chat.title)  \(chat.chatID)  monitored=\(chat.isMonitored) mode=\(chat.mode) priority=\(chat.priority)")
}

private func emitQueueItems(_ items: [ChannelQueueItem], json: Bool) throws {
    if json {
        try printJSON(items)
        return
    }
    if items.isEmpty {
        print("No queue items.")
        return
    }
    for item in items {
        let title = item.title ?? item.chatID
        let body = (item.body ?? "").prefix(80)
        print("#\(item.id) \(item.status) \(title) attempts=\(item.attempts) author=\(item.author ?? "unknown") body=\(body)")
    }
}
