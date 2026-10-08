import AppKit
import ApplicationServices

/// Current frontmost application, correct in a CLI process.
///
/// `NSWorkspace.shared.frontmostApplication` is updated through run-loop
/// notifications. ktok never spins the main run loop while it sleeps in
/// `waitUntil`, so that property stays frozen at whatever app was in front when
/// the process started. Measured on KakaoTalk 26.4 / macOS 26: KakaoTalk became
/// frontmost 0.05s after `activate()`, yet the property kept reporting Finder for
/// the full 3s polling window.
///
/// The Accessibility focused application is read live from the window server, so
/// it is preferred. If that read fails (no AX trust, no focused app), the main run
/// loop is drained once so the workspace property is refreshed before use.
enum FrontmostApp {
    static func current() -> NSRunningApplication? {
        var value: AnyObject?
        let systemWide = AXUIElementCreateSystemWide()
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &value) == .success,
           let value,
           CFGetTypeID(value) == AXUIElementGetTypeID()
        {
            var pid: pid_t = 0
            // swiftlint:disable:next force_cast
            if AXUIElementGetPid(value as! AXUIElement, &pid) == .success,
               let app = NSRunningApplication(processIdentifier: pid)
            {
                return app
            }
        }
        RunLoop.current.run(until: Date())
        return NSWorkspace.shared.frontmostApplication
    }
}
