import CryptoKit
import Foundation

// MARK: - Models

struct ChatRecord {
    let chatId: String
    let displayName: String
    let myNickname: String?
    let firstSeenAt: String
    let lastSyncedAt: String?
}

struct MessageRecord {
    let id: Int64?                 // nil before insert
    let chatId: String
    let sentAt: String             // UTC ISO-8601
    let author: String
    let body: String
    let kind: MessageKind
    let rawLine: String?
    let dedupeKey: String
    let firstSyncedAt: String
}

/// Message classification. `other` is a catch-all so unknown markers don't
/// block sync; the raw_line column keeps the source text for later re-classify.
enum MessageKind: String {
    case text = "text"
    case image = "image"
    case file = "file"
    case voice = "voice"
    case video = "video"
    case emoticon = "emoticon"
    case system = "system"
    case other = "other"
}

struct AttachmentRecord {
    let id: Int64?
    let chatId: String
    let messageId: Int64?
    let direction: AttachmentDirection
    let filename: String?
    let localPath: String?
    let sentAt: String?
    let sizeBytes: Int64?
    let sha256: String?
    let source: AttachmentSource
    let recordedAt: String
}

enum AttachmentDirection: String {
    case sent = "sent"
    case received = "received"
    case unknown = "unknown"
}

enum AttachmentSource: String {
    case cliSendFile = "cli_send_file"
    case cliDownloadFile = "cli_download_file"
    case parsedFromDump = "parsed_from_dump"
    case manual = "manual"
}

struct SyncRunRecord {
    let id: Int64?
    let chatId: String
    let startedAt: String
    var finishedAt: String?
    var dumpFilePath: String?
    var linesParsed: Int?
    var messagesInserted: Int?
    var messagesSkippedDuplicates: Int?
    var attachmentsInserted: Int?
    var error: String?
}

// MARK: - Dedupe hashing

enum DedupeKey {
    /// SHA-256 hex of `chat_id|sent_at|author|body`. Fixed 64-char length is
    /// index-friendly. Changes in any component produce a new key, so
    /// edits/retransmissions count as new messages.
    static func compute(chatId: String, sentAt: String, author: String, body: String) -> String {
        let composite = "\(chatId)|\(sentAt)|\(author)|\(body)"
        let digest = SHA256.hash(data: Data(composite.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
