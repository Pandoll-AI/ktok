import Foundation

struct LoginCredentials {
    let alias: String
    let accountID: String
    let password: String
    let keepLoggedIn: Bool?
    let profileName: String?
    let keychainPath: String?
    let sourcePath: String?
}

enum LoginEnvironmentError: Error, CustomStringConvertible {
    case envFileNotFound(String)
    case aliasNotFound(alias: String, expectedIDKey: String, expectedPasswordKey: String, source: String)
    case invalidAlias(String)

    var description: String {
        switch self {
        case .envFileNotFound(let path):
            return "Environment file not found: \(path)"
        case .aliasNotFound(let alias, let expectedIDKey, let expectedPasswordKey, let source):
            return "Login alias '\(alias)' not found in \(source). Expected \(expectedIDKey) and \(expectedPasswordKey)."
        case .invalidAlias(let alias):
            return "Invalid login alias '\(alias)'. Use letters, numbers, dash, or underscore."
        }
    }
}

struct LoginEnvironment {
    private let values: [String: String]
    let sourcePath: String?

    static func load(path explicitPath: String? = nil) throws -> LoginEnvironment {
        let filePath = try resolveEnvFile(explicitPath: explicitPath)
        var values: [String: String] = [:]

        if let filePath {
            values.merge(try DotenvParser.parse(path: filePath)) { _, new in new }
        }

        for (key, value) in ProcessInfo.processInfo.environment {
            values[key] = value
        }

        return LoginEnvironment(values: values, sourcePath: filePath)
    }

    func credentials(alias rawAlias: String) throws -> LoginCredentials {
        let normalized = try Self.normalizedAlias(rawAlias)
        let idKey = "KTOK_LOGIN_\(normalized)_ID"
        let passwordKey = "KTOK_LOGIN_\(normalized)_PASSWORD"
        let keepKey = "KTOK_LOGIN_\(normalized)_KEEP_LOGGED_IN"
        let profileNameKey = "KTOK_LOGIN_\(normalized)_PROFILE_NAME"
        let alias = normalized.lowercased()
        let keychainPath = values["KTOK_KEYCHAIN_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        guard
            let id = values[idKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !id.isEmpty
        else {
            throw LoginEnvironmentError.aliasNotFound(
                alias: rawAlias,
                expectedIDKey: idKey,
                expectedPasswordKey: passwordKey,
                source: sourceDescription
            )
        }

        let envPassword = values[passwordKey]?.nilIfEmpty
        let password = envPassword ?? SecretStore.readPassword(alias: alias, keychainPath: keychainPath) ?? ""
        guard !password.isEmpty else {
            throw LoginEnvironmentError.aliasNotFound(
                alias: rawAlias,
                expectedIDKey: idKey,
                expectedPasswordKey: passwordKey,
                source: "\(sourceDescription) or \(SecretStore.recommendedBackendDescription)"
            )
        }

        return LoginCredentials(
            alias: alias,
            accountID: id,
            password: password,
            keepLoggedIn: values[keepKey].flatMap(Self.parseBool),
            profileName: values[profileNameKey]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            keychainPath: keychainPath,
            sourcePath: sourcePath
        )
    }

    func credentialsWithProfileNames() -> [LoginCredentials] {
        let aliases = values.keys.compactMap { key -> String? in
            guard key.hasPrefix("KTOK_LOGIN_"), key.hasSuffix("_ID") else { return nil }
            let start = key.index(key.startIndex, offsetBy: "KTOK_LOGIN_".count)
            let end = key.index(key.endIndex, offsetBy: -"_ID".count)
            guard start < end else { return nil }
            return String(key[start..<end])
        }

        return Array(Set(aliases))
            .sorted()
            .compactMap { try? credentials(alias: $0) }
            .filter { $0.profileName != nil }
    }

    private var sourceDescription: String {
        sourcePath ?? "process environment"
    }

    static func normalizedAlias(_ alias: String) throws -> String {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LoginEnvironmentError.invalidAlias(alias)
        }

        var out = ""
        var previousWasUnderscore = false
        for scalar in trimmed.unicodeScalars {
            let value = scalar.value
            let isAlpha = (65...90).contains(value) || (97...122).contains(value)
            let isDigit = (48...57).contains(value)
            if isAlpha || isDigit {
                out.unicodeScalars.append(UnicodeScalar(String(scalar).uppercased())!)
                previousWasUnderscore = false
            } else if scalar == "_" || scalar == "-" {
                if !previousWasUnderscore {
                    out.append("_")
                    previousWasUnderscore = true
                }
            } else {
                throw LoginEnvironmentError.invalidAlias(alias)
            }
        }

        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        guard !out.isEmpty else {
            throw LoginEnvironmentError.invalidAlias(alias)
        }
        return out
    }

    private static func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        case "0", "false", "no", "n", "off":
            return false
        default:
            return nil
        }
    }

    private static func resolveEnvFile(explicitPath: String?) throws -> String? {
        let fm = FileManager.default
        if let explicitPath, !explicitPath.isEmpty {
            let expanded = expandTilde(explicitPath)
            guard fm.fileExists(atPath: expanded) else {
                throw LoginEnvironmentError.envFileNotFound(expanded)
            }
            return expanded
        }

        let env = ProcessInfo.processInfo.environment
        for key in ["KTOK_LOGIN_ENV_FILE", "KTOK_ENV_FILE"] {
            if let path = env[key], !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let expanded = expandTilde(path)
                guard fm.fileExists(atPath: expanded) else {
                    throw LoginEnvironmentError.envFileNotFound(expanded)
                }
                return expanded
            }
        }

        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(fm.currentDirectoryPath)/.env",
            "\(KtokPaths.configDir.path)/.env",
            "\(KtokPaths.home.path)/.env.local",
            "\(home)/Library/Application Support/ktok/.env",
            "\(home)/.config/ktok/.env",
        ]

        return candidates.first { fm.fileExists(atPath: $0) }
    }

    private static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}

private enum DotenvParser {
    static func parse(path: String) throws -> [String: String] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var out: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line.removeFirst("export ".count)
                line = line.trimmingCharacters(in: .whitespaces)
            }
            guard let eq = line.firstIndex(of: "=") else { continue }

            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            value = unquote(value)
            out[key] = value
        }

        return out
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        let first = value.first
        let last = value.last
        guard (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }

        let body = String(value.dropFirst().dropLast())
        guard first == "\"" else { return body }

        var out = ""
        var escaping = false
        for char in body {
            if escaping {
                switch char {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(char)
                }
                escaping = false
            } else if char == "\\" {
                escaping = true
            } else {
                out.append(char)
            }
        }
        if escaping { out.append("\\") }
        return out
    }
}

struct LoginAccountState: Codable {
    let alias: String
    let accountID: String?
    let accountKey: String?
    let accountIDHash: String?
    let accountIDMasked: String?
    let profileName: String?
    let envFile: String?
    let loggedInAt: String

    enum CodingKeys: String, CodingKey {
        case alias
        case accountID
        case accountKey
        case accountIDHash
        case accountIDMasked
        case profileName
        case envFile
        case loggedInAt
    }

    init(
        alias: String,
        accountID: String?,
        accountKey: String?,
        accountIDHash: String?,
        accountIDMasked: String?,
        profileName: String?,
        envFile: String?,
        loggedInAt: String
    ) {
        self.alias = alias
        self.accountID = accountID
        self.accountKey = accountKey
        self.accountIDHash = accountIDHash
        self.accountIDMasked = accountIDMasked
        self.profileName = profileName
        self.envFile = envFile
        self.loggedInAt = loggedInAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decode(String.self, forKey: .alias)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        accountKey = try container.decodeIfPresent(String.self, forKey: .accountKey)
        accountIDHash = try container.decodeIfPresent(String.self, forKey: .accountIDHash)
        accountIDMasked = try container.decodeIfPresent(String.self, forKey: .accountIDMasked)
        profileName = try container.decodeIfPresent(String.self, forKey: .profileName)
        envFile = try container.decodeIfPresent(String.self, forKey: .envFile)
        loggedInAt = try container.decode(String.self, forKey: .loggedInAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(alias, forKey: .alias)
        try container.encodeIfPresent(accountKey, forKey: .accountKey)
        try container.encodeIfPresent(accountIDHash, forKey: .accountIDHash)
        try container.encodeIfPresent(accountIDMasked, forKey: .accountIDMasked)
        try container.encodeIfPresent(profileName, forKey: .profileName)
        try container.encodeIfPresent(envFile, forKey: .envFile)
        try container.encode(loggedInAt, forKey: .loggedInAt)
    }

    static var defaultPath: String {
        KtokPaths.currentAccountState.path
    }

    static func read(path: String = defaultPath) -> LoginAccountState? {
        KtokPaths.migrateLegacyStorageIfNeeded()
        return readWithoutMigration(path: path)
    }

    static func readWithoutMigration(path: String = defaultPath) -> LoginAccountState? {
        guard
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let state = try? JSONDecoder().decode(LoginAccountState.self, from: data)
        else {
            return nil
        }
        return state
    }

    static func save(credentials: LoginCredentials, profileName: String? = nil, path: String = defaultPath) throws {
        let hash = KtokPaths.shortHash(credentials.accountID)
        let state = LoginAccountState(
            alias: credentials.alias,
            accountID: nil,
            accountKey: "account_\(hash)",
            accountIDHash: hash,
            accountIDMasked: maskedAccountID(credentials.accountID),
            profileName: profileName ?? credentials.profileName,
            envFile: credentials.sourcePath,
            loggedInAt: ISO8601DateFormatter().string(from: Date())
        )
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic])
        KtokPaths.writeAccountMetadata(credentials: credentials, profileName: profileName)
        KtokPaths.migrateLegacyStorageIfNeeded()
    }

    static func clear(path: String = defaultPath) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

func maskedAccountID(_ id: String) -> String {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 4 else { return String(repeating: "*", count: max(trimmed.count, 1)) }
    return "\(trimmed.prefix(2))\(String(repeating: "*", count: max(trimmed.count - 4, 3)))\(trimmed.suffix(2))"
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
