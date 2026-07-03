import ApplicationServices.HIServices
import Foundation

struct AXActionRunner {
    typealias TraceWriter = (String) -> Void

    private let traceEnabled: Bool
    private let traceWriter: TraceWriter

    init(traceEnabled: Bool) {
        self.traceEnabled = traceEnabled
        self.traceWriter = { message in
            guard let data = "[trace-ax] \(message)\n".data(using: .utf8) else { return }
            FileHandle.standardError.write(data)
        }
    }

    func log(_ message: @autoclosure () -> String) {
        guard traceEnabled else { return }
        traceWriter(message())
    }

    @discardableResult
    func waitUntil(
        label: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.1,
        evaluateAfterTimeout: Bool = true,
        condition: () -> Bool
    ) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if condition() {
                log("\(label): ready")
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        let elapsed = Date().timeIntervalSince(start)
        log("\(label): timeout after \(String(format: "%.2f", elapsed))s")
        return evaluateAfterTimeout ? condition() : false
    }

    @discardableResult
    func focusWithVerification(
        _ element: UIElement,
        label: String,
        attempts: Int = 3,
        retryDelay: TimeInterval = 0.08
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            do {
                try element.focus()
            } catch {
                log("\(label): focus attempt \(attempt) failed (\(error))")
            }

            if element.isFocused || waitUntil(label: "\(label) focused", timeout: 0.25, condition: {
                element.isFocused
            }) {
                log("\(label): focused on attempt \(attempt)")
                return true
            }

            do {
                try element.press()
            } catch {
                log("\(label): press fallback \(attempt) failed (\(error))")
            }

            if element.isFocused || waitUntil(label: "\(label) focused", timeout: 0.25, condition: {
                element.isFocused
            }) {
                log("\(label): focused by press fallback on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): focus verification failed")
        return false
    }

    @discardableResult
    func setTextWithVerification(
        _ text: String,
        on element: UIElement,
        label: String,
        attempts: Int = 2,
        retryDelay: TimeInterval = 0.08
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            do {
                try element.setAttribute(kAXValueAttribute, value: text as CFString)
            } catch {
                log("\(label): set AXValue attempt \(attempt) failed (\(error))")
                Thread.sleep(forTimeInterval: retryDelay)
                continue
            }

            let reflected = waitUntil(label: "\(label) AXValue reflected", timeout: 0.3, condition: {
                isInputReflected(expected: text, current: element.stringValue)
            })
            if reflected {
                log("\(label): set AXValue succeeded on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): set AXValue verification failed")
        return false
    }

    @discardableResult
    func typeTextWithVerification(
        _ text: String,
        on element: UIElement?,
        label: String,
        attempts: Int = 2,
        perCharacterDelay: TimeInterval = 0.01,
        retryDelay: TimeInterval = 0.08,
        reflectionTimeout: TimeInterval = 0.3,
        deliverToPID: pid_t? = nil
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            let before = element?.stringValue
            typeText(text, perCharacterDelay: perCharacterDelay, toPID: deliverToPID)
            guard let element else {
                log("\(label): typed without verification target")
                return true
            }

            let reflected = waitUntil(label: "\(label) typing reflected", timeout: reflectionTimeout, condition: {
                let after = element.stringValue
                return isTypingReflected(before: before, after: after, typed: text)
            })
            if reflected {
                log("\(label): typing reflected on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): typing verification failed")
        return false
    }

    @discardableResult
    /// Presses Enter and verifies the input reflected the send (cleared/changed).
    ///
    /// When `deliverToPID` is non-nil, the key event is delivered directly to
    /// that process via `CGEvent.postToPid` instead of the global HID tap. This
    /// lets a send complete WITHOUT bringing KakaoTalk to the foreground, so the
    /// user's frontmost app is not disturbed. The caller falls back to the
    /// foreground path (global tap) if this returns false.
    func pressEnterWithVerification(
        on element: UIElement?,
        label: String,
        attempts: Int = 2,
        reflectionTimeout: TimeInterval = 0.45,
        retryDelay: TimeInterval = 0.12,
        deliverToPID: pid_t? = nil
    ) -> Bool {
        for attempt in 1...max(attempts, 1) {
            let before = element?.stringValue ?? ""
            pressKey(code: 36, toPID: deliverToPID)

            guard let element else {
                log("\(label): Enter sent without verification target")
                return true
            }

            let reflected = waitUntil(label: "\(label) Enter reflected", timeout: reflectionTimeout, condition: {
                let after = element.stringValue ?? ""
                return didEnterEffect(before: before, after: after)
            })
            if reflected {
                log("\(label): Enter reflected on attempt \(attempt)")
                return true
            }

            Thread.sleep(forTimeInterval: retryDelay)
        }

        log("\(label): Enter verification failed")
        return false
    }

    @discardableResult
    func clickWithRetry(
        _ element: UIElement,
        label: String,
        attempts: Int = 3,
        retryDelay: TimeInterval = 0.2
    ) -> Bool {
        for attempt in 1...attempts {
            do {
                try element.press()
                log("\(label): clicked on attempt \(attempt)")
                return true
            } catch {
                log("\(label): click attempt \(attempt) failed (\(error))")
                Thread.sleep(forTimeInterval: retryDelay)
            }
        }
        return false
    }

    func pressEscape() {
        pressKey(code: 53)
    }

    func pressEnterKey() {
        pressKey(code: 36)
    }

    /// Presses Enter delivered directly to a specific process via
    /// `CGEvent.postToPid`, so it reaches KakaoTalk even when it is not the
    /// frontmost app (background-safe; won't leak keys to another app).
    func pressEnterKey(toPID pid: pid_t) {
        pressKey(code: 36, toPID: pid)
    }

    func pressDownArrowKey() {
        pressKey(code: 125)
    }

    func pressCommandW() {
        pressKey(code: 13, flags: .maskCommand) // W
    }

    func pressCommandF() {
        log("keyboard: pressing Cmd+F")
        pressKey(code: 3, flags: .maskCommand) // F
    }

    func pressCommandA() {
        log("keyboard: pressing Cmd+A")
        pressKey(code: 0, flags: .maskCommand) // A
    }

    @discardableResult
    func clickScreenPoint(_ point: CGPoint, label: String) -> Bool {
        log("\(label): clicking screen point x=\(Int(point.x)) y=\(Int(point.y))")
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let move = CGEvent(
                mouseEventSource: source,
                mouseType: .mouseMoved,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let down = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left
            ),
            let up = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            )
        else {
            log("\(label): failed to create mouse click events")
            return false
        }
        move.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up.post(tap: .cghidEventTap)
        log("\(label): posted mouse move/down/up")
        return true
    }

    func pressCommandNumber(_ number: Int) {
        let keyCodes: [Int: CGKeyCode] = [
            1: 18,
            2: 19,
            3: 20,
            4: 21,
            5: 23,
            6: 22,
            7: 26,
            8: 28,
            9: 25,
        ]
        guard let keyCode = keyCodes[number] else { return }
        pressKey(code: keyCode, flags: .maskCommand)
    }

    func pressPaste() {
        pressKey(code: 9, flags: .maskCommand) // V
    }

    private func typeText(_ text: String, perCharacterDelay: TimeInterval, toPID: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)

        for char in text {
            let unit = String(char)
            if let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                var unicode = Array(unit.utf16)
                down.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
                if let toPID { down.postToPid(toPID) } else { down.post(tap: .cghidEventTap) }
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                var unicode = Array(unit.utf16)
                up.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
                if let toPID { up.postToPid(toPID) } else { up.post(tap: .cghidEventTap) }
            }
            Thread.sleep(forTimeInterval: perCharacterDelay)
        }
    }

    private func pressKey(code: CGKeyCode, flags: CGEventFlags = [], toPID: pid_t? = nil) {
        let source = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
            down.flags = flags
            if let toPID {
                down.postToPid(toPID)
            } else {
                down.post(tap: .cghidEventTap)
            }
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
            up.flags = flags
            if let toPID {
                up.postToPid(toPID)
            } else {
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private func isInputReflected(expected: String, current: String?) -> Bool {
        guard let current else { return false }
        return current == expected || current.contains(expected)
    }

    private func isTypingReflected(before: String?, after: String?, typed: String) -> Bool {
        guard let after else { return false }
        if after == typed || after.contains(typed) {
            return true
        }
        guard let before else { return !after.isEmpty }
        return after != before
    }

    private func didEnterEffect(before: String, after: String) -> Bool {
        let trimmedAfter = after.trimmingCharacters(in: .whitespacesAndNewlines)
        if !before.isEmpty && trimmedAfter.isEmpty {
            return true
        }
        return after != before
    }
}
