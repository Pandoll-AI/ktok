import CryptoKit
import Foundation

struct ChatIdentityRecord: Codable {
    var chatID: String
    var accountKey: String
    var accountAlias: String?
    var accountIDHash: String?
    var displayName: String
    var normalizedName: String
    var lastPreviewNormalized: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var lastSeenIndex: Int?
    var lastRefreshTrigger: String?

    enum CodingKeys: String, CodingKey {
        case chatID
        case accountKey
        case accountAlias
        case accountIDHash
        case displayName
        case normalizedName
        case lastPreviewNormalized
        case firstSeenAt
        case lastSeenAt
        case lastSeenIndex
        case lastRefreshTrigger
    }

    init(
        chatID: String,
        accountKey: String,
        accountAlias: String?,
        accountIDHash: String?,
        displayName: String,
        normalizedName: String,
        lastPreviewNormalized: String?,
        firstSeenAt: Date,
        lastSeenAt: Date,
        lastSeenIndex: Int?,
        lastRefreshTrigger: String?
    ) {
        self.chatID = chatID
        self.accountKey = accountKey
        self.accountAlias = accountAlias
        self.accountIDHash = accountIDHash
        self.displayName = displayName
        self.normalizedName = normalizedName
        self.lastPreviewNormalized = lastPreviewNormalized
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.lastSeenIndex = lastSeenIndex
        self.lastRefreshTrigger = lastRefreshTrigger
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let activeAccount = ChatAccountContext.active()

        chatID = try container.decode(String.self, forKey: .chatID)
        accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey) ?? activeAccount.accountKey
        accountAlias = try container.decodeIfPresent(String.self, forKey: .accountAlias) ?? activeAccount.alias
        accountIDHash = try container.decodeIfPresent(String.self, forKey: .accountIDHash) ?? activeAccount.accountIDHash
        displayName = try container.decode(String.self, forKey: .displayName)
        normalizedName = try container.decode(String.self, forKey: .normalizedName)
        lastPreviewNormalized = try container.decodeIfPresent(String.self, forKey: .lastPreviewNormalized)
        firstSeenAt = try container.decode(Date.self, forKey: .firstSeenAt)
        lastSeenAt = try container.decode(Date.self, forKey: .lastSeenAt)
        lastSeenIndex = try container.decodeIfPresent(Int.self, forKey: .lastSeenIndex)
        lastRefreshTrigger = try container.decodeIfPresent(String.self, forKey: .lastRefreshTrigger)
    }
}

private struct ChatIdentityRegistryDocument: Codable {
    var schemaVersion: Int
    var records: [ChatIdentityRecord]
    var updatedAt: Date
}

final class ChatIdentityRegistryStore: @unchecked Sendable {
    static var shared: ChatIdentityRegistryStore {
        ChatIdentityRegistryStore()
    }
    static let schemaVersion = 2

    let fileURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedDocument: ChatIdentityRegistryDocument?

    init(fileURL: URL = ChatIdentityRegistryStore.defaultURL()) {
        self.fileURL = fileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func assignChatIDs(
        for discoveries: [ChatListDiscovery],
        account: ChatAccountContext = .active(),
        trigger: ChatListUpdateTrigger = .manualChatsCommand
    ) -> [String] {
        var document = loadDocument()
        var records = document.records
        let now = Date()
        var assignedIDs = Array(repeating: "", count: discoveries.count)
        let scopedRecordIndices = records.indices.filter { records[$0].accountKey == account.accountKey }

        let groupedCurrent = Dictionary(grouping: discoveries.indices) { index in
            ChatTextNormalizer.normalize(discoveries[index].title)
        }
        let groupedExisting = Dictionary(grouping: scopedRecordIndices) { index in
            records[index].normalizedName
        }

        for (normalizedName, currentIndices) in groupedCurrent {
            var unmatchedCurrent = currentIndices.sorted { discoveries[$0].listIndex < discoveries[$1].listIndex }
            var unmatchedRecords = (groupedExisting[normalizedName] ?? []).sorted { lhs, rhs in
                let lhsPreview = records[lhs].lastPreviewNormalized ?? ""
                let rhsPreview = records[rhs].lastPreviewNormalized ?? ""
                if lhsPreview == rhsPreview {
                    return (records[lhs].lastSeenIndex ?? .max) < (records[rhs].lastSeenIndex ?? .max)
                }
                return lhsPreview < rhsPreview
            }

            for currentIndex in currentIndices {
                let preview = normalizePreview(discoveries[currentIndex].lastMessage)
                guard let preview, !preview.isEmpty else { continue }
                guard let matchOffset = unmatchedRecords.firstIndex(where: { records[$0].lastPreviewNormalized == preview }) else {
                    continue
                }
                let recordIndex = unmatchedRecords.remove(at: matchOffset)
                unmatchedCurrent.removeAll { $0 == currentIndex }
                records[recordIndex] = updatedRecord(
                    records[recordIndex],
                    with: discoveries[currentIndex],
                    preview: preview,
                    account: account,
                    trigger: trigger,
                    now: now
                )
                assignedIDs[currentIndex] = records[recordIndex].chatID
            }

            let sortedRemainingRecords = unmatchedRecords.sorted { lhs, rhs in
                (records[lhs].lastSeenIndex ?? .max) < (records[rhs].lastSeenIndex ?? .max)
            }
            let zippedCount = min(unmatchedCurrent.count, sortedRemainingRecords.count)
            if zippedCount > 0 {
                for offset in 0..<zippedCount {
                    let currentIndex = unmatchedCurrent[offset]
                    let recordIndex = sortedRemainingRecords[offset]
                    let preview = normalizePreview(discoveries[currentIndex].lastMessage)
                    records[recordIndex] = updatedRecord(
                        records[recordIndex],
                        with: discoveries[currentIndex],
                        preview: preview,
                        account: account,
                        trigger: trigger,
                        now: now
                    )
                    assignedIDs[currentIndex] = records[recordIndex].chatID
                }
                unmatchedCurrent.removeFirst(zippedCount)
            }

            for currentIndex in unmatchedCurrent {
                let preview = normalizePreview(discoveries[currentIndex].lastMessage)
                let chatID = nextChatID(for: normalizedName, account: account, existingRecords: records)
                let record = ChatIdentityRecord(
                    chatID: chatID,
                    accountKey: account.accountKey,
                    accountAlias: account.alias,
                    accountIDHash: account.accountIDHash,
                    displayName: discoveries[currentIndex].title,
                    normalizedName: normalizedName,
                    lastPreviewNormalized: preview,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    lastSeenIndex: discoveries[currentIndex].listIndex,
                    lastRefreshTrigger: trigger.rawValue
                )
                records.append(record)
                assignedIDs[currentIndex] = chatID
            }
        }

        document.records = records
        document.updatedAt = now
        cachedDocument = document
        try? persist(document)
        return assignedIDs
    }

    func record(for chatID: String) -> ChatIdentityRecord? {
        let document = loadDocument()
        let activeAccount = ChatAccountContext.active()
        return document.records.first(where: { $0.chatID == chatID && $0.accountKey == activeAccount.accountKey })
            ?? document.records.first(where: { $0.chatID == chatID })
    }

    private func updatedRecord(
        _ record: ChatIdentityRecord,
        with discovery: ChatListDiscovery,
        preview: String?,
        account: ChatAccountContext,
        trigger: ChatListUpdateTrigger,
        now: Date
    ) -> ChatIdentityRecord {
        var updated = record
        updated.accountKey = account.accountKey
        updated.accountAlias = account.alias
        updated.accountIDHash = account.accountIDHash
        updated.displayName = discovery.title
        updated.lastSeenAt = now
        updated.lastSeenIndex = discovery.listIndex
        updated.lastRefreshTrigger = trigger.rawValue
        if let preview, !preview.isEmpty {
            updated.lastPreviewNormalized = preview
        }
        return updated
    }

    private func nextChatID(
        for normalizedName: String,
        account: ChatAccountContext,
        existingRecords: [ChatIdentityRecord]
    ) -> String {
        let base = shortHash("\(account.accountKey)|\(normalizedName)")
        let prefix = "chat_\(base)"
        let existingIDs = Set(existingRecords.map(\.chatID))

        if !existingIDs.contains(prefix) {
            return prefix
        }

        var suffix = 2
        while existingIDs.contains("\(prefix)_\(suffix)") {
            suffix += 1
        }
        return "\(prefix)_\(suffix)"
    }

    private func shortHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private func normalizePreview(_ preview: String?) -> String? {
        guard let preview else { return nil }
        let normalized = ChatTextNormalizer.normalize(preview)
        guard !normalized.isEmpty else { return nil }
        return normalized
    }

    private func loadDocument(forceReload: Bool = false) -> ChatIdentityRegistryDocument {
        if !forceReload, let cachedDocument {
            return cachedDocument
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let document = emptyDocument()
            cachedDocument = document
            return document
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let document = try decoder.decode(ChatIdentityRegistryDocument.self, from: data)
            guard document.schemaVersion <= Self.schemaVersion else {
                let reset = emptyDocument()
                cachedDocument = reset
                return reset
            }
            if document.schemaVersion < Self.schemaVersion {
                var migrated = document
                migrated.schemaVersion = Self.schemaVersion
                migrated.updatedAt = Date()
                cachedDocument = migrated
                try? persist(migrated)
                return migrated
            }
            cachedDocument = document
            return document
        } catch {
            let reset = emptyDocument()
            cachedDocument = reset
            return reset
        }
    }

    private func persist(_ document: ChatIdentityRegistryDocument) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        try data.write(to: fileURL, options: .atomic)
    }

    private func emptyDocument() -> ChatIdentityRegistryDocument {
        ChatIdentityRegistryDocument(
            schemaVersion: Self.schemaVersion,
            records: [],
            updatedAt: Date()
        )
    }

    private static func defaultURL() -> URL {
        KtokPaths.migrateLegacyStorageIfNeeded()
        let alias = LoginAccountState.readWithoutMigration()?.alias ?? "unknown"
        return KtokPaths.rooms(alias: alias)
    }
}

struct ChatAccountContext: Codable {
    let accountKey: String
    let alias: String?
    let accountIDHash: String?

    static func active() -> ChatAccountContext {
        guard let state = LoginAccountState.read() else {
            return ChatAccountContext(accountKey: "account_unknown", alias: nil, accountIDHash: nil)
        }

        let hash = state.accountIDHash ?? state.accountID.map(KtokPaths.shortHash)
        guard let hash else {
            return ChatAccountContext(accountKey: "account_unknown", alias: state.alias, accountIDHash: nil)
        }
        return ChatAccountContext(
            accountKey: state.accountKey ?? "account_\(hash)",
            alias: state.alias,
            accountIDHash: hash
        )
    }
}

enum ChatListUpdateTrigger: String, Codable {
    case manualChatsCommand = "manual_chats_command"
    case successfulLogin = "successful_login"
    case successfulChatOpen = "successful_chat_open"

    static let policySummary = """
    Chat list cache update policy:
    - Account scope is derived from the last successful `ktok login <alias>`.
    - `ktok chats` is the authoritative refresh trigger because it scans the visible KakaoTalk chat list.
    - `ktok login <alias>` changes account scope but does not force a full scan; callers should run `ktok chats --limit <n>` after switching accounts when they need fresh membership.
    - Successful direct chat opens may update individual chat recency later, but they should not replace a full `chats` refresh.
    """
}
