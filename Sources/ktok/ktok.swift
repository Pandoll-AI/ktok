import ArgumentParser
import Foundation

@main
struct Ktok: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ktok",
        abstract: "A CLI tool for KakaoTalk on macOS",
        discussion: """
            ktok uses macOS Accessibility APIs to interact with KakaoTalk.

            Before using ktok, make sure:
            1. KakaoTalk is installed and running
            2. Accessibility permission is granted (System Settings > Privacy & Security > Accessibility)

            Run 'ktok status' to check if everything is set up correctly.

            Examples:
              ktok status
              ktok chats --json
              ktok send "채팅방" "메시지"
              ktok send-image "채팅방" "/path/to/image.png"
              ktok login work
              ktok assume work
              ktok whoami
              ktok storage paths --json
              ktok inputs save-text --account work --source cli --text "hello" --json
              ktok watch "채팅방"
              ktok watch "채팅방" --json
              ktok mcp-server

            Tip:
              ktok -v
            """,
        version: BuildVersion.current,
        subcommands: [
            StatusCommand.self,
            InspectCommand.self,
            ChatsCommand.self,
            SendCommand.self,
            SendImageCommand.self,
            SendFileCommand.self,
            DownloadFileCommand.self,
            ReadCommand.self,
            WatchCommand.self,
            StorageCommand.self,
            EventsCommand.self,
            InputsCommand.self,
            CacheCommand.self,
            ImportHistoryCommand.self,
            HistoryCommand.self,
            SyncHistoryCommand.self,
            DumpChatUICommand.self,
            LoginCommand.self,
            LogoutCommand.self,
            AssumeCommand.self,
            WhoamiCommand.self,
            MCPServerCommand.self,
        ],
        defaultSubcommand: StatusCommand.self
    )

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.count == 1, arguments[0] == "-v" {
            print(BuildVersion.current)
            return
        }
        self.main(arguments)
    }
}
