import AppKit
import ApplicationServices.HIServices
import Foundation

/// KakaoTalk 26.x folder chips have no AXPress and reject AXSelected.
/// Selection is not exposed, so each command clicks "All folder" at most once
/// when the strip exists. Builds without the strip do nothing.
final class ChatroomFolderRecovery {
    private var attempted = false

    /// Posts one HID click on All folder. Returns true only when the click was posted.
    /// Waits until the visible row elements change, or 0.6s if they stay the same.
    @discardableResult
    func ensureAllFolder(
        in window: UIElement,
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        reason: String,
        trace: @escaping (String) -> Void
    ) -> Bool {
        guard !attempted else { return false }
        guard let list = Self.chatroomFolderList(in: window),
              let chip = Self.allFolderText(in: list) else {
            trace("folder: chatroom folder strip absent")
            return false
        }

        attempted = true
        guard let point = Self.clickPoint(for: chip) else {
            trace("folder: All folder chip has no frame")
            return false
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
            trace("folder: All folder click skipped because KakaoTalk is not frontmost")
            return false
        }

        let scanner = ChatListScanner()
        let baseline = scanner.visibleRowElements(in: window, limit: 80)
        guard runner.clickScreenPoint(point, label: "all-folder chip") else {
            return false
        }
        trace("folder: ensured All folder (reason=\(reason))")
        _ = runner.waitUntil(
            label: "all-folder rows",
            timeout: 0.6,
            pollInterval: 0.05,
            evaluateAfterTimeout: false
        ) {
            let now = scanner.visibleRowElements(in: window, limit: 80)
            return !Self.sameRowElements(baseline, now)
        }
        return true
    }

    private static func sameRowElements(_ previous: [UIElement], _ rows: [UIElement]) -> Bool {
        guard previous.count == rows.count else { return false }
        for (lhs, rhs) in zip(previous, rows) {
            if !CFEqual(lhs.axElement, rhs.axElement) {
                return false
            }
        }
        return true
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
