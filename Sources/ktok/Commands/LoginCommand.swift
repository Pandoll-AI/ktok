import ArgumentParser
import Foundation

struct LoginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Log in to KakaoTalk using an alias from .env",
        discussion: """
            .env format:
              KTOK_LOGIN_WORK_ID=your-account@example.com
              KTOK_LOGIN_WORK_PROFILE_NAME=Your KakaoTalk profile name
              KTOK_LOGIN_WORK_KEEP_LOGGED_IN=true
              KTOK_LOGIN_PRIVATE_ID=01012345678

            Store passwords in macOS Keychain with scripts/setup-login-env.sh
            or another platform secret backend. Avoid committing password values
            to env files.

            Default .env lookup order:
              $KTOK_LOGIN_ENV_FILE, $KTOK_ENV_FILE, ./.env,
              ~/.ktok/config/.env, ~/.ktok/.env.local,
              ~/Library/Application Support/ktok/.env, ~/.config/ktok/.env
            """
    )

    @Argument(help: "Login alias, e.g. work or private")
    var alias: String

    @Option(name: .long, help: "Path to .env file")
    var envFile: String?

    @Option(name: .long, help: "Seconds to wait for login completion")
    var timeout: Double = 12.0

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    @Flag(name: .long, help: "Skip login when ktok's saved account state already matches this alias")
    var trustState: Bool = false

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        do {
            let environment = try LoginEnvironment.load(path: envFile)
            let credentials = try environment.credentials(alias: alias)
            let runner = AXActionRunner(traceEnabled: traceAX)
            let kakao = try KakaoTalkApp()
            let navigator = LoginNavigator(kakao: kakao, runner: runner)
            let status = navigator.status()
            let detector = AccountProfileDetector(kakao: kakao, runner: runner)

            if status.isRunning, !status.isLoginWindowVisible, credentials.profileName != nil {
                let profileName = detector.detectCurrentProfileName(timeoutSec: 1.0, restoreChatsTab: true)
                if AccountProfileDetector.profileName(credentials.profileName, matches: profileName) {
                    SecretStore.savePassword(credentials.password, alias: credentials.alias, keychainPath: credentials.keychainPath)
                    try LoginAccountState.save(credentials: credentials, profileName: profileName)
                    print("Already logged in as '\(credentials.alias)' via profile '\(profileName ?? "")' (\(maskedAccountID(credentials.accountID))).")
                    return
                }
            }

            if
                trustState,
                status.isRunning,
                !status.isLoginWindowVisible,
                let stored = LoginAccountState.read(),
                stored.alias == credentials.alias,
                stored.accountIDHash == KtokPaths.shortHash(credentials.accountID)
            {
                print("Already logged in as '\(credentials.alias)' (\(maskedAccountID(credentials.accountID))).")
                return
            }

            print("Logging in as alias '\(credentials.alias)' (\(maskedAccountID(credentials.accountID)))...")
            try navigator.login(credentials: credentials, timeoutSec: timeout)
            SecretStore.savePassword(credentials.password, alias: credentials.alias, keychainPath: credentials.keychainPath)
            try LoginAccountState.save(credentials: credentials)
            print("Logged in as '\(credentials.alias)'.")
        } catch {
            print("Login failed: \(error)")
            throw ExitCode.failure
        }
    }
}

struct LogoutCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logout",
        abstract: "Log out of KakaoTalk"
    )

    @Option(name: .long, help: "Seconds to wait for logout completion")
    var timeout: Double = 12.0

    @Flag(name: .long, help: "Show AX traversal and retry details")
    var traceAX: Bool = false

    func run() throws {
        guard AccessibilityPermission.ensureGranted() else {
            AccessibilityPermission.printInstructions()
            throw ExitCode.failure
        }

        do {
            let runner = AXActionRunner(traceEnabled: traceAX)
            let kakao = try KakaoTalkApp()
            let navigator = LoginNavigator(kakao: kakao, runner: runner)
            try navigator.logout(timeoutSec: timeout)
            print("Logged out.")
        } catch {
            print("Logout failed: \(error)")
            throw ExitCode.failure
        }
    }
}

struct AssumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assume",
        abstract: "Record the current manually selected KakaoTalk account alias"
    )

    @Argument(help: "Login alias that is currently active in KakaoTalk")
    var alias: String

    @Option(name: .long, help: "Path to .env file")
    var envFile: String?

    func run() throws {
        do {
            let environment = try LoginEnvironment.load(path: envFile)
            let credentials = try environment.credentials(alias: alias)
            SecretStore.savePassword(credentials.password, alias: credentials.alias, keychainPath: credentials.keychainPath)
            try LoginAccountState.save(credentials: credentials)
            print("Recorded current KakaoTalk account as '\(credentials.alias)' (\(maskedAccountID(credentials.accountID))).")
        } catch {
            print("Assume failed: \(error)")
            throw ExitCode.failure
        }
    }
}

struct WhoamiCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whoami",
        abstract: "Show the current ktok login alias"
    )

    @Flag(name: .long, help: "Emit JSON")
    var json: Bool = false

    @Option(name: .long, help: "Path to .env file")
    var envFile: String?

    func run() throws {
        let stored = LoginAccountState.read()
        let status: KakaoLoginStatus
        var detectedProfileName: String?
        var detectedCredentials: LoginCredentials?

        if KakaoTalkApp.isRunning, let kakao = try? KakaoTalkApp(autoLaunch: false) {
            let runner = AXActionRunner(traceEnabled: false)
            let navigator = LoginNavigator(kakao: kakao, runner: runner)
            status = navigator.status()
            if status.isRunning, !status.isLoginWindowVisible {
                detectedProfileName = AccountProfileDetector(kakao: kakao, runner: runner)
                    .detectCurrentProfileName(timeoutSec: 1.0, restoreChatsTab: true)
                if let environment = try? LoginEnvironment.load(path: envFile), let detectedProfileName {
                    detectedCredentials = environment.credentialsWithProfileNames().first { credentials in
                        AccountProfileDetector.profileName(credentials.profileName, matches: detectedProfileName)
                    }
                    if let detectedCredentials {
                        SecretStore.savePassword(detectedCredentials.password, alias: detectedCredentials.alias, keychainPath: detectedCredentials.keychainPath)
                        try? LoginAccountState.save(credentials: detectedCredentials, profileName: detectedProfileName)
                    }
                }
            }
        } else {
            status = KakaoLoginStatus(
                isRunning: false,
                isLoginWindowVisible: false,
                loginFormAccountID: nil
            )
        }

        if json {
            printJSON([
                "running": status.isRunning,
                "logged_in": status.isRunning && !status.isLoginWindowVisible,
                "login_window_visible": status.isLoginWindowVisible,
                "alias": status.isRunning && !status.isLoginWindowVisible ? ((detectedCredentials?.alias ?? stored?.alias) as Any) : NSNull(),
                "account_key": status.isRunning && !status.isLoginWindowVisible ? ((LoginAccountState.read()?.accountKey ?? stored?.accountKey) as Any) : NSNull(),
                "account_id_hash": status.isRunning && !status.isLoginWindowVisible ? ((LoginAccountState.read()?.accountIDHash ?? stored?.accountIDHash) as Any) : NSNull(),
                "account_id_masked": status.isRunning && !status.isLoginWindowVisible ? ((detectedCredentials.map { maskedAccountID($0.accountID) } ?? stored?.accountIDMasked ?? stored?.accountID.map(maskedAccountID)) as Any) : NSNull(),
                "profile_name": detectedProfileName as Any,
                "profile_verified": detectedCredentials != nil,
                "login_form_account_id": status.loginFormAccountID as Any,
                "state_file": LoginAccountState.defaultPath,
                "logged_in_at": (LoginAccountState.read()?.loggedInAt ?? stored?.loggedInAt) as Any,
            ])
            return
        }

        guard status.isRunning else {
            print("KakaoTalk is not running.")
            return
        }

        if status.isLoginWindowVisible {
            if let id = status.loginFormAccountID, !id.isEmpty {
                print("Not logged in. Login form has account ID \(maskedAccountID(id)).")
            } else {
                print("Not logged in.")
            }
            return
        }

        if let detectedCredentials {
            print("Logged in as '\(detectedCredentials.alias)' (\(maskedAccountID(detectedCredentials.accountID))) via profile '\(detectedProfileName ?? "")'.")
        } else if let detectedProfileName {
            print("Logged in, profile '\(detectedProfileName)' did not match any .env alias. Add KTOK_LOGIN_<ALIAS>_PROFILE_NAME to verify it.")
        } else if let stored {
            let account = stored.accountIDMasked ?? stored.accountID.map(maskedAccountID) ?? "unknown account"
            print("Logged in as '\(stored.alias)' (\(account)) from saved ktok state; profile could not be verified.")
        } else {
            print("Logged in, but alias is unknown. Use 'ktok login <alias>' to record ktok account state.")
        }
    }

    private func printJSON(_ object: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let string = String(data: data, encoding: .utf8)
        else {
            print("{\"ok\":false,\"error\":\"json_encode_failed\"}")
            return
        }
        print(string)
    }
}
