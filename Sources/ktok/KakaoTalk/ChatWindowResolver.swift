import ApplicationServices.HIServices
import AppKit
import CoreGraphics
import Foundation

enum ChatWindowResolutionMethod {
    case existingWindow
    case openedViaVisibleRow
    case openedViaSearch
}

struct ChatWindowResolution {
    let window: UIElement
    let method: ChatWindowResolutionMethod

    var openedViaSearch: Bool {
        method == .openedViaSearch
    }

    /// True when this resolution opened a chat window that was not already
    /// present (visible-row press or search). Callers that clean up
    /// auto-opened windows (e.g. `--keep-window` gating) should treat both the
    /// visible-row and search paths the same way.
    var openedNewWindow: Bool {
        method == .openedViaVisibleRow || method == .openedViaSearch
    }

    var methodLabel: String {
        switch method {
        case .existingWindow: return "existing-window"
        case .openedViaVisibleRow: return "visible-row"
        case .openedViaSearch: return "search"
        }
    }
}

private enum ChatWindowFailureCode: String {
    case focusFail = "FOCUS_FAIL"
    case inputNotReflected = "INPUT_NOT_REFLECTED"
    case windowNotReady = "WINDOW_NOT_READY"
    case searchMiss = "SEARCH_MISS"
}

private struct SearchScanProfile {
    let label: String
    let timeout: TimeInterval
    let pollInterval: TimeInterval
    let rowLimit: Int
    let cellLimit: Int
    let supplementalLimit: Int
    let candidateNodeBudget: Int
    let textLimit: Int
    let textNodeBudget: Int
    let includeSupplementalRoles: Bool
    let includeApplicationRoot: Bool
}

private struct SearchCandidate {
    let element: UIElement
    let textScore: Int
    let matchedText: String
}

struct ChatWindowResolver {
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner
    private let useCache: Bool
    private let deepRecoveryEnabled: Bool

    init(
        kakao: KakaoTalkApp,
        runner: AXActionRunner,
        useCache: Bool = true,
        deepRecoveryEnabled: Bool = false
    ) {
        self.kakao = kakao
        self.runner = runner
        self.useCache = useCache
        self.deepRecoveryEnabled = deepRecoveryEnabled
    }

    func resolve(query: String) throws -> ChatWindowResolution {
        let usableWindow = try requireUsableWindow()

        // 1) Already-open conversation window (exact title). Cheapest path.
        if let existingWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return ChatWindowResolution(window: existingWindow, method: .existingWindow)
        }

        // 2) Optimistic fast path: if the target chat is visible in the chat
        // list, press its row directly. This reuses the proven ChatListScanner
        // (the same scan `ktok chats` relies on) and skips the slow, brittle
        // search-field dance (focus → clear → type → 0.6s wait → ambiguous-
        // result refusal). Most sends/reads target a recent room that is
        // already near the top of the visible list, so this is the common case.
        let searchWindow = selectSearchWindow(fallback: usableWindow)
        if let rowWindow = openVisibleExactChatRow(
            query: query,
            rootWindow: searchWindow,
            fallbackWindow: usableWindow
        ) {
            return ChatWindowResolution(window: rowWindow, method: .openedViaVisibleRow)
        }

        // 2b) The visible-row scan only sees the currently-rendered rows. If the
        // Friends tab is active (or the row was not rendered yet), switch to the
        // chatrooms tab once and retry before paying for the search flow.
        activateChatroomsTab(in: searchWindow)
        let chatroomsRoot = selectSearchWindow(fallback: usableWindow)
        if let rowWindow = openVisibleExactChatRow(
            query: query,
            rootWindow: chatroomsRoot,
            fallbackWindow: usableWindow
        ) {
            return ChatWindowResolution(window: rowWindow, method: .openedViaVisibleRow)
        }

        // 3) Fallback: the room is not open and not visible in the list (needs
        // scrolling/search) — use the heavier search-field flow.
        let chatWindow = try openChatViaSearch(query: query, in: chatroomsRoot, fallbackWindow: usableWindow)
        return ChatWindowResolution(window: chatWindow, method: .openedViaSearch)
    }

    @discardableResult
    func closeWindow(_ window: UIElement) -> Bool {
        let closeAction = "AXClose"

        // Prefer AX close paths that work on a *background* window so closing a
        // chat after a focus-free send does not yank KakaoTalk to the front.
        // Only the Cmd+W keyboard fallback below needs the app foregrounded.
        if supportsAction(closeAction, on: window) {
            do {
                try window.performAction(closeAction)
                if waitForWindowClosed(window, label: "close via AXClose") {
                    return true
                }
            } catch {
                runner.log("close window: AXClose failed (\(error))")
            }
        }

        if let closeButton = findCloseButton(in: window) {
            do {
                try closeButton.press()
                if waitForWindowClosed(window, label: "close via button") {
                    return true
                }
            } catch {
                runner.log("close window: button press failed (\(error))")
            }
        }

        runner.log("close window: fallback via cmd+w")
        kakao.activate()
        _ = tryRaiseWindow(window)
        guard runKakaoKeyboardFallback(label: "close window Cmd+W fallback", action: { runner.pressCommandW() }) else {
            runner.log("close window: Cmd+W fallback skipped because KakaoTalk is not frontmost")
            return false
        }
        return waitForWindowClosed(window, label: "close via cmd+w")
    }

    private func requireUsableWindow() throws -> UIElement {
        if let immediateWindow = kakao.focusedWindow ?? kakao.mainWindow ?? kakao.windows.first {
            runner.log("Usable window found via immediate probe")
            return immediateWindow
        }

        if let usableWindow = kakao.ensureMainWindow(timeout: 0.9, mode: .fast, trace: { message in
            runner.log(message)
        }) {
            return usableWindow
        }

        runner.log("window fast path failed; attempting one-shot open defense")
        if let usableWindow = attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: !deepRecoveryEnabled) {
            return usableWindow
        }

        guard deepRecoveryEnabled else {
            runner.log("window fast path failed; deep recovery disabled")
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Usable KakaoTalk window unavailable (fast mode)")
        }

        runner.log("window: escalating to full recovery (3.0s)")
        if let usableWindow = kakao.ensureMainWindow(timeout: 3.0, mode: .recovery, trace: { message in
            runner.log(message)
        }) {
            return usableWindow
        }

        throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Usable KakaoTalk window unavailable")
    }

    private func attemptQuickOpenDefense(forceOpenEvenIfWindowPresent: Bool) -> UIElement? {
        runner.log("window: quick-open defense start")

        let hasVisibleWindow = kakao.focusedWindow != nil || kakao.mainWindow != nil || !kakao.windows.isEmpty
        if forceOpenEvenIfWindowPresent || !hasVisibleWindow {
            if KakaoTalkApp.isRunning {
                if hasVisibleWindow && forceOpenEvenIfWindowPresent {
                    runner.log("window: forcing open /Applications/KakaoTalk.app (fast-mode fallback)")
                } else {
                    runner.log("window: no visible windows; forcing open /Applications/KakaoTalk.app")
                }
                _ = KakaoTalkApp.forceOpen(timeout: 0.8)
            } else {
                runner.log("window: KakaoTalk not running; launching")
                _ = KakaoTalkApp.launch(timeout: 0.8)
            }
        } else {
            runner.log("window: quick-open defense skipped (windows already present)")
        }

        kakao.activate()
        if let usableWindow = kakao.ensureMainWindow(timeout: 0.8, mode: .fast, trace: { message in
            runner.log(message)
        }) {
            runner.log("window: quick-open defense succeeded")
            return usableWindow
        }

        runner.log("window: quick-open defense failed")
        return nil
    }

    private func selectSearchWindow(fallback: UIElement) -> UIElement {
        if let chatListWindow = kakao.chatListWindow {
            runner.log("search root selected: chatListWindow")
            return chatListWindow
        }
        if let mainWindow = kakao.mainWindow {
            runner.log("search root selected: mainWindow")
            return mainWindow
        }
        runner.log("search root selected: fallback usable window")
        return fallback
    }

    private func openChatViaSearch(query: String, in rootWindow: UIElement, fallbackWindow: UIElement) throws -> UIElement {
        // KakaoTalk's default tab is often "friends" — its search field only
        // returns friends, so group-chat queries come back empty. Activate the
        // chatrooms tab first and then re-select the search root because Cmd+2
        // or a tab press can change the focused/main window reference.
        activateChatroomsTab(in: rootWindow)
        let searchRoot = selectSearchWindow(fallback: fallbackWindow)

        runner.log("search: locating search field")

        let searchField = locateSearchField(in: searchRoot)
            ?? recoverSearchFieldWithKeyboardShortcut(in: searchRoot)
            ?? recoverSearchFieldWithGeometryClick(in: searchRoot)

        guard let searchField else {
            if let geometryWindow = openChatWithBlindGeometrySearch(
                query: query,
                rootWindow: searchRoot,
                fallbackWindow: fallbackWindow
            ) {
                return geometryWindow
            }
            if let visibleRowWindow = openVisibleExactChatRow(
                query: query,
                rootWindow: searchRoot,
                fallbackWindow: fallbackWindow
            ) {
                return visibleRowWindow
            }
            throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] Search field not found after Chats tab activation")
        }

        let searchFieldFocused = runner.focusWithVerification(searchField, label: "search field", attempts: 1)
        if !searchFieldFocused {
            runner.log("search field: focus verification failed; trying AXValue set before typing fallback")
        }

        _ = runner.setTextWithVerification("", on: searchField, label: "search field clear", attempts: 1)

        let searchInputReady =
            runner.setTextWithVerification(query, on: searchField, label: "search field input", attempts: 1) ||
            (searchFieldFocused && typeIntoSearchFieldIfSafe(query, searchField: searchField))

        guard searchInputReady else {
            dismissKakaoSearchIfSafe(label: "search input cleanup")
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.inputNotReflected.rawValue)] Search keyword was not entered")
        }

        let matchingCandidates = waitForMatchingSearchResults(query: query, rootWindow: searchRoot)
        guard let matchingResult = pickBestSearchResult(from: matchingCandidates) else {
            dismissKakaoSearchIfSafe(label: "search miss cleanup")
            throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] No search result found for '\(query)'")
        }

        let openTriggered = triggerSearchResultOpen(
            matchingResult,
            searchField: searchField
        ) {
            resolveOpenedChatWindowFast(query: query) != nil
        }
        guard openTriggered else {
            dismissKakaoSearchIfSafe(label: "search open cleanup")
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.searchMiss.rawValue)] Could not open matched search result")
        }

        if let window = waitForOpenedChatWindow(query: query, fallbackWindow: fallbackWindow) {
            return window
        }

        throw KakaoTalkError.windowNotFound("[\(ChatWindowFailureCode.windowNotReady.rawValue)] Chat window for '\(query)' did not open")
    }

    private func resolveCachedElement(
        slot: AXPathSlot,
        root: UIElement,
        validate: (UIElement) -> Bool
    ) -> UIElement? {
        guard useCache else { return nil }
        return AXPathCacheStore.shared.resolve(
            slot: slot,
            root: root,
            validate: validate,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func rememberCachedElement(slot: AXPathSlot, root: UIElement, element: UIElement) {
        guard useCache else { return }
        AXPathCacheStore.shared.remember(
            slot: slot,
            root: root,
            element: element,
            trace: { message in
                runner.log(message)
            }
        )
    }

    private func activateChatroomsTab(in rootWindow: UIElement) {
        kakao.activate()
        Thread.sleep(forTimeInterval: 0.08)
        let buttons = rootWindow.findAll(role: kAXButtonRole, limit: 24, maxNodes: 220)
        guard let chatroomsButton = buttons.first(where: {
            ($0.identifier ?? "").lowercased() == "chatrooms"
        }) else {
            runner.log("tab: 'chatrooms' button not found in search root; trying Window > Chats menu item")
            if activateChatsMenuItem() {
                Thread.sleep(forTimeInterval: 0.15)
                return
            }
            runner.log("tab: Chats menu item unavailable; falling back to Cmd+2")
            if runKakaoKeyboardFallback(label: "tab Cmd+2 fallback", action: { runner.pressCommandNumber(2) }) {
                Thread.sleep(forTimeInterval: 0.2)
            } else {
                runner.log("tab: Cmd+2 fallback skipped because KakaoTalk is not frontmost")
            }
            return
        }
        do {
            try chatroomsButton.press()
            runner.log("tab: chatrooms tab activated")
            Thread.sleep(forTimeInterval: 0.1)
        } catch {
            runner.log("tab: chatrooms press failed (\(error)); continuing with current tab")
        }
    }

    private func activateChatsMenuItem() -> Bool {
        let menuBarItems = kakao.applicationElement.findAll(role: kAXMenuBarItemRole, limit: 32, maxNodes: 400)
        guard let windowMenuBarItem = menuBarItems.first(where: { ($0.title ?? "") == "Window" }) else {
            runner.log("tab: Window menu bar item not found")
            return false
        }
        let menuItems = windowMenuBarItem.findAll(role: kAXMenuItemRole, limit: 64, maxNodes: 240)
        guard let chatsItem = menuItems.first(where: { item in
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return title == "Chats" || title == "채팅"
        }) else {
            runner.log("tab: Window > Chats menu item not found")
            return false
        }
        do {
            try chatsItem.press()
            runner.log("tab: activated Chats via menu item")
            return true
        } catch {
            runner.log("tab: Chats menu item press failed (\(error))")
            return false
        }
    }

    private func locateSearchField(in rootWindow: UIElement) -> UIElement? {
        if let cachedSearchField = resolveCachedElement(
            slot: .searchField,
            root: rootWindow,
            validate: { field in
                field.isEnabled && field.role == kAXTextFieldRole
            }
        ) {
            return cachedSearchField
        }

        if let field = findAndRememberSearchField(in: rootWindow) {
            return field
        }

        // KakaoTalk 26.x often renders the Chats search box collapsed behind a
        // toolbar icon.  The icon is sometimes unlabeled in AX, so a text-only
        // button search misses it.  Probe only AXButton elements exposed by the
        // KakaoTalk AX tree, score them by accessibility metadata first and by
        // safe header geometry second, and press the best AX button with AXPress.
        // This is intentionally not a mouse/coordinate click fallback: no screen
        // coordinates are clicked and no search result is opened unless later
        // exact-title verification succeeds.
        let searchButtons = discoverSearchButtonCandidates(in: rootWindow)
        runner.log("search: AX search-button probe candidates=\(searchButtons.count)")

        for button in searchButtons.prefix(4) {
            do {
                try button.press()
                runner.log("search: pressed AX search probe button title='\(button.title ?? "")' id='\(button.identifier ?? "")'")
            } catch {
                runner.log("search: AX search probe button press failed (\(error))")
            }

            Thread.sleep(forTimeInterval: 0.12)
            if let field = findAndRememberSearchField(in: rootWindow) {
                runner.log("search: field exposed after AX search-button probe")
                return field
            }
        }

        return nil
    }

    private func findAndRememberSearchField(in rootWindow: UIElement) -> UIElement? {
        let fields = discoverSearchFieldCandidates(in: rootWindow)
        if let field = pickSearchField(from: fields) {
            rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
            return field
        }
        return nil
    }

    private func recoverSearchFieldWithKeyboardShortcut(in rootWindow: UIElement) -> UIElement? {
        runner.log("search: attempting bounded keyboard fallback Cmd+F")
        guard ensureKakaoFrontmost(label: "search Cmd+F fallback") else {
            runner.log("search: Cmd+F fallback skipped because KakaoTalk is not frontmost; HID events would target another app/session")
            return nil
        }
        runner.pressCommandF()
        Thread.sleep(forTimeInterval: 0.18)
        if let field = findAndRememberSearchField(in: rootWindow) {
            runner.log("search: field exposed after Cmd+F fallback")
            return field
        }
        runner.log("search: Cmd+F fallback did not expose AX search field")
        return nil
    }

    private func recoverSearchFieldWithGeometryClick(in rootWindow: UIElement) -> UIElement? {
        let probes = searchIconGeometryProbePoints(rootWindow: rootWindow)
        guard !probes.isEmpty else {
            runner.log("search: geometry fallback unavailable; no KakaoTalk onscreen window bounds")
            return nil
        }

        runner.log("search: attempting bounded geometry fallback probeCount=\(probes.count) reason=AX search controls unavailable")
        for (index, probe) in probes.enumerated() {
            guard ensureKakaoFrontmost(label: "search geometry fallback probe \(index + 1)") else {
                runner.log("search: geometry probe \(index + 1) skipped because KakaoTalk is not frontmost; HID click would target another app/session")
                break
            }
            runner.log(
                "search: geometry probe \(index + 1)/\(probes.count) bounds=\(formatRect(probe.windowBounds)) point=\(formatPoint(probe.point)) rel=\(probe.relativeDescription)"
            )
            guard runner.clickScreenPoint(probe.point, label: "search geometry fallback") else {
                continue
            }
            Thread.sleep(forTimeInterval: 0.45)
            if let field = findAndRememberSearchField(in: rootWindow) {
                runner.log("search: field exposed after geometry fallback probe \(index + 1)")
                return field
            }
        }

        runner.log("search: geometry fallback did not expose AX search field after \(probes.count) probes")
        return nil
    }

    private func openChatWithBlindGeometrySearch(query: String, rootWindow: UIElement, fallbackWindow: UIElement) -> UIElement? {
        // Deliberately conservative: geometry clicks are allowed as bounded,
        // logged recovery, but text entry is not allowed unless an input target
        // or exact AX result is verified.  Typing query+Enter into an unknown
        // focused element can send to a wrong already-open chat.
        runner.log("search: blind geometry typing/open disabled; no verified search field or exact AX result")
        return nil
    }

    private func discoverSearchButtonCandidates(in rootWindow: UIElement) -> [UIElement] {
        var roots: [UIElement] = [rootWindow]
        if let focusedWindow = kakao.focusedWindow { roots.append(focusedWindow) }
        if let mainWindow = kakao.mainWindow { roots.append(mainWindow) }
        roots = deduplicateElements(roots)

        let pressableRoles: Set<String> = [
            kAXButtonRole,
            kAXGroupRole,
            kAXImageRole,
            kAXCellRole,
        ]

        var scored: [(button: UIElement, score: Int)] = []
        for root in roots {
            let candidates = collectDescendants(
                from: root,
                roles: pressableRoles,
                limit: 80,
                maxNodes: 900,
                includeAlternateChildAttributes: true
            )
            for candidate in candidates {
                let score = scoreSearchProbeButton(candidate, rootWindow: rootWindow)
                guard score > 0 else { continue }
                scored.append((candidate, score))
            }
        }

        let unique = deduplicateElements(
            scored
                .sorted { lhs, rhs in lhs.score > rhs.score }
                .map(\.button)
        )
        if unique.isEmpty {
            runner.log("search: AX search-button probe saw no safe pressable header candidates")
        }
        return unique
    }

    private func scoreSearchProbeButton(_ button: UIElement, rootWindow: UIElement) -> Int {
        let identifier = (button.identifier ?? "").lowercased()
        if identifier == "friends" || identifier == "chatrooms" || identifier == "more" {
            return 0
        }
        guard supportsAction("AXPress", on: button) else { return 0 }

        let title = (button.title ?? "").lowercased()
        let description = (button.axDescription ?? "").lowercased()
        let joined = [identifier, title, description].joined(separator: " ")
        let hasSearchMetadata = joined.contains("search") || joined.contains("검색")
        guard let geometryScore = scoreHeaderSearchButtonGeometry(button, rootWindow: rootWindow) else {
            return 0
        }

        var score = geometryScore
        if hasSearchMetadata {
            score += 10_000
        }

        // Keep the probe conservative: the element must be an AX-pressable
        // control in the chat-list header geometry. Search metadata boosts the
        // score, but does not override the geometry/root containment guard.
        return score >= 1_000 ? score : 0
    }

    private func scoreHeaderSearchButtonGeometry(_ button: UIElement, rootWindow: UIElement) -> Int? {
        guard
            let buttonFrame = button.frame,
            let windowFrame = rootWindow.frame,
            windowFrame.width > 0,
            windowFrame.height > 0,
            isElementLikelyInsideWindow(elementFrame: buttonFrame, windowFrame: windowFrame)
        else {
            return nil
        }

        let relativeX = (buttonFrame.midX - windowFrame.minX) / windowFrame.width
        let relativeY = (buttonFrame.midY - windowFrame.minY) / windowFrame.height
        let side = buttonFrame.width
        let height = buttonFrame.height

        guard side >= 10, side <= 48, height >= 10, height <= 48 else { return nil }
        guard relativeY >= 0.03, relativeY <= 0.22 else { return nil }
        guard relativeX >= 0.62, relativeX <= 0.92 else { return nil }

        // The compose/new-chat button sits farther right than the search icon in
        // the Chats header.  Favor the left member of the top-right button group.
        let distanceFromExpectedSearchX = abs(relativeX - 0.82)
        let geometryScore = max(0, 4_000 - Int(distanceFromExpectedSearchX * 10_000))
        return 1_000 + geometryScore
    }

    private func discoverSearchFieldCandidates(in rootWindow: UIElement) -> [UIElement] {
        var fields: [UIElement] = []
        fields.append(contentsOf: collectDescendants(
            from: rootWindow,
            roles: [kAXTextFieldRole],
            limit: 12,
            maxNodes: 220,
            includeAlternateChildAttributes: true
        ))
        if let focusedWindow = kakao.focusedWindow {
            fields.append(contentsOf: collectDescendants(
                from: focusedWindow,
                roles: [kAXTextFieldRole],
                limit: 12,
                maxNodes: 220,
                includeAlternateChildAttributes: true
            ))
        }
        if let mainWindow = kakao.mainWindow {
            fields.append(contentsOf: collectDescendants(
                from: mainWindow,
                roles: [kAXTextFieldRole],
                limit: 12,
                maxNodes: 220,
                includeAlternateChildAttributes: true
            ))
        }
        return deduplicateElements(fields).filter { $0.isEnabled }
    }

    private func collectDescendants(
        from root: UIElement,
        roles: Set<String>,
        limit: Int,
        maxNodes: Int,
        includeAlternateChildAttributes: Bool
    ) -> [UIElement] {
        var results: [UIElement] = []
        var queue = childElements(of: root, includeAlternateChildAttributes: includeAlternateChildAttributes)
        var visited: [UIElement] = []
        var index = 0

        while index < queue.count && visited.count < maxNodes && results.count < limit {
            let current = queue[index]
            index += 1
            if visited.contains(where: { areSameAXElement($0, current) }) {
                continue
            }
            visited.append(current)

            if let role = current.role, roles.contains(role) {
                results.append(current)
                if results.count >= limit { break }
            }

            let children = childElements(of: current, includeAlternateChildAttributes: includeAlternateChildAttributes)
            for child in children where !visited.contains(where: { areSameAXElement($0, child) }) {
                queue.append(child)
            }
        }

        return deduplicateElements(results)
    }

    private func childElements(of element: UIElement, includeAlternateChildAttributes: Bool) -> [UIElement] {
        var children = element.children
        guard includeAlternateChildAttributes else {
            return deduplicateElements(children)
        }

        let alternateAttributes = [
            "AXVisibleChildren",
            "AXChildrenInNavigationOrder",
            "AXContents",
        ]
        for attributeName in alternateAttributes {
            if let axChildren: [AXUIElement] = element.attributeOptional(attributeName) {
                children.append(contentsOf: axChildren.map { UIElement($0) })
            }
        }

        return deduplicateElements(children)
    }

    private func waitForMatchingSearchResults(query: String, rootWindow: UIElement) -> [SearchCandidate] {
        let fastProfile = SearchScanProfile(
            label: "fast",
            timeout: 0.22,
            pollInterval: 0.04,
            rowLimit: 24,
            cellLimit: 24,
            supplementalLimit: 0,
            candidateNodeBudget: 320,
            textLimit: 6,
            textNodeBudget: 80,
            includeSupplementalRoles: false,
            includeApplicationRoot: false
        )
        let expandedProfile = SearchScanProfile(
            label: "expanded",
            timeout: 0.75,
            pollInterval: 0.05,
            rowLimit: 120,
            cellLimit: 120,
            supplementalLimit: 80,
            candidateNodeBudget: 1_200,
            textLimit: 16,
            textNodeBudget: 220,
            includeSupplementalRoles: true,
            includeApplicationRoot: true
        )

        var matches: [SearchCandidate] = []
        let foundFast = runner.waitUntil(label: "search results (\(fastProfile.label))", timeout: fastProfile.timeout, pollInterval: fastProfile.pollInterval) {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: fastProfile)
            return !matches.isEmpty
        }
        if !foundFast {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: fastProfile)
        }
        if !matches.isEmpty {
            runner.log("search: matching candidates=\(matches.count) via \(fastProfile.label)")
            return matches
        }

        runner.log("search: no matches in fast scan; expanding search scope")
        let foundExpanded = runner.waitUntil(label: "search results (\(expandedProfile.label))", timeout: expandedProfile.timeout, pollInterval: expandedProfile.pollInterval) {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: expandedProfile)
            return !matches.isEmpty
        }
        if !foundExpanded {
            matches = findMatchingSearchResults(query: query, rootWindow: rootWindow, profile: expandedProfile)
        }
        runner.log("search: matching candidates=\(matches.count)")
        return matches
    }

    private func findMatchingSearchResults(
        query: String,
        rootWindow: UIElement,
        profile: SearchScanProfile
    ) -> [SearchCandidate] {
        var roots: [UIElement] = [rootWindow]
        if let focusedWindow = kakao.focusedWindow {
            roots.append(focusedWindow)
        }
        if let mainWindow = kakao.mainWindow {
            roots.append(mainWindow)
        }
        if profile.includeApplicationRoot {
            roots.append(kakao.applicationElement)
        }
        roots = deduplicateElements(roots)

        var results: [SearchCandidate] = []
        for root in roots {
            var candidates: [UIElement] = []
            candidates.append(contentsOf: root.findAll(role: kAXRowRole, limit: profile.rowLimit, maxNodes: profile.candidateNodeBudget))
            candidates.append(contentsOf: root.findAll(role: kAXCellRole, limit: profile.cellLimit, maxNodes: profile.candidateNodeBudget))

            if profile.includeSupplementalRoles {
                candidates.append(contentsOf: root.findAll(role: kAXGroupRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
                candidates.append(contentsOf: root.findAll(role: kAXButtonRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
                candidates.append(contentsOf: root.findAll(role: kAXStaticTextRole, limit: profile.supplementalLimit, maxNodes: profile.candidateNodeBudget))
            }

            candidates = deduplicateElements(candidates)
            for candidate in candidates {
                let (matchScore, matchedText) = bestQueryMatch(
                    query: query,
                    in: candidate,
                    textLimit: profile.textLimit,
                    textNodeBudget: profile.textNodeBudget
                )
                guard matchScore > 0, let matchedText else { continue }
                let activationCandidate = activationTarget(for: candidate)
                results.append(
                    SearchCandidate(
                        element: activationCandidate,
                        textScore: matchScore,
                        matchedText: matchedText
                    )
                )
            }

            if !results.isEmpty && !profile.includeSupplementalRoles {
                break
            }
        }

        return deduplicateSearchCandidates(results)
    }

    private func waitForOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement? {
        var resolved: UIElement?
        _ = runner.waitUntil(label: "chat context ready", timeout: 0.8, pollInterval: 0.05, evaluateAfterTimeout: false) {
            resolved = resolveOpenedChatWindowFast(query: query)
            return resolved != nil
        }
        return resolved ?? resolveOpenedChatWindow(query: query, fallbackWindow: fallbackWindow)
    }

    private func openVisibleExactChatRow(query: String, rootWindow: UIElement, fallbackWindow: UIElement) -> UIElement? {
        runner.log("resolve: probing visible chat-list rows by exact title")
        let visibleRows = ChatListScanner().scan(in: rootWindow, limit: 80) { message in
            runner.log("search-row: \(message)")
        }
        let matches = visibleRows.filter { snapshot in
            scoreQueryMatch(query: query, candidateText: snapshot.discovery.title) > 0
        }

        guard matches.count == 1, let match = matches.first else {
            runner.log("search: visible exact-row fallback refused; matches=\(matches.count)")
            return nil
        }

        runner.log("search: visible exact-row candidate title='\(match.discovery.title)' index=\(match.discovery.listIndex)")
        if tryActivateSearchResult(match.element, label: "visible-chat-row") {
            if let opened = waitForOpenedChatWindow(query: query, fallbackWindow: fallbackWindow) {
                return opened
            }
            runner.log("search: visible exact-row AXPress/AXConfirm was not verified; refusing Enter fallback")
            return nil
        }

        let selected = trySelectSearchResult(match.element, label: "visible-chat-row")
        guard selected, isElementSelected(match.element) else {
            runner.log("search: visible exact-row selection was not verified; refusing Enter fallback")
            return nil
        }

        runner.log("search: visible exact-row selected; confirming via Enter")
        // Prefer delivering Enter straight to KakaoTalk's process so a selected
        // row opens even when KakaoTalk is in the background (e.g. bot/monitor
        // running behind the user's app). postToPid is background-safe: the key
        // reaches KakaoTalk only, never another frontmost app.
        if let pid = kakao.processIdentifier {
            runner.pressEnterKey(toPID: pid)
            if let opened = waitForOpenedChatWindow(query: query, fallbackWindow: fallbackWindow) {
                return opened
            }
            runner.log("search: postToPid Enter did not open window; trying frontmost keyboard fallback")
        }
        guard runKakaoKeyboardFallback(label: "visible exact-row Enter fallback", action: { runner.pressEnterKey() }) else {
            runner.log("search: visible exact-row Enter fallback skipped because KakaoTalk is not frontmost")
            return nil
        }
        if let opened = waitForOpenedChatWindow(query: query, fallbackWindow: fallbackWindow) {
            return opened
        }

        runner.log("search: visible exact-row fallback did not open verified exact-title window")
        return nil
    }

    private func resolveOpenedChatWindowFast(query: String) -> UIElement? {
        if let matchedWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return matchedWindow
        }

        if let focusedWindow = kakao.focusedWindow,
           let title = focusedWindow.title,
           scoreQueryMatch(query: query, candidateText: title) > 0
        {
            return focusedWindow
        }

        return nil
    }

    private func resolveOpenedChatWindow(query: String, fallbackWindow: UIElement) -> UIElement? {
        // Safety: after an exact search-result match, only accept a chat window
        // whose title also matches exactly after normalization. Do not fall back
        // to "likely chat input" windows here; that can turn a wrong opened room
        // into a valid send target.
        return resolveOpenedChatWindowFast(query: query)
    }

    private func windowContainsLikelyChatInput(_ window: UIElement) -> Bool {
        if window.findFirst(where: { element in
            guard element.isEnabled else { return false }
            return element.role == kAXTextAreaRole
        }) != nil {
            return true
        }

        return window.findFirst(where: { element in
            isLikelyMessageInputElement(element, in: window) && element.role != kAXTextFieldRole
        }) != nil
    }

    private func isLikelyMessageInputElement(_ element: UIElement, in window: UIElement? = nil) -> Bool {
        guard element.isEnabled else { return false }
        let role = element.role ?? ""
        if role == kAXTextAreaRole {
            return true
        }

        let editable: Bool = element.attributeOptional(kAXEditableAttribute) ?? false
        guard editable else { return false }
        guard role != kAXStaticTextRole && role != kAXImageRole else { return false }
        if role == kAXTextFieldRole, isLikelySearchField(element, in: window) {
            return false
        }
        return true
    }

    private func isLikelySearchField(_ element: UIElement, in window: UIElement?) -> Bool {
        let role = element.role ?? ""
        guard role == kAXTextFieldRole else { return false }

        let joinedText = [
            element.identifier ?? "",
            element.title ?? "",
            element.axDescription ?? "",
        ]
        .joined(separator: " ")
        .lowercased()

        if joinedText.contains("search") || joinedText.contains("검색") {
            return true
        }

        guard let windowFrame = window?.frame, let elementFrame = element.frame, windowFrame.height > 0 else {
            return false
        }

        if !isElementLikelyInsideWindow(elementFrame: elementFrame, windowFrame: windowFrame) {
            return true
        }

        let relativeY = (elementFrame.midY - windowFrame.minY) / windowFrame.height
        return relativeY < 0.5
    }

    private func pickBestSearchResult(from candidates: [SearchCandidate]) -> UIElement? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.count == 1 else {
            runner.log("search: refusing ambiguous exact search candidates count=\(candidates.count)")
            return nil
        }
        let best = candidates.max { lhs, rhs in
            scoreSearchResult(lhs) < scoreSearchResult(rhs)
        }
        if let best {
            runner.log(
                "search: best result role='\(best.element.role ?? "unknown")' title='\(best.element.title ?? "")' textScore=\(best.textScore) matched='\(best.matchedText)'"
            )
        }
        return best?.element
    }

    private func scoreSearchResult(_ candidate: SearchCandidate) -> Int {
        var score = candidate.textScore * 4
        let element = candidate.element
        if supportsAction("AXPress", on: element) {
            score += 4_000
        }
        if supportsAction("AXConfirm", on: element) {
            score += 3_000
        }
        if element.role == kAXRowRole {
            score += 1_600
        } else if element.role == kAXCellRole {
            score += 1_200
        } else if element.role == kAXButtonRole {
            score += 800
        }
        if let title = element.title, !title.isEmpty {
            score += 300
        }
        if element.role == nil || element.role?.isEmpty == true {
            score -= 2_000
        }
        return score
    }

    private func triggerSearchResultOpen(
        _ result: UIElement,
        searchField: UIElement,
        opened: () -> Bool
    ) -> Bool {
        var didTriggerAction = false

        if tryActivateSearchResult(result, label: "result") {
            didTriggerAction = true
            if runner.waitUntil(label: "search open confirm", timeout: 0.24, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                return true
            }
        }
        runner.log("search: direct activate miss; skipping heavy neighbor scan for speed")

        let selected = trySelectSearchResult(result, label: "result")
        if !selected, let parent = result.parent {
            let parentSelected = trySelectSearchResult(parent, label: "result.parent")
            didTriggerAction = didTriggerAction || parentSelected
        }
        didTriggerAction = didTriggerAction || selected
        if selected,
           runner.waitUntil(label: "search open confirm", timeout: 0.14, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened)
        {
            return true
        }

        if selected {
            kakao.activate()
            if runner.focusWithVerification(searchField, label: "search field confirm", attempts: 1) {
                runner.log("search: fallback confirm via Enter")
                guard runKakaoKeyboardFallback(label: "search confirm Enter fallback", action: { runner.pressEnterKey() }) else {
                    runner.log("search: fallback confirm Enter skipped because KakaoTalk is not frontmost")
                    return didTriggerAction
                }
                didTriggerAction = true
                if runner.waitUntil(label: "search open confirm", timeout: 0.18, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                    return true
                }
            } else {
                runner.log("search: fallback confirm skipped (search field focus failed)")
            }
        } else {
            runner.log("search: skipping Enter fallback because result selection was not available")
        }

        runner.log("search: Down+Enter fallback disabled; refusing to open non-selected search results")
        return didTriggerAction
    }

    private func tryActivateSearchResult(_ element: UIElement, label: String) -> Bool {
        if let actions = try? element.actionNames(), !actions.isEmpty {
            runner.log("search: \(label) actions=\(actions.joined(separator: ","))")
        }

        do {
            if supportsAction("AXPress", on: element) {
                try element.press()
                runner.log("search: \(label) activated via AXPress")
                return true
            }
        } catch {
            runner.log("search: \(label) AXPress failed (\(error))")
        }

        do {
            if supportsAction("AXConfirm", on: element) {
                try element.performAction("AXConfirm")
                runner.log("search: \(label) activated via AXConfirm")
                return true
            }
        } catch {
            runner.log("search: \(label) AXConfirm failed (\(error))")
        }

        return false
    }

    private func trySelectSearchResult(_ element: UIElement, label: String) -> Bool {
        do {
            try element.setAttribute("AXSelected", value: true as CFBoolean)
            runner.log("search: \(label) selected via AXSelected=true")
            return true
        } catch {
            runner.log("search: \(label) select failed (\(error))")
            return false
        }
    }

    private func isElementSelected(_ element: UIElement) -> Bool {
        element.attributeOptional("AXSelected") ?? false
    }

    private func supportsAction(_ action: String, on element: UIElement) -> Bool {
        guard let actions = try? element.actionNames() else { return false }
        return actions.contains(action)
    }

    private func findMatchingChatWindow(in windows: [UIElement], query: String) -> UIElement? {
        let matches = windows.compactMap { window -> (window: UIElement, score: Int)? in
            guard let title = window.title else { return nil }
            let score = scoreQueryMatch(query: query, candidateText: title)
            guard score > 0 else { return nil }
            return (window, score)
        }
        guard matches.count <= 1 else {
            runner.log("window: refusing ambiguous exact-title windows count=\(matches.count) query='\(query)'")
            return nil
        }
        return matches.max(by: { lhs, rhs in
            lhs.score < rhs.score
        })?.window
    }

    private func bestQueryMatch(
        query: String,
        in element: UIElement,
        textLimit: Int,
        textNodeBudget: Int
    ) -> (score: Int, matchedText: String?) {
        let candidateTexts = collectCandidateTexts(
            from: element,
            textLimit: textLimit,
            textNodeBudget: textNodeBudget
        )
        guard !candidateTexts.isEmpty else { return (0, nil) }

        var bestScore = 0
        var bestText: String?
        for candidateText in candidateTexts {
            let score = scoreQueryMatch(query: query, candidateText: candidateText)
            if score > bestScore {
                bestScore = score
                bestText = candidateText
            }
        }

        return (bestScore, bestText)
    }

    private func collectCandidateTexts(
        from element: UIElement,
        textLimit: Int,
        textNodeBudget: Int
    ) -> [String] {
        var texts: [String] = []

        func appendText(_ raw: String?) {
            guard let raw else { return }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            texts.append(trimmed)
        }

        appendText(element.title)
        appendText(element.stringValue)
        appendText(element.axDescription)

        let staticTexts = element.findAll(
            role: kAXStaticTextRole,
            limit: textLimit,
            maxNodes: textNodeBudget
        )
        for staticText in staticTexts {
            appendText(staticText.stringValue)
        }

        let textAreas = element.findAll(
            role: kAXTextAreaRole,
            limit: max(2, textLimit / 2),
            maxNodes: textNodeBudget
        )
        for textArea in textAreas {
            appendText(textArea.stringValue)
        }

        return deduplicateStringsPreservingOrder(texts)
    }

    private func scoreQueryMatch(query: String, candidateText: String) -> Int {
        let queryNormalized = normalizeSearchToken(query)
        let candidateNormalized = normalizeSearchToken(candidateText)
        guard !queryNormalized.isEmpty, !candidateNormalized.isEmpty else { return 0 }

        // Recipient/window safety rule: ktok channel resolution must not use
        // partial/contains matching. Search result groups often include message
        // previews and other neighboring text; opening a result because some
        // descendant merely contains the query can target the wrong room. Allow
        // only normalized exact equality (whitespace/punctuation/width folded).
        return queryNormalized == candidateNormalized ? 12_000 : 0
    }

    private func normalizeSearchToken(_ text: String) -> String {
        let lowered = text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current).lowercased()
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            if CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar) {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }


    private func deduplicateSearchCandidates(_ candidates: [SearchCandidate]) -> [SearchCandidate] {
        var unique: [SearchCandidate] = []
        unique.reserveCapacity(candidates.count)

        for candidate in candidates {
            if let index = unique.firstIndex(where: { existing in
                areSameAXElement(existing.element, candidate.element)
            }) {
                if candidate.textScore > unique[index].textScore {
                    unique[index] = candidate
                }
                continue
            }
            unique.append(candidate)
        }

        return unique
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)
        for element in elements {
            if unique.contains(where: { existing in
                areSameAXElement(existing, element)
            }) {
                continue
            }
            unique.append(element)
        }

        return unique
    }

    private func deduplicateStringsPreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values {
            if seen.contains(value) {
                continue
            }
            seen.insert(value)
            unique.append(value)
        }

        return unique
    }

    private func activationTarget(for element: UIElement) -> UIElement {
        if isSearchActivationRole(element.role) {
            return element
        }

        var cursor = element.parent
        var hops = 0
        while let current = cursor, hops < 4 {
            if isSearchActivationRole(current.role) {
                return current
            }
            cursor = current.parent
            hops += 1
        }

        return element
    }

    private func isSearchActivationRole(_ role: String?) -> Bool {
        switch role {
        case kAXRowRole, kAXCellRole, kAXButtonRole, kAXGroupRole:
            return true
        default:
            return false
        }
    }

    private func pickSearchField(from fields: [UIElement]) -> UIElement? {
        fields
            .filter { $0.isEnabled }
            .sorted { lhs, rhs in
                let lhsY = lhs.position?.y ?? .greatestFiniteMagnitude
                let rhsY = rhs.position?.y ?? .greatestFiniteMagnitude
                return lhsY < rhsY
            }
            .first
    }

    private func tryRaiseWindow(_ window: UIElement) -> Bool {
        if supportsAction(kAXRaiseAction, on: window) {
            do {
                try window.performAction(kAXRaiseAction)
                runner.log("window: raised via AXRaise")
                return true
            } catch {
                runner.log("window: AXRaise failed (\(error))")
            }
        }
        return false
    }

    private func ensureKakaoFrontmost(label: String) -> Bool {
        let before = NSWorkspace.shared.frontmostApplication
        runner.log("\(label): frontmost before bundle='\(before?.bundleIdentifier ?? "")' pid=\(before?.processIdentifier ?? -1)")
        kakao.activate()
        if let rootWindow = kakao.focusedWindow ?? kakao.mainWindow ?? kakao.windows.first {
            _ = tryRaiseWindow(rootWindow)
        }
        let expectedPID = KakaoTalkApp.runningApplication?.processIdentifier
        let becameFrontmost = runner.waitUntil(label: "\(label) frontmost", timeout: 0.6, pollInterval: 0.06, evaluateAfterTimeout: true) {
            guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
            return frontmost.bundleIdentifier == KakaoTalkApp.bundleIdentifier || frontmost.processIdentifier == expectedPID
        }
        let after = NSWorkspace.shared.frontmostApplication
        runner.log("\(label): frontmost after bundle='\(after?.bundleIdentifier ?? "")' pid=\(after?.processIdentifier ?? -1) ok=\(becameFrontmost)")
        return becameFrontmost
    }

    @discardableResult
    private func runKakaoKeyboardFallback(label: String, action: () -> Void) -> Bool {
        guard ensureKakaoFrontmost(label: label) else {
            runner.log("\(label): skipped keyboard HID event because KakaoTalk is not frontmost")
            return false
        }
        action()
        return true
    }

    private func typeIntoSearchFieldIfSafe(_ query: String, searchField: UIElement) -> Bool {
        guard ensureKakaoFrontmost(label: "search field typing fallback") else {
            runner.log("search field input: typing fallback skipped because KakaoTalk is not frontmost")
            return false
        }
        return runner.typeTextWithVerification(query, on: searchField, label: "search field input", attempts: 2)
    }

    private func dismissKakaoSearchIfSafe(label: String) {
        _ = runKakaoKeyboardFallback(label: "\(label) Escape fallback", action: { runner.pressEscape() })
    }

    private func findCloseButton(in window: UIElement) -> UIElement? {
        let buttons = window.findAll(role: kAXButtonRole, limit: 6, maxNodes: 80)
        if let match = buttons.first(where: { button in
            let joined = [
                button.identifier ?? "",
                button.title ?? "",
                button.axDescription ?? "",
            ].joined(separator: " ").lowercased()
            return joined.contains("close") || joined.contains("닫기")
        }) {
            return match
        }

        runner.log("close window: no verified close button found; refusing arbitrary first-button fallback")
        return nil
    }

    private func waitForWindowClosed(_ window: UIElement, label: String) -> Bool {
        runner.waitUntil(label: label, timeout: 0.9, pollInterval: 0.06, evaluateAfterTimeout: false) {
            !kakao.windows.contains { candidate in
                areSameAXElement(candidate, window)
            }
        }
    }

    private func areSameAXElement(_ lhs: UIElement, _ rhs: UIElement) -> Bool {
        CFEqual(lhs.axElement, rhs.axElement)
    }

    private struct GeometryProbe {
        let windowBounds: CGRect
        let point: CGPoint
        let relativeDescription: String
    }

    private func searchIconGeometryProbePoints(rootWindow: UIElement) -> [GeometryProbe] {
        guard let bounds = primaryKakaoOnscreenWindowBounds(preferredFrame: rootWindow.frame) else { return [] }
        // KakaoTalk 26.x chat-list header: search icon is the left member of the
        // top-right toolbar pair. Probe a tiny bounded cluster in the header to
        // tolerate titlebar/theme/version drift. Every point is window-relative
        // and logged before use.
        let xs: [CGFloat] = [0.817, 0.785, 0.850]
        let ys: [CGFloat] = [0.044, 0.055, 0.070]
        return xs.flatMap { x in
            ys.map { y in
                GeometryProbe(
                    windowBounds: bounds,
                    point: CGPoint(x: bounds.minX + bounds.width * x, y: bounds.minY + bounds.height * y),
                    relativeDescription: String(format: "x=%.3f y=%.3f", Double(x), Double(y))
                )
            }
        }
    }

    private func primaryKakaoOnscreenWindowBounds(preferredFrame: CGRect?) -> CGRect? {
        guard let pid = KakaoTalkApp.runningApplication?.processIdentifier else { return nil }
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowInfo = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var candidates: [(bounds: CGRect, area: CGFloat, overlap: CGFloat)] = []
        var rejectedForPID = 0
        for info in windowInfo {
            guard intValue(info[kCGWindowOwnerPID as String]) == Int(pid) else { continue }
            guard intValue(info[kCGWindowLayer as String]) == 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any] else { continue }
            let bounds = CGRect(
                x: numberValue(boundsDict["X"]),
                y: numberValue(boundsDict["Y"]),
                width: numberValue(boundsDict["Width"]),
                height: numberValue(boundsDict["Height"])
            )
            guard bounds.width >= 280, bounds.height >= 360 else {
                rejectedForPID += 1
                continue
            }
            let overlap = preferredFrame.map { bounds.intersection($0).width * bounds.intersection($0).height } ?? 0
            candidates.append((bounds, bounds.width * bounds.height, overlap))
        }

        runner.log("search: CGWindow geometry candidates=\(candidates.count) rejectedSmall=\(rejectedForPID)")
        if let preferred = candidates.max(by: { lhs, rhs in lhs.overlap < rhs.overlap }), preferred.overlap > 0 {
            runner.log("search: selected CGWindow by AX-frame overlap overlap=\(Int(preferred.overlap))")
            return preferred.bounds
        }
        let largest = candidates.max { lhs, rhs in lhs.area < rhs.area }
        if let largest {
            runner.log("search: selected CGWindow by largest area area=\(Int(largest.area))")
        }
        return largest?.bounds
    }

    private func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int32 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private func numberValue(_ value: Any?) -> CGFloat {
        if let value = value as? CGFloat { return value }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        if let value = value as? NSNumber { return CGFloat(truncating: value) }
        return 0
    }

    private func formatRect(_ rect: CGRect) -> String {
        "x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }

    private func formatPoint(_ point: CGPoint) -> String {
        "x=\(Int(point.x)) y=\(Int(point.y))"
    }

    private func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)
        return expandedWindow.intersects(elementFrame)
    }
}
