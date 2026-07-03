import AppKit
import Foundation

/// Shared focus-free message delivery.
///
/// Types the message and Enter straight to KakaoTalk's process via
/// `CGEvent.postToPid`, so the app is never brought to the foreground and the
/// user's active window is untouched. Both steps are verified against the
/// resolved input element (typed text reflected, then input cleared on Enter),
/// which also guards recipient safety: if the wrong field had focus our element
/// would not clear and the send is reported as failed.
///
/// Background AXValue *writes* are ignored by KakaoTalk, so key events are used;
/// background AX *reads* work but are slower than the 0.25s messaging cap, hence
/// the generous verification timeouts.
enum MessageSender {
    /// Focus-free send into an already-resolved input element. Does NOT activate
    /// the app. Returns true only when the send is verified.
    @discardableResult
    static func sendFocusFree(
        message: String,
        input: UIElement,
        pid: pid_t,
        runner: AXActionRunner,
        label: String = "focus-free send"
    ) -> Bool {
        guard runner.focusWithVerification(input, label: label, attempts: 1) else { return false }
        guard runner.typeTextWithVerification(
            message,
            on: input,
            label: label,
            attempts: 2,
            reflectionTimeout: 1.0,
            deliverToPID: pid
        ) else { return false }
        return runner.pressEnterWithVerification(
            on: input,
            label: label,
            attempts: 2,
            reflectionTimeout: 1.0,
            retryDelay: 0.1,
            deliverToPID: pid
        )
    }

    /// Foreground fallback: bring KakaoTalk forward, fill + Enter via the global
    /// HID tap, then restore the previously-frontmost app. Use only when the
    /// focus-free path could not be verified.
    @discardableResult
    static func sendForeground(
        message: String,
        input: UIElement,
        window: UIElement,
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        label: String = "foreground send"
    ) -> Bool {
        let previousFrontmost = NSWorkspace.shared.frontmostApplication
        defer { restoreFrontmostApp(previousFrontmost, runner: runner) }

        kakao.activate()
        if let actions = try? window.actionNames(), actions.contains(kAXRaiseAction) {
            try? window.performAction(kAXRaiseAction)
        }
        Thread.sleep(forTimeInterval: 0.1)

        guard runner.focusWithVerification(input, label: label, attempts: 1) else { return false }
        let filled =
            runner.setTextWithVerification(message, on: input, label: label, attempts: 1) ||
            runner.typeTextWithVerification(message, on: input, label: label, attempts: 2)
        guard filled else { return false }
        var sent = runner.pressEnterWithVerification(on: input, label: label, attempts: 1, reflectionTimeout: 0.34, retryDelay: 0.06)
        if !sent {
            _ = runner.focusWithVerification(input, label: "\(label) retry", attempts: 1)
            sent = runner.pressEnterWithVerification(on: input, label: "\(label) retry", attempts: 1, reflectionTimeout: 0.34, retryDelay: 0.06)
        }
        return sent
    }

    /// Reactivate the app that was frontmost before a foreground send. No-op if
    /// the user already moved to another app or that app is KakaoTalk itself.
    static func restoreFrontmostApp(_ app: NSRunningApplication?, runner: AXActionRunner) {
        guard let app,
              app.bundleIdentifier != KakaoTalkApp.bundleIdentifier,
              !app.isTerminated
        else { return }
        if let current = NSWorkspace.shared.frontmostApplication,
           current.bundleIdentifier != KakaoTalkApp.bundleIdentifier {
            return
        }
        runner.log("send: restoring foreground app '\(app.bundleIdentifier ?? "?")'")
        app.activate(options: [.activateIgnoringOtherApps])
        _ = runner.waitUntil(label: "restore frontmost", timeout: 0.25, pollInterval: 0.05) {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == app.bundleIdentifier
        }
    }
}
