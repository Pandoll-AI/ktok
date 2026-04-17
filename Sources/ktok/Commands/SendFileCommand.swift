import AppKit
import ArgumentParser
import Foundation

struct SendFileCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send-file",
        abstract: "Send a file attachment to a chat"
    )

    @Argument(help: "Name of the chat or friend to send to")
    var recipient: String

    @Argument(help: "Path to the file to send")
    var filePath: String

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Disable AX path cache for this run")
    var noCache: Bool = false

    @Flag(name: [.short, .long], help: "Keep chat and list windows open after sending")
    var keepWindow: Bool = false

    @Flag(name: .long, help: "Enable deep window recovery when fast window detection fails")
    var deepRecovery: Bool = false

    @Flag(name: .long, help: "Block execution and return CONFIRMATION_REQUIRED (for MCP confirm flow)")
    var confirm: Bool = false

    func run() throws {
        if confirm {
            print("[CONFIRMATION_REQUIRED] ktok send-file blocked because --confirm is set.")
            throw ExitCode.failure
        }

        let expanded = (filePath as NSString).expandingTildeInPath
        let absolutePath = URL(fileURLWithPath: expanded).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: absolutePath) else {
            print("Error: File not found at \(absolutePath)")
            throw ExitCode.failure
        }

        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let fileURL = URL(fileURLWithPath: absolutePath)

        let kakao = try KakaoTalkApp()
        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            useCache: !noCache,
            deepRecoveryEnabled: deepRecovery
        )

        do {
            print("Looking for chat with '\(recipient)'...")
            let resolution = try chatWindowResolver.resolve(query: recipient)

            try sendFileToWindow(fileURL, window: resolution.window, kakao: kakao, runner: runner)
            closeWindowsIfNeeded(
                resolution: resolution,
                kakao: kakao,
                resolver: chatWindowResolver,
                runner: runner
            )
        } catch {
            print("Failed to send file: \(error)")
            throw ExitCode.failure
        }
    }

    private func sendFileToWindow(_ fileURL: URL, window: UIElement, kakao: KakaoTalkApp, runner: AXActionRunner) throws {
        PasteboardWriter.writeFile(fileURL)
        runner.log("File copied to clipboard: \(fileURL.path)")

        kakao.activate()
        try? window.focus()
        Thread.sleep(forTimeInterval: 0.5)

        runner.pressPaste()
        runner.log("send-file: Cmd+V posted")

        // KakaoTalk shows a brief preview sheet for files — wait before pressing Return.
        Thread.sleep(forTimeInterval: 2.0)

        runner.pressEnterKey()
        runner.log("send-file: Return posted")

        print("✓ File sent to '\(recipient)': \(fileURL.lastPathComponent)")
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func closeWindowsIfNeeded(
        resolution: ChatWindowResolution,
        kakao: KakaoTalkApp,
        resolver: ChatWindowResolver,
        runner: AXActionRunner
    ) {
        guard !keepWindow else {
            runner.log("send-file: keep-window enabled; skipping auto-close")
            return
        }

        if resolver.closeWindow(resolution.window) {
            print("✓ Chat window closed.")
        } else {
            runner.log("send-file: close window could not be verified")
        }

        if let listWindow = kakao.chatListWindow,
           !areSameAXElement(listWindow, resolution.window)
        {
            if resolver.closeWindow(listWindow) {
                runner.log("send-file: chat list window closed")
            } else {
                runner.log("send-file: chat list window could not be verified")
            }
        }
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
}
