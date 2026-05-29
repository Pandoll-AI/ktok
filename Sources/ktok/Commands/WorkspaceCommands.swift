import ArgumentParser
import Foundation

struct StorageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "Inspect and validate the shared ktok workspace",
        subcommands: [
            StoragePathsCommand.self,
            StorageValidateCommand.self,
        ],
        defaultSubcommand: StoragePathsCommand.self
    )
}

struct StoragePathsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paths",
        abstract: "Print shared workspace paths"
    )

    @Option(name: .long, help: "Account alias. Defaults to current ktok account if known.")
    var account: String?

    @Option(name: .customLong("chat-id"), help: "Optional chat_id scope.")
    var chatID: String?

    @Option(name: .long, help: "Optional chat title to resolve through rooms.json.")
    var chat: String?

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let object = KtokWorkspaceStore.paths(accountAlias: account, chatID: chatID, chatTitle: chat)
        if json {
            KtokWorkspaceStore.printJSON(object)
            return
        }

        print("ktok workspace: \(object["home"] ?? "")")
        for key in ["account_alias", "account_dir", "account_events", "inputs_text", "inputs_files", "rooms_json", "room_dir", "room_events", "room_attachments"] {
            if let value = object[key], !(value is NSNull) {
                print("\(key): \(value)")
            }
        }
    }
}

struct StorageValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Create missing base workspace directories and validate them"
    )

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        let object = KtokWorkspaceStore.validate()
        if json {
            KtokWorkspaceStore.printJSON(object)
            return
        }

        print("ktok workspace: \(object["home"] ?? "")")
        if let checked = object["checked"] as? [[String: Any]] {
            for item in checked {
                let ok = (item["exists"] as? Bool) == true && (item["is_directory"] as? Bool) == true
                print("\(ok ? "ok" : "missing") \(item["path"] ?? "")")
            }
        }
    }
}

struct EventsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "events",
        abstract: "Append shared workspace events",
        subcommands: [
            EventsAppendCommand.self,
        ],
        defaultSubcommand: EventsAppendCommand.self
    )
}

struct EventsAppendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "append",
        abstract: "Append an event JSON payload to the shared workspace"
    )

    @Option(name: .long, help: "Account alias")
    var account: String

    @Option(name: .customLong("chat-id"), help: "Optional chat_id scope.")
    var chatID: String?

    @Option(name: .long, help: "Optional chat title to resolve through rooms.json.")
    var chat: String?

    @Option(name: .customLong("type"), help: "Event type, e.g. message, attachment, input_text, input_file, download.")
    var eventType: String

    @Option(name: .long, help: "Event source name. Defaults to ktok_events.")
    var source: String = "ktok_events"

    @Option(name: .customLong("json-file"), help: "JSON payload path, or '-' for stdin.")
    var jsonFile: String

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        do {
            let payload = try readPayload(jsonFile)
            let scope = KtokWorkspaceStore.resolveScope(accountAlias: account, chatID: chatID, chatTitle: chat)
            let result = try KtokWorkspaceStore.appendEvent(
                accountAlias: scope.accountAlias,
                accountKey: scope.accountKey,
                chatID: scope.chatID,
                chatTitle: scope.chatTitle,
                eventType: eventType,
                source: source,
                payload: payload
            )
            emit(result.jsonObject())
        } catch {
            emitError(error)
            throw ExitCode.failure
        }
    }

    private func readPayload(_ path: String) throws -> Any {
        let data: Data
        if path == "-" {
            data = FileHandle.standardInput.readDataToEndOfFile()
        } else {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            data = try Data(contentsOf: url)
        }
        return try KtokWorkspaceStore.jsonObject(from: data)
    }

    private func emit(_ object: [String: Any]) {
        if json {
            KtokWorkspaceStore.printJSON(object)
            return
        }
        print("event: \(object["id"] ?? "")")
        print("event_path: \(object["event_path"] ?? "")")
    }

    private func emitError(_ error: Error) {
        if json {
            KtokWorkspaceStore.printJSON([
                "ok": false,
                "error": ["code": "WORKSPACE_WRITE_FAILED", "message": String(describing: error)],
            ])
        } else {
            print("[WORKSPACE_WRITE_FAILED] \(error)")
        }
    }
}

struct InputsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inputs",
        abstract: "Save user input text and files into the shared workspace",
        subcommands: [
            InputsSaveTextCommand.self,
            InputsSaveFileCommand.self,
        ]
    )
}

struct InputsSaveTextCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save-text",
        abstract: "Save a user text input into the shared workspace"
    )

    @Option(name: .long, help: "Account alias")
    var account: String

    @Option(name: .customLong("chat-id"), help: "Optional chat_id scope.")
    var chatID: String?

    @Option(name: .long, help: "Optional chat title to resolve through rooms.json.")
    var chat: String?

    @Option(name: .long, help: "Input source name")
    var source: String

    @Option(name: .long, help: "Text to save")
    var text: String

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        do {
            let result = try KtokWorkspaceStore.saveText(
                accountAlias: account,
                chatID: chatID,
                chatTitle: chat,
                source: source,
                text: text
            )
            emit(result.jsonObject())
        } catch {
            emitError(error)
            throw ExitCode.failure
        }
    }

    private func emit(_ object: [String: Any]) {
        if json {
            KtokWorkspaceStore.printJSON(object)
            return
        }
        print("saved input: \(object["path"] ?? "")")
        print("event_path: \(object["event_path"] ?? "")")
    }

    private func emitError(_ error: Error) {
        if json {
            KtokWorkspaceStore.printJSON([
                "ok": false,
                "error": ["code": "WORKSPACE_WRITE_FAILED", "message": String(describing: error)],
            ])
        } else {
            print("[WORKSPACE_WRITE_FAILED] \(error)")
        }
    }
}

struct InputsSaveFileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save-file",
        abstract: "Save a user file input into the shared workspace"
    )

    @Option(name: .long, help: "Account alias")
    var account: String

    @Option(name: .customLong("chat-id"), help: "Optional chat_id scope.")
    var chatID: String?

    @Option(name: .long, help: "Optional chat title to resolve through rooms.json.")
    var chat: String?

    @Option(name: .long, help: "Input source name")
    var source: String

    @Argument(help: "File path to store")
    var file: String

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    func run() throws {
        do {
            let result = try KtokWorkspaceStore.saveFile(
                accountAlias: account,
                chatID: chatID,
                chatTitle: chat,
                source: source,
                filePath: file
            )
            emit(result.jsonObject())
        } catch {
            emitError(error)
            throw ExitCode.failure
        }
    }

    private func emit(_ object: [String: Any]) {
        if json {
            KtokWorkspaceStore.printJSON(object)
            return
        }
        print("saved file: \(object["path"] ?? "")")
        print("metadata: \(object["metadata_path"] ?? "")")
        print("event_path: \(object["event_path"] ?? "")")
    }

    private func emitError(_ error: Error) {
        if json {
            KtokWorkspaceStore.printJSON([
                "ok": false,
                "error": ["code": "WORKSPACE_WRITE_FAILED", "message": String(describing: error)],
            ])
        } else {
            print("[WORKSPACE_WRITE_FAILED] \(error)")
        }
    }
}
