import ArgumentParser
import Foundation

struct ChatsCommand: ParsableCommand {
    private struct ChatsJSONResponse: Codable {
        let count: Int
        let account: ChatAccountSummary
        let updateTrigger: String
        let chats: [ChatListEntry]

        enum CodingKeys: String, CodingKey {
            case count
            case account
            case updateTrigger = "update_trigger"
            case chats
        }
    }

    private struct ChatAccountSummary: Codable {
        let key: String
        let alias: String?
    }

    static let configuration = CommandConfiguration(
        commandName: "chats",
        abstract: "List chat rooms"
    )

    @Flag(name: .shortAndLong, help: "Show detailed information")
    var verbose: Bool = false

    @Option(name: .shortAndLong, help: "Maximum number of chats to show. Omit for a full scroll scan.")
    var limit: Int?

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: [.short, .long], help: "Keep auto-opened chat window after chats")
    var keepWindow: Bool = false

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: traceAX)
        let chatWindowResolver = ChatWindowResolver(kakao: kakao, runner: runner)
        let windowsBefore = kakao.windows

        // Prefer the chat list window ("카카오톡") over any conversation window
        let mainWindow: UIElement
        let autoOpenedWindow: Bool
        if let chatListWindow = kakao.chatListWindow {
            mainWindow = chatListWindow
            autoOpenedWindow = false
            runner.log("chats: using chatListWindow title='\(chatListWindow.title ?? "")'")
        } else if let fallback = kakao.ensureMainWindow(timeout: 5.0, trace: { message in
            runner.log(message)
        }) {
            mainWindow = fallback
            autoOpenedWindow = !windowsBefore.contains(where: { existing in
                CFEqual(existing.axElement, fallback.axElement)
            })
            runner.log("chats: fallback to ensureMainWindow")
        } else {
            print("Could not find a usable KakaoTalk window.")
            throw ExitCode.failure
        }

        defer {
            if autoOpenedWindow && keepWindow {
                runner.log("chats: keep-window enabled; auto-opened window will be kept")
            } else if autoOpenedWindow {
                if chatWindowResolver.closeWindow(mainWindow) {
                    runner.log("chats: auto-opened window closed")
                } else {
                    runner.log("chats: failed to close auto-opened window")
                }
            }
        }

        runner.log("chats: usable window ready")
        if
            let environment = try? LoginEnvironment.load(),
            let detected = AccountProfileDetector(kakao: kakao, runner: runner)
                .detectCurrentProfile(environment: environment, timeoutSec: 1.0, restoreChatsTab: true),
            let credentials = detected.credentials
        {
            try? LoginAccountState.save(credentials: credentials)
            runner.log("chats: verified active account via profile '\(detected.profileName)' as alias '\(credentials.alias)'")
        } else {
            runner.pressCommandNumber(2)
            Thread.sleep(forTimeInterval: 0.25)
        }

        let scanner = ChatListScanner()
        let snapshots: [ChatListSnapshotItem]
        if let limit {
            snapshots = scanner.scan(in: mainWindow, limit: limit, trace: { message in
                runner.log(message)
            })
        } else {
            snapshots = scanner.scanAll(in: mainWindow, trace: { message in
                runner.log(message)
            })
        }

        if snapshots.isEmpty {
            if json {
                try printChatsAsJSON([], account: ChatAccountContext.active())
                return
            }
            print("No chat list found.")
            print("\nTip: Make sure you're on the 'Chats' (채팅) tab in KakaoTalk.")
            print("Use 'ktok inspect' to explore the UI structure.")
            runner.log("chats: no chat items found after traversal")
            return
        }

        let registry = ChatIdentityRegistryStore.shared
        let account = ChatAccountContext.active()
        let assignedIDs = registry.assignChatIDs(
            for: snapshots.map(\.discovery),
            account: account,
            trigger: .manualChatsCommand
        )
        let chats = zip(snapshots, assignedIDs).map { snapshot, chatID in
            ChatListEntry(
                title: snapshot.discovery.title,
                chatID: chatID.isEmpty ? nil : chatID,
                lastMessage: snapshot.discovery.lastMessage
            )
        }
        if json {
            try printChatsAsJSON(chats, account: account)
            return
        }

        print("Searching for chat list in KakaoTalk...\n")
        if let alias = account.alias {
            print("Account: \(alias) (\(account.accountKey))\n")
        } else {
            print("Account: unknown (\(account.accountKey))\n")
        }
        print("Found \(chats.count) chat(s):\n")

        for (index, chat) in chats.enumerated() {
            print("[\(index + 1)] \(chat.title)")
            print("    chat_id: \(chat.chatID ?? "unavailable")")
            if verbose, let msg = chat.lastMessage {
                print("    └─ \(msg)")
            }
        }
    }

    private func printChatsAsJSON(_ chats: [ChatListEntry], account: ChatAccountContext) throws {
        let response = ChatsJSONResponse(
            count: chats.count,
            account: ChatAccountSummary(key: account.accountKey, alias: account.alias),
            updateTrigger: ChatListUpdateTrigger.manualChatsCommand.rawValue,
            chats: chats
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(response)
        if let string = String(data: data, encoding: .utf8) {
            print(string)
        }
    }
}
