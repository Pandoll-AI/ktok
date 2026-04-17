import ApplicationServices.HIServices
import AppKit
import Foundation

/// Handles macOS Accessibility permission checking and requesting
public enum AccessibilityPermission {
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    /// Check if the app has accessibility permissions
    public static func isGranted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompt user to grant accessibility permissions if not already granted
    /// Returns true if permissions are already granted
    @discardableResult
    public static func requestIfNeeded() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Ensure accessibility permission by triggering the system prompt and opening settings if needed.
    /// Note: macOS does not allow fully automatic granting; user confirmation in System Settings is required.
    @discardableResult
    public static func ensureGranted(
        autoPrompt: Bool = true,
        openSettingsOnFailure: Bool = true,
        waitAfterPrompt: TimeInterval = 1.0
    ) -> Bool {
        if isGranted() {
            return true
        }

        if autoPrompt {
            _ = requestIfNeeded()
            if waitUntilGranted(timeout: waitAfterPrompt) {
                return true
            }
        }

        if openSettingsOnFailure {
            openAccessibilitySettings()
        }

        return isGranted()
    }

    /// Open the Accessibility pane in System Settings.
    public static func openAccessibilitySettings() {
        guard let settingsURL else { return }
        _ = NSWorkspace.shared.open(settingsURL)
    }

    /// Print instructions for granting accessibility permissions
    public static func printInstructions() {
        print("""
        ⚠️  Accessibility permission required!

        ktok requested permission automatically, but macOS still requires manual approval.

        To use ktok, you need to grant Accessibility permissions:

        1. Open System Settings > Privacy & Security > Accessibility
        2. Click the '+' button
        3. Navigate to and select the ktok binary
        4. Enable the toggle for ktok
        """)
    }

    private static func waitUntilGranted(timeout: TimeInterval, pollInterval: TimeInterval = 0.1) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if isGranted() {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return isGranted()
    }
}
