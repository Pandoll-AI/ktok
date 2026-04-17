import Foundation

/// Matches the 60+ file extensions KakaoTalk treats as attachments plus the
/// Korean/English save/download markers surfaced on file bubbles.
///
/// Groups mirror the Python source:
///   Office / 한글, PDF/text/data, Image, Video, Audio, Archive,
///   Executable/installer, Dev/script, Design, Other.
enum FileExtensionMatcher {
    static let saveMarkers: Set<String> = [
        "저장", "다운로드", "download", "Download", "Save", "save", "Save As",
    ]

    private static let pattern =
        #"\.\b(xlsx?|docx?|pptx?|hwpx?|hwt|ods|odt|odp"#
        + #"|pdf|csv|txt|json|xml|yaml|yml|log|md"#
        + #"|png|jpe?g|gif|bmp|tiff?|svg|webp|heic"#
        + #"|mp4|mov|avi|mkv|wmv|webm"#
        + #"|mp3|wav|aac|m4a|ogg|flac"#
        + #"|zip|rar|7z|tar|gz|tgz|bz2"#
        + #"|exe|dmg|pkg|apk|ipa"#
        + #"|py|js|ts|sh|sql"#
        + #"|psd|ai|fig|sketch"#
        + #"|ics|vcf|eml)\b"#

    static let regex: NSRegularExpression = {
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            // The pattern is a literal — compilation failure would be a programmer error
            // surfaced only during development, never at runtime for a release build.
            fatalError("FileExtensionMatcher regex failed to compile")
        }
        return compiled
    }()

    static func containsKnownExtension(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return regex.firstMatch(in: text, options: [], range: range) != nil
    }

    static func containsSaveMarker(_ text: String) -> Bool {
        for marker in saveMarkers where text.contains(marker) {
            return true
        }
        return false
    }
}
