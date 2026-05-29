import ApplicationServices.HIServices
import Foundation

enum LoginNavigatorError: Error, CustomStringConvertible {
    case loginWindowNotFound
    case loginFieldsNotFound(count: Int)
    case loginButtonNotFound
    case loginFailed(String)
    case logoutMenuItemNotFound(String)
    case logoutFailed(String)

    var description: String {
        switch self {
        case .loginWindowNotFound:
            return "KakaoTalk login window was not found. Log out first, or restart KakaoTalk to show the login screen."
        case .loginFieldsNotFound(let count):
            return "KakaoTalk login fields not found. Found \(count) text field(s)."
        case .loginButtonNotFound:
            return "KakaoTalk login button not found."
        case .loginFailed(let message):
            return "KakaoTalk login failed: \(message)"
        case .logoutMenuItemNotFound(let details):
            return "KakaoTalk logout menu item not found: \(details)"
        case .logoutFailed(let message):
            return "KakaoTalk logout failed: \(message)"
        }
    }
}

struct KakaoLoginStatus {
    let isRunning: Bool
    let isLoginWindowVisible: Bool
    let loginFormAccountID: String?
}

final class LoginNavigator {
    private let kakao: KakaoTalkApp
    private let runner: AXActionRunner

    init(kakao: KakaoTalkApp, runner: AXActionRunner) {
        self.kakao = kakao
        self.runner = runner
    }

    func login(credentials: LoginCredentials, timeoutSec: TimeInterval = 12.0) throws {
        kakao.activate()
        var loginWindow = waitForLoginWindow(timeoutSec: 5.0)
        if loginWindow == nil {
            runner.log("login: login window not visible; attempting logout before account switch")
            try logout(timeoutSec: timeoutSec)
            loginWindow = waitForLoginWindow(timeoutSec: 5.0)
        }

        guard let loginWindow else {
            throw LoginNavigatorError.loginWindowNotFound
        }

        let fields = loginFields(in: loginWindow)
        guard fields.count >= 2 else {
            throw LoginNavigatorError.loginFieldsNotFound(count: fields.count)
        }

        let accountField = fields[0]
        let passwordField = fields[1]

        guard runner.focusWithVerification(accountField, label: "login account field", attempts: 2) else {
            throw LoginNavigatorError.loginFailed("Could not focus account field.")
        }
        guard runner.setTextWithVerification(credentials.accountID, on: accountField, label: "login account field", attempts: 2) else {
            throw LoginNavigatorError.loginFailed("Could not enter account ID.")
        }

        guard runner.focusWithVerification(passwordField, label: "login password field", attempts: 2) else {
            throw LoginNavigatorError.loginFailed("Could not focus password field.")
        }
        try setPassword(credentials.password, on: passwordField)

        if let keepLoggedIn = credentials.keepLoggedIn {
            setKeepLoggedIn(keepLoggedIn, in: loginWindow)
        }

        guard let loginButton = findLoginButton(in: loginWindow) else {
            throw LoginNavigatorError.loginButtonNotFound
        }
        guard runner.clickWithRetry(loginButton, label: "login button", attempts: 2) else {
            throw LoginNavigatorError.loginFailed("Could not press login button.")
        }

        if waitForLoggedIn(timeoutSec: timeoutSec) {
            return
        }

        if let error = dismissLoginErrorIfPresent(timeoutSec: 0.5) {
            throw LoginNavigatorError.loginFailed(error)
        }
        throw LoginNavigatorError.loginFailed("Login window did not disappear within \(Int(timeoutSec))s.")
    }

    func logout(timeoutSec: TimeInterval = 12.0) throws {
        kakao.activate()
        if waitForLoginWindow(timeoutSec: 0.4) != nil {
            LoginAccountState.clear()
            return
        }

        let clicked = clickLogoutMenuItem()
        guard clicked.clicked else {
            throw LoginNavigatorError.logoutMenuItemNotFound(clicked.details)
        }

        confirmLogoutIfNeeded(timeoutSec: 4.0)
        guard waitForLoginWindow(timeoutSec: timeoutSec) != nil else {
            throw LoginNavigatorError.logoutFailed("Login window did not appear within \(Int(timeoutSec))s.")
        }
        LoginAccountState.clear()
    }

    func status() -> KakaoLoginStatus {
        let loginWindow = findLoginWindow()
        let accountID = loginWindow.flatMap { loginFields(in: $0).first?.stringValue }
        return KakaoLoginStatus(
            isRunning: KakaoTalkApp.isRunning,
            isLoginWindowVisible: loginWindow != nil,
            loginFormAccountID: accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func findLoginWindow() -> UIElement? {
        for window in kakao.windows {
            let title = (window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if title == "log in" || title == "login" || title == "로그인" {
                return window
            }
            if findLoginButton(in: window) != nil, loginFields(in: window).count >= 2 {
                return window
            }
        }
        return nil
    }

    private func waitForLoginWindow(timeoutSec: TimeInterval) -> UIElement? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSec {
            if let window = findLoginWindow() {
                return window
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return findLoginWindow()
    }

    private func waitForLoggedIn(timeoutSec: TimeInterval) -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSec {
            if dismissLoginErrorIfPresent(timeoutSec: 0.05) != nil {
                return false
            }
            if findLoginWindow() == nil {
                runner.log("login: login window disappeared")
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return findLoginWindow() == nil
    }

    private func loginFields(in root: UIElement) -> [UIElement] {
        root.findAll(where: { element in
            let role = element.role ?? ""
            return (role == kAXTextFieldRole || role == "AXSecureTextField") && element.isEnabled
        }, limit: 4, maxNodes: 300)
    }

    private func findLoginButton(in root: UIElement) -> UIElement? {
        let labels: Set<String> = ["log in", "login", "로그인"]
        return root.findAll(role: kAXButtonRole, limit: 40, maxNodes: 300).first { button in
            let title = (button.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let desc = (button.axDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return labels.contains(title) || labels.contains(desc)
        }
    }

    private func setPassword(_ password: String, on field: UIElement) throws {
        do {
            try field.setAttribute(kAXValueAttribute, value: password as CFString)
            runner.log("login password field: set AXValue")
        } catch {
            runner.log("login password field: set AXValue failed (\(error)); typing fallback")
            guard runner.typeTextWithVerification(password, on: nil, label: "login password field", attempts: 1) else {
                throw LoginNavigatorError.loginFailed("Could not enter password.")
            }
        }
    }

    private func setKeepLoggedIn(_ desired: Bool, in root: UIElement) {
        let labels: Set<String> = ["keep me logged in", "자동로그인", "자동 로그인", "로그인 상태 유지"]
        guard let checkbox = root.findAll(role: kAXCheckBoxRole, limit: 8, maxNodes: 300).first(where: { box in
            let title = (box.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let desc = (box.axDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return labels.contains(title) || labels.contains(desc)
        }) else {
            runner.log("keep-logged-in: checkbox not found")
            return
        }

        let rawValue: Any? = checkbox.attributeOptional(kAXValueAttribute)
        let current: Bool
        if let bool = rawValue as? Bool {
            current = bool
        } else if let int = rawValue as? Int {
            current = int != 0
        } else {
            runner.log("keep-logged-in: checkbox value unavailable; leaving unchanged")
            return
        }

        guard current != desired else {
            runner.log("keep-logged-in: already \(desired)")
            return
        }
        _ = runner.clickWithRetry(checkbox, label: "keep-logged-in checkbox", attempts: 1)
    }

    private func dismissLoginErrorIfPresent(timeoutSec: TimeInterval) -> String? {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSec {
            if let result = findAndDismissLoginError() {
                return result
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return findAndDismissLoginError()
    }

    private func findAndDismissLoginError() -> String? {
        let markers = [
            "password", "account", "login", "log in",
            "비밀번호", "계정", "로그인", "카카오계정",
        ]
        for root in kakao.windows {
            guard let ok = findConfirmationButton(in: root, labels: ["OK", "확인"]) else {
                continue
            }

            let texts = root.findAll(role: kAXStaticTextRole, limit: 80, maxNodes: 500).compactMap {
                $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }

            let lower = texts.joined(separator: " ").lowercased()
            guard markers.contains(where: { lower.contains($0) }) else { continue }

            _ = runner.clickWithRetry(ok, label: "login error OK", attempts: 1)
            return texts.prefix(3).joined(separator: " ")
        }
        return nil
    }

    private func confirmLogoutIfNeeded(timeoutSec: TimeInterval) {
        let start = Date()
        while Date().timeIntervalSince(start) < timeoutSec {
            if pressLogoutConfirmationButtonIfPresent() {
                return
            }
            if findLoginWindow() != nil {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private func pressLogoutConfirmationButtonIfPresent() -> Bool {
        let markers = ["log out", "logout", "로그아웃"]
        for root in kakao.windows {
            let texts = root.findAll(role: kAXStaticTextRole, limit: 80, maxNodes: 500).compactMap {
                $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty }
            let joined = texts.joined(separator: " ")
            guard markers.contains(where: { joined.contains($0) }) else { continue }

            if let button = findConfirmationButton(in: root, labels: ["Log out", "Logout", "로그아웃", "OK", "확인"]) {
                _ = runner.clickWithRetry(button, label: "logout confirmation", attempts: 2)
                return true
            }
        }
        return false
    }

    private func findConfirmationButton(in root: UIElement, labels: Set<String>) -> UIElement? {
        let lowered = Set(labels.map { $0.lowercased() })
        return root.findAll(role: kAXButtonRole, limit: 40, maxNodes: 400).first { button in
            let title = (button.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let desc = (button.axDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return lowered.contains(title) || lowered.contains(desc)
        }
    }

    private func clickLogoutMenuItem() -> (clicked: Bool, details: String) {
        let script = """
        const se = Application('System Events');
        se.includeStandardAdditions = true;
        const labels = ['Log out', 'Logout', '로그아웃'];
        (() => {
          try {
            const p = se.processes.byName('KakaoTalk');
            for (const mb of p.menuBars()) {
              for (const mbi of mb.menuBarItems()) {
                let menuTitle = '';
                try { menuTitle = mbi.title(); } catch (_) {}
                if (menuTitle !== 'KakaoTalk' && menuTitle !== '카카오톡') continue;
                let menu;
                try { menu = mbi.menus[0]; } catch (_) { continue; }
                for (const item of menu.menuItems()) {
                  let title = '';
                  try { title = item.title(); } catch (_) {}
                  if (!labels.includes(title)) continue;
                  let enabled = true;
                  try { enabled = item.enabled(); } catch (_) {}
                  if (!enabled) {
                    return JSON.stringify({ clicked: false, details: 'menu item disabled: ' + title });
                  }
                  item.click();
                  return JSON.stringify({ clicked: true, details: 'clicked: ' + title });
                }
              }
            }
            return JSON.stringify({ clicked: false, details: 'no matching menu item' });
          } catch (e) {
            return JSON.stringify({ clicked: false, details: String(e) });
          }
        })();
        """

        let output = AppleScriptRunner.runJXA(script, timeoutSec: 5.0)
        guard
            output.returncode == 0,
            let data = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (false, "jxa_rc=\(output.returncode) stdout=\(output.stdout.prefix(120)) stderr=\(output.stderr.prefix(120))")
        }
        return (
            object["clicked"] as? Bool ?? false,
            object["details"] as? String ?? "unknown"
        )
    }
}
