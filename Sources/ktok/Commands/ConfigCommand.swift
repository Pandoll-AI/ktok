import ArgumentParser
import Foundation

/// Move the portable, personalized ktok config (persona, channel allowlist, chat
/// maps) to another Mac.
///
/// Deliberately excludes machine-specific state (the AX path cache, which is tied
/// to this Mac's KakaoTalk layout and rebuilds itself) and logs. Login passwords
/// live in the macOS Keychain (not in files), so they are never in the archive —
/// re-run `ktok login` on the target machine.
struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Export/import the portable ktok config to move it between Macs.",
        subcommands: [ConfigExportCommand.self, ConfigImportCommand.self],
        defaultSubcommand: ConfigExportCommand.self
    )

    /// Paths (relative to KTOK_HOME) that are safe and useful to carry across
    /// machines. Only existing paths are archived.
    static func portableRelPaths(home: URL, withHistory: Bool, withEnv: Bool) -> [String] {
        var rel = [
            "persona",
            "channel/channel.sqlite",
            "channel/channel.sqlite-wal",
            "channel/channel.sqlite-shm",
            "chat-id-map.json",
            "chat-registry.json",
            "state/current-account.json",
        ]
        if withEnv { rel.append("config/.env") }
        if withHistory { rel.append("accounts") }
        let fm = FileManager.default
        return rel.filter { fm.fileExists(atPath: home.appendingPathComponent($0).path) }
    }

    /// Never carried across machines (machine-specific or noise).
    static let excludedNote = "cache/ (AX path cache), ax-cache.json, logs/ are excluded (machine-specific / noise)."
}

struct ConfigExportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Bundle the portable config into a .tgz archive."
    )

    @Option(name: [.short, .long], help: "Output archive path.")
    var output: String = "ktok-config.tgz"

    @Flag(name: .long, help: "Include message history (accounts/, can be large).")
    var withHistory: Bool = false

    @Flag(name: .long, help: "Include config/.env login settings (no password; that stays in Keychain).")
    var withEnv: Bool = false

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() throws {
        let home = KtokPaths.home
        let rel = ConfigCommand.portableRelPaths(home: home, withHistory: withHistory, withEnv: withEnv)
        guard !rel.isEmpty else {
            throw ValidationError("Nothing to export under \(home.path). Run ktok first (e.g. persona init, channel monitor add).")
        }

        let outURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // tar -czf <out> -C <home> <relpaths...>  — archive is rooted at KTOK_HOME.
        var args = ["-czf", outURL.path, "-C", home.path]
        args.append(contentsOf: rel)
        let result = Self.runTar(args)
        guard result.status == 0 else {
            throw ValidationError("tar failed (exit \(result.status)): \(result.output)")
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size] as? Int) ?? nil
        if json {
            printJSONDict([
                "ok": true,
                "archive": outURL.path,
                "size_bytes": size ?? 0,
                "included": rel.joined(separator: ","),
                "excluded_note": ConfigCommand.excludedNote,
                "keychain_note": "Login password stays in macOS Keychain; run `ktok login <alias>` on the target.",
            ])
            return
        }
        print("✓ Exported: \(outURL.path)\(size.map { " (\($0) bytes)" } ?? "")")
        print("  included: \(rel.joined(separator: ", "))")
        print("  excluded: \(ConfigCommand.excludedNote)")
        print("  note: login password is NOT included (macOS Keychain). Run `ktok login <alias>` on the target Mac.")
        print("  next: copy the archive over (AirDrop/scp), then: ktok config import \(outURL.lastPathComponent)")
    }

    static func runTar(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "\(error)")
        }
    }
}

struct ConfigImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Restore a config archive into KTOK_HOME (~/.ktok)."
    )

    @Argument(help: "Archive produced by `ktok config export`.")
    var archive: String

    @Flag(name: .long, help: "List the archive contents without extracting.")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() throws {
        let archiveURL = URL(fileURLWithPath: (archive as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: archiveURL.path) else {
            throw ValidationError("Archive not found: \(archiveURL.path)")
        }
        let home = KtokPaths.home

        if dryRun {
            let listed = ConfigExportCommand.runTar(["-tzf", archiveURL.path])
            print(listed.output.trimmingCharacters(in: .whitespacesAndNewlines))
            return
        }

        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // tar -xzf <archive> -C <home>  — extraction is rooted at KTOK_HOME.
        let result = ConfigExportCommand.runTar(["-xzf", archiveURL.path, "-C", home.path])
        guard result.status == 0 else {
            throw ValidationError("tar extract failed (exit \(result.status)): \(result.output)")
        }

        if json {
            printJSONDict([
                "ok": true,
                "home": home.path,
                "note": "AX cache excluded and will rebuild. Run `ktok login <alias>` for the password (Keychain).",
            ])
            return
        }
        print("✓ Imported into \(home.path)")
        print("  next steps on this Mac:")
        print("   1) ktok login <alias>     # restore the password (Keychain; not in the archive)")
        print("   2) ktok persona validate  # confirm the persona loaded")
        print("   3) ktok channel monitor list   # confirm the allowlist")
        print("  (AX cache was excluded and rebuilds automatically on first use.)")
    }
}

private func printJSONDict(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}
