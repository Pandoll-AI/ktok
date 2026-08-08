import ArgumentParser
import Foundation

/// Fail-closed default-room resolution for `ktok bot`.
///
/// Priority (single-room default path):
/// 1. explicit `--chat` / `--chat-id`
/// 2. persona `self_chat_id` (must be monitored + `self_control`)
/// 3. persona `self_chat_title` (must be monitored + `self_control`)
/// 4. exactly one monitored `self_control` room
///
/// `--all-monitored` is an explicit multi-room opt-in and is incompatible with
/// a room override.
enum BotRoomSelector {
    static func validateFlags(chat: String?, chatID: String?, allMonitored: Bool) throws {
        if chat != nil && chatID != nil {
            throw ValidationError("Use either --chat or --chat-id, not both.")
        }
        if allMonitored && (chat != nil || chatID != nil) {
            throw ValidationError("Use --all-monitored or an explicit room override, not both.")
        }
    }

    static func selectRooms(
        store: ChannelStore,
        persona: PersonaConfig,
        chat: String?,
        chatID: String?,
        allMonitored: Bool
    ) throws -> [ChannelChat] {
        try validateFlags(chat: chat, chatID: chatID, allMonitored: allMonitored)

        if allMonitored {
            let rooms = try store.monitoredChats()
            guard !rooms.isEmpty else {
                throw ValidationError("No monitored rooms. Add rooms with: ktok channel monitor add --title \"<room>\"")
            }
            return rooms
        }

        if chat != nil || chatID != nil {
            return [try store.resolveChat(exactTitle: chat, chatID: chatID)]
        }

        if let selfChatID = nonEmpty(persona.selfChatId) {
            let room = try store.resolveChat(exactTitle: nil, chatID: selfChatID)
            try requireDefaultBotRoom(room, source: "persona self_chat_id")
            return [room]
        }

        if let selfChatTitle = nonEmpty(persona.selfChatTitle) {
            let room = try store.resolveChat(exactTitle: selfChatTitle, chatID: nil)
            try requireDefaultBotRoom(room, source: "persona self_chat_title")
            return [room]
        }

        let defaults = try store.monitoredChats().filter { $0.mode == "self_control" }
        guard defaults.count == 1 else {
            if defaults.isEmpty {
                throw ValidationError(
                    "No default bot room is configured. Set persona self_chat_id/self_chat_title to a monitored self_control room, mark exactly one room with --mode self_control, or pass --chat/--chat-id."
                )
            }
            throw ValidationError(
                "Multiple self_control rooms are configured. Pass --chat or --chat-id to choose one explicitly."
            )
        }
        return defaults
    }

    /// Before opening a room by title, ensure the title still maps only to the
    /// selected chat_id so title collisions cannot send to a wrong room.
    static func verifyTitleMapsToChatID(store: ChannelStore, title: String, chatID: String) throws {
        let ids = try store.chatIDsForTitle(title)
        guard !ids.isEmpty else {
            throw ChannelError.chatNotFound(
                "chat title '\(title)' no longer maps to chat_id '\(chatID)'; run `ktok channel refresh-chats`"
            )
        }
        guard ids.count == 1 else {
            throw ChannelError.ambiguousTitle(
                "duplicate title '\(title)' has chat_ids: \(ids.joined(separator: ", ")); expected only '\(chatID)'"
            )
        }
        guard ids[0] == chatID else {
            throw ChannelError.chatNotFound(
                "chat title '\(title)' maps to chat_id '\(ids[0])', expected '\(chatID)'"
            )
        }
    }

    private static func requireDefaultBotRoom(_ room: ChannelChat, source: String) throws {
        guard room.isMonitored, room.mode == "self_control" else {
            throw ValidationError(
                "Default bot room from \(source) must be monitored with mode self_control (chat_id=\(room.chatID), title=\(room.title), monitored=\(room.isMonitored), mode=\(room.mode)). Use: ktok channel monitor add --chat-id '\(room.chatID)' --mode self_control"
            )
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
