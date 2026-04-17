import CoreGraphics
import Foundation

enum MouseEvents {
    /// Move the pointer without clicking. Used before scroll events so macOS
    /// routes the scroll to the window under the cursor (otherwise the chat
    /// list sidebar often swallows the event).
    @discardableResult
    static func move(to point: CGPoint) -> Bool {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            return false
        }
        event.post(tap: .cghidEventTap)
        return true
    }
}
