import Foundation

/// Polls one or more directories for a newly-landed, stable file — used to
/// detect when a KakaoTalk download completes.
enum DirectoryWatcher {
    struct Entry: Equatable {
        let mtime: TimeInterval
        let size: Int
    }

    typealias Snapshot = [String: Entry]

    private static let inProgressSuffixes = [".download", ".crdownload", ".part", ".tmp"]
    private static let pollInterval: TimeInterval = 0.5

    static func snapshot(_ path: String) -> Snapshot {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else {
            return [:]
        }
        var result: Snapshot = [:]
        for name in names {
            if name.hasPrefix(".") { continue }
            let full = (path as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: full) else { continue }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            result[name] = Entry(mtime: mtime, size: size)
        }
        return result
    }

    /// Wait for a new file in any watched directory whose (mtime, size) is
    /// stable across two polls and whose name does not end with an
    /// in-progress download suffix.
    static func waitForNewStableFile(
        dirs: [String],
        baseline: [String: Snapshot],
        timeoutSec: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(max(1.0, timeoutSec))
        var lastSeen: [String: Entry] = [:]

        while Date() < deadline {
            for dir in dirs {
                let current = snapshot(dir)
                let base = baseline[dir] ?? [:]
                for (name, entry) in current {
                    if base[name] == entry { continue }
                    if inProgressSuffixes.contains(where: { name.hasSuffix($0) }) { continue }
                    if entry.size <= 0 { continue }
                    let key = (dir as NSString).appendingPathComponent(name)
                    let previous = lastSeen[key]
                    lastSeen[key] = entry
                    if previous == entry {
                        return key
                    }
                }
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return nil
    }

    /// If the file appeared in ~/Downloads but the caller wanted it elsewhere,
    /// move it. Returns the final path (may be unchanged on error).
    static func relocateIfNeeded(_ path: String, preferredDir: String) -> String {
        let fm = FileManager.default
        let currentDir = (path as NSString).deletingLastPathComponent
        let standardPreferred = URL(fileURLWithPath: preferredDir).standardizedFileURL.path
        let standardCurrent = URL(fileURLWithPath: currentDir).standardizedFileURL.path
        if standardCurrent == standardPreferred { return path }

        let basename = (path as NSString).lastPathComponent
        let destination = (standardPreferred as NSString).appendingPathComponent(basename)
        if fm.fileExists(atPath: destination) {
            return path // do not clobber
        }
        do {
            try fm.moveItem(atPath: path, toPath: destination)
            return destination
        } catch {
            return path
        }
    }
}
