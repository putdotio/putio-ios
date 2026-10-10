import Foundation

// Foundation-only on purpose: no Sentry, UIKit, or app types, so the SwiftUI
// app on `next` can adopt this file unchanged when it adds Sentry (#139).

/// A failure the app reports, reduced to fields that are safe to send:
/// a stable category, the error's domain and code, and allowlisted context.
/// Raw error messages, user info, URLs, and media names never get here.
struct TelemetryFailure: Equatable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case downloadedAssetDeletion = "downloaded_asset_deletion"
        case downloadsObservation = "downloads_observation"
        case playback
        case pushRegistration = "push_registration"
    }

    enum ContextKey: String, CaseIterable, Sendable {
        case platform
        case player
    }

    let category: Category
    let domain: String
    let code: Int
    let context: [ContextKey: String]

    init(_ category: Category, error: Error? = nil, context: [ContextKey: String] = [:]) {
        self.category = category
        if let error {
            let nsError = error as NSError
            domain = TelemetryRedaction.scrub(nsError.domain)
            code = nsError.code
        } else {
            domain = "io.put.telemetry"
            code = 0
        }
        self.context = context.mapValues { TelemetryRedaction.scrub($0) }
    }

    /// Groups events by what failed, never by message text.
    var fingerprint: [String] {
        [category.rawValue, domain, String(code)]
    }

    var tags: [String: String] {
        var tags = ["category": category.rawValue, "error_domain": domain, "error_code": String(code)]
        for (key, value) in context {
            tags[key.rawValue] = value
        }
        return tags
    }

    static let tagKeys: Set<String> = Set(["category", "error_domain", "error_code"] + ContextKey.allCases.map(\.rawValue))
}

/// The redaction rules every telemetry field goes through.
enum TelemetryRedaction {
    static let redacted = "[redacted]"
    static let path = "[path]"
    static let file = "[file]"

    /// Strips credentials, URL paths and query values, file paths, and media
    /// filenames from free text. Media titles have no detectable shape, which is
    /// why reporters send `TelemetryFailure` categories instead of messages.
    static func scrub(_ text: String) -> String {
        var result = replaceURLs(in: text)
        result = replace(#"(?i)\b(bearer|basic|token|digest)\s+[A-Za-z0-9._~+/=-]{6,}"#, in: result, with: "$1 \(redacted)")
        result = replace(
            #"(?i)([A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|pwd|auth[a-z]*|signature|sig|api[_-]?key|access[_-]?key|cookie|session[_-]?id|credential|otp)[A-Za-z0-9_.-]*)("?\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s&,;"')\]}]+)"#,
            in: result,
            with: "$1$2\(redacted)"
        )
        result = replace(#"(?:~|\B)/(?:[^\s/:"'\[\]]+/)+[^\s/:"'\[\]]*"#, in: result, with: path)
        result = replace(
            #"(?i)[^\s/\\"'\[\]]+\.(?:mkv|mp4|m4v|mov|avi|wmv|flv|webm|mpe?g|ts|m3u8|mpd|mp3|m4a|m4b|aac|flac|wav|ogg|opus|srt|vtt|ass|ssa|sub|idx|pdf|epub|cbz|cbr|zip|rar|7z|tar|gz|iso|torrent|jpe?g|png|gif|heic|webp|txt|nfo|docx?)\b"#,
            in: result,
            with: file
        )
        return result
    }

    /// Scrubs a value of any telemetry shape. Keys that name credentials or
    /// media lose their value entirely; unknown object types are dropped rather
    /// than serialized through `description`.
    static func scrub(value: Any, key: String? = nil) -> Any {
        if let key, isSensitiveKey(key) {
            return redacted
        }
        switch value {
        case let string as String:
            return scrub(string)
        case let url as URL:
            return scrub(url.absoluteString)
        case let dictionary as [String: Any]:
            return scrub(dictionary)
        case let array as [Any]:
            return array.map { scrub(value: $0) }
        case let error as NSError:
            return "\(scrub(error.domain)) \(error.code)"
        case is NSNumber, is Bool, is Int, is Double, is Date, is NSNull:
            return value
        default:
            return redacted
        }
    }

    static func scrub(_ dictionary: [String: Any]) -> [String: Any] {
        dictionary.reduce(into: [:]) { result, entry in
            result[entry.key] = scrub(value: entry.value, key: entry.key)
        }
    }

    /// True for keys whose values are credentials, request payloads, or media
    /// identity. URL-like keys are not listed: their values keep only the host.
    static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
        if exactSensitiveKeys.contains(normalized) {
            return true
        }
        return sensitiveKeyFragments.contains { normalized.contains($0) }
    }

    private static let exactSensitiveKeys: Set<String> = [
        "body", "cookies", "email", "file", "fragment", "headers", "httpfragment", "httpquery",
        "ipaddress", "mail", "path", "query", "querystring", "title", "username",
    ]

    private static let sensitiveKeyFragments = [
        "accesskey", "apikey", "assettitle", "auth", "cookie", "credential", "filename", "filepath",
        "mediatitle", "otp", "passwd", "password", "secret", "sessionid", "signature", "token",
    ]

    private static func replaceURLs(in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>\]\[)(]+"#) else {
            return redacted
        }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += urlPlaceholder(for: source.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }

    private static func urlPlaceholder(for url: String) -> String {
        guard let components = URLComponents(string: url), components.scheme?.lowercased() != "file" else {
            return path
        }
        guard let host = components.host, host.isEmpty == false else {
            return "[url]"
        }
        return "[url:\(host.lowercased())]"
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return redacted
        }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }
}
