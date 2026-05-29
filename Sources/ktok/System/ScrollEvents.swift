import CoreGraphics
import ApplicationServices.HIServices
import Foundation

enum ScrollEvents {
    enum Direction {
        case up
        case down
    }

    /// Scroll inside KakaoTalk's message pane by targeting 70% width / 55% height
    /// of the front window. Mouse is moved first so the scroll event routes to
    /// the window under the pointer (the chat list sidebar would otherwise
    /// swallow it).
    @discardableResult
    static func scrollChatArea(direction: Direction = .up, amount: Int32 = 6) -> Bool {
        guard let bounds = KakaoTalkWindowBounds.frontWindow() else {
            return false
        }
        let cx = bounds.minX + bounds.width * 0.7
        let cy = bounds.minY + bounds.height * 0.55
        let point = CGPoint(x: cx, y: cy)

        MouseEvents.move(to: point)
        Thread.sleep(forTimeInterval: 0.05)

        let delta = direction == .up ? amount : -amount
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else {
            return false
        }
        event.location = point
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    static func scrollElement(_ element: UIElement, direction: Direction = .down, amount: Int32 = 8) -> Bool {
        guard let frame = element.frame else {
            return false
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        MouseEvents.move(to: point)
        Thread.sleep(forTimeInterval: 0.05)

        let delta = direction == .up ? amount : -amount
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 1,
            wheel1: delta,
            wheel2: 0,
            wheel3: 0
        ) else {
            return false
        }
        event.location = point
        event.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    static func setVerticalScrollPosition(_ element: UIElement, value: Double) -> Bool {
        let clamped = min(max(value, 0.0), 1.0)
        let candidates = [element, element.parent].compactMap { $0 }
        for candidate in candidates {
            guard let rawScrollBar: AXUIElement = candidate.attributeOptional(kAXVerticalScrollBarAttribute) else {
                continue
            }
            let scrollBar = UIElement(rawScrollBar)
            do {
                try scrollBar.setAttribute(kAXValueAttribute, value: clamped as CFNumber)
                return true
            } catch {
                continue
            }
        }
        return false
    }
}
