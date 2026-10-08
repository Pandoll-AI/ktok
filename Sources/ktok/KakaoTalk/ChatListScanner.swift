import ApplicationServices.HIServices
import Foundation

enum ChatTextNormalizer {
    static func normalize(_ text: String) -> String {
        let lowered = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(lowered.unicodeScalars.count)

        for scalar in lowered.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            if CharacterSet.punctuationCharacters.contains(scalar) { continue }
            if CharacterSet.symbols.contains(scalar) { continue }
            if scalar.value == 0x200B || scalar.value == 0x200C || scalar.value == 0x200D || scalar.value == 0xFEFF {
                continue
            }
            scalars.append(scalar)
        }

        return String(scalars)
    }

    /// English month + day, optional year. Compiled once.
    private static let englishMonthDay = compileTimePattern(
        #"^(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\s+\d{1,2}(?:,\s*\d{4})?$"#
    )
    /// "h:mm AM/PM", optional space.
    private static let clockWithMeridiem = compileTimePattern(
        #"^\d{1,2}:\d{2}\s*(?:am|pm)$"#
    )
    /// "오전/오후 h:mm".
    private static let koreanMeridiemClock = compileTimePattern(
        #"^(?:오전|오후)\s*\d{1,2}:\d{2}$"#
    )
    /// Yesterday/Today and the Korean labels already used on the chat list.
    private static let relativeDay = compileTimePattern(
        #"^(?:yesterday|today|오늘|어제|그저께)$"#
    )
    /// Full weekday names plus the English three-letter forms. Longer names are listed first.
    private static let weekdayName = compileTimePattern(
        #"^(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tue|wed|thu|fri|sat|일요일|월요일|화요일|수요일|목요일|금요일|토요일)$"#
    )
    /// "yyyy. m. d.", "m/d/yy", "yyyy-mm-dd".
    private static let numericDate = compileTimePattern(
        #"^(?:\d{4}\.\s*\d{1,2}\.\s*\d{1,2}\.?|\d{1,2}/\d{1,2}/\d{2,4}|\d{4}-\d{1,2}-\d{1,2})$"#
    )
    /// "N일", "M월 D일", "yyyy년 M월 D일", "N일 전". Not every string that ends in 일.
    private static let koreanDayLabel = compileTimePattern(
        #"^(?:\d{1,2}일|\d{1,2}월\s*\d{1,2}일|\d{4}년\s*\d{1,2}월\s*\d{1,2}일|\d{1,2}일\s*전)$"#
    )

    private static func compileTimePattern(_ pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        } catch {
            preconditionFailure("ChatTextNormalizer pattern failed: \(error)")
        }
    }

    private static func wholeMatch(_ expression: NSRegularExpression, _ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range) != nil
    }

    static func isTimeLikeValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let parts = trimmed.split(separator: ":")
        if parts.count == 2,
           parts[0].count <= 2, parts[1].count == 2,
           parts[0].allSatisfy(\.isNumber), parts[1].allSatisfy(\.isNumber)
        {
            return true
        }

        if wholeMatch(englishMonthDay, trimmed)
            || wholeMatch(clockWithMeridiem, trimmed)
            || wholeMatch(koreanMeridiemClock, trimmed)
            || wholeMatch(relativeDay, trimmed)
            || wholeMatch(weekdayName, trimmed)
            || wholeMatch(numericDate, trimmed)
            || wholeMatch(koreanDayLabel, trimmed)
        {
            return true
        }

        return false
    }

    static func isUnreadCountLike(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0.isNumber || $0 == "+" || $0 == "," }
    }
}

struct ChatListDiscovery {
    let title: String
    let lastMessage: String?
    let listIndex: Int
}

struct ChatListEntry: Codable, Equatable {
    let title: String
    let chatID: String?
    let lastMessage: String?

    enum CodingKeys: String, CodingKey {
        case title
        case chatID = "chat_id"
        case lastMessage = "last_message"
    }
}

struct ChatListSnapshotItem {
    let element: UIElement
    let discovery: ChatListDiscovery
}

struct ChatListScanner {
    func scan(in window: UIElement, limit: Int, trace: ((String) -> Void)? = nil) -> [ChatListSnapshotItem] {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            trace?("chats: chat list container unavailable")
            return []
        }

        let rows = collectChatItems(from: container, limit: limit)
        guard !rows.isEmpty else {
            trace?("chats: chat list container found but no rows/items resolved")
            return []
        }

        var snapshots: [ChatListSnapshotItem] = []
        snapshots.reserveCapacity(rows.count)

        for (index, row) in rows.enumerated() {
            let title = extractTitle(from: row, trace: trace)
            let preview = extractPreview(from: row, title: title, trace: trace)
            let discovery = ChatListDiscovery(title: title, lastMessage: preview, listIndex: index)
            snapshots.append(ChatListSnapshotItem(element: row, discovery: discovery))
        }

        trace?("chats: resolved rows=\(snapshots.count)")
        return snapshots
    }

    func scanAll(
        in window: UIElement,
        maxPasses: Int = 80,
        trace: ((String) -> Void)? = nil
    ) -> [ChatListSnapshotItem] {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            trace?("chats: chat list container unavailable")
            return []
        }

        _ = ScrollEvents.setVerticalScrollPosition(container, value: 0.0)
        Thread.sleep(forTimeInterval: 0.2)

        var discoveries: [ChatListDiscovery] = []
        var seenKeys = Set<String>()
        var stablePasses = 0
        var scrollValue = 0.0

        for pass in 0..<maxPasses {
            let rows = collectChatItems(from: container, limit: 120)
            let visible = rows.map { row -> ChatListDiscovery in
                let title = extractTitle(from: row, trace: trace)
                let preview = extractPreview(from: row, title: title, trace: trace)
                return ChatListDiscovery(title: title, lastMessage: preview, listIndex: discoveries.count)
            }

            var newCount = 0
            for discovery in visible {
                let key = fullScanKey(discovery)
                guard !seenKeys.contains(key) else { continue }
                seenKeys.insert(key)
                discoveries.append(ChatListDiscovery(
                    title: discovery.title,
                    lastMessage: discovery.lastMessage,
                    listIndex: discoveries.count
                ))
                newCount += 1
            }

            trace?("chats: full scan pass=\(pass + 1), visible=\(visible.count), new=\(newCount), total=\(discoveries.count)")
            if newCount == 0 {
                stablePasses += 1
            } else {
                stablePasses = 0
            }
            if stablePasses >= 3 {
                break
            }

            scrollValue = min(1.0, scrollValue + 0.08)
            let didSetScroll = ScrollEvents.setVerticalScrollPosition(container, value: scrollValue)
            if !didSetScroll {
                guard ScrollEvents.scrollElement(container, direction: .down, amount: 10) else {
                    break
                }
            }
            if scrollValue >= 1.0, newCount == 0 {
                break
            }
            Thread.sleep(forTimeInterval: 0.18)
        }

        trace?("chats: full scan resolved rows=\(discoveries.count)")
        return discoveries.map { ChatListSnapshotItem(element: window, discovery: $0) }
    }

    func warmup(in window: UIElement, trace: ((String) -> Void)? = nil) -> [AXPathSlot] {
        guard let container = resolveChatListContainer(in: window, trace: trace) else {
            return []
        }

        var warmedSlots: [AXPathSlot] = [.chatListContainer]
        if let firstRow = collectChatItems(from: container, limit: 1).first {
            if extractTitleElement(from: firstRow, trace: trace)?.element != nil {
                warmedSlots.append(.chatRowTitle)
            }
            if extractPreviewElement(from: firstRow, title: extractTitle(from: firstRow, trace: trace), trace: trace)?.element != nil {
                warmedSlots.append(.chatRowPreview)
            }
        }

        return deduplicateSlots(warmedSlots)
    }

    private func resolveChatListContainer(in window: UIElement, trace: ((String) -> Void)? = nil) -> UIElement? {
        if let cached = AXPathCacheStore.shared.resolve(
            slot: .chatListContainer,
            root: window,
            validate: isLikelyChatListContainer,
            trace: trace
        ) {
            trace?("chats: container fast path hit")
            return cached
        }

        trace?("chats: container fast path miss, scanning")
        let found = window.findAll(
            roles: [kAXTableRole, kAXOutlineRole, kAXListRole],
            roleLimits: [kAXTableRole: 1, kAXOutlineRole: 1, kAXListRole: 1],
            maxNodes: 220
        )
        let container = found[kAXTableRole]?.first ?? found[kAXOutlineRole]?.first ?? found[kAXListRole]?.first

        if let container {
            AXPathCacheStore.shared.remember(slot: .chatListContainer, root: window, element: container, trace: trace)
        }

        return container
    }

    private func isLikelyChatListContainer(_ element: UIElement) -> Bool {
        switch element.role {
        case kAXTableRole, kAXOutlineRole, kAXListRole:
            return true
        default:
            return false
        }
    }

    private func collectChatItems(from container: UIElement, limit: Int) -> [UIElement] {
        let role = container.role ?? ""

        if role == kAXListRole {
            let children = Array(container.children.prefix(limit))
            return deduplicateElements(children)
        }

        let directRows = container.children.filter { $0.role == kAXRowRole }
        if !directRows.isEmpty {
            return Array(deduplicateElements(directRows).prefix(limit))
        }

        let discoveredRows = container.findAll(role: kAXRowRole, limit: limit, maxNodes: max(80, limit * 8))
        return deduplicateElements(discoveredRows)
    }

    private func fullScanKey(_ discovery: ChatListDiscovery) -> String {
        let title = ChatTextNormalizer.normalize(discovery.title)
        let preview = discovery.lastMessage.map(ChatTextNormalizer.normalize) ?? ""
        return preview.isEmpty ? title : "\(title)|\(preview)"
    }

    private func extractTitle(from row: UIElement, trace: ((String) -> Void)? = nil) -> String {
        if let resolved = extractTitleElement(from: row, trace: trace) {
            return resolved.text
        }
        return "(Unknown Chat)"
    }

    private func extractTitleElement(from row: UIElement, trace: ((String) -> Void)? = nil) -> (element: UIElement, text: String)? {
        if let cached = AXPathCacheStore.shared.resolve(
            slot: .chatRowTitle,
            root: row,
            validate: { candidate in
                titleText(from: candidate) != nil
            },
            trace: trace
        ), let text = titleText(from: cached) {
            return (cached, text)
        }

        if let text = titleText(from: row) {
            AXPathCacheStore.shared.remember(slot: .chatRowTitle, root: row, element: row, trace: trace)
            return (row, text)
        }

        let staticTexts = row.findAll(role: kAXStaticTextRole, limit: 12, maxNodes: 80)
        for textNode in staticTexts {
            guard let text = titleText(from: textNode) else { continue }
            AXPathCacheStore.shared.remember(slot: .chatRowTitle, root: row, element: textNode, trace: trace)
            return (textNode, text)
        }

        return nil
    }

    private func extractPreview(from row: UIElement, title: String, trace: ((String) -> Void)? = nil) -> String? {
        extractPreviewElement(from: row, title: title, trace: trace)?.text
    }

    private func extractPreviewElement(from row: UIElement, title: String, trace: ((String) -> Void)? = nil) -> (element: UIElement, text: String)? {
        if let cached = AXPathCacheStore.shared.resolve(
            slot: .chatRowPreview,
            root: row,
            validate: { candidate in
                previewText(from: candidate, title: title) != nil
            },
            trace: trace
        ), let text = previewText(from: cached, title: title) {
            return (cached, text)
        }

        let textAreas = row.findAll(role: kAXTextAreaRole, limit: 4, maxNodes: 60)
        for textArea in textAreas {
            guard let text = previewText(from: textArea, title: title) else { continue }
            AXPathCacheStore.shared.remember(slot: .chatRowPreview, root: row, element: textArea, trace: trace)
            return (textArea, text)
        }

        let staticTexts = row.findAll(role: kAXStaticTextRole, limit: 16, maxNodes: 100)
        for textNode in staticTexts {
            guard let text = previewText(from: textNode, title: title) else { continue }
            AXPathCacheStore.shared.remember(slot: .chatRowPreview, root: row, element: textNode, trace: trace)
            return (textNode, text)
        }

        return nil
    }

    private func titleText(from element: UIElement) -> String? {
        if let title = normalizedText(element.title), !ChatTextNormalizer.isTimeLikeValue(title), !ChatTextNormalizer.isUnreadCountLike(title) {
            return title
        }

        if element.identifier == "Count Label" {
            return nil
        }

        switch element.role {
        case kAXRowRole, kAXCellRole, kAXGroupRole, kAXListRole, kAXTableRole, kAXOutlineRole:
            return nil
        default:
            break
        }

        if let value = normalizedText(element.stringValue), !ChatTextNormalizer.isTimeLikeValue(value), !ChatTextNormalizer.isUnreadCountLike(value) {
            return value
        }

        return nil
    }

    private func previewText(from element: UIElement, title: String) -> String? {
        guard let value = normalizedText(element.stringValue) ?? normalizedText(element.title) else {
            return nil
        }
        if element.identifier == "Count Label" {
            return nil
        }
        if ChatTextNormalizer.isTimeLikeValue(value) || ChatTextNormalizer.isUnreadCountLike(value) {
            return nil
        }
        if ChatTextNormalizer.normalize(value) == ChatTextNormalizer.normalize(title) {
            return nil
        }
        return value
    }

    private func normalizedText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func deduplicateElements(_ elements: [UIElement]) -> [UIElement] {
        var unique: [UIElement] = []
        unique.reserveCapacity(elements.count)

        for element in elements {
            if unique.contains(where: { existing in
                CFEqual(existing.axElement, element.axElement)
            }) {
                continue
            }
            unique.append(element)
        }

        return unique
    }

    private func deduplicateSlots(_ slots: [AXPathSlot]) -> [AXPathSlot] {
        var seen = Set<AXPathSlot>()
        return slots.filter { seen.insert($0).inserted }
    }
}
