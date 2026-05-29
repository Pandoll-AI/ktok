import CryptoKit
import Darwin
import Foundation

struct WorkspaceChatScope: Sendable {
    let accountAlias: String
    let accountKey: String?
    let chatID: String?
    let chatTitle: String?
    let resolved: Bool
}

struct WorkspaceWriteResult: Sendable {
    let id: String
    let accountAlias: String
    let chatID: String?
    let path: String?
    let eventPath: String?
    let eventPaths: [String]
    let createdAt: String
    let extra: [String: AnySendable]

    func jsonObject(ok: Bool = true) -> [String: Any] {
        var object: [String: Any] = [
            "ok": ok,
            "id": id,
            "account_alias": accountAlias,
            "chat_id": chatID.map { $0 as Any } ?? NSNull(),
            "path": path.map { $0 as Any } ?? NSNull(),
            "event_path": eventPath.map { $0 as Any } ?? NSNull(),
            "event_paths": eventPaths,
            "created_at": createdAt,
        ]
        for (key, value) in extra {
            object[key] = value.value
        }
        return object
    }
}

struct AnySendable: @unchecked Sendable {
    let value: Any
}

enum KtokWorkspaceError: Error, CustomStringConvertible {
    case invalidJSON(String)
    case invalidInput(String)
    case writeFailed(String)

    var description: String {
        switch self {
        case .invalidJSON(let message):
            return "Invalid JSON: \(message)"
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .writeFailed(let message):
            return "Workspace write failed: \(message)"
        }
    }
}

enum KtokWorkspaceStore {
    static let schemaVersion = 1

    static func resolveScope(accountAlias: String?, chatID: String?, chatTitle: String?) -> WorkspaceChatScope {
        let alias = normalizedAccountAlias(accountAlias)
        KtokPaths.ensureAccountWorkspace(alias: alias)

        let accountState = LoginAccountState.readWithoutMigration()
        let accountKey = accountState?.alias == alias ? accountState?.accountKey : nil
        let trimmedChatID = trimmedNonEmpty(chatID)
        let trimmedChatTitle = trimmedNonEmpty(chatTitle)

        if let trimmedChatID {
            return WorkspaceChatScope(
                accountAlias: alias,
                accountKey: accountKey,
                chatID: trimmedChatID,
                chatTitle: trimmedChatTitle,
                resolved: true
            )
        }

        guard let trimmedChatTitle else {
            return WorkspaceChatScope(
                accountAlias: alias,
                accountKey: accountKey,
                chatID: nil,
                chatTitle: nil,
                resolved: false
            )
        }

        if let resolved = resolveChatID(alias: alias, chatTitle: trimmedChatTitle) {
            return WorkspaceChatScope(
                accountAlias: alias,
                accountKey: accountKey,
                chatID: resolved,
                chatTitle: trimmedChatTitle,
                resolved: true
            )
        }

        let fallback = "chat_\(hashPrefix("\(alias)|\(ChatTextNormalizer.normalize(trimmedChatTitle))", bytes: 6))"
        return WorkspaceChatScope(
            accountAlias: alias,
            accountKey: accountKey,
            chatID: fallback,
            chatTitle: trimmedChatTitle,
            resolved: false
        )
    }

    static func paths(accountAlias: String?, chatID: String?, chatTitle: String?) -> [String: Any] {
        KtokPaths.ensureWorkspace()
        var result: [String: Any] = [
            "ok": true,
            "home": KtokPaths.home.path,
            "config": KtokPaths.configDir.path,
            "state": KtokPaths.stateDir.path,
            "current_account": KtokPaths.currentAccountState.path,
            "cache": KtokPaths.cacheDir.path,
            "ax_cache": KtokPaths.axCache.path,
            "logs": KtokPaths.logsDir.path,
        ]

        let alias = trimmedNonEmpty(accountAlias) ?? KtokPaths.activeAccountAlias()
        guard let alias else {
            result["active_alias"] = NSNull()
            return result
        }

        let scope = resolveScope(accountAlias: alias, chatID: chatID, chatTitle: chatTitle)
        result["account_alias"] = scope.accountAlias
        result["account_dir"] = KtokPaths.accountDir(alias: scope.accountAlias).path
        result["account_events"] = KtokPaths.accountEventsDir(alias: scope.accountAlias).path
        result["inputs_text"] = KtokPaths.accountTextInputsDir(alias: scope.accountAlias).path
        result["inputs_files"] = KtokPaths.accountFileInputsDir(alias: scope.accountAlias).path
        result["rooms_json"] = KtokPaths.rooms(alias: scope.accountAlias).path
        result["rooms_dir"] = KtokPaths.accountRoomsDir(alias: scope.accountAlias).path
        result["history_db"] = KtokPaths.defaultDB(alias: scope.accountAlias)
        result["downloads"] = KtokPaths.defaultDownloads(alias: scope.accountAlias)
        result["exports"] = KtokPaths.defaultExports(alias: scope.accountAlias)
        result["jobs"] = KtokPaths.defaultJobs(alias: scope.accountAlias)

        if let chatID = scope.chatID {
            result["chat_id"] = chatID
            result["chat_title"] = scope.chatTitle.map { $0 as Any } ?? NSNull()
            result["chat_resolved"] = scope.resolved
            result["room_dir"] = KtokPaths.roomDir(alias: scope.accountAlias, chatID: chatID).path
            result["room_events"] = KtokPaths.roomEventsDir(alias: scope.accountAlias, chatID: chatID).path
            result["room_attachments"] = KtokPaths.roomAttachmentsDir(alias: scope.accountAlias, chatID: chatID).path
        }

        return result
    }

    static func validate() -> [String: Any] {
        KtokPaths.ensureWorkspace()
        var checked = [
            KtokPaths.home,
            KtokPaths.configDir,
            KtokPaths.stateDir,
            KtokPaths.accountsDir,
            KtokPaths.cacheDir,
            KtokPaths.logsDir,
        ]
        let accountAliases = discoveredAccountAliases()
        for alias in accountAliases {
            KtokPaths.ensureAccountWorkspace(alias: alias)
            checked.append(contentsOf: [
                KtokPaths.accountDir(alias: alias),
                KtokPaths.accountEventsDir(alias: alias),
                KtokPaths.accountTextInputsDir(alias: alias),
                KtokPaths.accountFileInputsDir(alias: alias),
                KtokPaths.accountRoomsDir(alias: alias),
            ])
        }

        let statuses = checked.map { url -> [String: Any] in
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return [
                "path": url.path,
                "exists": exists,
                "is_directory": exists && isDirectory.boolValue,
            ]
        }

        return [
            "ok": statuses.allSatisfy { ($0["exists"] as? Bool) == true },
            "home": KtokPaths.home.path,
            "accounts": accountAliases,
            "checked": statuses,
        ]
    }

    static func saveText(
        accountAlias: String,
        chatID: String?,
        chatTitle: String?,
        source: String,
        text: String
    ) throws -> WorkspaceWriteResult {
        let scope = resolveScope(accountAlias: accountAlias, chatID: chatID, chatTitle: chatTitle)
        let createdAt = isoString(Date())
        let date = localDateString(Date())
        let inputID = "inp_\(uuidString())"
        let directory = KtokPaths.accountTextInputsDir(alias: scope.accountAlias)
            .appendingPathComponent(date, isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(inputID).json")

        let object: [String: Any] = [
            "schema_version": schemaVersion,
            "input_id": inputID,
            "source": source,
            "account_alias": scope.accountAlias,
            "account_key": scope.accountKey.map { $0 as Any } ?? NSNull(),
            "chat_id": scope.chatID.map { $0 as Any } ?? NSNull(),
            "chat_title": scope.chatTitle.map { $0 as Any } ?? NSNull(),
            "chat_resolved": scope.resolved,
            "text": text,
            "created_at": createdAt,
        ]
        try writeJSONObject(object, to: fileURL)

        let event = try appendEvent(
            accountAlias: scope.accountAlias,
            accountKey: scope.accountKey,
            chatID: scope.chatID,
            chatTitle: scope.chatTitle,
            eventType: "input_text",
            source: "ktok_inputs",
            payload: [
                "input_id": inputID,
                "source": source,
                "text_path": fileURL.path,
                "text_preview": String(text.prefix(160)),
            ],
            eventID: "evt_\(hashPrefix("input_text|\(scope.accountAlias)|\(scope.chatID ?? "")|\(inputID)", bytes: 8))",
            timestamp: createdAt,
            paths: ["input_text": fileURL.path]
        )

        return WorkspaceWriteResult(
            id: inputID,
            accountAlias: scope.accountAlias,
            chatID: scope.chatID,
            path: fileURL.path,
            eventPath: event.eventPath,
            eventPaths: event.eventPaths,
            createdAt: createdAt,
            extra: [
                "chat_title": AnySendable(value: scope.chatTitle.map { $0 as Any } ?? NSNull()),
                "chat_resolved": AnySendable(value: scope.resolved),
            ]
        )
    }

    static func saveFile(
        accountAlias: String,
        chatID: String?,
        chatTitle: String?,
        source: String,
        filePath: String
    ) throws -> WorkspaceWriteResult {
        let sourceURL = URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw KtokWorkspaceError.invalidInput("file does not exist or is a directory: \(sourceURL.path)")
        }

        let scope = resolveScope(accountAlias: accountAlias, chatID: chatID, chatTitle: chatTitle)
        let createdAt = isoString(Date())
        let date = localDateString(Date())
        let inputID = "inp_\(uuidString())"
        let directory = KtokPaths.accountFileInputsDir(alias: scope.accountAlias)
            .appendingPathComponent(date, isDirectory: true)
            .appendingPathComponent(inputID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let originalName = sourceURL.lastPathComponent
        let storedName = "original" + (sourceURL.pathExtension.isEmpty ? "" : ".\(sourceURL.pathExtension)")
        let storedURL = directory.appendingPathComponent(storedName)
        try copyFileAtomically(from: sourceURL, to: storedURL)

        let attributes = try FileManager.default.attributesOfItem(atPath: storedURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let sha = try sha256File(storedURL)
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let metadata: [String: Any] = [
            "schema_version": schemaVersion,
            "input_id": inputID,
            "source": source,
            "account_alias": scope.accountAlias,
            "account_key": scope.accountKey.map { $0 as Any } ?? NSNull(),
            "chat_id": scope.chatID.map { $0 as Any } ?? NSNull(),
            "chat_title": scope.chatTitle.map { $0 as Any } ?? NSNull(),
            "chat_resolved": scope.resolved,
            "original_filename": originalName,
            "stored_path": storedURL.path,
            "sha256": sha,
            "size_bytes": size,
            "created_at": createdAt,
        ]
        try writeJSONObject(metadata, to: metadataURL)

        let event = try appendEvent(
            accountAlias: scope.accountAlias,
            accountKey: scope.accountKey,
            chatID: scope.chatID,
            chatTitle: scope.chatTitle,
            eventType: "input_file",
            source: "ktok_inputs",
            payload: [
                "input_id": inputID,
                "source": source,
                "original_filename": originalName,
                "stored_path": storedURL.path,
                "metadata_path": metadataURL.path,
                "sha256": sha,
                "size_bytes": size,
            ],
            eventID: "evt_\(hashPrefix("input_file|\(scope.accountAlias)|\(scope.chatID ?? "")|\(inputID)", bytes: 8))",
            timestamp: createdAt,
            paths: ["input_file": storedURL.path, "metadata": metadataURL.path]
        )

        return WorkspaceWriteResult(
            id: inputID,
            accountAlias: scope.accountAlias,
            chatID: scope.chatID,
            path: storedURL.path,
            eventPath: event.eventPath,
            eventPaths: event.eventPaths,
            createdAt: createdAt,
            extra: [
                "metadata_path": AnySendable(value: metadataURL.path),
                "sha256": AnySendable(value: sha),
                "size_bytes": AnySendable(value: size),
                "original_filename": AnySendable(value: originalName),
                "chat_title": AnySendable(value: scope.chatTitle.map { $0 as Any } ?? NSNull()),
                "chat_resolved": AnySendable(value: scope.resolved),
            ]
        )
    }

    @discardableResult
    static func appendEvent(
        accountAlias: String,
        accountKey: String? = nil,
        chatID: String?,
        chatTitle: String?,
        eventType: String,
        source: String,
        payload: Any,
        eventID: String? = nil,
        timestamp: String = isoString(Date()),
        paths: [String: String]? = nil
    ) throws -> WorkspaceWriteResult {
        guard JSONSerialization.isValidJSONObject(payloadContainer(payload)) else {
            throw KtokWorkspaceError.invalidJSON("payload must be JSON-serializable")
        }

        let safeEventType = trimmedNonEmpty(eventType) ?? "event"
        let safeSource = trimmedNonEmpty(source) ?? "external"
        let eventID = eventID ?? "evt_\(hashPrefix("\(accountAlias)|\(chatID ?? "")|\(safeEventType)|\(safeSource)|\(timestamp)|\(stableJSONString(payload))", bytes: 8))"
        let date = String(timestamp.prefix(10))
        let accountEventURL = KtokPaths.accountEventsDir(alias: accountAlias)
            .appendingPathComponent("\(date).jsonl")

        var event: [String: Any] = [
            "schema_version": schemaVersion,
            "event_id": eventID,
            "event_type": safeEventType,
            "account_alias": accountAlias,
            "account_key": accountKey.map { $0 as Any } ?? NSNull(),
            "chat_id": chatID.map { $0 as Any } ?? NSNull(),
            "chat_title": chatTitle.map { $0 as Any } ?? NSNull(),
            "source": safeSource,
            "created_at": timestamp,
            "observed_at": timestamp,
            "payload": payload,
        ]
        if let paths {
            event["paths"] = paths
        }

        var eventPaths: [String] = []
        try appendJSONLine(event, to: accountEventURL)
        eventPaths.append(accountEventURL.path)

        if let chatID {
            let roomEventURL = KtokPaths.roomEventsDir(alias: accountAlias, chatID: chatID)
                .appendingPathComponent("\(date).jsonl")
            try appendJSONLine(event, to: roomEventURL)
            eventPaths.append(roomEventURL.path)
        }

        return WorkspaceWriteResult(
            id: eventID,
            accountAlias: accountAlias,
            chatID: chatID,
            path: nil,
            eventPath: eventPaths.last ?? eventPaths.first,
            eventPaths: eventPaths,
            createdAt: timestamp,
            extra: [
                "event_type": AnySendable(value: safeEventType),
                "source": AnySendable(value: safeSource),
            ]
        )
    }

    static func recordReadSnapshot(_ snapshot: TranscriptSnapshot, source: String = "ktok_read") {
        let scope = resolveScope(accountAlias: KtokPaths.activeAccountAlias() ?? "unknown", chatID: nil, chatTitle: snapshot.chat)
        let observedAt = isoString(snapshot.fetchedAt)

        for message in snapshot.messages {
            let eventID = "evt_\(hashPrefix("message|\(scope.accountAlias)|\(scope.chatID ?? "")|\(message.author ?? "")|\(message.timeRaw ?? "")|\(message.body)", bytes: 8))"
            _ = try? appendEvent(
                accountAlias: scope.accountAlias,
                accountKey: scope.accountKey,
                chatID: scope.chatID,
                chatTitle: scope.chatTitle,
                eventType: message.isSystem ? "system" : "message",
                source: source,
                payload: [
                    "author": message.author ?? "(me)",
                    "time_raw": message.timeRaw.map { $0 as Any } ?? NSNull(),
                    "body": message.body,
                    "is_system": message.isSystem,
                ],
                eventID: eventID,
                timestamp: observedAt
            )
        }

        for attachment in snapshot.attachments {
            recordAttachmentSighting(attachment, scope: scope, source: source, observedAt: observedAt)
        }
    }

    static func recordAttachmentSighting(
        _ attachment: TranscriptAttachment,
        scope: WorkspaceChatScope? = nil,
        source: String,
        observedAt: String = isoString(Date())
    ) {
        let scope = scope ?? resolveScope(accountAlias: KtokPaths.activeAccountAlias() ?? "unknown", chatID: attachment.chatID, chatTitle: attachment.chat)
        let attachmentDir = scope.chatID.map {
            KtokPaths.roomAttachmentDir(alias: scope.accountAlias, chatID: $0, attachmentID: attachment.attachmentID)
        }
        var paths: [String: String] = [:]
        if let attachmentDir {
            try? FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
            let metadataURL = attachmentDir.appendingPathComponent("metadata.json")
            paths["metadata"] = metadataURL.path
            let metadata = attachmentMetadataObject(
                attachment: attachment,
                scope: scope,
                status: "seen",
                downloadedFile: nil,
                saveDir: nil,
                createdAt: observedAt
            )
            if (try? writeAttachmentMetadata(metadata, to: metadataURL, lastSeenAt: observedAt)) != nil {
                paths["metadata"] = metadataURL.path
            }
        }

        let eventID = "evt_\(hashPrefix("attachment|\(scope.accountAlias)|\(scope.chatID ?? "")|\(attachment.attachmentID)", bytes: 8))"
        _ = try? appendEvent(
            accountAlias: scope.accountAlias,
            accountKey: scope.accountKey,
            chatID: scope.chatID,
            chatTitle: scope.chatTitle,
            eventType: "attachment",
            source: source,
            payload: attachmentPayload(attachment),
            eventID: eventID,
            timestamp: observedAt,
            paths: paths.isEmpty ? nil : paths
        )
    }

    @discardableResult
    static func recordDownload(
        chatTitle: String,
        attachmentID: String,
        candidateValue: String,
        target: [String: Any],
        downloadedFile: String?,
        saveDir: String,
        watchedDirs: [String],
        status: String
    ) -> WorkspaceWriteResult? {
        let scope = resolveScope(accountAlias: KtokPaths.activeAccountAlias() ?? "unknown", chatID: nil, chatTitle: chatTitle)
        let createdAt = isoString(Date())
        var paths: [String: String] = ["save_dir": saveDir]
        if let downloadedFile {
            paths["downloaded_file"] = downloadedFile
        }

        if let chatID = scope.chatID {
            let attachmentDir = KtokPaths.roomAttachmentDir(alias: scope.accountAlias, chatID: chatID, attachmentID: attachmentID)
            try? FileManager.default.createDirectory(at: attachmentDir, withIntermediateDirectories: true)
            let metadataURL = attachmentDir.appendingPathComponent("metadata.json")
            paths["metadata"] = metadataURL.path
            let metadata: [String: Any] = [
                "schema_version": schemaVersion,
                "attachment_id": attachmentID,
                "account_alias": scope.accountAlias,
                "account_key": scope.accountKey.map { $0 as Any } ?? NSNull(),
                "chat_id": scope.chatID.map { $0 as Any } ?? NSNull(),
                "chat_title": scope.chatTitle.map { $0 as Any } ?? NSNull(),
                "chat_resolved": scope.resolved,
                "candidate_value": candidateValue,
                "target": target,
                "downloaded_file": downloadedFile.map { $0 as Any } ?? NSNull(),
                "save_dir": saveDir,
                "watched_dirs": watchedDirs,
                "status": status,
                "created_at": createdAt,
            ]
            if (try? writeAttachmentMetadata(metadata, to: metadataURL, lastSeenAt: nil)) != nil {
                paths["metadata"] = metadataURL.path
            }
        }

        return try? appendEvent(
            accountAlias: scope.accountAlias,
            accountKey: scope.accountKey,
            chatID: scope.chatID,
            chatTitle: scope.chatTitle,
            eventType: "download",
            source: "ktok_download_file",
            payload: [
                "attachment_id": attachmentID,
                "candidate_value": candidateValue,
                "downloaded_file": downloadedFile.map { $0 as Any } ?? NSNull(),
                "save_dir": saveDir,
                "watched_dirs": watchedDirs,
                "status": status,
                "target": target,
            ],
            eventID: "evt_\(hashPrefix("download|\(scope.accountAlias)|\(scope.chatID ?? "")|\(attachmentID)|\(status)|\(downloadedFile ?? "")", bytes: 8))",
            timestamp: createdAt,
            paths: paths
        )
    }

    static func attachmentDirectory(accountAlias: String, chatTitle: String, attachmentID: String) -> URL {
        let scope = resolveScope(accountAlias: accountAlias, chatID: nil, chatTitle: chatTitle)
        let chatID = scope.chatID ?? "chat_\(hashPrefix("\(scope.accountAlias)|\(chatTitle)", bytes: 6))"
        return KtokPaths.roomAttachmentDir(alias: scope.accountAlias, chatID: chatID, attachmentID: attachmentID)
    }

    static func printJSON(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
            let string = String(data: data, encoding: .utf8)
        else {
            print("{}")
            return
        }
        print(string)
    }

    static func jsonObject(from data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw KtokWorkspaceError.invalidJSON(error.localizedDescription)
        }
    }

    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func localDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func hashPrefix(_ text: String, bytes: Int) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedAccountAlias(_ alias: String?) -> String {
        trimmedNonEmpty(alias) ?? KtokPaths.activeAccountAlias() ?? "unknown"
    }

    private static func discoveredAccountAliases() -> [String] {
        var aliases = Set<String>()
        if let active = KtokPaths.activeAccountAlias() {
            aliases.insert(active)
        }
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: KtokPaths.accountsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in contents {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                if values?.isDirectory == true {
                    aliases.insert(url.lastPathComponent)
                }
            }
        }
        return aliases.sorted()
    }

    private static func resolveChatID(alias: String, chatTitle: String) -> String? {
        let url = KtokPaths.rooms(alias: alias)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["records"] as? [[String: Any]]
        else {
            return nil
        }

        let normalizedTitle = ChatTextNormalizer.normalize(chatTitle)
        for record in records {
            let displayName = (record["displayName"] ?? record["display_name"]) as? String
            let normalizedName = (record["normalizedName"] ?? record["normalized_name"]) as? String
            let chatID = (record["chatID"] ?? record["chat_id"]) as? String
            if displayName == chatTitle || normalizedName == normalizedTitle || ChatTextNormalizer.normalize(displayName ?? "") == normalizedTitle {
                return chatID
            }
        }
        return nil
    }

    private static func writeJSONObject(_ object: Any, to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(payloadContainer(object)) else {
            throw KtokWorkspaceError.invalidJSON("object is not JSON-serializable")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writeDataAtomically(data, to: url)
    }

    private static func writeAttachmentMetadata(_ incoming: [String: Any], to url: URL, lastSeenAt: String?) throws {
        var metadata = incoming
        if let existing = try? readJSONObjectDictionary(from: url) {
            metadata = mergeAttachmentMetadata(existing: existing, incoming: incoming)
        }
        if let lastSeenAt {
            metadata["last_seen_at"] = lastSeenAt
        }
        try writeJSONObject(metadata, to: url)
    }

    private static func readJSONObjectDictionary(from url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KtokWorkspaceError.invalidJSON("metadata is not a JSON object")
        }
        return object
    }

    private static func mergeAttachmentMetadata(existing: [String: Any], incoming: [String: Any]) -> [String: Any] {
        let existingRank = attachmentStatusRank(existing["status"] as? String)
        let incomingRank = attachmentStatusRank(incoming["status"] as? String)
        var merged = existing

        if incomingRank >= existingRank {
            for (key, value) in incoming {
                merged[key] = value
            }
        } else {
            let preservedKeys: Set<String> = [
                "created_at",
                "downloaded_file",
                "save_dir",
                "status",
                "target",
                "watched_dirs",
            ]
            for (key, value) in incoming where !preservedKeys.contains(key) {
                merged[key] = value
            }
        }

        if let createdAt = existing["created_at"] {
            merged["created_at"] = createdAt
        }
        return merged
    }

    private static func attachmentStatusRank(_ status: String?) -> Int {
        switch status {
        case "seen":
            return 0
        case "pending_download", "download_not_observed", "failed", "expired":
            return 1
        case "downloaded":
            return 2
        case "extracted":
            return 3
        case "summarized", "unreadable_drm":
            return 4
        default:
            return -1
        }
    }

    private static func appendJSONLine(_ object: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw KtokWorkspaceError.invalidJSON("event is not JSON-serializable")
        }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = directory.appendingPathComponent(".\(url.lastPathComponent).lock")
        let lockFD = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            throw KtokWorkspaceError.writeFailed("could not open lock \(lockURL.path)")
        }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX) == 0 else {
            throw KtokWorkspaceError.writeFailed("could not acquire lock \(lockURL.path)")
        }
        defer { flock(lockFD, LOCK_UN) }

        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        let fd = Darwin.open(url.path, O_CREAT | O_WRONLY | O_APPEND, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw KtokWorkspaceError.writeFailed("could not open \(url.path)")
        }
        defer { Darwin.close(fd) }
        try writeAll(data, to: fd, path: url.path)
    }

    private static func writeAll(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < data.count {
                let written = Darwin.write(fd, base.advanced(by: totalWritten), data.count - totalWritten)
                if written > 0 {
                    totalWritten += written
                    continue
                }
                if written == -1, errno == EINTR {
                    continue
                }
                let message = written == 0 ? "zero-length write" : String(cString: strerror(errno))
                throw KtokWorkspaceError.writeFailed("could not append to \(path): \(message)")
            }
        }
    }

    private static func writeDataAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            try replaceItemAtomically(from: tmp, to: url)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func copyFileAtomically(from source: URL, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = directory.appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: source, to: tmp)
            try replaceItemAtomically(from: tmp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func replaceItemAtomically(from tmp: URL, to destination: URL) throws {
        let result = tmp.path.withCString { tmpPath in
            destination.path.withCString { destinationPath in
                Darwin.rename(tmpPath, destinationPath)
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            throw KtokWorkspaceError.writeFailed("could not rename \(tmp.path) to \(destination.path): \(message)")
        }
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func attachmentPayload(_ attachment: TranscriptAttachment) -> [String: Any] {
        [
            "attachment_id": attachment.attachmentID,
            "chat": attachment.chat,
            "chat_id": attachment.chatID.map { $0 as Any } ?? NSNull(),
            "filename": attachment.filename.map { $0 as Any } ?? NSNull(),
            "candidate_value": attachment.candidateValue,
            "author": attachment.author.map { $0 as Any } ?? NSNull(),
            "time_raw": attachment.timeRaw.map { $0 as Any } ?? NSNull(),
            "row_index": attachment.rowIndex,
            "reason": attachment.reason,
        ]
    }

    private static func attachmentMetadataObject(
        attachment: TranscriptAttachment,
        scope: WorkspaceChatScope,
        status: String,
        downloadedFile: String?,
        saveDir: String?,
        createdAt: String
    ) -> [String: Any] {
        [
            "schema_version": schemaVersion,
            "attachment_id": attachment.attachmentID,
            "account_alias": scope.accountAlias,
            "account_key": scope.accountKey.map { $0 as Any } ?? NSNull(),
            "chat_id": scope.chatID.map { $0 as Any } ?? NSNull(),
            "chat_title": scope.chatTitle.map { $0 as Any } ?? NSNull(),
            "chat_resolved": scope.resolved,
            "filename": attachment.filename.map { $0 as Any } ?? NSNull(),
            "candidate_value": attachment.candidateValue,
            "author": attachment.author.map { $0 as Any } ?? NSNull(),
            "time_raw": attachment.timeRaw.map { $0 as Any } ?? NSNull(),
            "row_index": attachment.rowIndex,
            "reason": attachment.reason,
            "downloaded_file": downloadedFile.map { $0 as Any } ?? NSNull(),
            "save_dir": saveDir.map { $0 as Any } ?? NSNull(),
            "status": status,
            "created_at": createdAt,
        ]
    }

    private static func payloadContainer(_ payload: Any) -> Any {
        if payload is NSNull { return ["value": NSNull()] }
        if payload is [String: Any] || payload is [Any] {
            return payload
        }
        return ["value": payload]
    }

    private static func stableJSONString(_ value: Any) -> String {
        let object = payloadContainer(value)
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func uuidString() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
