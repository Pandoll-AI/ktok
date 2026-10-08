import AppKit
import ApplicationServices.HIServices
import Foundation

/// KakaoTalk 26.x folder chips have no AXPress and reject AXSelected.
/// Selection is not exposed. A click is posted only after AXRaise on the chat
/// list window, the chip frame is re-read, and the hit element is that chip.
/// A failed raise still continues. A skipped click returns false and leaves
/// the caller's next path unchanged.
final class ChatroomFolderRecovery {
    private var attempted = false

    /// True after this instance has found the strip and started an attempt.
    var hasAttempted: Bool { attempted }

    /// `resolve()` calls this at entry so the next call can click again.
    func resetAttempt() {
        attempted = false
    }

    /// Posts one HID click on All folder. Returns true only when the click was posted.
    /// Waits until the visible row elements change, or 0.6s if they stay the same.
    /// After that wait, restores the app that was frontmost before activate
    /// when it is not KakaoTalk and not already front.
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
              Self.allFolderText(in: list) != nil else {
            trace("folder: chatroom folder strip absent")
            return false
        }

        attempted = true
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
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
            Self.reportClickSkipped("not frontmost")
            return false
        }
        // Raise can unminimize. Refuse that before AXRaise so a minimized list
        // window is not brought up just to click the chip.
        guard Self.minimizedIsFalse(window) else {
            trace("folder: All folder click skipped because AXMinimized is not false")
            Self.reportClickSkipped("minimized")
            return false
        }
        Self.raiseMainWindow(window, trace: trace)

        guard let target = Self.clickTargetAfterActivation(in: window) else {
            trace("folder: All folder chip frame missing after raise")
            Self.reportClickSkipped("chip frame missing")
            return false
        }
        let hit = Self.hitOnAllChip(target.point, chip: target.chip)
        guard hit.matches else {
            trace("folder: All folder click skipped because the point is not the All folder chip")
            Self.reportClickSkipped("hit-test refused \(Self.describeHit(hit.element))")
            return false
        }

        let scanner = ChatListScanner()
        let baseline = scanner.visibleRowElements(in: window, limit: 80)
        let savedCursor = CGEvent(source: nil)?.location
        let posted = runner.clickScreenPoint(target.point, label: "all-folder chip")
        if let savedCursor {
            _ = MouseEvents.move(to: savedCursor)
        }
        guard posted else { return false }
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
        Self.restorePreviousFrontmost(previousFrontmost, trace: trace)
        return true
    }

    /// Send may restore the same app again later. Already-front is a no-op.
    private static func restorePreviousFrontmost(_ app: NSRunningApplication?, trace: (String) -> Void) {
        guard let app, !app.isTerminated else { return }
        let kakaoPID = KakaoTalkApp.runningApplication?.processIdentifier
        if app.bundleIdentifier == KakaoTalkApp.bundleIdentifier || app.processIdentifier == kakaoPID {
            return
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier == app.processIdentifier {
            return
        }
        trace("folder: restoring frontmost app '\(app.bundleIdentifier ?? "?")'")
        app.activate(options: [.activateIgnoringOtherApps])
    }

    /// A chat window can cover the list. Failure still falls through to the frame read.
    private static func raiseMainWindow(_ window: UIElement, trace: (String) -> Void) {
        do {
            let actions = try window.actionNames()
            guard actions.contains(kAXRaiseAction) else {
                trace("folder: AXRaise unavailable, continuing")
                return
            }
            try window.performAction(kAXRaiseAction)
            trace("folder: raised chat list window")
        } catch {
            trace("folder: AXRaise failed (\(error)), continuing")
        }
    }

    private struct AllFolderClickTarget {
        let chip: UIElement
        let point: CGPoint
    }

    /// Frame is read after AXRaise. The pre-raise frame can belong to a covered chip.
    private static func clickTargetAfterActivation(in window: UIElement) -> AllFolderClickTarget? {
        guard let list = chatroomFolderList(in: window),
              let text = allFolderText(in: list) else {
            return nil
        }
        return clickTarget(for: text)
    }

    /// `true` only when the attribute is present and false. A missing value is not a confirmation.
    private static func minimizedIsFalse(_ window: UIElement) -> Bool {
        guard let minimized: Bool = window.attributeOptional(kAXMinimizedAttribute) else {
            return false
        }
        return minimized == false
    }

    private struct ChipHit {
        let matches: Bool
        let element: UIElement?
    }

    /// The hit element itself, or an ancestor within 4 steps, must be the chip
    /// we are about to click. A sibling Unread chip shares the folder list and
    /// must not pass.
    private static func hitOnAllChip(_ point: CGPoint, chip: UIElement) -> ChipHit {
        let system = UIElement(AXUIElementCreateSystemWide())
        guard let hit = try? system.element(at: point) else {
            return ChipHit(matches: false, element: nil)
        }
        if CFEqual(hit.axElement, chip.axElement) {
            return ChipHit(matches: true, element: hit)
        }
        var node = hit.parent
        var steps = 0
        while let current = node, steps < 4 {
            steps += 1
            if CFEqual(current.axElement, chip.axElement) {
                return ChipHit(matches: true, element: hit)
            }
            node = current.parent
        }
        return ChipHit(matches: false, element: hit)
    }

    /// Always stderr, including when `--trace-ax` is off. One line, stdout untouched.
    private static func reportClickSkipped(_ reason: String) {
        let line = "ktok: all-folder click skipped: \(oneLine(reason))\n"
        guard let data = line.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }

    /// AXTitle when set. Folder chips often keep the label in AXValue instead.
    private static func describeHit(_ element: UIElement?) -> String {
        guard let element else { return "role=? title=?" }
        return "role=\(oneLine(element.role ?? "?")) title=\(oneLine(hitLabel(element)))"
    }

    private static func hitLabel(_ element: UIElement) -> String {
        if let title = element.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let value = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return "?"
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
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

    /// The click target is the parent AXGroup when that group has a frame.
    /// Otherwise it is the AXStaticText "All folder".
    private static func clickTarget(for text: UIElement) -> AllFolderClickTarget? {
        if let parent = text.parent,
           parent.role == kAXGroupRole,
           let frame = parent.frame,
           frame.width > 0,
           frame.height > 0 {
            return AllFolderClickTarget(chip: parent, point: CGPoint(x: frame.midX, y: frame.midY))
        }
        guard let frame = text.frame, frame.width > 0, frame.height > 0 else {
            return nil
        }
        return AllFolderClickTarget(chip: text, point: CGPoint(x: frame.midX, y: frame.midY))
    }
}
