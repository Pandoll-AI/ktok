import ApplicationServices.HIServices
import ArgumentParser
import Foundation

/// Always-on background persona chatbot.
///
/// Watches the allowlisted KakaoTalk rooms (`ktok channel monitor add`) for new
/// messages and replies as a persona via the `codex` LLM. Replies are delivered
/// focus-free (KakaoTalk is never brought to the foreground). Only allowlisted
/// rooms are ever answered; brand-new/unlisted rooms are ignored for safety.
struct BotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bot",
        abstract: "Run an always-on persona chatbot over allowlisted KakaoTalk rooms",
        discussion: """
            The bot only replies in rooms you allowlist with:
              ktok channel monitor add --title "<room>"

            Persona identity/voice comes from ~/.ktok/persona/<name>.json
            (see 'ktok persona init' and docs/PERSONA_SETUP.md). Replies are sent
            focus-free, so your active app is not disturbed.

            Examples:
              ktok bot run --persona luna
              ktok bot run --persona luna --trigger-mode mention --json
              ktok bot run --persona luna --dry-run --max-loops 3 --json
            """,
        subcommands: [BotRunCommand.self, BotInstallDaemonCommand.self],
        defaultSubcommand: BotRunCommand.self
    )
}

/// Installs a macOS LaunchAgent so the bot runs always-on in the background,
/// supervised by launchd (restarted on crash/logout).
struct BotInstallDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-daemon",
        abstract: "Install a macOS LaunchAgent that runs the bot always-on.",
        discussion: "Writes ~/Library/LaunchAgents/<label>.plist running 'ktok bot run'. Use --load to bootstrap it into the current Aqua GUI session."
    )

    @Option(name: .long, help: "Persona name.")
    var persona: String = "luna"

    @Option(name: .long, help: "Reply trigger mode: persona | mention | all | off.")
    var triggerMode: BotTriggerMode = .persona

    @Option(name: .long, help: "LaunchAgent label.")
    var label: String = "com.ktok.bot"

    @Option(name: .long, help: "Path to ktok binary (defaults to the running executable).")
    var binary: String = LaunchAgentSupport.defaultBinaryPath()

    @Flag(name: .long, help: "Immediately bootstrap/kickstart the LaunchAgent after writing the plist.")
    var load: Bool = false

    @Flag(name: .long, help: "Print the plist without writing or loading it.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() throws {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents")
        let botDir = KtokPaths.home.appendingPathComponent("bot", isDirectory: true)
        let logsDir = botDir.appendingPathComponent("logs", isDirectory: true)
        let plistURL = launchAgentsDir.appendingPathComponent("\(label).plist")
        let stdoutURL = logsDir.appendingPathComponent("bot.out.log")
        let stderrURL = logsDir.appendingPathComponent("bot.err.log")

        let arguments = [binary, "bot", "run", "--persona", persona, "--trigger-mode", triggerMode.rawValue, "--json"]
        let plist = LaunchAgentSupport.plist(
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
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: botDir.path)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: logsDir.path)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistURL.path)

        var loaded = false
        var loadOutput = ""
        if load {
            loadOutput += LaunchAgentSupport.runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
            let bootstrap = LaunchAgentSupport.runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            loadOutput += bootstrap
            let kickstart = LaunchAgentSupport.runLaunchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
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
}

enum BotTriggerMode: String, ExpressibleByArgument, CaseIterable {
    /// Reply only when the persona's own decision() logic says so (default).
    case persona
    /// Reply only to direct calls / mentions of the persona.
    case mention
    /// Reply to every new inbound message (excludes own outgoing messages).
    case all
    /// Never reply — detect only.
    case off
}

struct BotRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the bot loop over allowlisted rooms."
    )

    @Option(name: .long, help: "Persona name (loads ~/.ktok/persona/<name>.json).")
    var persona: String = "luna"

    @Option(name: .long, help: "When to reply: persona | mention | all | off.")
    var triggerMode: BotTriggerMode = .persona

    @Option(name: .long, help: "Codex model for reply generation.")
    var model: String = "gpt-5.4-mini"

    @Option(name: .long, help: "Codex reasoning effort config value.")
    var reasoningEffort: String = "medium"

    @Option(name: .long, help: "Seconds to wait for a generated reply.")
    var replyTimeout: Double = 30

    @Option(name: .long, help: "Base seconds to sleep between full room sweeps.")
    var loopDelay: Double = 3

    @Option(name: .long, help: "Extra seconds to sleep after each sweep.")
    var pollInterval: Double = 0

    @Option(name: .long, help: "Visible messages retained per room for context.")
    var snapshotLimit: Int = 8

    @Option(name: .long, help: "Seconds between heartbeat events. Use 0 to disable.")
    var heartbeatInterval: Double = 60

    @Option(name: .long, help: "Stop after N sweeps (0 = run forever). For testing.")
    var maxLoops: Int = 0

    @Flag(name: .long, help: "Decide and log replies without sending.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Emit concise JSONL bot events.")
    var json: Bool = false

    @Flag(name: .long, help: "Enable deep window recovery for flaky AX states.")
    var deepRecovery: Bool = false

    @Flag(name: .long, help: "Show AX traversal and bot trace.")
    var traceAX: Bool = false

    @Flag(name: .customLong("no-caffeine"), help: "Allow the Mac to sleep while running. By default the bot keeps the system awake so it never misses messages.")
    var noCaffeine: Bool = false

    func validate() throws {
        if persona.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("Persona name is required.")
        }
    }

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let personaConfig = try Persona.load(named: persona)
        let alias = KtokPaths.activeAccountAlias() ?? "unknown"

        let rooms = try ChannelStore().monitoredChats()
        guard !rooms.isEmpty else {
            emit([
                "event": "no_monitored_rooms",
                "hint": "Add rooms with: ktok channel monitor add --title \"<room>\"",
            ])
            return
        }

        // Caffeine mode: keep the system awake so the background bot never
        // misses messages while the Mac is idle. Native power assertion (no
        // `caffeinate` subprocess); released when the process exits.
        var caffeineToken: NSObjectProtocol?
        if !noCaffeine {
            caffeineToken = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "ktok bot: monitoring KakaoTalk; keep system awake"
            )
        }
        defer {
            if let caffeineToken { ProcessInfo.processInfo.endActivity(caffeineToken) }
        }

        let db = try MonitorStateStore.open()
        try MonitorStateStore.ensureTables(db: db)

        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try KakaoTalkApp()
        let resolver = ChatWindowResolver(kakao: kakao, runner: runner, useCache: true, deepRecoveryEnabled: deepRecovery)
        let contextResolver = MessageContextResolver(kakao: kakao, runner: runner)
        let reader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner)
        let generator = CodexReplyGenerator(model: model, reasoningEffort: reasoningEffort, timeout: replyTimeout)
        let boundedSnapshotLimit = max(8, min(snapshotLimit, 200))

        var runtimes: [RoomRuntime] = []
        for room in rooms {
            let monitorID = MonitorStateStore.monitorID(accountAlias: alias, chatTitle: room.title, persona: personaConfig.name)
            let seeded = (try? MonitorStateStore.recentSentBodies(db: db, monitorID: monitorID, limit: 40)) ?? []
            runtimes.append(RoomRuntime(title: room.title, monitorID: monitorID, sentBodies: Set(seeded)))
        }

        emit([
            "event": "started",
            "persona": personaConfig.name,
            "trigger_mode": triggerMode.rawValue,
            "rooms": rooms.map(\.title).joined(separator: ", "),
            "room_count": "\(rooms.count)",
            "dry_run": dryRun ? "true" : "false",
            "caffeine": noCaffeine ? "off" : "on",
        ])

        var loop = 0
        var lastHeartbeatAt = Date()
        while true {
            loop += 1
            for runtime in runtimes {
                processRoom(
                    runtime,
                    db: db,
                    resolver: resolver,
                    reader: reader,
                    contextResolver: contextResolver,
                    generator: generator,
                    persona: personaConfig,
                    kakao: kakao,
                    runner: runner,
                    snapshotLimit: boundedSnapshotLimit
                )
            }

            if heartbeatInterval > 0, Date().timeIntervalSince(lastHeartbeatAt) >= heartbeatInterval {
                emit(["event": "heartbeat", "loop": "\(loop)"])
                lastHeartbeatAt = Date()
            }

            if maxLoops > 0 && loop >= maxLoops { break }
            let sleepFor = max(0.5, loopDelay) + max(0, min(pollInterval, 30))
            Thread.sleep(forTimeInterval: sleepFor)
        }
    }

    // MARK: - Per-room processing

    private func processRoom(
        _ runtime: RoomRuntime,
        db: Database,
        resolver: ChatWindowResolver,
        reader: KakaoTalkTranscriptReader,
        contextResolver: MessageContextResolver,
        generator: CodexReplyGenerator,
        persona: Persona,
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        snapshotLimit: Int
    ) {
        // Resolve/open the room window (kept open across sweeps so re-reads are
        // warm and focus-free). Re-resolve if a prior read invalidated it.
        if runtime.window == nil {
            do {
                let resolution = try resolver.resolve(query: runtime.title)
                runtime.window = resolution.window
            } catch {
                emit(["event": "resolve_failed", "room": runtime.title, "error": "\(error)"])
                return
            }
        }
        guard let window = runtime.window else { return }

        // Scope reads/replies to THIS room's window. The read/input resolvers
        // have "currently-focused window" fast paths; when several chat windows
        // are open, reading room B while room A is focused would return A's
        // content (and could reply to the wrong room). Only raise when the
        // target is NOT already focused — so a steady single-room bot stays
        // focus-free, but focus drift (user opened another chat) is corrected
        // before we read. AXRaise targets one window and does not type or click.
        let targetTitle = window.title
        let focusedTitle = kakao.focusedWindow?.title
        if targetTitle == nil || focusedTitle != targetTitle {
            if let actions = try? window.actionNames(), actions.contains(kAXRaiseAction) {
                try? window.performAction(kAXRaiseAction)
            }
        }

        let snapshot: TranscriptSnapshot
        do {
            snapshot = try reader.readSnapshot(
                from: window,
                fallbackChatTitle: runtime.title,
                limit: snapshotLimit,
                includeSystemMessages: false,
                includeAttachments: false
            )
        } catch {
            emit(["event": "read_failed", "room": runtime.title, "error": "\(error)"])
            runtime.window = nil // force re-resolve next sweep
            return
        }

        runtime.recentMessages = snapshot.messages

        // Suppress the backlog the first time we see a room.
        if !runtime.baselineDone {
            runtime.pollState.replaceBaseline(with: snapshot.messages)
            try? MonitorStateStore.rememberSeen(db: db, monitorID: runtime.monitorID, messages: snapshot.messages)
            runtime.baselineDone = true
            return
        }

        let fresh = runtime.pollState.consume(snapshotMessages: snapshot.messages)
        for message in fresh {
            handleMessage(
                message,
                runtime: runtime,
                db: db,
                contextResolver: contextResolver,
                generator: generator,
                persona: persona,
                kakao: kakao,
                runner: runner,
                window: window
            )
        }
    }

    private func handleMessage(
        _ message: TranscriptMessage,
        runtime: RoomRuntime,
        db: Database,
        contextResolver: MessageContextResolver,
        generator: CodexReplyGenerator,
        persona: Persona,
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        window: UIElement
    ) {
        let key = MonitorStateStore.messageKey(message)
        if (try? MonitorStateStore.hasSeen(db: db, monitorID: runtime.monitorID, messageKey: key)) == true {
            return
        }
        try? MonitorStateStore.rememberSeen(db: db, monitorID: runtime.monitorID, message: message, messageKey: key)

        let (shouldReply, reason) = triggerDecision(message, persona: persona, sentBodies: runtime.sentBodies)
        guard shouldReply else {
            emit([
                "event": "skip",
                "room": runtime.title,
                "reason": reason,
                "author": message.author ?? "(me)",
                "body": persona.logSnippet(message.body),
            ])
            return
        }

        let generated = generator.generate(
            persona: persona,
            trigger: message,
            recentMessages: runtime.recentMessages,
            systemPreamble: Self.operationPreamble
        ) ?? persona.fallbackReply(for: message)
        let reply = persona.boundReply(generated)

        emit(["event": "reply_ready", "room": runtime.title, "reason": reason, "reply": reply])

        if dryRun {
            try? MonitorStateStore.recordReply(db: db, monitorID: runtime.monitorID, messageKey: key, reply: reply, status: "dry_run", error: nil)
            return
        }

        let sent = send(reply, window: window, contextResolver: contextResolver, kakao: kakao, runner: runner)
        if sent {
            runtime.sentBodies.insert(normalizeBody(reply))
            try? MonitorStateStore.recordReply(db: db, monitorID: runtime.monitorID, messageKey: key, reply: reply, status: "sent", error: nil)
            emit(["event": "sent", "room": runtime.title, "reply": reply])
        } else {
            try? MonitorStateStore.recordReply(db: db, monitorID: runtime.monitorID, messageKey: key, reply: reply, status: "failed", error: "send_unverified")
            emit(["event": "send_failed", "room": runtime.title])
        }
    }

    /// Resolve the room's input and deliver the reply focus-free, falling back to
    /// the foreground path only if focus-free delivery cannot be verified.
    private func send(
        _ reply: String,
        window: UIElement,
        contextResolver: MessageContextResolver,
        kakao: KakaoTalkApp,
        runner: AXActionRunner
    ) -> Bool {
        guard let input = contextResolver.resolve(in: window)?.inputElement else { return false }
        if let pid = kakao.processIdentifier,
           MessageSender.sendFocusFree(message: reply, input: input, pid: pid, runner: runner, label: "bot reply (focus-free)") {
            return true
        }
        return MessageSender.sendForeground(message: reply, input: input, window: window, kakao: kakao, runner: runner, label: "bot reply")
    }

    private func triggerDecision(_ message: TranscriptMessage, persona: Persona, sentBodies: Set<String>) -> (Bool, String) {
        switch triggerMode {
        case .off:
            return (false, "trigger-off")
        case .persona:
            let d = persona.decision(for: message, sentBodies: sentBodies)
            return (d.shouldRespond, d.reason)
        case .mention:
            if isOwnOrEmpty(message, sentBodies: sentBodies) { return (false, "self-or-empty") }
            return persona.isDirectCall(message) ? (true, "direct-call") : (false, "not-mention")
        case .all:
            if isOwnOrEmpty(message, sentBodies: sentBodies) { return (false, "self-or-empty") }
            return (true, "all")
        }
    }

    /// Guards used by mention/all modes to avoid replying to our own outgoing
    /// messages (which would loop) or to empty content.
    private func isOwnOrEmpty(_ message: TranscriptMessage, sentBodies: Set<String>) -> Bool {
        let body = normalizeBody(message.body)
        if body.isEmpty { return true }
        if sentBodies.contains(body) { return true }
        if message.author == nil || message.author == "(me)" { return true }
        return false
    }

    private func normalizeBody(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    // MARK: - Operation preamble (how the bot works, prepended to the persona)

    static let operationPreamble: String = """
    You are operating as an always-on background reply bot for the room owner.
    You only see rooms the owner explicitly allowlisted, and the runtime has
    already selected the single new message to answer. Reply only to that trigger
    as the persona defined below; never answer unrelated older messages, and never
    reply to your own outgoing messages. Keep the reply to one short KakaoTalk
    message. If replying is unsafe, unclear, or unnecessary, output exactly SKIP.
    """

    // MARK: - Event output

    private func emit(_ payload: [String: String]) {
        if json {
            var withEvent = payload
            if let data = try? JSONSerialization.data(withJSONObject: withEvent, options: [.sortedKeys, .withoutEscapingSlashes]),
               let line = String(data: data, encoding: .utf8) {
                print(line)
            }
            _ = withEvent
        } else {
            let event = payload["event"] ?? "event"
            let rest = payload.filter { $0.key != "event" }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            print("[bot] \(event): \(rest)")
        }
        // Ensure timely delivery when piped to a log/daemon.
        fflush(stdout)
    }
}

/// Mutable per-room runtime state for the bot loop.
private final class RoomRuntime {
    let title: String
    let monitorID: String
    var window: UIElement?
    var pollState: WatchPollingState
    var recentMessages: [TranscriptMessage]
    var sentBodies: Set<String>
    var baselineDone: Bool

    init(title: String, monitorID: String, sentBodies: Set<String>) {
        self.title = title
        self.monitorID = monitorID
        self.window = nil
        self.pollState = WatchPollingState(includeSystemMessages: false, maxFingerprintCount: 200)
        self.recentMessages = []
        self.sentBodies = sentBodies
        self.baselineDone = false
    }
}
