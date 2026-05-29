import ArgumentParser
import Foundation

struct ReadCommand: ParsableCommand {
    private struct ReadJSONResponse: Encodable {
        let chat: String
        let fetchedAt: String
        let count: Int
        let messages: [TranscriptMessage]
        let attachments: [TranscriptAttachment]

        enum CodingKeys: String, CodingKey {
            case chat
            case fetchedAt = "fetched_at"
            case count
            case messages
            case attachments
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Read messages from a chat",
        discussion: "When author is \"(me)\", the message was sent by you."
    )

    @Argument(help: "Name of the chat to read from (partial match supported)")
    var chat: String

    @Option(name: .shortAndLong, help: "Maximum number of messages to show")
    var limit: Int = 20

    @Flag(name: .long, help: "Show raw element info for debugging")
    var debug: Bool = false

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: [.short, .long], help: "Keep auto-opened chat window after read")
    var keepWindow: Bool = false

    @Flag(
        name: .long,
        help: ArgumentHelp(
            "Enable deep window recovery when fast window detection fails",
            visibility: .default
        )
    )
    var deepRecovery: Bool = false

    @Flag(name: .long, help: "Output in JSON format")
    var json: Bool = false

    @Flag(name: .customLong("record-events"), inversion: .prefixedNo, help: "Record observed messages and attachments to the shared ktok workspace")
    var recordEvents: Bool = true

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let kakao = try KakaoTalkApp()
        let runner = AXActionRunner(traceEnabled: traceAX)
        let chatWindowResolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            deepRecoveryEnabled: deepRecovery
        )
        let transcriptReader = KakaoTalkTranscriptReader(kakao: kakao, runner: runner)

        let resolution: ChatWindowResolution
        do {
            resolution = try chatWindowResolver.resolve(query: chat)
        } catch {
            print("No chat window found for '\(chat)'")
            print("Reason: \(error)")
            print("\nAvailable windows:")
            for (index, window) in kakao.windows.enumerated() {
                print("  [\(index)] \(window.title ?? "(untitled)")")
            }
            throw ExitCode.failure
        }

        let window = resolution.window
        if resolution.openedViaSearch {
            runner.log("read: opening chat via search")
            if keepWindow {
                runner.log("read: keep-window enabled; auto-opened window will be kept")
            } else {
                runner.log("read: auto-opened window will be closed after read")
            }
        } else {
            runner.log("read: found existing chat window")
        }

        defer {
            if resolution.openedViaSearch && !keepWindow {
                let resolvedTitle = window.title ?? ""
                if !resolvedTitle.isEmpty && !resolvedTitle.localizedCaseInsensitiveContains(chat) {
                    runner.log("read: skipped auto-close because resolved title '\(resolvedTitle)' did not match query")
                } else if chatWindowResolver.closeWindow(window) {
                    runner.log("read: auto-opened chat window closed")
                } else {
                    runner.log("read: failed to close auto-opened chat window")
                }
            } else if resolution.openedViaSearch && keepWindow {
                runner.log("read: auto-opened chat window kept by --keep-window")
            }
        }

        let snapshot: TranscriptSnapshot
        do {
            snapshot = try transcriptReader.readSnapshot(
                from: window,
                fallbackChatTitle: chat,
                limit: limit
            )
        } catch TranscriptReadError.transcriptContextUnavailable {
            print("Could not locate chat transcript area.")
            print("Use 'ktok inspect --window <n>' to inspect the opened chat window.")
            return
        } catch TranscriptReadError.noMessageRows {
            print("No message rows found in the chat transcript area.")
            print("Use 'ktok inspect --window <n>' to inspect transcript structure.")
            return
        } catch TranscriptReadError.noReadableMessages {
            print("No message body text extracted from transcript container.")
            print("Use 'ktok inspect --window <n>' to inspect message nodes.")
            return
        }

        if recordEvents {
            KtokWorkspaceStore.recordReadSnapshot(snapshot)
        }

        if json {
            try printMessagesAsJSON(snapshot)
            return
        }

        print("Reading messages from: \(snapshot.chat)\n")
        print("Recent messages (\(snapshot.count)):\n")
        for (index, message) in snapshot.messages.enumerated() {
            if debug {
                print("[\(index + 1)] author=\(message.author ?? "(me)") time=\(message.timeRaw ?? "unknown") body=\(message.body)")
                continue
            }

            print("[\(index + 1)] author: \(message.author ?? "(me)")")
            print("    time: \(message.timeRaw ?? "unknown")")
            print("    body: \(message.body)")
            print("")
        }

        if !snapshot.attachments.isEmpty {
            print("Attachments detected (\(snapshot.attachments.count)):\n")
            for attachment in snapshot.attachments {
                print("- \(attachment.attachmentID) \(attachment.candidateValue)")
                if let author = attachment.author {
                    print("    author: \(author)")
                }
                if let timeRaw = attachment.timeRaw {
                    print("    time: \(timeRaw)")
                }
                if let filename = attachment.filename {
                    print("    filename: \(filename)")
                }
                print("    row_index: \(attachment.rowIndex)")
                print("")
            }
        }
    }

    private func printMessagesAsJSON(_ snapshot: TranscriptSnapshot) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let payload = ReadJSONResponse(
            chat: snapshot.chat,
            fetchedAt: formatter.string(from: snapshot.fetchedAt),
            count: snapshot.count,
            messages: snapshot.messages,
            attachments: snapshot.attachments
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}
