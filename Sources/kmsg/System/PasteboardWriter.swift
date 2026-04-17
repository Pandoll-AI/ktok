import AppKit
import Foundation

enum PasteboardWriter {
    /// Copy a file to the general pasteboard so Cmd+V pastes it as an attachment.
    ///
    /// KakaoTalk's desktop app only accepts file drops when `NSFilenamesPboardType`
    /// is present, so we write both the NSURL object and the deprecated path list.
    static func writeFile(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setPropertyList([url.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    }
}
