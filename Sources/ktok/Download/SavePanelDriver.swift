import AppKit
import Foundation

/// Interact with the `NSSavePanel` that KakaoTalk opens after "Save As".
enum SavePanelDriver {
    /// Poll the AX tree for a sheet on window 1, or any window with subrole
    /// `AXDialog`. Returns true if seen within `timeoutSec`.
    static func waitForSavePanel(timeoutSec: TimeInterval = 4.0) -> Bool {
        let script = """
        tell application "System Events"
          tell process "KakaoTalk"
            try
              if (count of sheets of window 1) > 0 then return "YES"
            end try
            try
              repeat with w in windows
                if subrole of w is "AXDialog" then return "YES"
              end repeat
            end try
          end tell
        end tell
        return "NO"
        """
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            let output = AppleScriptRunner.runAppleScript(script, timeoutSec: 2.0)
            if output.returncode == 0, output.stdout.contains("YES") {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Click the Download / Save button inside the KakaoTalk Save panel.
    static func clickDownloadButton() -> Bool {
        let script = """
        var se=Application("System Events");
        var kk=se.processes.byName("KakaoTalk");
        var wins=kk.windows();var saveWin=null;
        for(var w=0;w<wins.length;w++){
        try{if(wins[w].title()==="Save"||wins[w].title()==="저장"){
        saveWin=wins[w];break;}}catch(x){}}
        var clicked=false;
        function F(e,d){if(d>6||clicked)return;try{var c=e.uiElements();
        for(var i=0;i<c.length;i++){try{
        if(c[i].role()==="AXButton"&&
        (c[i].title()==="Download"||c[i].title()==="Save"
        ||c[i].title()==="다운로드"||c[i].title()==="저장")){
        c[i].actions.byName("AXPress").perform();clicked=true;return;}
        F(c[i],d+1);}catch(x){}}}catch(x){}}
        if(saveWin)F(saveWin,0);
        JSON.stringify({clicked:clicked,panel:saveWin!==null})
        """
        let output = AppleScriptRunner.runJXA(script, timeoutSec: 8.0)
        guard output.returncode == 0,
              let data = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return obj["clicked"] as? Bool ?? false
    }

    /// Override the Save panel's destination to `saveDir` via Cmd+Shift+G.
    ///
    /// Path goes through NSPasteboard (not keystrokes) so Unicode directory
    /// names survive keyboard-layout differences. Returns (success, info).
    static func overridePath(_ saveDir: String) -> (Bool, String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(saveDir, forType: .string)

        let drive = """
        tell application "System Events"
          tell process "KakaoTalk"
            keystroke "g" using {command down, shift down}
            delay 0.4
            keystroke "a" using command down
            delay 0.1
            keystroke "v" using command down
            delay 0.3
            keystroke return
            delay 0.5
            keystroke return
          end tell
        end tell
        return "OK"
        """
        let output = AppleScriptRunner.runAppleScript(drive, timeoutSec: 8.0)
        if output.returncode != 0 {
            let err = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let short = err.count > 160 ? String(err.prefix(160)) : err
            return (false, "drive_failed:\(short)")
        }
        return (true, "ok")
    }

    /// Accept the panel's default destination.
    static func acceptDefault() {
        let script = """
        tell application "System Events" to keystroke return
        """
        _ = AppleScriptRunner.runAppleScript(script, timeoutSec: 3.0)
    }

    /// Press the Save button in the NSSavePanel using AX AXPress (no
    /// keystroke, no system beep). Searches the entire KakaoTalk AX
    /// hierarchy for a button whose title is "Save" / "저장" — this
    /// covers both standalone panel windows and sheets attached to the
    /// settings window.
    ///
    /// Returns true if a Save button was successfully pressed. Falls
    /// back to `acceptDefault()` (keystroke return) if AX press misses
    /// — this is still usable as a last resort even though it may beep
    /// on some KakaoTalk versions.
    @discardableResult
    static func pressSaveButtonViaAX(kakao: KakaoTalkApp, runner: AXActionRunner, timeoutSec: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        let saveTitles: Set<String> = ["Save", "저장", "Download", "다운로드"]

        while Date() < deadline {
            let roots: [UIElement] = kakao.windows + [kakao.applicationElement]
            for root in roots {
                let buttons = root.findAll(role: kAXButtonRole, limit: 80, maxNodes: 600)
                guard let save = buttons.first(where: { saveTitles.contains(($0.title ?? "").trimmingCharacters(in: .whitespaces)) }) else {
                    continue
                }

                // Before pressing: find the enclosing window and raise it
                // so the Save panel gains focus. Pressing an unfocused
                // button produces a macOS beep even when the press itself
                // "succeeds" — the system treats it as a background-app
                // interaction and plays the alert sound.
                if let panelWindow = findEnclosingWindow(for: save) {
                    if let actions = try? panelWindow.actionNames(), actions.contains(kAXRaiseAction) {
                        do {
                            try panelWindow.performAction(kAXRaiseAction)
                            runner.log("save-panel: raised enclosing window before AX press")
                        } catch {
                            runner.log("save-panel: AXRaise failed (\(error)); continuing anyway")
                        }
                    }
                    // Also activate the app in case focus is on another app.
                    kakao.activate()
                    Thread.sleep(forTimeInterval: 0.12)
                }

                do {
                    try save.press()
                    runner.log("save-panel: pressed Save button via AX (title='\(save.title ?? "")')")
                    return true
                } catch {
                    runner.log("save-panel: AX press on Save failed (\(error))")
                }
            }
            Thread.sleep(forTimeInterval: 0.12)
        }
        runner.log("save-panel: Save button not found via AX within \(timeoutSec)s")
        return false
    }

    /// Walk up an element's parent chain to find the enclosing AXWindow.
    /// The Save button lives inside an AXSheet inside AXWindow (for a
    /// sheet-style save panel) OR directly inside AXWindow (standalone).
    private static func findEnclosingWindow(for element: UIElement) -> UIElement? {
        var cursor: UIElement? = element
        var hops = 0
        while let current = cursor, hops < 12 {
            if current.role == kAXWindowRole {
                return current
            }
            cursor = current.parent
            hops += 1
        }
        return nil
    }
}
