import ApplicationServices.HIServices
import Foundation

enum ChatWindowResolutionMethod {
    case existingWindow
    case openedViaSearch
}

struct ChatWindowResolution {
    let window: UIElement
    let method: ChatWindowResolutionMethod

    var openedViaSearch: Bool {
        method == .openedViaSearch
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

        if let existingWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return ChatWindowResolution(window: existingWindow, method: .existingWindow)
        }

        let searchWindow = selectSearchWindow(fallback: usableWindow)
        let chatWindow = try openChatViaSearch(query: query, in: searchWindow, fallbackWindow: usableWindow)
        return ChatWindowResolution(window: chatWindow, method: .openedViaSearch)
    }

    @discardableResult
    func closeWindow(_ window: UIElement) -> Bool {
        let closeAction = "AXClose"

        kakao.activate()
        _ = tryRaiseWindow(window)

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
        runner.pressCommandW()
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
        // KakaoTalk's default tab is "friends" — its search field only returns
        // friends, so group-chat queries come back empty. Press the "chatrooms"
        // tab first so the search field scopes to chat rooms. Idempotent
        // (pressing an already-active tab is a no-op) and swallows failure —
        // the downstream search will still log informatively if this was
        // actually required and didn't take.
        activateChatroomsTab(in: rootWindow)

        runner.log("search: locating search field")

        guard let searchField = locateSearchField(in: rootWindow) else {
            throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] Search field not found")
        }

        guard runner.focusWithVerification(searchField, label: "search field", attempts: 1) else {
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.focusFail.rawValue)] Could not focus search field")
        }

        _ = runner.setTextWithVerification("", on: searchField, label: "search field clear", attempts: 1)

        let searchInputReady =
            runner.setTextWithVerification(query, on: searchField, label: "search field input", attempts: 1) ||
            runner.typeTextWithVerification(query, on: searchField, label: "search field input", attempts: 2)

        guard searchInputReady else {
            runner.pressEscape()
            throw KakaoTalkError.actionFailed("[\(ChatWindowFailureCode.inputNotReflected.rawValue)] Search keyword was not entered")
        }

        let matchingCandidates = waitForMatchingSearchResults(query: query, rootWindow: rootWindow)
        guard let matchingResult = pickBestSearchResult(from: matchingCandidates) else {
            runner.pressEscape()
            throw KakaoTalkError.elementNotFound("[\(ChatWindowFailureCode.searchMiss.rawValue)] No search result found for '\(query)'")
        }

        let openTriggered = triggerSearchResultOpen(
            matchingResult,
            searchField: searchField
        ) {
            resolveOpenedChatWindowFast(query: query) != nil
        }
        guard openTriggered else {
            runner.pressEscape()
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
        let buttons = rootWindow.findAll(role: kAXButtonRole, limit: 24, maxNodes: 220)
        guard let chatroomsButton = buttons.first(where: {
            ($0.identifier ?? "").lowercased() == "chatrooms"
        }) else {
            runner.log("tab: 'chatrooms' button not found in search root; leaving active tab as-is")
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

        let initialFields = discoverSearchFieldCandidates(in: rootWindow)
        if let field = pickSearchField(from: initialFields) {
            rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
            return field
        }

        let searchButtons = rootWindow.findAll(role: kAXButtonRole, limit: 24, maxNodes: 220).filter { button in
            let title = (button.title ?? "").lowercased()
            let description = (button.axDescription ?? "").lowercased()
            let identifier = (button.identifier ?? "").lowercased()

            if identifier == "friends" || identifier == "chatrooms" || identifier == "more" {
                return false
            }

            return title.contains("search")
                || title.contains("검색")
                || description.contains("search")
                || description.contains("검색")
                || identifier.contains("search")
        }

        for button in searchButtons.prefix(4) {
            do {
                try button.press()
                runner.log("search: pressed search-like button title='\(button.title ?? "")' id='\(button.identifier ?? "")'")
            } catch {
                runner.log("search: search-like button press failed (\(error))")
            }

            Thread.sleep(forTimeInterval: 0.08)
            let fields = discoverSearchFieldCandidates(in: rootWindow)
            if let field = pickSearchField(from: fields) {
                rememberCachedElement(slot: .searchField, root: rootWindow, element: field)
                return field
            }
        }

        return nil
    }

    private func discoverSearchFieldCandidates(in rootWindow: UIElement) -> [UIElement] {
        var fields: [UIElement] = []
        fields.append(contentsOf: rootWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        if let focusedWindow = kakao.focusedWindow {
            fields.append(contentsOf: focusedWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        }
        if let mainWindow = kakao.mainWindow {
            fields.append(contentsOf: mainWindow.findAll(role: kAXTextFieldRole, limit: 8, maxNodes: 140))
        }
        return fields.filter { $0.isEnabled }
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
        if let fastWindow = resolveOpenedChatWindowFast(query: query) {
            return fastWindow
        }

        if let matchedWindow = findMatchingChatWindow(in: kakao.windows, query: query) {
            return matchedWindow
        }

        if let focusedWindow = kakao.focusedWindow, windowContainsLikelyChatInput(focusedWindow) {
            return focusedWindow
        }

        if windowContainsLikelyChatInput(fallbackWindow) {
            return fallbackWindow
        }

        if let mainWindow = kakao.mainWindow, windowContainsLikelyChatInput(mainWindow) {
            return mainWindow
        }

        return nil
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
                runner.pressEnterKey()
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

        kakao.activate()
        if searchField.isFocused || runner.focusWithVerification(searchField, label: "search field confirm", attempts: 1) {
            runner.log("search: fallback confirm via Down+Enter")
            runner.pressDownArrowKey()
            Thread.sleep(forTimeInterval: 0.03)
            runner.pressEnterKey()
            didTriggerAction = true
            if runner.waitUntil(label: "search open confirm", timeout: 0.22, pollInterval: 0.05, evaluateAfterTimeout: false, condition: opened) {
                return true
            }
        } else {
            runner.log("search: Down+Enter skipped (search field focus unavailable)")
        }

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

    private func supportsAction(_ action: String, on element: UIElement) -> Bool {
        guard let actions = try? element.actionNames() else { return false }
        return actions.contains(action)
    }

    private func findMatchingChatWindow(in windows: [UIElement], query: String) -> UIElement? {
        windows.compactMap { window -> (window: UIElement, score: Int)? in
            guard let title = window.title else { return nil }
            let score = scoreQueryMatch(query: query, candidateText: title)
            guard score > 0 else { return nil }
            return (window, score)
        }
        .max(by: { lhs, rhs in
            lhs.score < rhs.score
        })?
        .window
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

        if queryNormalized == candidateNormalized {
            return 12_000
        }
        if candidateNormalized.hasPrefix(queryNormalized) {
            return 10_500
        }
        if candidateNormalized.contains(queryNormalized) {
            return 9_800
        }
        if queryNormalized.contains(candidateNormalized), candidateNormalized.count >= 2 {
            return 8_800
        }

        let queryVariants = honorificVariants(of: queryNormalized)
        let candidateVariants = honorificVariants(of: candidateNormalized)
        var best = 0

        for queryVariant in queryVariants where !queryVariant.isEmpty {
            for candidateVariant in candidateVariants where !candidateVariant.isEmpty {
                if queryVariant == candidateVariant {
                    best = max(best, 8_700)
                    continue
                }
                if candidateVariant.hasPrefix(queryVariant) {
                    best = max(best, 8_400)
                    continue
                }
                if candidateVariant.contains(queryVariant) {
                    best = max(best, 8_200)
                    continue
                }
                if queryVariant.contains(candidateVariant), candidateVariant.count >= 2 {
                    best = max(best, 7_900)
                }
            }
        }

        if best > 0 {
            return best
        }

        let minLength = min(queryNormalized.count, candidateNormalized.count)
        if minLength >= 2 {
            let shortest = queryNormalized.count <= candidateNormalized.count ? queryNormalized : candidateNormalized
            let longest = queryNormalized.count > candidateNormalized.count ? queryNormalized : candidateNormalized
            if longest.contains(shortest) {
                return 6_600
            }
        }

        return 0
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

    private func honorificVariants(of text: String) -> [String] {
        let suffixes = ["선생님", "님", "씨"]
        var variants = Set<String>([text])
        for suffix in suffixes where text.hasSuffix(suffix) {
            let candidate = String(text.dropLast(suffix.count))
            if !candidate.isEmpty {
                variants.insert(candidate)
            }
        }
        return Array(variants)
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

        return buttons.first
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

    private func isElementLikelyInsideWindow(elementFrame: CGRect, windowFrame: CGRect) -> Bool {
        let expandedWindow = windowFrame.insetBy(dx: -24, dy: -24)
        return expandedWindow.intersects(elementFrame)
    }
}
