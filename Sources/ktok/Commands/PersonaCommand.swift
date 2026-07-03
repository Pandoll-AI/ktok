import ArgumentParser
import Foundation

/// Manage persona config files under `~/.ktok/persona/`.
///
/// Persona identity/voice/owner data is user-owned and never committed. Scaffold
/// a starting file with `ktok persona init`, then edit it (or have an LLM fill it
/// in per docs/PERSONA_SETUP.md).
struct PersonaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "persona",
        abstract: "Manage persona config files under ~/.ktok/persona/",
        subcommands: [
            PersonaInitCommand.self,
            PersonaShowCommand.self,
            PersonaValidateCommand.self,
            PersonaPathCommand.self,
        ],
        defaultSubcommand: PersonaShowCommand.self
    )
}

struct PersonaInitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Scaffold a persona config file with neutral placeholders."
    )

    @Option(name: .long, help: "Persona name (file becomes ~/.ktok/persona/<name>.json).")
    var name: String = "luna"

    @Flag(name: .long, help: "Overwrite an existing config file.")
    var force: Bool = false

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() throws {
        let url = PersonaConfig.fileURL(name: name)
        if FileManager.default.fileExists(atPath: url.path) && !force {
            throw ValidationError("Config already exists at \(url.path). Use --force to overwrite.")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = PersonaConfig.neutralDefault(name: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(template)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

        if json {
            printJSON(["ok": true, "path": url.path, "name": name])
        } else {
            print("Wrote persona template: \(url.path)")
            print("Edit it to define identity/voice/owner. See docs/PERSONA_SETUP.md.")
            print("This file is private (gitignored) — never commit real names or biography.")
        }
    }
}

struct PersonaShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print the resolved persona config (file or neutral default)."
    )

    @Option(name: .long, help: "Persona name.")
    var name: String = "luna"

    func run() throws {
        let config = try PersonaConfig.load(name: name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(config)
        print(String(data: data, encoding: .utf8) ?? "{}")
    }
}

struct PersonaValidateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "validate",
        abstract: "Check that the persona config file parses."
    )

    @Option(name: .long, help: "Persona name.")
    var name: String = "luna"

    @Flag(name: .long, help: "Emit JSON.")
    var json: Bool = false

    func run() throws {
        let url = PersonaConfig.fileURL(name: name)
        let exists = FileManager.default.fileExists(atPath: url.path)
        do {
            let config = try PersonaConfig.load(name: name)
            let source = exists ? "file" : "neutral-default"
            if json {
                printJSON([
                    "ok": true,
                    "source": source,
                    "path": url.path,
                    "name": config.name,
                    "direct_call_count": config.triggers.directCall.count,
                    "system_prompt_chars": config.systemPrompt.count,
                ])
            } else {
                print("OK: persona '\(config.name)' loaded from \(source).")
                if !exists { print("(No file at \(url.path); using neutral default. Run 'ktok persona init'.)") }
            }
        } catch {
            if json {
                printJSON(["ok": false, "path": url.path, "error": "\(error)"])
            } else {
                print("INVALID: \(url.path) failed to parse: \(error)")
            }
            throw ExitCode.failure
        }
    }
}

struct PersonaPathCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path",
        abstract: "Print the persona config file path."
    )

    @Option(name: .long, help: "Persona name.")
    var name: String = "luna"

    func run() throws {
        print(PersonaConfig.fileURL(name: name).path)
    }
}

private func printJSON(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
       let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}
