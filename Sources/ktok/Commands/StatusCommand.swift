import ArgumentParser
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check KakaoTalk and accessibility status"
    )

    @Flag(name: .long, help: "Show detailed information")
    var verbose: Bool = false

    func run() throws {
        KtokPaths.migrateLegacyStorageIfNeeded()
        print("ktok - KakaoTalk CLI Tool\n")

        // Check accessibility permission
        let hasPermission = AccessibilityPermission.ensureGranted()
        print("Accessibility Permission: \(hasPermission ? "✓ Granted" : "✗ Not Granted")")

        if !hasPermission {
            print("")
            AccessibilityPermission.printInstructions()
            return
        }

        // Check KakaoTalk status - launch if not running
        var isRunning = KakaoTalkApp.isRunning
        if !isRunning {
            print("KakaoTalk: Not running, launching...")
            if KakaoTalkApp.launch() != nil {
                isRunning = true
                print("KakaoTalk: ✓ Launched")
            } else {
                print("KakaoTalk: ✗ Failed to launch")
                return
            }
        } else {
            print("KakaoTalk: ✓ Running")
        }

        // Get detailed info if verbose
        if verbose {
            print("")
            do {
                let kakao = try KakaoTalkApp()
                let windows = kakao.windows

                print("Windows (\(windows.count)):")
                for (index, window) in windows.enumerated() {
                    let title = window.title ?? "(untitled)"
                    let frame = window.frame.map { "(\(Int($0.origin.x)), \(Int($0.origin.y))) \(Int($0.size.width))x\(Int($0.size.height))" } ?? "unknown"
                    print("  [\(index)] \(title) - \(frame)")
                }
            } catch {
                print("Error accessing KakaoTalk: \(error)")
            }
        }

        print("")
        print("Storage:")
        print("  root: \(KtokPaths.home.path)")
        print("  current_account: \(KtokPaths.currentAccountState.path)")
        print("  ax_cache: \(KtokPaths.axCache.path)")
        if let alias = KtokPaths.activeAccountAlias() {
            print("  active_alias: \(alias)")
            print("  account_dir: \(KtokPaths.accountDir(alias: alias).path)")
            print("  rooms: \(KtokPaths.rooms(alias: alias).path)")
            print("  db: \(KtokPaths.defaultDB(alias: alias))")
            print("  downloads: \(KtokPaths.defaultDownloads(alias: alias))")
            print("  exports: \(KtokPaths.defaultExports(alias: alias))")
        } else {
            print("  active_alias: unknown")
        }
        if FileManager.default.fileExists(atPath: KtokPaths.legacyAccountState.path)
            || FileManager.default.fileExists(atPath: KtokPaths.legacyDatabase.path)
            || FileManager.default.fileExists(atPath: KtokPaths.legacyChatRegistry.path)
            || FileManager.default.fileExists(atPath: KtokPaths.legacyAXCache.path) {
            print("  legacy: present, copied forward when matching new files were absent")
        }

        print("\n✓ Ready to use ktok commands\n")
        printUsage()
    }

    private func printUsage() {
        print("""
        USAGE: ktok <command> [options]

        COMMANDS:
          status    Check KakaoTalk and accessibility status
          chats     List chat rooms
          read      Read messages from a chat room
          send      Send a message to a chat room
          send-image Send an image to a chat
          login     Log in using an alias from .env
          logout    Log out of KakaoTalk
          whoami    Show the current ktok login alias
          storage   Inspect shared ~/.ktok workspace paths
          events    Append shared workspace events
          inputs    Save user text/files into shared workspace
          cache     Manage AX path cache
          inspect   Inspect KakaoTalk UI hierarchy (debug)
          mcp-server Run the stdio MCP server for integrations

        OPTIONS:
          --help    Show help for any command
          -v, --version Show version

        EXAMPLES:
          ktok -v                         Show version
          ktok chats                      List all chat rooms
          ktok chats --json               List chat rooms with chat_id in JSON
          ktok read "친구이름"             Read messages from chat
          ktok send "친구이름" "안녕!"      Send a message
          ktok send-image "친구이름" "/tmp/a.png" Send an image
          ktok login work                 Log in using KTOK_LOGIN_WORK_* from .env
          ktok whoami                     Show current login alias
          ktok storage paths --json       Show shared workspace paths
          ktok inputs save-text --account work --source cli --text "hello" --json
          ktok send --chat-id "<id>" "안녕!" Send a message by chat_id
          ktok mcp-server                 Run local MCP server
        """)
    }
}
