import CryptoKit
import Foundation

enum KtokPaths {
    static var home: URL {
        if let override = ProcessInfo.processInfo.environment["KTOK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
                .standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ktok", isDirectory: true)
    }

    static var configDir: URL { home.appendingPathComponent("config", isDirectory: true) }
    static var stateDir: URL { home.appendingPathComponent("state", isDirectory: true) }
    static var accountsDir: URL { home.appendingPathComponent("accounts", isDirectory: true) }
    static var cacheDir: URL { home.appendingPathComponent("cache", isDirectory: true) }
    static var logsDir: URL { home.appendingPathComponent("logs", isDirectory: true) }

    static var currentAccountState: URL {
        stateDir.appendingPathComponent("current-account.json")
    }

    static var legacyMigrationMarker: URL {
        stateDir.appendingPathComponent("legacy-migration.json")
    }

    static var axCache: URL {
        cacheDir.appendingPathComponent("ax-cache.json")
    }

    static func accountDir(alias: String) -> URL {
        accountsDir.appendingPathComponent(safeAlias(alias), isDirectory: true)
    }

    static func accountMetadata(alias: String) -> URL {
        accountDir(alias: alias).appendingPathComponent("account.json")
    }

    static func rooms(alias: String) -> URL {
        accountDir(alias: alias).appendingPathComponent("rooms.json")
    }

    static func defaultDB(alias: String) -> String {
        accountDir(alias: alias).appendingPathComponent("history.sqlite").path
    }

    static func defaultExports(alias: String) -> String {
        accountDir(alias: alias).appendingPathComponent("exports", isDirectory: true).path
    }

    static func defaultDownloads(alias: String) -> String {
        accountDir(alias: alias).appendingPathComponent("downloads", isDirectory: true).path
    }

    static func defaultJobs(alias: String) -> String {
        accountDir(alias: alias).appendingPathComponent("jobs", isDirectory: true).path
    }

    static func accountEventsDir(alias: String) -> URL {
        accountDir(alias: alias).appendingPathComponent("events", isDirectory: true)
    }

    static func accountInputsDir(alias: String) -> URL {
        accountDir(alias: alias).appendingPathComponent("inputs", isDirectory: true)
    }

    static func accountTextInputsDir(alias: String) -> URL {
        accountInputsDir(alias: alias).appendingPathComponent("text", isDirectory: true)
    }

    static func accountFileInputsDir(alias: String) -> URL {
        accountInputsDir(alias: alias).appendingPathComponent("files", isDirectory: true)
    }

    static func accountRoomsDir(alias: String) -> URL {
        accountDir(alias: alias).appendingPathComponent("rooms", isDirectory: true)
    }

    static func roomDir(alias: String, chatID: String) -> URL {
        accountRoomsDir(alias: alias).appendingPathComponent(safeComponent(chatID), isDirectory: true)
    }

    static func roomEventsDir(alias: String, chatID: String) -> URL {
        roomDir(alias: alias, chatID: chatID).appendingPathComponent("events", isDirectory: true)
    }

    static func roomAttachmentsDir(alias: String, chatID: String) -> URL {
        roomDir(alias: alias, chatID: chatID).appendingPathComponent("attachments", isDirectory: true)
    }

    static func roomAttachmentDir(alias: String, chatID: String, attachmentID: String) -> URL {
        roomAttachmentsDir(alias: alias, chatID: chatID)
            .appendingPathComponent(safeComponent(attachmentID), isDirectory: true)
    }

    static func activeAccountAlias() -> String? {
        LoginAccountState.readWithoutMigration()?.alias
    }

    static func activeAccountDir() -> URL? {
        activeAccountAlias().map(accountDir(alias:))
    }

    static func activeDatabasePath() throws -> String {
        migrateLegacyStorageIfNeeded()
        guard let alias = activeAccountAlias() else {
            throw KtokStorageError.accountUnknown
        }
        return defaultDB(alias: alias)
    }

    static func activeExportsPath() throws -> String {
        migrateLegacyStorageIfNeeded()
        guard let alias = activeAccountAlias() else {
            throw KtokStorageError.accountUnknown
        }
        return defaultExports(alias: alias)
    }

    static func activeDownloadsPath() throws -> String {
        migrateLegacyStorageIfNeeded()
        guard let alias = activeAccountAlias() else {
            throw KtokStorageError.accountUnknown
        }
        return defaultDownloads(alias: alias)
    }

    static func ensureWorkspace() {
        let fm = FileManager.default
        for dir in [home, configDir, stateDir, accountsDir, cacheDir, logsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let gitignore = home.appendingPathComponent(".gitignore")
        if !fm.fileExists(atPath: gitignore.path) {
            let contents = """
            *
            !.gitignore
            !README.md
            !config/
            !config/.gitkeep
            """
            try? contents.write(to: gitignore, atomically: true, encoding: .utf8)
        }

        let readme = home.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            let contents = """
            # ktok local workspace

            This directory is the shared local ktok workspace for KakaoTalk account
            state, room cache, live events, user inputs, attachments, explicit history
            imports/exports, downloads, logs, and AX cache.

            External services should write shared ktok data through the ktok CLI first,
            then read the filesystem paths returned by ktok.

            It is safe to initialize this directory as a Git repository, but operational
            data is local-only by default.
            """
            try? contents.write(to: readme, atomically: true, encoding: .utf8)
        }

        let configKeep = configDir.appendingPathComponent(".gitkeep")
        if !fm.fileExists(atPath: configKeep.path) {
            try? Data().write(to: configKeep)
        }
    }

    static func migrateLegacyStorageIfNeeded() {
        ensureWorkspace()
        let fm = FileManager.default

        copyIfNeeded(from: legacyAccountState, to: currentAccountState)
        copyIfNeeded(from: legacyAXCache, to: axCache)

        guard let alias = activeAccountAlias() else {
            return
        }

        let accountDirectory = accountDir(alias: alias)
        try? fm.createDirectory(at: accountDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: defaultExports(alias: alias), withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: defaultDownloads(alias: alias), withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: defaultJobs(alias: alias), withIntermediateDirectories: true)

        guard !fm.fileExists(atPath: legacyMigrationMarker.path) else {
            return
        }

        copyIfNeeded(from: legacyChatRegistry, to: rooms(alias: alias))
        let newDB = URL(fileURLWithPath: defaultDB(alias: alias))
        copyIfNeeded(from: legacyDatabase, to: newDB)
        copyIfNeeded(from: URL(fileURLWithPath: legacyDatabase.path + "-wal"), to: URL(fileURLWithPath: newDB.path + "-wal"))
        copyIfNeeded(from: URL(fileURLWithPath: legacyDatabase.path + "-shm"), to: URL(fileURLWithPath: newDB.path + "-shm"))
        writeLegacyMigrationMarker(alias: alias)
    }

    static func writeAccountMetadata(credentials: LoginCredentials, profileName: String? = nil) {
        ensureWorkspace()
        let hash = shortHash(credentials.accountID)
        let metadata = AccountMetadata(
            alias: credentials.alias,
            accountIDHash: hash,
            profileName: profileName ?? credentials.profileName,
            keychainService: SecretStore.serviceName,
            keychainAccount: SecretStore.accountName(alias: credentials.alias),
            credentialBackend: SecretStore.recommendedBackendDescription,
            lastVerifiedAt: ISO8601DateFormatter().string(from: Date())
        )

        let url = accountMetadata(alias: credentials.alias)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(metadata) {
            try? data.write(to: url, options: .atomic)
        }
    }

    static func ensureAccountWorkspace(alias: String) {
        ensureWorkspace()
        let dirs = [
            accountDir(alias: alias),
            accountEventsDir(alias: alias),
            accountTextInputsDir(alias: alias),
            accountFileInputsDir(alias: alias),
            accountRoomsDir(alias: alias),
            URL(fileURLWithPath: defaultExports(alias: alias), isDirectory: true),
            URL(fileURLWithPath: defaultDownloads(alias: alias), isDirectory: true),
            URL(fileURLWithPath: defaultJobs(alias: alias), isDirectory: true),
        ]
        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    static var legacyAccountState: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ktok/account-state.json")
    }

    static var legacyDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ktok/ktok.db")
    }

    static var legacyChatRegistry: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ktok/chat-registry.json")
    }

    static var legacyAXCache: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ktok/ax-cache.json")
    }

    private static func copyIfNeeded(from source: URL, to destination: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: destination.path) else {
            return
        }
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: source, to: destination)
    }

    private static func writeLegacyMigrationMarker(alias: String) {
        let record: [String: String] = [
            "migrated_alias": alias,
            "migrated_at": ISO8601DateFormatter().string(from: Date()),
            "source": "legacy-application-support-and-dot-ktok-root",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? FileManager.default.createDirectory(at: legacyMigrationMarker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: legacyMigrationMarker, options: .atomic)
    }

    private static func safeAlias(_ alias: String) -> String {
        safeComponent(alias)
    }

    static func safeComponent(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var out = ""
        for scalar in trimmed.unicodeScalars {
            let value = scalar.value
            let isAlpha = (97...122).contains(value)
            let isDigit = (48...57).contains(value)
            if isAlpha || isDigit {
                out.unicodeScalars.append(scalar)
            } else if scalar == "_" || scalar == "-" {
                out.append("_")
            }
        }
        return out.isEmpty ? "unknown" : out
    }

    static func shortHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}

struct AccountMetadata: Codable {
    let alias: String
    let accountIDHash: String
    let profileName: String?
    let keychainService: String
    let keychainAccount: String
    let credentialBackend: String
    let lastVerifiedAt: String
}

enum KtokStorageError: Error, CustomStringConvertible {
    case accountUnknown

    var description: String {
        switch self {
        case .accountUnknown:
            return "Current ktok account is unknown. Run 'ktok login <alias>' or 'ktok assume <alias>' first."
        }
    }
}
