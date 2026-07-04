import Foundation

/// Runtime persona: reply-eligibility decisions, the LLM instruction block, and
/// fallback replies — all driven by an external `PersonaConfig` so no private
/// content lives in source. Shared by `ktok monitor` and `ktok bot`.
struct Persona {
    let config: PersonaConfig

    var name: String { config.name }

    /// Loads the persona by name from `~/.ktok/persona/<name>.json`, falling
    /// back to the neutral default when no config file exists.
    static func load(named rawName: String) throws -> Persona {
        Persona(config: try PersonaConfig.load(name: rawName))
    }

    /// The full instruction block sent to the LLM (identity/voice/examples/safety).
    var replyInstructions: String { config.systemPrompt }

    var maxReplyCharacters: Int { config.maxReplyChars }

    // MARK: - Reply-eligibility decision

    /// Decides whether the persona should reply to a message. This is the
    /// `persona` trigger mode; `ktok bot` also offers mention/all/off modes.
    func decision(for message: TranscriptMessage, sentBodies: Set<String>) -> (shouldRespond: Bool, reason: String) {
        let body = normalized(message.body)
        guard !body.isEmpty else { return (false, "empty") }
        if sentBodies.contains(body) { return (false, "sent-body") }
        if body.localizedCaseInsensitiveContains("bookmarked here for unread messages") { return (false, "bookmark") }
        if body.localizedCaseInsensitiveContains("joined this chatroom") { return (false, "system") }
        if isLowValue(body) { return (false, "low-value") }

        let isBossOrLocalUser = isOwnerAuthor(message.author) || isLocalUserAuthor(message.author)
        if config.triggers.directCall.contains(where: { body.localizedCaseInsensitiveContains($0) }) {
            return (true, "direct-call")
        }

        let containsOtherName = config.excludedNames.contains { body.localizedCaseInsensitiveContains($0) }
        if containsOtherName && !isBossOrLocalUser && !isExcludedNameAuthor(message.author) {
            return (false, "other-name")
        }

        if config.triggers.greeting.contains(where: { body.localizedCaseInsensitiveContains($0) }) {
            return (true, "greeting")
        }
        if config.triggers.empathy.contains(where: { body.localizedCaseInsensitiveContains($0) }) {
            return (true, "warm-empathy")
        }
        if isProfileQuestion(body) {
            return (true, "persona-profile")
        }
        if config.triggers.search.contains(where: { body.localizedCaseInsensitiveContains($0) }) {
            return (true, "search-request")
        }
        if config.triggers.question.contains(where: { body.localizedCaseInsensitiveContains($0) }) {
            return (true, "recent-question")
        }
        return (false, "not-addressed")
    }

    /// Whether the message is a direct call/mention of the persona (mention mode).
    func isDirectCall(_ message: TranscriptMessage) -> Bool {
        let body = normalized(message.body)
        return config.triggers.directCall.contains { body.localizedCaseInsensitiveContains($0) }
    }

    /// Whether the message is a greeting configured for the persona.
    func isGreeting(_ message: TranscriptMessage) -> Bool {
        let body = normalized(message.body)
        return config.triggers.greeting.contains { body.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - Fallback replies (used when the LLM returns nil)

    func fallbackReply(for message: TranscriptMessage) -> String {
        let body = normalized(message.body)
        let prefix = Self.recipientDisplayName(from: message.author).map { "\($0)님, " } ?? ""
        let fb = config.fallbackReplies
        if isProfileQuestion(body), let profile = fb.profile {
            return prefix + profile
        }
        if let secret = fb.secret,
           body.localizedCaseInsensitiveContains("api") || body.localizedCaseInsensitiveContains("비번") || body.localizedCaseInsensitiveContains("token") {
            return prefix + secret
        }
        if let comfort = fb.comfort,
           body.localizedCaseInsensitiveContains("우울") || body.localizedCaseInsensitiveContains("울적") {
            return prefix + comfort
        }
        if let greeting = fb.greeting,
           config.triggers.greeting.contains(where: { body.localizedCaseInsensitiveContains($0) }) {
            return prefix + greeting
        }
        return prefix + fb.default
    }

    func boundReply(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard trimmed.count > config.maxReplyChars else { return trimmed }
        return String(trimmed.prefix(config.maxReplyChars))
    }

    func logSnippet(_ raw: String) -> String {
        let text = normalized(raw)
        guard text.count > 80 else { return text }
        return "\(text.prefix(80))..."
    }

    // MARK: - Helpers

    private func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func isLowValue(_ body: String) -> Bool {
        let stripped = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.range(of: #"^[ㅋㅎㅠㅜ!?.\s]+$"#, options: .regularExpression) != nil {
            return true
        }
        return ["넵", "네", "아항", "오", "앗", "굿", "좋아요", "ㅇㅋ", "ok", "OK"].contains(stripped)
    }

    private func isProfileQuestion(_ body: String) -> Bool {
        config.triggers.profile.contains { body.localizedCaseInsensitiveContains($0) }
    }

    private func isOwnerAuthor(_ author: String?) -> Bool {
        guard let author else { return false }
        return config.ownerTokens.contains { author.localizedCaseInsensitiveContains($0) }
    }

    private func isLocalUserAuthor(_ author: String?) -> Bool {
        author == nil || author == "(me)"
    }

    private func isExcludedNameAuthor(_ author: String?) -> Bool {
        guard let author else { return false }
        return config.excludedNames.contains { author.localizedCaseInsensitiveContains($0) }
    }

    static func recipientDisplayName(from author: String?) -> String? {
        guard var name = author?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty,
              name != "(me)"
        else {
            return nil
        }
        if name.hasPrefix("@") {
            name.removeFirst()
        }
        if let slash = name.firstIndex(of: "/") {
            name = String(name[..<slash])
        }
        if let at = name.firstIndex(of: "@") {
            name = String(name[..<at])
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "@ /"))
        guard !name.isEmpty else { return nil }
        if name.count > 14 {
            return String(name.prefix(14))
        }
        return name
    }
}
