import AppKit
import ApplicationServices

/// Current frontmost application, read live from the window server.
///
/// `NSWorkspace.shared.frontmostApplication` is updated through run-loop
/// notifications. ktok never spins the main run loop while it sleeps in
/// `waitUntil`, so that property stays frozen at whatever app was in front when
/// the process started. Measured on KakaoTalk 26.4 / macOS 26: KakaoTalk became
/// frontmost 0.05s after `activate()`, yet the property kept reporting Finder for
/// the full 3s polling window.
///
/// The Accessibility focused application is the app that receives HID key
/// events, so it is the right gate for global key/click posting. When it cannot
/// be read this returns `nil` (fail closed): callers treat `nil` as "not
/// KakaoTalk" and skip global input. Falling back to the frozen workspace value
/// could report KakaoTalk while the user is in another app.
enum FrontmostApp {
    static func current() -> NSRunningApplication? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedApplicationAttribute as CFString,
            &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return NSRunningApplication(processIdentifier: pid)
    }
}
