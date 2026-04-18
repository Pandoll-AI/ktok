import Foundation

/// Classifies a KakaoTalk CSV row into a `MessageKind` plus (if applicable)
/// an attachment filename. Pure function — no DB or AX side effects.
///
/// Rules are driven by patterns observed in real KakaoTalk English-export
/// CSVs. Unknown markers fall through to `.text` (NOT `.other`) to avoid
/// over-labelling — .other is reserved for explicit future markers we know
/// are non-text but don't yet classify.
///
/// To extend: add a case to `detect(...)`. Preserve the raw message in the
/// caller's `raw_line` column so later re-classification can re-run over all
/// rows without losing source text.
enum MessageClassifier {
    struct Output {
        let kind: MessageKind
        let author: String          // may be rewritten ("system" for deletes)
        let body: String            // may be trimmed
        let attachmentFilename: String?
    }

    static func classify(rawUser: String, rawMessage: String) -> Output {
        let trimmedUser = rawUser.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = rawMessage

        // System: a message deletion is emitted with BOTH user and date blank
        // in the source CSV. The parser already strips the (empty) Date.
        if trimmedBody == "The message has been deleted." {
            return Output(
                kind: .system,
                author: "system",
                body: trimmedBody,
                attachmentFilename: nil
            )
        }

        // System: invitations / joins / leaves — actor is the User column.
        if !trimmedUser.isEmpty, isChatLifecycleEvent(trimmedBody, actor: trimmedUser) {
            return Output(
                kind: .system,
                author: trimmedUser,
                body: trimmedBody,
                attachmentFilename: nil
            )
        }

        // File: attached file (any type) — filename lives after the prefix.
        if trimmedBody.hasPrefix("File: ") {
            let filename = String(trimmedBody.dropFirst("File: ".count))
                .trimmingCharacters(in: .whitespaces)
            return Output(
                kind: .file,
                author: trimmedUser,
                body: trimmedBody,
                attachmentFilename: filename.isEmpty ? nil : filename
            )
        }

        // Image: KakaoTalk emits bare "Photo" (no caption, no album counter
        // observed yet). Keep as exact match — loose `hasPrefix` risks
        // false positives on legitimate text starting with "Photo".
        if trimmedBody == "Photo" {
            return Output(kind: .image, author: trimmedUser, body: trimmedBody, attachmentFilename: nil)
        }

        // Video / Voice / Emoticon — pattern guesses based on KakaoTalk's
        // typical English placeholders. Refine once we see real samples.
        if trimmedBody == "Video" {
            return Output(kind: .video, author: trimmedUser, body: trimmedBody, attachmentFilename: nil)
        }
        if trimmedBody == "Voice Note" || trimmedBody == "Voice Message" {
            return Output(kind: .voice, author: trimmedUser, body: trimmedBody, attachmentFilename: nil)
        }
        if trimmedBody == "Emoticon" {
            return Output(kind: .emoticon, author: trimmedUser, body: trimmedBody, attachmentFilename: nil)
        }

        // Default: text (possibly multi-line).
        return Output(kind: .text, author: trimmedUser, body: trimmedBody, attachmentFilename: nil)
    }

    private static func isChatLifecycleEvent(_ body: String, actor: String) -> Bool {
        // Phrases observed in English export:
        //   "{name} invited {name}."
        //   "{name} left the chatroom."
        //   "{name} joined the chatroom."
        // Detection anchors on the actor's name appearing as a prefix AND a
        // known lifecycle verb — reduces false positives against normal text
        // that happens to mention "invited" or "left".
        guard body.hasPrefix(actor) else { return false }
        let lowered = body.lowercased()
        return lowered.contains(" invited ")
            || lowered.contains(" left the chatroom")
            || lowered.contains(" joined the chatroom")
    }
}
