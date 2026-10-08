import AppKit
import ApplicationServices.HIServices
import Foundation

/// KakaoTalk 26.x folder chips have no AXPress and reject AXSelected.
/// One command may click "All folder" at most once, and only after a chat-list
/// scan returned no rows. Builds without the folder strip do nothing.
final class ChatroomFolderRecovery {
    private var attempted = false

    func recoverIfEmpty(
        rows: [ChatListSnapshotItem],
        window: UIElement,
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        limit: Int,
        trace: @escaping (String) -> Void
    ) -> [ChatListSnapshotItem] {
        guard rows.isEmpty, !attempted else { return rows }
        guard let list = Self.chatroomFolderList(in: window),
              let chip = Self.allFolderText(in: list) else {
            trace("chats: chatroom folder strip absent")
            return rows
        }

        attempted = true
        guard let point = Self.clickPoint(for: chip) else {
            trace("chats: All folder chip has no frame")
            return rows
        }

        kakao.activate()
        Thread.sleep(forTimeInterval: 0.08)
        let frontmost = runner.waitUntil(
            label: "all-folder frontmost",
            timeout: 0.6,
            pollInterval: 0.06,
            evaluateAfterTimeout: true
        ) {
            guard let front = NSWorkspace.shared.frontmostApplication else { return false }
            let expectedPID = KakaoTalkApp.runningApplication?.processIdentifier
            return front.bundleIdentifier == KakaoTalkApp.bundleIdentifier
                || front.processIdentifier == expectedPID
        }
        guard frontmost else {
            trace("chats: All folder click skipped because KakaoTalk is not frontmost")
            return rows
        }

        trace("chats: clicking All folder chip x=\(Int(point.x)) y=\(Int(point.y))")
        guard runner.clickScreenPoint(point, label: "all-folder chip") else {
            return rows
        }

        let scanner = ChatListScanner()
        var recovered: [ChatListSnapshotItem] = []
        _ = runner.waitUntil(
            label: "all-folder rows",
            timeout: 1.5,
            pollInterval: 0.05,
            evaluateAfterTimeout: true
        ) {
            recovered = scanner.scan(in: window, limit: limit, trace: trace)
            return !recovered.isEmpty
        }
        trace("chats: All folder rescan rows=\(recovered.count)")
        return recovered
    }

    /// Shallow walk. Chat tables and outlines are not entered, so a long row
    /// list does not hide the folder strip or exhaust the node budget.
    private static func chatroomFolderList(in window: UIElement) -> UIElement? {
        var queue = window.children
        var index = 0
        var visited = 0
        while index < queue.count && visited < 240 {
            let current = queue[index]
            index += 1
            visited += 1
            let role = current.role
            if role == kAXTableRole || role == kAXOutlineRole || role == kAXRowRole {
                continue
            }
            if role == kAXListRole {
                let title = current.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                if title == "Chatroom folder" {
                    return current
                }
            }
            if visited < 240 {
                queue.append(contentsOf: current.children)
            }
        }
        return nil
    }

    private static func allFolderText(in list: UIElement) -> UIElement? {
        var queue = list.children
        var index = 0
        var visited = 0
        while index < queue.count && visited < 80 {
            let current = queue[index]
            index += 1
            visited += 1
            if current.role == kAXStaticTextRole {
                let value = current.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let title = current.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "All folder" || title == "All folder" {
                    return current
                }
            }
            if visited < 80 {
                queue.append(contentsOf: current.children)
            }
        }
        return nil
    }

    private static func clickPoint(for text: UIElement) -> CGPoint? {
        if let parent = text.parent,
           parent.role == kAXGroupRole,
           let frame = parent.frame,
           frame.width > 0,
           frame.height > 0 {
            return CGPoint(x: frame.midX, y: frame.midY)
        }
        guard let frame = text.frame, frame.width > 0, frame.height > 0 else {
            return nil
        }
        return CGPoint(x: frame.midX, y: frame.midY)
    }
}
