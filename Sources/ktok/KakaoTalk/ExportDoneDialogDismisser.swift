import ApplicationServices.HIServices
import Foundation

/// Click the OK button in KakaoTalk's "Successfully exported your chat
/// history" confirmation dialog. Uses AX AXPress (not keystroke), so no
/// system beep if the dialog isn't yet interactive.
///
/// The dialog appears after KakaoTalk finishes writing the export CSV.
/// We detect it by scanning the application root for AXSheet / AXDialog
/// that contains either a "Successfully exported" static text or an "OK"
/// button with exact label.
enum ExportDoneDialogDismisser {
    /// Returns true if an OK button was successfully pressed; false if no
    /// dialog was detected within the timeout window (which is fine — the
    /// dialog may have auto-dismissed or never appeared).
    @discardableResult
    static func dismiss(kakao: KakaoTalkApp, runner: AXActionRunner, timeoutSec: TimeInterval = 3.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            if let okButton = findOKButton(kakao: kakao) {
                do {
                    try okButton.press()
                    runner.log("export-done-dialog: pressed OK via AXPress")
                    return true
                } catch {
                    runner.log("export-done-dialog: OK press failed (\(error)); continuing")
                    return false
                }
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        runner.log("export-done-dialog: no OK button detected within \(timeoutSec)s (dialog may have auto-dismissed)")
        return false
    }

    /// Find an "OK" button belonging to the export-done confirmation dialog.
    /// We look for AXButton elements whose title is exactly "OK" (or the
    /// Korean equivalent) in any KakaoTalk window or sheet. To avoid pressing
    /// an unrelated OK button, we require the button to be in a window /
    /// sheet that ALSO contains a static text mentioning "Successfully
    /// exported" or "내보내기" — that's the dialog-level fingerprint.
    private static func findOKButton(kakao: KakaoTalkApp) -> UIElement? {
        let candidateRoots = kakao.windows + [kakao.applicationElement]
        let okLabels: Set<String> = ["OK", "확인"]
        let dialogTextMarkers: [String] = [
            "Successfully exported",
            "successfully exported",
            "exported your chat",
            "내보내기",
            "저장되었습니다",
        ]

        for root in candidateRoots {
            let buttons = root.findAll(role: kAXButtonRole, limit: 40, maxNodes: 400)
            guard let okCandidate = buttons.first(where: { btn in
                let title = (btn.title ?? "").trimmingCharacters(in: .whitespaces)
                return okLabels.contains(title)
            }) else {
                continue
            }

            // Confirm the dialog marker appears somewhere in the same root —
            // avoids pressing an OK on an unrelated dialog/sheet.
            let texts = root.findAll(role: kAXStaticTextRole, limit: 40, maxNodes: 400)
            let hasMarker = texts.contains { t in
                let v = (t.stringValue ?? "").trimmingCharacters(in: .whitespaces)
                return dialogTextMarkers.contains { marker in
                    v.localizedCaseInsensitiveContains(marker)
                }
            }
            if hasMarker {
                return okCandidate
            }
        }
        return nil
    }
}
