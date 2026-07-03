import Foundation

/// Generates a persona reply by invoking the `codex` CLI as a subprocess.
///
/// Runs `codex exec ... -m <model> -c model_reasoning_effort=<effort> -o <file> -`
/// with the assembled prompt on stdin and reads the reply from the `-o` output
/// file. Returns nil on timeout / non-zero exit / empty / `SKIP`, so callers can
/// fall back to `Persona.fallbackReply`.
struct CodexReplyGenerator {
    let model: String
    let reasoningEffort: String
    let timeout: Double

    func generate(persona: Persona, trigger: TranscriptMessage, recentMessages: [TranscriptMessage], systemPreamble: String? = nil) -> String? {
        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ktok-reply-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let prompt = buildPrompt(persona: persona, trigger: trigger, recentMessages: recentMessages, systemPreamble: systemPreamble)
        let process = Process()
        process.executableURL = Self.codexExecutableURL()
        process.currentDirectoryURL = Self.workingDirectory()
        var environment = ProcessInfo.processInfo.environment
        environment["OTEL_SDK_DISABLED"] = "true"
        process.environment = environment
        process.arguments = [
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox", "read-only",
            "--color", "never",
            "-m", model,
            "-c", "model_reasoning_effort=\"\(reasoningEffort)\"",
            "-o", outputURL.path,
            "-",
        ]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            if let data = prompt.data(using: .utf8) {
                input.fileHandleForWriting.write(data)
            }
            input.fileHandleForWriting.closeFile()
            let deadline = Date().addingTimeInterval(max(3, min(timeout, 120)))
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                return nil
            }
        } catch {
            return nil
        }

        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: outputURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        let reply = clean(text)
        if reply == "SKIP" || reply.isEmpty {
            return nil
        }
        return reply
    }

    private func buildPrompt(persona: Persona, trigger: TranscriptMessage, recentMessages: [TranscriptMessage], systemPreamble: String?) -> String {
        let recipientDisplayName = Persona.recipientDisplayName(from: trigger.author)
        let recent = recentMessages.suffix(8).map {
            [
                "author": $0.author ?? "(me)",
                "time_raw": $0.timeRaw ?? "",
                "body": $0.body,
            ]
        }
        let payload: [String: Any] = [
            "persona": persona.name,
            "recipient_display_name": recipientDisplayName ?? "",
            "recent": Array(recent),
            "trigger": [
                "author": trigger.author ?? "(me)",
                "time_raw": trigger.timeRaw ?? "",
                "body": trigger.body,
            ],
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let preamble = systemPreamble.map { "\($0)\n" } ?? ""
        return """
        \(preamble)\(persona.replyInstructions)
        Context JSON:
        \(json)
        """
    }

    private func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: #"^```[a-zA-Z]*\s*"#, with: "", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Working directory for the codex subprocess. Defaults to the ktok home
    /// (`~/.ktok`), overridable via `KTOK_CODEX_WORKDIR`. Never hardcodes a
    /// developer-specific path.
    private static func workingDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["KTOK_CODEX_WORKDIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return KtokPaths.home
    }

    private static func codexExecutableURL() -> URL {
        for path in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"] where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/opt/homebrew/bin/codex")
    }
}
