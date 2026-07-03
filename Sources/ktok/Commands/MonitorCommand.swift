import ArgumentParser
import ApplicationServices.HIServices
import CryptoKit
import Darwin
import Foundation

struct MonitorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "monitor",
        abstract: "Monitor one KakaoTalk room and reply with a persona"
    )

    @Argument(help: "Chat room name to monitor")
    var chat: String

    @Option(name: .long, help: "Persona to use. Currently supported: luna")
    var persona: String = "luna"

    @Option(name: .long, help: "Optional extra sleep in seconds after each monitor poll")
    var pollInterval: Double = 0

    @Option(name: .long, help: "Codex model for reply generation")
    var model: String = "gpt-5.4-mini"

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
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }
        // Persona identity/voice is loaded from ~/.ktok/persona/<name>.json
        // (see `ktok persona init`); a neutral, name-free default is used when
        // no config file exists.
        let personaConfig = try Persona.load(named: persona)

        let db = try MonitorStateStore.open()
        let monitorID = MonitorStateStore.monitorID(accountAlias: KtokPaths.activeAccountAlias() ?? "unknown", chatTitle: chat, persona: personaConfig.name)
        try MonitorStateStore.ensureTables(db: db)

        let extraSleep = max(0, min(pollInterval, 30.0))
        let boundedSnapshotLimit = max(8, min(snapshotLimit, 200))
        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao = try KakaoTalkApp()
        let resolver = ChatWindowResolver(kakao: kakao, runner: runner, useCache: true, deepRecoveryEnabled: deepRecovery)
        let messageContextResolver = MessageContextResolver(kakao: kakao, runner: runner)
        let transcriptReader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner)
        let restartFailureLimit = max(0, restartAfterReadFailures)

        let resolution: ChatWindowResolution
        do {
            resolution = try resolver.resolve(query: chat)
        } catch {
            emitReadError(event: "initial_resolve_failed", error: error, chat: chat)
            try restartSelf(reason: "initial_resolve_failed", error: error, failureCount: 1)
        }
        var currentWindow = resolution.window
        var currentChatTitle = currentWindow.title ?? chat
        var cachedContext: MessageTranscriptContext?
        var watchState = WatchPollingState(includeSystemMessages: false, maxFingerprintCount: 200)
        var recentMessages: [TranscriptMessage] = []
        var sentBodies = Set(try MonitorStateStore.recentSentBodies(db: db, monitorID: monitorID, limit: 40))
        var pollCount = 0
        var lastHeartbeatAt = Date()
        var consecutiveReadRecoveryFailures = 0

        let initial: TranscriptSnapshot
        do {
            initial = try readSnapshot(
                transcriptReader: transcriptReader,
                messageContextResolver: messageContextResolver,
                currentWindow: currentWindow,
                currentChatTitle: currentChatTitle,
                snapshotLimit: boundedSnapshotLimit,
                cachedContext: &cachedContext
            )
        } catch {
            emitReadError(event: "initial_read_failed", error: error, chat: currentChatTitle)
            do {
                initial = try recoverSnapshot(
                    resolver: resolver,
                    transcriptReader: transcriptReader,
                    messageContextResolver: messageContextResolver,
                    currentWindow: &currentWindow,
                    currentChatTitle: &currentChatTitle,
                    snapshotLimit: boundedSnapshotLimit,
                    cachedContext: &cachedContext
                )
                emit([
                    "event": "initial_read_recovered",
                    "chat": initial.chat,
                    "visible_messages": initial.messages.count,
                ])
            } catch {
                emitReadError(event: "initial_read_recovery_failed", error: error, chat: currentChatTitle)
                try restartSelf(reason: "initial_read_recovery_failed", error: error, failureCount: 1)
            }
        }
        currentChatTitle = initial.chat
        recentMessages = initial.messages
        watchState.replaceBaseline(with: initial.messages)
        try MonitorStateStore.rememberSeen(db: db, monitorID: monitorID, messages: initial.messages)
        emit(["event": "started", "chat": currentChatTitle, "persona": personaConfig.name, "monitor_id": monitorID])

        while true {
            let snapshot: TranscriptSnapshot
            do {
                snapshot = try readSnapshot(
                    transcriptReader: transcriptReader,
                    messageContextResolver: messageContextResolver,
                    currentWindow: currentWindow,
                    currentChatTitle: currentChatTitle,
                    snapshotLimit: boundedSnapshotLimit,
                    cachedContext: &cachedContext
                )
            } catch {
                emitReadError(event: "read_failed", error: error, chat: currentChatTitle)
                do {
                    let recovered = try recoverSnapshot(
                        resolver: resolver,
                        transcriptReader: transcriptReader,
                        messageContextResolver: messageContextResolver,
                        currentWindow: &currentWindow,
                        currentChatTitle: &currentChatTitle,
                        snapshotLimit: boundedSnapshotLimit,
                        cachedContext: &cachedContext
                    )
                    emit([
                        "event": "read_recovered",
                        "chat": recovered.chat,
                        "visible_messages": recovered.messages.count,
                    ])
                    consecutiveReadRecoveryFailures = 0
                    recentMessages = recovered.messages
                    let emitted = watchState.consume(snapshotMessages: recovered.messages)
                    try handle(
                        emitted: emitted,
                        snapshot: recovered,
                        chatWindow: currentWindow,
                        persona: personaConfig,
                        db: db,
                        monitorID: monitorID,
                        recentMessages: &recentMessages,
                        sentBodies: &sentBodies
                    )
                } catch {
                    consecutiveReadRecoveryFailures += 1
                    emitReadError(event: "read_recovery_failed", error: error, chat: currentChatTitle)
                    emit([
                        "event": "read_failure_streak",
                        "chat": currentChatTitle,
                        "failures": consecutiveReadRecoveryFailures,
                        "restart_after": restartFailureLimit,
                    ])
                    if restartFailureLimit > 0 && consecutiveReadRecoveryFailures >= restartFailureLimit {
                        try restartSelf(
                            reason: "read_recovery_failure_limit",
                            error: error,
                            failureCount: consecutiveReadRecoveryFailures
                        )
                    }
                }
                continue
            }

            currentChatTitle = snapshot.chat
            consecutiveReadRecoveryFailures = 0
            recentMessages = snapshot.messages
            let emitted = watchState.consume(snapshotMessages: snapshot.messages)
            pollCount += 1
            try handle(
                emitted: emitted,
                snapshot: snapshot,
                chatWindow: currentWindow,
                persona: personaConfig,
                db: db,
                monitorID: monitorID,
                recentMessages: &recentMessages,
                sentBodies: &sentBodies
            )
            emitHeartbeatIfNeeded(
                chat: currentChatTitle,
                messageCount: snapshot.messages.count,
                emittedCount: emitted.count,
                pollCount: pollCount,
                lastHeartbeatAt: &lastHeartbeatAt
            )
            if extraSleep > 0 {
                Thread.sleep(forTimeInterval: extraSleep)
            }
        }
    }

    private func readSnapshot(
        transcriptReader: KakaoTalkTranscriptReader,
        messageContextResolver: MessageContextResolver,
        currentWindow: UIElement,
        currentChatTitle: String,
        snapshotLimit: Int,
        cachedContext: inout MessageTranscriptContext?
    ) throws -> TranscriptSnapshot {
        if let cachedContext,
           let snapshot = try? transcriptReader.readSnapshot(
                from: cachedContext,
                chatWindow: currentWindow,
                fallbackChatTitle: currentChatTitle,
                limit: snapshotLimit,
                includeAttachments: false
           ) {
            return snapshot
        }

        guard let context = messageContextResolver.resolve(in: currentWindow) else {
            throw TranscriptReadError.transcriptContextUnavailable
        }
        cachedContext = context
        return try transcriptReader.readSnapshot(
            from: context,
            chatWindow: currentWindow,
            fallbackChatTitle: currentChatTitle,
            limit: snapshotLimit,
            includeAttachments: false
        )
    }

    private func recoverSnapshot(
        resolver: ChatWindowResolver,
        transcriptReader: KakaoTalkTranscriptReader,
        messageContextResolver: MessageContextResolver,
        currentWindow: inout UIElement,
        currentChatTitle: inout String,
        snapshotLimit: Int,
        cachedContext: inout MessageTranscriptContext?
    ) throws -> TranscriptSnapshot {
        cachedContext = nil
        let resolution = try resolver.resolve(query: chat)
        currentWindow = resolution.window
        currentChatTitle = currentWindow.title ?? chat
        return try readSnapshot(
            transcriptReader: transcriptReader,
            messageContextResolver: messageContextResolver,
            currentWindow: currentWindow,
            currentChatTitle: currentChatTitle,
            snapshotLimit: snapshotLimit,
            cachedContext: &cachedContext
        )
    }

    private func handle(
        emitted: [TranscriptMessage],
        snapshot: TranscriptSnapshot,
        chatWindow: UIElement,
        persona: Persona,
        db: Database,
        monitorID: String,
        recentMessages: inout [TranscriptMessage],
        sentBodies: inout Set<String>
    ) throws {
        guard !emitted.isEmpty else { return }

        for message in emitted {
            let key = MonitorStateStore.messageKey(message)
            if try MonitorStateStore.hasSeen(db: db, monitorID: monitorID, messageKey: key) {
                continue
            }
            try MonitorStateStore.rememberSeen(db: db, monitorID: monitorID, message: message, messageKey: key)

            let decision = persona.decision(for: message, sentBodies: sentBodies)
            guard decision.shouldRespond else {
                emit([
                    "event": "skip",
                    "reason": decision.reason,
                    "author": message.author ?? "(me)",
                    "body": persona.logSnippet(message.body),
                ])
                continue
            }

            let reply = CodexReplyGenerator(
                model: model,
                reasoningEffort: reasoningEffort,
                timeout: replyTimeout
            ).generate(persona: persona, trigger: message, recentMessages: recentMessages)
                ?? persona.fallbackReply(for: message)

            let boundedReply = persona.boundReply(reply)
            emit(["event": "reply_ready", "reason": decision.reason, "reply": boundedReply])

            if dryRun {
                try MonitorStateStore.recordReply(db: db, monitorID: monitorID, messageKey: key, reply: boundedReply, status: "dry_run", error: nil)
                continue
            }

            do {
                try send(reply: boundedReply, chatWindow: chatWindow, fallbackChatTitle: snapshot.chat)
                sentBodies.insert(boundedReply)
                try MonitorStateStore.recordReply(db: db, monitorID: monitorID, messageKey: key, reply: boundedReply, status: "sent", error: nil)
                emit(["event": "sent", "reply": boundedReply])
            } catch {
                try MonitorStateStore.recordReply(db: db, monitorID: monitorID, messageKey: key, reply: boundedReply, status: "failed", error: String(describing: error))
                emit(["event": "send_failed", "error": String(describing: error)])
            }
        }
    }

    private func send(reply: String, chatWindow: UIElement, fallbackChatTitle: String) throws {
        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: traceAX)
        let contextResolver = MessageContextResolver(kakao: kakao, runner: runner)
        kakao.activate()
        _ = tryRaiseWindow(chatWindow, runner: runner)
        Thread.sleep(forTimeInterval: 0.08)
        guard let context = contextResolver.resolve(in: chatWindow) else {
            guard let fallbackWindow = kakao.windows.first(where: { ($0.title ?? "") == fallbackChatTitle }) else {
                throw TranscriptReadError.transcriptContextUnavailable
            }
            _ = tryRaiseWindow(fallbackWindow, runner: runner)
            guard let fallbackContext = contextResolver.resolve(in: fallbackWindow) else {
                throw TranscriptReadError.transcriptContextUnavailable
            }
            return try send(reply: reply, input: fallbackContext.inputElement, runner: runner)
        }
        try send(reply: reply, input: context.inputElement, runner: runner)
    }

    private func send(reply: String, input: UIElement, runner: AXActionRunner) throws {
        guard runner.focusWithVerification(input, label: "monitor input", attempts: 1) else {
            throw KakaoTalkError.actionFailed("Could not focus message input")
        }
        let ready = runner.setTextWithVerification(reply, on: input, label: "monitor input", attempts: 1)
            || runner.typeTextWithVerification(reply, on: input, label: "monitor input", attempts: 2)
        guard ready else {
            throw KakaoTalkError.actionFailed("Reply text was not reflected in input")
        }
        guard runner.pressEnterWithVerification(on: input, label: "monitor input", attempts: 2) else {
            throw KakaoTalkError.actionFailed("Enter key did not send reply")
        }
    }

    private func tryRaiseWindow(_ window: UIElement, runner: AXActionRunner) -> Bool {
        if supportsAction(kAXRaiseAction, on: window) {
            do {
                try window.performAction(kAXRaiseAction)
                runner.log("monitor: window raised via AXRaise")
                return true
            } catch {
                runner.log("monitor: AXRaise failed (\(error))")
            }
        }
        return false
    }

    private func supportsAction(_ action: String, on element: UIElement) -> Bool {
        guard let actions = try? element.actionNames() else { return false }
        return actions.contains(action)
    }

    private func emitHeartbeatIfNeeded(
        chat: String,
        messageCount: Int,
        emittedCount: Int,
        pollCount: Int,
        lastHeartbeatAt: inout Date
    ) {
        guard heartbeatInterval > 0 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastHeartbeatAt) >= heartbeatInterval else { return }
        lastHeartbeatAt = now
        emit([
            "event": "heartbeat",
            "chat": chat,
            "poll_count": pollCount,
            "visible_messages": messageCount,
            "new_messages": emittedCount,
        ])
    }

    private func emitReadError(event: String, error: Error, chat: String) {
        var payload: [String: Any] = [
            "event": event,
            "chat": chat,
            "error": String(describing: error),
        ]
        if let description = localizedDescription(for: error) {
            payload["detail"] = description
        }
        emit(payload)
    }

    private func localizedDescription(for error: Error) -> String? {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        let description = error.localizedDescription
        return description == String(describing: error) ? nil : description
    }

    private func restartSelf(reason: String, error: Error, failureCount: Int) throws -> Never {
        let boundedDelay = max(0, min(restartDelay, 30))
        emit([
            "event": "self_restart",
            "reason": reason,
            "error": String(describing: error),
            "failures": failureCount,
            "delay_seconds": boundedDelay,
        ])
        fflush(stdout)
        fflush(stderr)

        if boundedDelay > 0 {
            Thread.sleep(forTimeInterval: boundedDelay)
        }

        let arguments = CommandLine.arguments
        guard let executable = arguments.first, !executable.isEmpty else {
            throw KakaoTalkError.actionFailed("Cannot restart monitor: executable path is empty")
        }

        let cArguments = arguments.map { strdup($0) } + [nil]
        defer {
            for case let argument? in cArguments {
                free(argument)
            }
        }

        executable.withCString { executablePath in
            cArguments.withUnsafeBufferPointer { buffer in
                _ = execv(executablePath, UnsafeMutablePointer(mutating: buffer.baseAddress))
            }
        }

        let execError = String(cString: strerror(errno))
        emit([
            "event": "self_restart_failed",
            "reason": reason,
            "error": execError,
        ])
        throw KakaoTalkError.actionFailed("Cannot restart monitor: \(execError)")
    }

    private func emit(_ object: [String: Any]) {
        if json {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
                  let text = String(data: data, encoding: .utf8)
            else {
                writeLine("{}")
                return
            }
            writeLine(text)
            return
        }

        let event = object["event"] as? String ?? "monitor"
        if let reply = object["reply"] as? String {
            writeLine("[monitor] \(event): \(reply)")
        } else if let reason = object["reason"] as? String {
            writeLine("[monitor] \(event): \(reason)")
        } else if let error = object["error"] as? String {
            writeLine("[monitor] \(event): \(error)")
        } else {
            writeLine("[monitor] \(event)")
        }
    }

    private func writeLine(_ text: String) {
        guard let data = "\(text)\n".data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
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
