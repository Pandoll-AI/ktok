import CoreGraphics
import Foundation

/// Live KakaoTalk window geometry, queried via AppleScript / System Events.
///
/// We deliberately avoid AX-tree traversal here because the chat window title
/// varies per chat, so a bounds lookup that depends on the current front
/// window is simpler and correct without resolver plumbing.
enum KakaoTalkWindowBounds {
    /// Front KakaoTalk window bounds: (x, y, width, height) in screen coordinates.
    static func frontWindow() -> CGRect? {
        let script = """
        tell application "System Events"
          tell process "KakaoTalk"
            set p to position of window 1
            set s to size of window 1
            return {item 1 of p, item 2 of p, item 1 of s, item 2 of s}
          end tell
        end tell
        """
        let output = AppleScriptRunner.runAppleScript(script, timeoutSec: 5.0)
        guard output.returncode == 0 else { return nil }
        return parse4Tuple(output.stdout)
    }

    private static func parse4Tuple(_ raw: String) -> CGRect? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.components(separatedBy: ", ")
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let w = Double(parts[2]),
              let h = Double(parts[3])
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
