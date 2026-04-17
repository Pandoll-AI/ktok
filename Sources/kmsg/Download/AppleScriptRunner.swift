import Darwin
import Foundation

/// Runs AppleScript / JXA via `osascript` with a timeout and argv.
///
/// Using argv (not string interpolation) keeps user input (chat names, filenames,
/// paths) unpoisonable — the same guarantee the Python MCP locked in (commit b14ade1).
struct AppleScriptRunner {
    struct Output {
        let returncode: Int32
        let stdout: String
        let stderr: String
        let latencyMs: Int
        let timedOut: Bool
    }

    static func runAppleScript(_ script: String, argv: [String] = [], timeoutSec: TimeInterval = 10.0) -> Output {
        var args = ["-e", script]
        if !argv.isEmpty {
            args.append("--")
            args.append(contentsOf: argv)
        }
        return runProcess(arguments: args, timeoutSec: timeoutSec)
    }

    static func runJXA(_ script: String, argv: [String] = [], timeoutSec: TimeInterval = 15.0) -> Output {
        var args = ["-l", "JavaScript", "-e", script]
        if !argv.isEmpty {
            args.append("--")
            args.append(contentsOf: argv)
        }
        return runProcess(arguments: args, timeoutSec: timeoutSec)
    }

    private static func runProcess(arguments: [String], timeoutSec: TimeInterval) -> Output {
        let start = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return Output(
                returncode: 127,
                stdout: "",
                stderr: String(describing: error),
                latencyMs: Int(Date().timeIntervalSince(start) * 1000),
                timedOut: false
            )
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            semaphore.signal()
        }

        let timedOut = semaphore.wait(timeout: .now() + timeoutSec) == .timedOut
        if timedOut {
            process.terminate()
            let killSem = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                process.waitUntilExit()
                killSem.signal()
            }
            if killSem.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let stdout = String(decoding: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: stderrPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return Output(
            returncode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            latencyMs: Int(Date().timeIntervalSince(start) * 1000),
            timedOut: timedOut
        )
    }
}
