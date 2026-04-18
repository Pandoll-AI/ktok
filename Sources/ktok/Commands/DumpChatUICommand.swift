import ApplicationServices.HIServices
import ArgumentParser
import Foundation

struct DumpChatUICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-chat-ui",
        abstract: "Read-only AX dump of a chat window (no presses, no side effects)",
        discussion: """
            Opens a chat window and enumerates every button (plus, optionally,
            cells / menu items / static text) with its index, AX identifier,
            role, title, description, value, and frame.

            Zero presses are performed — this command exists to identify the
            correct AX path for new features (like sync-history's hamburger)
            without any risk of triggering a phone call, share, or other
            side-effect button.

            Examples:
              ktok dump-chat-ui "채팅방"
              ktok dump-chat-ui "채팅방" --json
              ktok dump-chat-ui "채팅방" --include-cells --include-static-texts
            """
    )

    @Argument(help: "Name of the chat to inspect")
    var chatName: String

    @Flag(name: .long, help: "Include AXCell elements (useful for settings-panel debug)")
    var includeCells: Bool = false

    @Flag(name: .long, help: "Include AXStaticText elements")
    var includeStaticTexts: Bool = false

    @Flag(name: .long, help: "Include AXMenuItem elements (app-wide, for popovers)")
    var includeMenuItems: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of human table")
    var json: Bool = false

    @Flag(name: .long, help: "Press the hamburger (desc='Menu') ONCE, wait, then dump — shows what popover/panel appears. Safe: only the exact-label-match Menu button is pressed, blocklist excludes call/video/share.")
    var pressHamburgerThenDump: Bool = false

    @Flag(name: .long, help: "Full path: press hamburger → press 'Chatroom Settings' in popover → dump the resulting settings window (buttons, cells, rows, static texts).")
    var openSettingsThenDump: Bool = false

    @Flag(name: .long, help: "After opening settings, press each sidebar tab (buttons with AXPress, no visible label) one by one and dump what static texts appear. Helps identify the 'Manage Chats' tab.")
    var probeSettingsTabs: Bool = false

    @Flag(name: .long, help: "Show AX traversal tracing")
    var traceAX: Bool = false

    @Flag(name: [.short, .long], help: "Keep chat window open after dump")
    var keepWindow: Bool = true  // default ON — closing would strip context

    @Flag(name: .long, help: "Enable deep window recovery")
    var deepRecovery: Bool = false

    func validate() throws {
        if chatName.isEmpty {
            throw ValidationError("Chat name is required.")
        }
    }

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        let runner = AXActionRunner(traceEnabled: traceAX)
        let kakao: KakaoTalkApp
        do {
            kakao = try KakaoTalkApp()
        } catch {
            print("Failed to attach to KakaoTalk: \(error)")
            throw ExitCode.failure
        }

        let resolver = ChatWindowResolver(
            kakao: kakao,
            runner: runner,
            useCache: true,
            deepRecoveryEnabled: deepRecovery
        )

        let resolution: ChatWindowResolution
        do {
            resolution = try resolver.resolve(query: chatName)
        } catch {
            print("Could not open chat '\(chatName)': \(error)")
            throw ExitCode.failure
        }

        defer {
            if !keepWindow {
                _ = resolver.closeWindow(resolution.window)
            }
        }

        let chatWindow = resolution.window
        kakao.activate()
        Thread.sleep(forTimeInterval: 0.4)

        // Optional: press the hamburger and dump AFTER the popover appears.
        // Uses the SAME strict selector as ChatSettingsNavigator (exact label
        // match on "Menu" / "메뉴", dangerous-button blocklist applied).
        var hamburgerPressLog: [String] = []
        var settingsWindow: UIElement?
        if pressHamburgerThenDump || openSettingsThenDump {
            let navigator = ChatSettingsNavigator(kakao: kakao, runner: runner)
            let (pressed, logLines) = navigator.diagnosticPressHamburger(in: chatWindow)
            hamburgerPressLog = logLines
            if !pressed {
                print("⚠️  Hamburger press did not succeed — see trace/log for reason.")
            }
            Thread.sleep(forTimeInterval: 1.2)

            if openSettingsThenDump {
                // Click "Chatroom Settings" menu item to open the settings window.
                let menuItems = kakao.applicationElement.findAll(role: kAXMenuItemRole, limit: 60, maxNodes: 400)
                let settingsItem = menuItems.first { item in
                    let t = (item.title ?? "").trimmingCharacters(in: .whitespaces).lowercased()
                    return t == "chatroom settings" || t == "채팅방 설정"
                }
                if let settingsItem {
                    do {
                        try settingsItem.press()
                        hamburgerPressLog.append("chatroom settings: pressed '\(settingsItem.title ?? "")'")
                        Thread.sleep(forTimeInterval: 1.5)
                        // Find the new window that appeared.
                        settingsWindow = kakao.windows.first { !areSame($0, chatWindow) }
                        if let settingsWindow {
                            hamburgerPressLog.append("settings window: title='\(settingsWindow.title ?? "")' frame=\(frameStr(settingsWindow.frame))")
                        } else {
                            hamburgerPressLog.append("settings window: no new window detected")
                        }
                    } catch {
                        hamburgerPressLog.append("chatroom settings press failed: \(error)")
                    }
                } else {
                    hamburgerPressLog.append("chatroom settings menu item not found")
                }
            }
        }

        // The dump target: either the settings window (if we opened it) or the chat window.
        let dumpRoot = settingsWindow ?? chatWindow
        let dumpRootLabel = settingsWindow != nil ? "settings-window" : "chat-window"

        // --probe-settings-tabs: press each pressable button in the settings
        // window (except known Edit/Select kinds), dump the resulting static
        // text labels, then press the next one. Outputs one section per tab.
        var probeOutput: [(label: String, textLabels: [String])] = []
        if probeSettingsTabs, let settingsWindow {
            let pressableButtons = settingsWindow.findAll(role: kAXButtonRole, limit: 40, maxNodes: 300).filter { btn in
                let actions = (try? btn.actionNames()) ?? []
                guard actions.contains("AXPress") else { return false }
                // Skip generic action buttons (Edit/Select/etc) and the close X.
                let title = (btn.title ?? "").trimmingCharacters(in: .whitespaces)
                let desc = (btn.axDescription ?? "").trimmingCharacters(in: .whitespaces)
                let skip = ["Edit", "Select", "Select Sound", "Save", "Save As", "Share", "Done", "Cancel"]
                return !skip.contains(title) && !desc.contains("Close")
            }
            // Exclude the traffic-light close button (tiny 16x16 top-left).
            // We identify it by its small size *in a pre-probe frame check*,
            // since post-press AX refs can get invalidated. This is a
            // one-off diagnostic — coordinate check is acceptable here.
            for (idx, tab) in pressableButtons.enumerated() {
                let frameStr = tab.frame.map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
                let desc = "button[\(idx)] id='\(tab.identifier ?? "")' title='\(tab.title ?? "")' desc='\(tab.axDescription ?? "")' size=\(frameStr)"
                // Skip suspiciously small buttons (likely close/traffic-light).
                if let f = tab.frame, f.width < 24 && f.height < 24 {
                    probeOutput.append((desc + " SKIPPED_too_small", []))
                    continue
                }
                do {
                    try tab.press()
                } catch {
                    probeOutput.append((desc + " PRESS_FAILED:\(error)", []))
                    continue
                }
                Thread.sleep(forTimeInterval: 0.4)
                let texts = settingsWindow.findAll(role: kAXStaticTextRole, limit: 60, maxNodes: 500).compactMap { t -> String? in
                    let v = (t.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                    return v.isEmpty ? nil : v
                }
                // Also dump pressable elements in the content area AFTER this
                // tab activation (what the user would see / interact with).
                let pressables = settingsWindow.findAll(
                    where: { el in
                        let r = el.role ?? ""
                        guard [kAXButtonRole, kAXCellRole, kAXRowRole, kAXStaticTextRole].contains(r) else { return false }
                        return (try? el.actionNames())?.contains("AXPress") == true
                    },
                    limit: 40, maxNodes: 400
                )
                let pressableLines = pressables.map { el -> String in
                    let r = el.role ?? "?"
                    let t = (el.title ?? "").trimmingCharacters(in: .whitespaces)
                    let v = (el.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                    let d = (el.axDescription ?? "").trimmingCharacters(in: .whitespaces)
                    let id = el.identifier ?? ""
                    return "[\(r)] id='\(id)' t='\(t)' v='\(v.prefix(40))' d='\(d)'"
                }
                let allLabels = texts + ["---PRESSABLE---"] + pressableLines
                probeOutput.append((desc, allLabels))
            }
        }

        let buttons = dumpRoot.findAll(role: kAXButtonRole, limit: 200, maxNodes: 2_000)
        // For settings-window dumps, enable cells/static-texts automatically —
        // manage-chats style navigation commonly uses those roles.
        let autoIncludeCells = includeCells || openSettingsThenDump
        let autoIncludeStaticTexts = includeStaticTexts || openSettingsThenDump
        let cells = autoIncludeCells ? dumpRoot.findAll(role: kAXCellRole, limit: 200, maxNodes: 2_000) : []
        let staticTexts = autoIncludeStaticTexts ? dumpRoot.findAll(role: kAXStaticTextRole, limit: 200, maxNodes: 2_000) : []
        let rows = openSettingsThenDump ? dumpRoot.findAll(role: kAXRowRole, limit: 200, maxNodes: 2_000) : []
        let menuItems = includeMenuItems ? kakao.applicationElement.findAll(role: kAXMenuItemRole, limit: 200, maxNodes: 2_000) : []

        let windowFrame = chatWindow.frame

        // If we pressed hamburger, also scan additional surfaces that might
        // host the post-press popover or menu.
        let postPressAppMenuItems = pressHamburgerThenDump
            ? kakao.applicationElement.findAll(role: kAXMenuItemRole, limit: 100, maxNodes: 800)
            : []
        let postPressNewWindows = pressHamburgerThenDump
            ? kakao.windows.filter { !areSame($0, chatWindow) }
            : []

        if json {
            var result: [String: Any] = [
                "ok": true,
                "chat_window": [
                    "title": chatWindow.title as Any,
                    "frame": frameDict(windowFrame),
                ],
                "buttons": buttons.enumerated().map { describeJSON(index: $0.offset, element: $0.element, windowFrame: windowFrame) },
                "cells": cells.enumerated().map { describeJSON(index: $0.offset, element: $0.element, windowFrame: windowFrame) },
                "static_texts": staticTexts.enumerated().map { describeJSON(index: $0.offset, element: $0.element, windowFrame: windowFrame) },
                "menu_items": menuItems.enumerated().map { describeJSON(index: $0.offset, element: $0.element, windowFrame: windowFrame) },
            ]
            if pressHamburgerThenDump {
                result["hamburger_press_log"] = hamburgerPressLog
                result["post_press_app_menu_items"] = postPressAppMenuItems.enumerated().map {
                    describeJSON(index: $0.offset, element: $0.element, windowFrame: nil)
                }
                result["post_press_new_windows"] = postPressNewWindows.map { w in
                    [
                        "title": w.title as Any,
                        "frame": frameDict(w.frame),
                        "button_count": w.findAll(role: kAXButtonRole, limit: 80, maxNodes: 400).count,
                    ] as [String: Any]
                }
            }
            printJSON(result)
        } else {
            let rootTitle = dumpRoot.title ?? chatName
            print("Dump root: \(dumpRootLabel) '\(rootTitle)' frame=\(frameStr(dumpRoot.frame))")
            print("")
            print("=== BUTTONS (\(buttons.count)) ===")
            print("idx  id           desc                       title             frame                actions")
            for (i, b) in buttons.enumerated() {
                print(describeHuman(index: i, element: b))
            }
            if !cells.isEmpty {
                print("")
                print("=== CELLS (\(cells.count)) ===")
                for (i, c) in cells.enumerated() {
                    print(describeHuman(index: i, element: c))
                }
            }
            if !staticTexts.isEmpty {
                print("")
                print("=== STATIC TEXT (\(staticTexts.count), first 60) ===")
                for (i, t) in staticTexts.prefix(60).enumerated() {
                    print(describeHuman(index: i, element: t))
                }
            }
            if !rows.isEmpty {
                print("")
                print("=== ROWS (\(rows.count)) ===")
                for (i, r) in rows.enumerated() {
                    print(describeHuman(index: i, element: r))
                }
            }
            if !menuItems.isEmpty {
                print("")
                print("=== MENU ITEMS (\(menuItems.count)) ===")
                for (i, m) in menuItems.enumerated() {
                    print(describeHuman(index: i, element: m))
                }
            }

            if !probeOutput.isEmpty {
                print("")
                print("=== SETTINGS TABS PROBE ===")
                for (i, result) in probeOutput.enumerated() {
                    print("")
                    print("  ── Tab #\(i): \(result.label)")
                    for label in result.textLabels.prefix(20) {
                        print("     • \(label.prefix(80))")
                    }
                }
            }

            if pressHamburgerThenDump {
                print("")
                print("=== HAMBURGER PRESS LOG ===")
                for line in hamburgerPressLog {
                    print("  \(line)")
                }
                print("")
                print("=== POST-PRESS APP-WIDE MENU ITEMS (\(postPressAppMenuItems.count)) ===")
                for (i, m) in postPressAppMenuItems.enumerated() {
                    print(describeHuman(index: i, element: m))
                }
                if !postPressNewWindows.isEmpty {
                    print("")
                    print("=== POST-PRESS NEW WINDOWS (\(postPressNewWindows.count)) ===")
                    for (i, w) in postPressNewWindows.enumerated() {
                        let t = w.title ?? "(no title)"
                        let f = frameStr(w.frame)
                        let btnCount = w.findAll(role: kAXButtonRole, limit: 80, maxNodes: 400).count
                        print("  [\(i)] title='\(t)' frame=\(f) buttons=\(btnCount)")
                    }
                }
            }
        }
    }

    private func areSame(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }

    // MARK: - Formatting

    private func describeHuman(index: Int, element: UIElement) -> String {
        let id = (element.identifier ?? "").padding(toLength: 12, withPad: " ", startingAt: 0)
        let desc = (element.axDescription ?? "").padding(toLength: 26, withPad: " ", startingAt: 0)
        let title = (element.title ?? "").padding(toLength: 18, withPad: " ", startingAt: 0)
        let frame = frameStr(element.frame).padding(toLength: 20, withPad: " ", startingAt: 0)
        let actions = (try? element.actionNames().joined(separator: ",")) ?? ""
        return "[\(String(format: "%3d", index))] \(id) \(desc) \(title) \(frame) \(actions)"
    }

    private func describeJSON(index: Int, element: UIElement, windowFrame: CGRect?) -> [String: Any] {
        var dict: [String: Any] = [
            "index": index,
            "role": element.role ?? "",
            "id": element.identifier ?? "",
            "title": element.title ?? "",
            "desc": element.axDescription ?? "",
            "value": element.stringValue ?? "",
            "frame": frameDict(element.frame),
            "actions": (try? element.actionNames()) ?? [],
        ]
        if let wf = windowFrame, let ef = element.frame {
            let rightFraction = (ef.midX - wf.minX) / max(1, wf.width)
            dict["right_fraction"] = rightFraction
        }
        return dict
    }

    private func frameStr(_ frame: CGRect?) -> String {
        guard let frame else { return "-" }
        return "\(Int(frame.minX)),\(Int(frame.minY))+\(Int(frame.width))x\(Int(frame.height))"
    }

    private func frameDict(_ frame: CGRect?) -> Any {
        guard let frame else { return NSNull() }
        return [
            "x": Int(frame.minX),
            "y": Int(frame.minY),
            "width": Int(frame.width),
            "height": Int(frame.height),
        ] as [String: Any]
    }

    private func printJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            print("{}")
            return
        }
        print(text)
    }
}
