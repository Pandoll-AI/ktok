import ApplicationServices.HIServices
import Foundation

/// Drives the UI path to KakaoTalk's "Save as a text file" export flow.
/// Sequence:
///   1. Click the hamburger (chat window top-right → opens chatroom settings)
///   2. Click "Manage Chats" on the left panel of the settings view
///   3. Click "Save as a text file" in the right/center panel
///
/// After step 3 KakaoTalk opens a native `NSSavePanel`. Drive that with the
/// existing `SavePanelDriver` (see `Sources/ktok/Download/SavePanelDriver.swift`).
///
/// Each step logs candidate buttons + the picked one so post-mortem on
/// KakaoTalk UI regressions is straightforward. If a button isn't found,
/// a `ChatSettingsNavigatorError` is thrown describing what was searched.
enum ChatSettingsNavigatorError: Error, CustomStringConvertible {
    case hamburgerNotFound(candidates: [String])
    case chatroomSettingsMenuItemNotFound(candidates: [String])
    case settingsPanelNeverAppeared(candidates: [String])
    case manageChatsNotFound(candidates: [String])
    case saveButtonNotFound(candidates: [String])

    var description: String {
        switch self {
        case let .hamburgerNotFound(candidates):
            return "Hamburger button not found in chat window. Candidates: \(candidates.joined(separator: " | "))"
        case let .chatroomSettingsMenuItemNotFound(candidates):
            return "'Chatroom Settings' menu item not found in popover. Candidates: \(candidates.joined(separator: " | "))"
        case let .settingsPanelNeverAppeared(candidates):
            return "Chatroom settings panel did not appear after clicking 'Chatroom Settings'. Visible: \(candidates.joined(separator: " | "))"
        case let .manageChatsNotFound(candidates):
            return "'Manage Chats' button not found. Candidates: \(candidates.joined(separator: " | "))"
        case let .saveButtonNotFound(candidates):
            return "'Save as a text file' button not found. Candidates: \(candidates.joined(separator: " | "))"
        }
    }
}

struct ChatSettingsNavigator {
    let kakao: KakaoTalkApp
    let runner: AXActionRunner
    /// Extra idle time inserted between steps when set > 0. Used by the
    /// `--debug-slow` flag to let the AX tree fully settle between presses,
    /// helping isolate whether "Cannot complete" first-press failures are
    /// caused by UI transition timing.
    var interStepDelay: TimeInterval = 0.0

    private func slowPause(_ label: String) {
        guard interStepDelay > 0 else { return }
        runner.log("\(label): slow-pause \(interStepDelay)s")
        Thread.sleep(forTimeInterval: interStepDelay)
    }

    // MARK: - Single-call orchestration

    /// Drive the full KakaoTalk "Save as a text file" flow from a chat
    /// window through Save-panel confirmation. Linear steps, each logs:
    ///   1. Press hamburger (desc='Menu') in chat window → opens popover
    ///   2. Press "Chatroom Settings" in popover → opens settings window
    ///   3. Activate the Manage Chats sidebar tab (tries sidebar tabs until
    ///      "Save as a text file" button becomes visible)
    ///   4. Press "Save as a text file" button → opens NSSavePanel
    ///   5. Press "Save" button in the NSSavePanel → file saves to
    ///      ~/Downloads
    ///
    /// Callers then wait for the file to land via DirectoryWatcher and
    /// (optionally) call `dismissExportDoneDialog()` to close the
    /// "Successfully exported" confirmation.
    ///
    /// - Parameter skipSavePress: diagnostic — if true, stops before step
    ///   5 (NSSavePanel Save press). User manually presses Save.
    /// - Parameter stopBeforeSaveAsText: diagnostic — if true, stops after
    ///   activating the Manage Chats tab but BEFORE pressing the "Save as
    ///   a text file" button. User manually clicks that button. Lets us
    ///   isolate whether the ding comes from our save-as-text AXPress or
    ///   from KakaoTalk's save-panel-appearance sound.
    func runExportFlow(
        chatWindow: UIElement,
        skipSavePress: Bool = false,
        stopBeforeSaveAsText: Bool = false
    ) throws {
        slowPause("runExportFlow: pre-openChatSettings")
        let settingsRoot = try openChatSettings(in: chatWindow)

        slowPause("runExportFlow: pre-clickManageChatsAndSaveAsText")
        try clickManageChatsAndSaveAsText(
            in: settingsRoot,
            chatWindow: chatWindow,
            stopBeforeSaveAsText: stopBeforeSaveAsText
        )

        if stopBeforeSaveAsText {
            runner.log("runExportFlow: --stop-before-save-as-text set; user presses Save-as-text then Save manually")
            return
        }

        if skipSavePress {
            runner.log("runExportFlow: --skip-save-press set; user presses Save manually in NSSavePanel")
            return
        }

        slowPause("runExportFlow: pre-pressSaveButtonInPanel")
        try pressSaveButtonInPanel()
    }

    /// Press the "Save" button inside the NSSavePanel via AX (no keystroke).
    /// Polls for up to 4 s. Raises the enclosing window + activates the
    /// app first so the panel has focus.
    func pressSaveButtonInPanel(timeoutSec: TimeInterval = 4.0) throws {
        let deadline = Date().addingTimeInterval(timeoutSec)
        let saveTitles: Set<String> = ["Save", "저장", "Download", "다운로드"]

        while Date() < deadline {
            let roots: [UIElement] = kakao.windows + [kakao.applicationElement]
            for root in roots {
                let buttons = root.findAll(role: kAXButtonRole, limit: 80, maxNodes: 600)
                guard let save = buttons.first(where: { btn in
                    saveTitles.contains((btn.title ?? "").trimmingCharacters(in: .whitespaces))
                }) else {
                    continue
                }

                focusEnclosingWindow(of: save)
                do {
                    try save.press()
                    runner.log("save-panel: pressed Save button via AX (title='\(save.title ?? "")')")
                    return
                } catch {
                    runner.log("save-panel: AX press on Save failed (\(error)); retrying")
                }
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        throw ChatSettingsNavigatorError.saveButtonNotFound(
            candidates: ["save_button_not_found_within_\(Int(timeoutSec))s"]
        )
    }

    /// Press the "OK" button in KakaoTalk's "Successfully exported your
    /// chat history" confirmation dialog via AX AXPress. No keystroke.
    /// Gated by a marker static text in the same root so we don't press
    /// an unrelated OK dialog.
    @discardableResult
    func dismissExportDoneDialog(timeoutSec: TimeInterval = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        let okLabels: Set<String> = ["OK", "확인"]
        let markers: [String] = [
            "Successfully exported",
            "exported your chat",
            "내보내기",
            "저장되었습니다",
        ]

        while Date() < deadline {
            let roots = kakao.windows + [kakao.applicationElement]
            for root in roots {
                let buttons = root.findAll(role: kAXButtonRole, limit: 40, maxNodes: 400)
                guard let ok = buttons.first(where: { okLabels.contains(($0.title ?? "").trimmingCharacters(in: .whitespaces)) }) else {
                    continue
                }
                let texts = root.findAll(role: kAXStaticTextRole, limit: 40, maxNodes: 400)
                let hasMarker = texts.contains { t in
                    let v = (t.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                    return markers.contains { m in v.localizedCaseInsensitiveContains(m) }
                }
                guard hasMarker else { continue }

                do {
                    try ok.press()
                    runner.log("export-done-dialog: pressed OK via AXPress")
                    return true
                } catch {
                    runner.log("export-done-dialog: OK press failed (\(error))")
                    return false
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        runner.log("export-done-dialog: no matching OK within \(timeoutSec)s (likely auto-dismissed or never shown)")
        return false
    }

    /// Raise the enclosing AXWindow of an element and activate KakaoTalk,
    /// so AX presses land on a focused target. Silent-best-effort.
    private func focusEnclosingWindow(of element: UIElement) {
        var cursor: UIElement? = element
        var hops = 0
        while let current = cursor, hops < 12 {
            if current.role == kAXWindowRole {
                if let actions = try? current.actionNames(), actions.contains(kAXRaiseAction) {
                    try? current.performAction(kAXRaiseAction)
                }
                break
            }
            cursor = current.parent
            hops += 1
        }
        kakao.activate()
        Thread.sleep(forTimeInterval: 0.1)
    }

    /// KakaoTalk English popover menu item label that leads to the full
    /// chatroom settings panel. Exact equality (case-insensitive, trimmed).
    private static let chatroomSettingsMenuLabels: [String] = [
        "Chatroom Settings",
        "채팅방 설정",
    ]

    /// Step 1 — click the hamburger button in the chat window's top toolbar,
    /// then click the "Chatroom Settings" item in the popover that appears.
    /// Returns the root element where settings UI appears (a new window if
    /// KakaoTalk opens one, otherwise the chat window after it repaints).
    ///
    /// Flow verified 2026-04-19 via `ktok dump-chat-ui --press-hamburger-then-dump`:
    ///   1. Press `AXButton desc='Menu'` in chat window → AX popover appears
    ///      as `AXMenuItem` elements under `AXApplication`.
    ///   2. Popover contains items like "Notifications", "Favorites",
    ///      "Chatroom Settings", "Leave chatroom", etc.
    ///   3. Pressing "Chatroom Settings" opens the full settings panel
    ///      where "Manage Chats" and "Save as a text file" live.
    func openChatSettings(in chatWindow: UIElement) throws -> UIElement {
        let (baselineButtonTitles, baselineStaticTexts) = snapshotMarkers(in: chatWindow)

        let candidates = rankHamburgerCandidates(in: chatWindow)
        let candidateSummary = candidates.prefix(8).map { describe($0.0) + " score=\($0.1)" }
        runner.log("hamburger: \(candidates.count) filtered candidates; top: \(candidateSummary.joined(separator: " ; "))")

        // SAFETY: only candidates that exactly match a known hamburger label
        // (score = 10_000) are allowed. No fallback to lower-scored buttons.
        // The near-miss incident (accidental Video Call) was caused by
        // pressing the "next-best" button when the top choice failed —
        // this path is now closed by strict equality.
        let strongest = candidates.first { $0.1 >= 10_000 }
        guard let (hamburger, score) = strongest else {
            throw ChatSettingsNavigatorError.hamburgerNotFound(
                candidates: ["no_button_with_exact_hamburger_label"] + candidateSummary
            )
        }
        runner.log("hamburger: selected uniquely \(describe(hamburger)) score=\(score)")

        // Press hamburger. Retry same button on transient AX failures — do
        // NOT fall back to a different candidate (that caused the Video Call
        // near-incident).
        var hamburgerPressed = false
        for attempt in 0..<3 {
            do {
                let target: UIElement
                if attempt == 0 {
                    target = hamburger
                } else {
                    Thread.sleep(forTimeInterval: 0.25)
                    guard let refreshed = rankHamburgerCandidates(in: chatWindow).first(where: { $0.1 >= 10_000 }) else {
                        runner.log("hamburger: retry \(attempt) — label-matched candidate vanished; aborting")
                        break
                    }
                    target = refreshed.0
                }
                try target.press()
                runner.log("hamburger: pressed \(describe(target))\(attempt > 0 ? " (retry \(attempt))" : "")")
                hamburgerPressed = true
                break
            } catch {
                runner.log("hamburger: press attempt \(attempt) failed: \(error)")
            }
        }
        guard hamburgerPressed else {
            throw ChatSettingsNavigatorError.hamburgerNotFound(
                candidates: ["menu_press_failed_after_retries"] + candidateSummary
            )
        }

        // Step 2: wait for the popover to appear and find "Chatroom Settings"
        // among its AXMenuItem children at the application root.
        let chatroomSettingsItem = try waitForAndPressChatroomSettingsItem(
            timeoutSec: 2.0
        )
        runner.log("chatroom-settings: pressed menu item \(describe(chatroomSettingsItem))")

        // Step 3: the settings view either opens as a new AX window or re-
        // paints part of the existing chat window. Poll for a root that
        // exposes the "Manage Chats" marker (which we haven't seen before).
        if let settingsRoot = pollForSettingsPanel(
            chatWindow: chatWindow,
            baselineButtons: baselineButtonTitles,
            baselineStaticTexts: baselineStaticTexts,
            timeoutSec: 3.0
        ) {
            runner.log("settings panel located at \(describe(settingsRoot))")
            return settingsRoot
        }

        throw ChatSettingsNavigatorError.settingsPanelNeverAppeared(
            candidates: diagnosticDumpLines(chatWindow: chatWindow)
        )
    }

    /// Wait for the popover menu to appear after hamburger press, then press
    /// the "Chatroom Settings" item. Returns the pressed element. Errors
    /// with a dump of visible menu items if the label isn't found.
    private func waitForAndPressChatroomSettingsItem(timeoutSec: TimeInterval) throws -> UIElement {
        var target: UIElement?
        _ = runner.waitUntil(label: "chatroom settings popover", timeout: timeoutSec, pollInterval: 0.1) {
            let items = kakao.applicationElement.findAll(role: kAXMenuItemRole, limit: 60, maxNodes: 400)
            if let match = items.first(where: { item in
                let title = (item.title ?? "").trimmingCharacters(in: .whitespaces)
                return Self.chatroomSettingsMenuLabels.contains { label in
                    title.caseInsensitiveCompare(label) == .orderedSame
                }
            }) {
                target = match
                return true
            }
            return false
        }

        guard let chatroomSettingsItem = target else {
            let items = kakao.applicationElement.findAll(role: kAXMenuItemRole, limit: 60, maxNodes: 400)
            let labels = items.prefix(20).compactMap { item -> String? in
                let t = (item.title ?? "").trimmingCharacters(in: .whitespaces)
                return t.isEmpty ? nil : "'\(t)'"
            }
            throw ChatSettingsNavigatorError.chatroomSettingsMenuItemNotFound(candidates: labels)
        }

        do {
            try chatroomSettingsItem.press()
            return chatroomSettingsItem
        } catch {
            // AXPress on AXMenuItem can fail with "cannot complete" if the
            // popover closed between scan and press. Try AXPick (also listed
            // in the observed actions) as a fallback.
            if let actions = try? chatroomSettingsItem.actionNames(), actions.contains("AXPick") {
                try chatroomSettingsItem.performAction("AXPick")
                return chatroomSettingsItem
            }
            throw error
        }
    }

    /// Emit the first few NEW labels in chatWindow for error messages.
    private func diagnosticDumpLines(chatWindow: UIElement) -> [String] {
        let buttons = chatWindow.findAll(role: kAXButtonRole, limit: 30, maxNodes: 300)
        let buttonLabels = buttons.compactMap { b -> String? in
            let t = (b.title ?? "").trimmingCharacters(in: .whitespaces)
            let d = (b.axDescription ?? "").trimmingCharacters(in: .whitespaces)
            if t.isEmpty && d.isEmpty { return nil }
            return "btn '\(t)'/\(d)'"
        }
        return Array(buttonLabels.prefix(15))
    }

    /// Descriptions / titles that must NEVER be pressed during hamburger
    /// discovery. These are buttons that would trigger real-world side
    /// effects (phone call, outbound share) if we misidentified them.
    ///
    /// Near-incident 2026-04-18: during AX retry the code fell through to
    /// the "Video Call" button (next-highest score after the real Menu
    /// button failed to press). A hard blocklist — applied at filtering
    /// time, not just scoring — ensures these buttons are invisible to the
    /// hamburger search no matter what.
    private static let dangerousButtonPatterns: [String] = [
        "call", "voice", "video",
        "share",
        "invite",
        "record",
        "통화", "영상", "음성", "공유", "초대", "녹화",
    ]

    /// AX description / title values that unambiguously name the hamburger.
    /// EXACT equality (after case-insensitive trim) is required — substring
    /// match is not safe (e.g., "Menu" could appear inside longer labels).
    ///
    /// To add a locale: append the KakaoTalk-reported AXDescription value
    /// here. Do NOT rely on coordinates, frame size, or position — UI
    /// resizing / zoom changes these without warning.
    private static let hamburgerLabels: [String] = [
        "Menu",
        "메뉴",
    ]

    /// Filter + rank candidate buttons WITHOUT using frames/coordinates.
    /// Matching is driven purely by AX label equality + a hard blocklist
    /// for buttons that trigger real-world side effects.
    private func rankHamburgerCandidates(in chatWindow: UIElement) -> [(UIElement, Int)] {
        let buttons = chatWindow.findAll(role: kAXButtonRole, limit: 80, maxNodes: 800)

        return buttons.compactMap { button -> (UIElement, Int)? in
            let desc = (button.axDescription ?? "").trimmingCharacters(in: .whitespaces)
            let title = (button.title ?? "").trimmingCharacters(in: .whitespaces)
            let identifier = (button.identifier ?? "").trimmingCharacters(in: .whitespaces)

            // HARD EXCLUSION FIRST — a button whose desc/title hits any
            // dangerous keyword is dropped from candidacy regardless of
            // score. Prevents accidental Video Call / Share / etc.
            let joinedLowered = "\(desc) \(title) \(identifier)".lowercased()
            for pattern in Self.dangerousButtonPatterns {
                if joinedLowered.contains(pattern) {
                    return nil
                }
            }

            // PRIMARY MATCH — exact equality (case-insensitive) against the
            // allowlist of known hamburger labels. This is the only signal
            // we trust. No coordinates, no size heuristics, no positional
            // tie-breakers — if the label doesn't match, we don't touch it.
            let descLower = desc.lowercased()
            let titleLower = title.lowercased()
            let matchesExactHamburgerLabel = Self.hamburgerLabels.contains { label in
                let lower = label.lowercased()
                return descLower == lower || titleLower == lower
            }
            if matchesExactHamburgerLabel {
                return (button, 10_000)
            }

            return nil
        }
        .sorted { $0.1 > $1.1 }
    }

    /// Capture button titles + static text values present in the chat window
    /// BEFORE pressing the hamburger. Used to detect "new" markers that
    /// appeared after the press — avoids false positives on labels that are
    /// always present in the chat header.
    private func snapshotMarkers(in chatWindow: UIElement) -> (Set<String>, Set<String>) {
        var buttons: Set<String> = []
        var texts: Set<String> = []
        for btn in chatWindow.findAll(role: kAXButtonRole, limit: 80, maxNodes: 600) {
            if let t = btn.title?.trimmingCharacters(in: .whitespaces), !t.isEmpty {
                buttons.insert(t)
            }
        }
        for txt in chatWindow.findAll(role: kAXStaticTextRole, limit: 80, maxNodes: 600) {
            if let v = txt.stringValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
                texts.insert(v)
            }
        }
        return (buttons, texts)
    }

    /// Step 2 + 3 combined — ensure the Manage Chats tab is active and press
    /// the Save-as-text button within it.
    ///
    /// KakaoTalk's settings window has a LEFT sidebar with icon-only buttons
    /// whose AXTitle/AXDescription are empty. The Manage Chats tab is thus
    /// not identifiable by label alone. Strategy:
    ///   1. If the save-as-text label is already visible (default tab covers
    ///      it), click it immediately.
    ///   2. Otherwise, press each pressable sidebar-style button (AXPress
    ///      action, empty title/desc, NOT one of the known generic action
    ///      buttons) in turn. After each press, re-check for the save label.
    ///   3. Abort after iterating all candidates without finding the label.
    ///
    /// Verified 2026-04-19: on current KakaoTalk English, the Manage Chats
    /// tab is the 2nd pressable empty-label button (identifier `_NS:50`).
    /// Pressing it reveals the static text "Save Messages as Documents".
    func clickManageChatsAndSaveAsText(
        in settingsRoot: UIElement,
        chatWindow: UIElement,
        stopBeforeSaveAsText: Bool = false
    ) throws {
        // Safety precondition — settingsRoot MUST be a distinct AXWindow, not
        // the chat window. The sidebar-tab iteration below presses empty-
        // label pressable buttons, and that fallback has no label-equality
        // safety net. Running it against chat-window children would re-open
        // the class of risk that caused the 2026-04-18 Video-Call near-miss.
        guard !areSame(settingsRoot, chatWindow) else {
            throw ChatSettingsNavigatorError.settingsPanelNeverAppeared(
                candidates: ["settings_root_equals_chat_window_refused_for_safety"]
            )
        }
        // AX BUTTON title strings (not the section header static-text).
        // Confirmed via `ktok dump-chat-ui --open-settings-then-dump
        // --probe-settings-tabs` (2026-04-19) — after activating the Manage
        // Chats sidebar tab, an AXButton with `title='Save as a text file'`
        // (id `_NS:8`) appears in the content area. We restrict matching
        // to AXButton role to avoid accidentally pressing the section
        // header static text ("Save Messages as Documents"), which isn't
        // pressable.
        let saveNeedles: Set<String> = [
            "save as a text file",
            "save as text file",
            "save chat as text",
            "텍스트 파일로 저장",
            "대화 내용 내보내기",
            "메시지 저장",
        ]

        // Direct path — if the save button is already visible (default tab
        // happens to be Manage Chats, or KakaoTalk opened the settings on
        // the right tab for this chat), click immediately.
        if let save = findSaveButton(in: settingsRoot, needles: saveNeedles) {
            runner.log("save-as-text: found on default tab")
            if stopBeforeSaveAsText {
                runner.log("save-as-text: stop-before-save-as-text set; not pressing")
                return
            }
            // Prefer JXA System Events route (bypasses Swift AXPress beep bug).
            if pressSaveAsTextViaJXA() {
                return
            }
            runner.log("save-as-text: JXA press miss, falling back to AX (may beep)")
            try pressOrAncestor(
                save,
                label: "save-as-text",
                refresh: { [self] in findSaveButton(in: settingsRoot, needles: saveNeedles) }
            )
            return
        }

        // Indirect path — iterate the sidebar tabs until one reveals the
        // save button. We press empty-label pressable buttons only; danger
        // blocklist + small-button skip keep us away from close/traffic-light.
        let sidebarTabs = findSidebarTabCandidates(in: settingsRoot)
        runner.log("manage-chats: \(sidebarTabs.count) candidate sidebar tabs")
        for (i, tab) in sidebarTabs.enumerated() {
            do {
                try tab.press()
                runner.log("manage-chats: pressed sidebar tab #\(i) \(describe(tab))")
            } catch {
                runner.log("manage-chats: tab #\(i) press failed: \(error)")
                continue
            }
            // Wait for KakaoTalk to finish rendering the Manage Chats tab
            // content before touching the Save-as-text button.
            Thread.sleep(forTimeInterval: 0.6)

            if let save = findSaveButton(in: settingsRoot, needles: saveNeedles) {
                runner.log("save-as-text: revealed on tab #\(i): \(describe(save))")
                if stopBeforeSaveAsText {
                    runner.log("save-as-text: stop-before-save-as-text set; not pressing")
                    return
                }
                // Route through JXA System Events instead of Swift AXPress.
                // The Swift AX C API's first press on KakaoTalk's Save-as-text
                // button consistently returns kAXErrorCannotComplete — that
                // failed call produces the macOS system beep user hears when
                // the save panel opens. JXA presses via a different code path
                // (app-scripting bridge), avoiding the beep.
                if pressSaveAsTextViaJXA() {
                    return
                }
                // JXA fallback failure → try the AX path as last resort
                // (may still beep, but file export might succeed).
                runner.log("save-as-text: JXA press miss, falling back to AX (may beep)")
                try pressOrAncestor(
                    save,
                    label: "save-as-text",
                    refresh: { [self] in findSaveButton(in: settingsRoot, needles: saveNeedles) }
                )
                return
            }
        }

        throw ChatSettingsNavigatorError.saveButtonNotFound(
            candidates: ["no_sidebar_tab_revealed_save_button"] + dumpCandidates(settingsRoot)
        )
    }

    /// Restrict save-as-text search to AXButton role (the pressable action
    /// button). Static text section headers also match these keywords but
    /// are not pressable — we must not return those.
    private func findSaveButton(in root: UIElement, needles: Set<String>) -> UIElement? {
        let buttons = root.findAll(role: kAXButtonRole, limit: 60, maxNodes: 500)
        return buttons.first { button in
            let title = (button.title ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let desc = (button.axDescription ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            return needles.contains(title) || needles.contains(desc)
        }
    }

    /// Press the "Save as a text file" button via JXA (JavaScript for
    /// Automation) scripting bridge.
    ///
    /// The reason: Swift's C-level AXPress call on this specific KakaoTalk
    /// button produces `kAXErrorCannotComplete` on the first attempt, and
    /// that failed call synthesizes a macOS system beep that plays ~100ms
    /// later — coinciding with the save panel appearance on screen. The
    /// beep persists across every AX-level mitigation tried (pre-press
    /// sleep, ready-check via actionNames, last-moment element refresh,
    /// kakao.activate + AXRaise). JXA routes through the application-scripting
    /// bridge instead of direct AX C-API; in practice it either succeeds
    /// without beep or silently no-ops.
    ///
    /// Returns true if the press succeeded, false otherwise.
    private func pressSaveAsTextViaJXA() -> Bool {
        let script = """
        var se = Application("System Events");
        var kk = se.processes.byName("KakaoTalk");
        var needles = [
          "Save as a text file",
          "Save as text file",
          "텍스트 파일로 저장",
          "대화 내용 내보내기",
          "메시지 저장"
        ];
        var clicked = false;
        function find(e, depth) {
          if (depth > 10 || clicked) return;
          try {
            var children = e.uiElements();
            for (var i = 0; i < children.length; i++) {
              try {
                var c = children[i];
                if (c.role() === "AXButton") {
                  var title = "";
                  try { title = c.title(); } catch(x) {}
                  if (needles.indexOf(title) !== -1) {
                    c.actions.byName("AXPress").perform();
                    clicked = true;
                    return;
                  }
                }
                find(c, depth + 1);
                if (clicked) return;
              } catch(x) {}
            }
          } catch(x) {}
        }
        var wins = kk.windows();
        for (var w = 0; w < wins.length; w++) {
          find(wins[w], 0);
          if (clicked) break;
        }
        JSON.stringify({clicked: clicked})
        """

        let output = AppleScriptRunner.runJXA(script, timeoutSec: 8.0)
        guard output.returncode == 0,
              let data = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clicked = obj["clicked"] as? Bool
        else {
            runner.log("save-as-text: JXA press result unparseable — stdout='\(output.stdout.prefix(160))' stderr='\(output.stderr.prefix(160))'")
            return false
        }
        if clicked {
            runner.log("save-as-text: pressed via JXA System Events (AX bypass, no beep)")
        } else {
            runner.log("save-as-text: JXA did not locate a matching button in any window")
        }
        return clicked
    }

    /// Sidebar tabs are AXButton elements with AXPress action, empty title
    /// AND empty description (icon-only), and NOT a generic action button
    /// (Edit / Select / Save / Share / Close etc).
    ///
    /// We do not use coordinates — user directive 2026-04-18. Filtering is
    /// purely by AX role + action availability + label exclusion. In the
    /// current KakaoTalk settings window this returns exactly the sidebar
    /// tabs (verified via --probe-settings-tabs).
    private func findSidebarTabCandidates(in settingsRoot: UIElement) -> [UIElement] {
        let skipTitles: Set<String> = [
            "edit", "select", "select sound", "save", "save as",
            "share", "done", "cancel", "open", "show in finder",
        ]
        let skipDescs: Set<String> = [
            "close", "profile",
        ]
        return settingsRoot.findAll(role: kAXButtonRole, limit: 60, maxNodes: 400).filter { button in
            let title = (button.title ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            let desc = (button.axDescription ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            guard title.isEmpty, desc.isEmpty else { return false }
            guard (try? button.actionNames().contains("AXPress")) == true else { return false }
            // The above already excludes title/desc matches, but be defensive.
            if skipTitles.contains(title) || skipDescs.contains(desc) { return false }
            // Also block any dangerous keywords just in case.
            let joined = "\(title) \(desc) \(button.identifier ?? "")".lowercased()
            for pattern in Self.dangerousButtonPatterns {
                if joined.contains(pattern) { return false }
            }
            return true
        }
    }

    /// Press an element robustly. Core insight (2026-04-19 debugging):
    /// KakaoTalk's "Save as a text file" AXPress consistently fails on
    /// attempt 0 with `kAXErrorCannotComplete` ("application has not yet
    /// responded") even though `actionNames()` reports `AXPress` as
    /// available. The failed call produces a macOS system beep that gets
    /// audible ~100ms later, coinciding with the save panel appearance.
    ///
    /// Strategy to make attempt 0 actually succeed (and thus suppress the
    /// beep):
    ///   1. **Minimum settle time** — unconditional 300ms sleep before the
    ///      very first press attempt. `actionNames` reports readiness
    ///      prematurely in KakaoTalk; this sleep lets the app reach a state
    ///      where it can actually service AXPress.
    ///   2. **Ready-check** — `actionNames()` must include `AXPress`
    ///      (passive, no beep on miss).
    ///   3. **Last-moment refresh** — immediately before every `press()`
    ///      call, fetch a fresh element ref via `refresh` if available, so
    ///      we never press a stale AX reference.
    ///
    /// If a press throws despite the above, retries do minimal additional
    /// wait + re-refresh. The ancestor fallback only runs if all retries
    /// exhaust.
    private func pressOrAncestor(
        _ element: UIElement,
        label: String,
        retries: Int = 3,
        readyTimeoutSec: TimeInterval = 1.5,
        firstAttemptSettleSec: TimeInterval = 0.3,
        refresh: (() -> UIElement?)? = nil
    ) throws {
        var current = element
        var lastError: Error?

        for attempt in 0...retries {
            // Unconditional settle before attempt 0. Without this, attempt 0
            // consistently fails with kAXErrorCannotComplete → system beep.
            // The empirical value 300ms was verified against KakaoTalk's
            // "Save as a text file" button.
            if attempt == 0 {
                Thread.sleep(forTimeInterval: firstAttemptSettleSec)
                if let refresh, let fresh = refresh() {
                    current = fresh
                }
            }

            // Ready-check: wait until AXPress is reported available. Passive
            // — does NOT beep on miss.
            let readyDeadline = Date().addingTimeInterval(readyTimeoutSec)
            var isReady = false
            while Date() < readyDeadline {
                if let actions = try? current.actionNames(), actions.contains("AXPress") {
                    isReady = true
                    break
                }
                if let refresh, let fresh = refresh() {
                    current = fresh
                }
                Thread.sleep(forTimeInterval: 0.08)
            }

            guard isReady else {
                runner.log("\(label): AXPress not ready within \(readyTimeoutSec)s (attempt \(attempt))")
                lastError = NSError(
                    domain: "ChatSettingsNavigator",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "AXPress action not reported"]
                )
                if attempt < retries {
                    Thread.sleep(forTimeInterval: 0.25)
                    if let refresh, let fresh = refresh() {
                        current = fresh
                    }
                }
                continue
            }

            // Final refresh RIGHT BEFORE press — gives us the freshest ref
            // immediately before the action. Prevents press() from being
            // called on an AX ref that went stale during ready-check.
            if let refresh, let fresh = refresh() {
                current = fresh
            }

            do {
                try current.press()
                runner.log("\(label): pressed\(attempt > 0 ? " (retry \(attempt))" : "") \(describe(current))")
                return
            } catch {
                lastError = error
                runner.log("\(label): press attempt \(attempt) failed: \(error)")
                if attempt < retries {
                    Thread.sleep(forTimeInterval: 0.3)
                    if let refresh, let fresh = refresh() {
                        current = fresh
                    }
                }
            }
        }

        // Final fallback — walk up ancestors on the most-recent ref.
        if pressViaAncestor(current, label: label) {
            return
        }
        throw lastError ?? NSError(domain: "ChatSettingsNavigator", code: -1)
    }

    // MARK: - Helpers

    /// Find a pressable element (AXButton, AXMenuItem, AXCell, AXStaticText)
    /// whose label lowercased matches one of `needles`.
    private func findPressable(in root: UIElement, matchingLowercased needles: Set<String>) -> UIElement? {
        let candidates = root.findAll(
            where: { element in
                switch element.role {
                case kAXButtonRole, kAXMenuItemRole, kAXCellRole, kAXStaticTextRole, kAXRowRole:
                    return true
                default:
                    return false
                }
            },
            limit: 160,
            maxNodes: 1_600
        )
        return candidates.first { element in
            let labels = [
                element.title ?? "",
                element.stringValue ?? "",
                element.axDescription ?? "",
            ]
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return labels.contains { needles.contains($0) }
        }
    }

    /// Walk up ancestors looking for one that supports AXPress. Some
    /// KakaoTalk settings rows expose the label on a StaticText whose parent
    /// AXCell / AXRow is the actual click target.
    private func pressViaAncestor(_ element: UIElement, label: String) -> Bool {
        var cursor = element.parent
        var attempts = 0
        while let current = cursor, attempts < 4 {
            if let actions = try? current.actionNames(), actions.contains("AXPress") {
                do {
                    try current.press()
                    runner.log("\(label): pressed ancestor \(describe(current))")
                    return true
                } catch {
                    cursor = current.parent
                    attempts += 1
                    continue
                }
            }
            cursor = current.parent
            attempts += 1
        }
        return false
    }

    /// Diagnostic-only helper — press the hamburger button once and return
    /// (success, log_lines). Used by `ktok dump-chat-ui --press-hamburger-then-dump`
    /// to reveal what AX UI appears after the press without triggering the
    /// downstream Manage Chats / Save navigation.
    ///
    /// Applies the SAME safety rules as `openChatSettings`: only the
    /// exact-label hamburger candidate is ever pressed; dangerous-button
    /// blocklist excludes call/video/share etc.
    func diagnosticPressHamburger(in chatWindow: UIElement) -> (Bool, [String]) {
        var log: [String] = []
        let candidates = rankHamburgerCandidates(in: chatWindow)
        log.append("filtered candidates: \(candidates.count)")
        for (c, s) in candidates.prefix(4) {
            log.append("  \(describe(c)) score=\(s)")
        }

        guard let (hamburger, _) = candidates.first(where: { $0.1 >= 10_000 }) else {
            log.append("no exact-label hamburger candidate; aborting")
            return (false, log)
        }
        log.append("selected: \(describe(hamburger))")

        // Try AXPress. If action isn't reported, fall back to explicit
        // AXShowMenu — some macOS menu-style buttons respond only to that.
        do {
            try hamburger.press()
            log.append("AXPress succeeded (may be no-op if button only supports AXShowMenu)")
        } catch {
            log.append("AXPress failed: \(error)")
        }

        if let actions = try? hamburger.actionNames() {
            log.append("reported actions: \(actions.joined(separator: ","))")
            if actions.contains("AXShowMenu"), !actions.contains("AXPress") {
                do {
                    try hamburger.performAction("AXShowMenu")
                    log.append("AXShowMenu succeeded")
                } catch {
                    log.append("AXShowMenu failed: \(error)")
                }
            }
        }

        return (true, log)
    }

    /// Produce a short dump of pressable labels for error messages.
    private func dumpCandidates(_ root: UIElement) -> [String] {
        let buttons = root.findAll(role: kAXButtonRole, limit: 24, maxNodes: 400)
        let menuItems = root.findAll(role: kAXMenuItemRole, limit: 24, maxNodes: 400)
        let cells = root.findAll(role: kAXCellRole, limit: 24, maxNodes: 400)
        return (buttons + menuItems + cells).prefix(30).map(describe)
    }

    /// Poll until a settings marker appears after hamburger press. Scans
    /// chat window + any NEW kakao windows only (skips application root to
    /// avoid multi-second per-iteration walks). On timeout, dumps visible
    /// labels to trace log so the missing marker can be identified.
    private func pollForSettingsPanel(
        chatWindow: UIElement,
        baselineButtons: Set<String>,
        baselineStaticTexts: Set<String>,
        timeoutSec: TimeInterval
    ) -> UIElement? {
        // ONLY a separate AX window counts as the settings root. An inline
        // panel inside the chat window is refused — `clickManageChatsAndSaveAsText`
        // iterates empty-label pressable buttons to find the Manage Chats tab,
        // and running that iteration against chat window children has no
        // safety guarantees (dangerous-button blocklist works on desc/title,
        // but chat-window empty-label buttons may be arbitrary). Verified
        // KakaoTalk always opens settings as a distinct AXWindow, so this
        // restriction loses no functionality.
        let baselineWindowCount = kakao.windows.count
        var settingsRoot: UIElement?
        let succeeded = runner.waitUntil(label: "settings panel", timeout: timeoutSec, pollInterval: 0.15) {
            let otherWindows = kakao.windows.filter { !areSame($0, chatWindow) }
            for candidate in otherWindows {
                if containsChatroomSettingsMarker(candidate) {
                    settingsRoot = candidate
                    return true
                }
            }
            return false
        }

        if !succeeded {
            let dump = diagnosticDump(chatWindow: chatWindow, baselineWindowCount: baselineWindowCount)
            runner.log("settings-panel-diagnostic: \(dump)")
        }
        return settingsRoot
    }

    /// The chatroom settings window always shows "Chatroom Settings" as its
    /// header static text (English) or "채팅방 설정" (Korean). Detecting this
    /// label in a candidate root confirms we found the right window.
    private func containsChatroomSettingsMarker(_ root: UIElement) -> Bool {
        let markers: Set<String> = [
            "Chatroom Settings",
            "채팅방 설정",
        ]
        let texts = root.findAll(role: kAXStaticTextRole, limit: 40, maxNodes: 300)
        return texts.contains { t in
            let v = (t.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            return markers.contains(v)
        }
    }

    /// Look for an element whose label matches a known marker AND did not
    /// exist in the chat window before the press (baseline sets). Scope is
    /// tightly bounded to keep each iteration fast (< 200ms).
    private func findSettingsMarker(
        in root: UIElement,
        baselineButtons: Set<String>,
        baselineStaticTexts: Set<String>
    ) -> UIElement? {
        // We return the ROOT, not the marker element — upstream uses the root
        // as the search surface for clickManageChats / clickSaveAsTextFile.
        let markers: Set<String> = [
            "Manage Chats", "채팅방 관리",
            "Save as a text file", "Save as text file",
            "텍스트 파일로 저장", "대화 내용 내보내기",
            "Chatroom Settings", "채팅방 설정",
        ]
        let buttons = root.findAll(role: kAXButtonRole, limit: 40, maxNodes: 300)
        for btn in buttons {
            let title = (btn.title ?? "").trimmingCharacters(in: .whitespaces)
            if markers.contains(title), !baselineButtons.contains(title) {
                return root
            }
        }
        let staticTexts = root.findAll(role: kAXStaticTextRole, limit: 40, maxNodes: 300)
        for txt in staticTexts {
            let val = (txt.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if markers.contains(val), !baselineStaticTexts.contains(val) {
                return root
            }
        }
        let menuItems = root.findAll(role: kAXMenuItemRole, limit: 40, maxNodes: 300)
        for item in menuItems {
            let title = (item.title ?? "").trimmingCharacters(in: .whitespaces)
            if markers.contains(title) {
                return root
            }
        }
        return nil
    }

    /// Emit the first few NEW labels that appeared in the chat window since
    /// the press, as a single log line. Used to debug marker-matcher misses.
    private func diagnosticDump(chatWindow: UIElement, baselineWindowCount: Int) -> String {
        var lines: [String] = []
        let buttons = chatWindow.findAll(role: kAXButtonRole, limit: 40, maxNodes: 300)
        let buttonLabels = buttons.compactMap { b -> String? in
            let t = (b.title ?? "").trimmingCharacters(in: .whitespaces)
            let d = (b.axDescription ?? "").trimmingCharacters(in: .whitespaces)
            if t.isEmpty && d.isEmpty { return nil }
            return "btn title='\(t)' desc='\(d)'"
        }
        lines.append("chatWindow buttons=\(buttonLabels.count): \(buttonLabels.prefix(12).joined(separator: " | "))")

        let texts = chatWindow.findAll(role: kAXStaticTextRole, limit: 40, maxNodes: 300)
        let textLabels = texts.compactMap { t -> String? in
            let v = (t.stringValue ?? "").trimmingCharacters(in: .whitespaces)
            if v.isEmpty { return nil }
            return "'\(v.prefix(40))'"
        }
        lines.append("chatWindow staticTexts=\(textLabels.count): \(textLabels.prefix(8).joined(separator: " | "))")

        if kakao.windows.count > baselineWindowCount {
            lines.append("new-windows=\(kakao.windows.count - baselineWindowCount)")
        } else {
            lines.append("new-windows=0")
        }

        return lines.joined(separator: "  ||  ")
    }

    private func describe(_ element: UIElement) -> String {
        let role = element.role ?? "?"
        let id = element.identifier ?? ""
        let title = element.title ?? ""
        let desc = element.axDescription ?? ""
        let frame = element.frame.map { "\(Int($0.minX)),\(Int($0.minY))+\(Int($0.width))x\(Int($0.height))" } ?? "-"
        return "[\(role) id='\(id)' title='\(title)' desc='\(desc)' frame=\(frame)]"
    }

    private func areSame(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }
}
