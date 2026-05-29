import Foundation

struct DetectedAccountProfile {
    let profileName: String
    let credentials: LoginCredentials?
}

struct AccountProfileDetector {
    let kakao: KakaoTalkApp
    let runner: AXActionRunner

    func detectCurrentProfileName(timeoutSec: TimeInterval = 2.0, restoreChatsTab: Bool = true) -> String? {
        kakao.activate()
        selectTab(identifier: "friends", fallbackCommandNumber: 1)
        waitForHeader("Friends", timeoutSec: timeoutSec)

        let name = (kakao.mainWindow ?? kakao.windows.first).flatMap(extractOwnProfileName)

        if restoreChatsTab {
            selectTab(identifier: "chatrooms", fallbackCommandNumber: 2)
            waitForHeader("Chats", timeoutSec: 1.0)
        }

        return name
    }

    func detectCurrentProfile(
        environment: LoginEnvironment,
        timeoutSec: TimeInterval = 2.0,
        restoreChatsTab: Bool = true
    ) -> DetectedAccountProfile? {
        guard let profileName = detectCurrentProfileName(timeoutSec: timeoutSec, restoreChatsTab: restoreChatsTab) else {
            return nil
        }

        let credentials = environment.credentialsWithProfileNames().first { credentials in
            Self.profileName(credentials.profileName, matches: profileName)
        }
        return DetectedAccountProfile(profileName: profileName, credentials: credentials)
    }

    static func profileName(_ expected: String?, matches actual: String?) -> Bool {
        guard let expected = normalizeProfileName(expected), let actual = normalizeProfileName(actual) else {
            return false
        }
        return expected == actual
    }

    private func extractOwnProfileName(from window: UIElement) -> String? {
        let rows = window.findAll(role: kAXRowRole, limit: 80, maxNodes: 2_000)
            .sorted { lhs, rhs in
                let lhsFrame = lhs.frame ?? .zero
                let rhsFrame = rhs.frame ?? .zero
                if abs(lhsFrame.minY - rhsFrame.minY) > 1 {
                    return lhsFrame.minY < rhsFrame.minY
                }
                return lhsFrame.minX < rhsFrame.minX
            }

        for row in rows {
            if let height = row.frame?.height, height <= 8 {
                continue
            }

            let texts = row.findAll(role: kAXStaticTextRole, limit: 8, maxNodes: 120)
                .compactMap { textValue($0) }
                .filter { !isProfileSectionLabel($0) }

            if let first = texts.first {
                return first
            }
        }

        return nil
    }

    private func selectTab(identifier: String, fallbackCommandNumber: Int) {
        kakao.activate()
        if
            let window = kakao.mainWindow ?? kakao.windows.first,
            let button = window.findFirst(identifier: identifier),
            runner.clickWithRetry(button, label: "select \(identifier) tab", attempts: 2)
        {
            return
        }
        runner.pressCommandNumber(fallbackCommandNumber)
    }

    @discardableResult
    private func waitForHeader(_ expected: String, timeoutSec: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeoutSec, 0.2))
        while Date() < deadline {
            if let window = kakao.mainWindow ?? kakao.windows.first {
                let found = window.findAll(role: kAXStaticTextRole, limit: 20, maxNodes: 400).contains { element in
                    textValue(element) == expected
                }
                if found {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private func textValue(_ element: UIElement) -> String? {
        let value = (element.stringValue ?? element.title ?? element.axDescription ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isProfileSectionLabel(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "my default profile",
            "friends",
            "friend",
            "내 프로필",
            "친구",
            "추천친구",
        ].contains(normalized)
    }

    private static func normalizeProfileName(_ text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.isEmpty ? nil : normalized
    }
}
