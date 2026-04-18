import CryptoKit
import Foundation

/// Derive a stable `chat_id` from a display name without going through the
/// live KakaoTalk registry. Useful for the import-history path where we
/// don't have an AX session.
///
/// Format: `chat_<12 hex chars of sha256(normalizedName)>` — matches the
/// shape of IDs produced by the live ChatIdentityRegistry so existing rows
/// in the DB can be located by name.
enum ChatIdentityHash {
    static func chatId(forDisplayName name: String) -> String {
        let normalized = normalize(name)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "chat_\(hex.prefix(12))"
    }

    /// Delegate to the shared `ChatTextNormalizer.normalize` so import-path
    /// chat_ids match live-registry chat_ids. Previously this function had
    /// its own near-duplicate that did NOT strip punctuation/symbols, which
    /// meant a chat name like "팀(신)" would hash differently between the
    /// live AX registry (strips the parens) and the import path (kept them).
    ///
    /// A single source of truth eliminates that divergence: any name that
    /// normalizes identically in both code paths will map to the same
    /// 12-hex-prefix chat_id regardless of who computed it.
    static func normalize(_ text: String) -> String {
        ChatTextNormalizer.normalize(text)
    }

    /// Extract the chat name from a KakaoTalk export filename:
    /// `KakaoTalk_Chat_<name>_<yyyy-MM-dd-HH-mm-ss>.csv` → `<name>`
    /// Returns nil if the filename doesn't match the pattern. Output is NFC
    /// (precomposed) so it compares byte-equal with shell-typed arguments.
    static func extractChatName(fromFilename filename: String) -> String? {
        let base = (filename as NSString).lastPathComponent
        let stem = (base as NSString).deletingPathExtension
        let prefix = "KakaoTalk_Chat_"
        guard stem.hasPrefix(prefix) else { return nil }
        let afterPrefix = String(stem.dropFirst(prefix.count))
        // Strip the trailing "_YYYY-MM-DD-HH-MM-SS" if present.
        let tsPattern = #"_\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}$"#
        let raw: String
        if let range = afterPrefix.range(of: tsPattern, options: .regularExpression) {
            raw = String(afterPrefix[..<range.lowerBound])
        } else {
            raw = afterPrefix
        }
        return forStorage(raw)
    }

    /// Canonical NFC normalization applied to any display name stored in the
    /// DB or compared at query time. macOS filesystems / iCloud Drive emit
    /// filenames in NFD, while terminal input and SQL literals arrive in NFC.
    /// Without this, SELECT ... WHERE display_name = ? misses every Korean
    /// chat whose name originated from a filename.
    static func forStorage(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
    }
}
