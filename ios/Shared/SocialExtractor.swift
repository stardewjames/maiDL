import Foundation

struct SocialMedia {
    let mediaUrl: URL
    let fileName: String?
    let referer: String
    let cookie: String?
}

enum SocialPlatform {
    case tiktok
    case instagram
    case x

    var referer: String {
        switch self {
        case .tiktok: return "https://www.tiktok.com/"
        case .instagram: return "https://www.instagram.com/"
        case .x: return "https://x.com/"
        }
    }

    var fileNameFallback: String {
        switch self {
        case .tiktok: return "tiktok.mp4"
        case .instagram: return "instagram.mp4"
        case .x: return "x.mp4"
        }
    }
}

enum SocialExtractorError: LocalizedError {
    case unsupported
    case blocked
    case noMedia

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Only TikTok, Instagram and X links use the built-in extractor."
        case .blocked:
            return "That page blocked the request. Try copying the direct video link."
        case .noMedia:
            return "No downloadable video was found. The post may require login."
        }
    }
}

/// Extracts a media URL from a public TikTok, Instagram or X page without a
/// server. The extractor keeps the page cookies so the download request uses
/// the same session that produced the media URL.
enum SocialExtractor {
    private static let userAgent = SharedConfig.userAgent
    private static let supportedHosts: [(String, SocialPlatform)] = [
        ("tiktok.com", .tiktok),
        ("instagram.com", .instagram),
        ("x.com", .x),
        ("twitter.com", .x),
        ("t.co", .x),
    ]

    static func platform(for url: URL) -> SocialPlatform? {
        guard let host = url.host?.lowercased() else { return nil }
        for (suffix, platform) in supportedHosts
            where host == suffix || host.hasSuffix(".\(suffix)") {
            return platform
        }
        return nil
    }

    static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "youtube.com" || host.hasSuffix(".youtube.com")
            || host == "youtu.be"
    }

    static func extract(
        _ url: URL,
        completion: @escaping (Result<SocialMedia, Error>) -> Void
    ) {
        guard let platform = platform(for: url) else {
            completion(.failure(SocialExtractorError.unsupported))
            return
        }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 30

        URLSession.shared.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(SocialExtractorError.blocked))
                return
            }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data
            else {
                completion(.failure(SocialExtractorError.blocked))
                return
            }
            let html = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
            let base = http.url ?? url
            do {
                completion(.success(
                    try parse(html, url: base, platform: platform)
                ))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func parse(
        _ html: String,
        url: URL,
        platform: SocialPlatform
    ) throws -> SocialMedia {
        switch platform {
        case .tiktok:
            return try parseTikTok(html, url: url)
        case .instagram:
            return try parseInstagram(html, url: url)
        case .x:
            return try parseX(html, url: url)
        }
    }

    private static func parseTikTok(_ html: String, url: URL) throws -> SocialMedia {
        for identifier in ["__UNIVERSAL_DATA_FOR_REHYDRATION__", "SIGI_STATE"] {
            guard let json = scriptJSON(html, id: identifier) else { continue }
            if let video = findVideo(json) {
                let raw = (video["downloadAddr"] as? String)
                    ?? (video["playAddr"] as? String)
                if let raw, let media = httpURL(raw) {
                    return makeMedia(media, platform: .tiktok)
                }
            }
            if let raw = findImagePost(json), let media = httpURL(raw) {
                return makeMedia(media, platform: .tiktok)
            }
        }
        if let media = OgParser.findMediaURL(in: html, baseURL: url),
           isVideoURL(media) {
            return makeMedia(media, platform: .tiktok)
        }
        throw SocialExtractorError.noMedia
    }

    private static func parseInstagram(_ html: String, url: URL) throws -> SocialMedia {
        let candidates = [
            firstMatch("\\\"video_url\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", in: html),
            firstMatch("\\\"contentUrl\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"", in: html),
            firstMatch(
                "\\\"video_versions\\\"\\s*:\\s*\\[\\s*\\{[^}]*\\\"url\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"",
                in: html
            ),
        ]
        for raw in candidates {
            if let raw, let media = httpURL(raw) {
                return makeMedia(media, platform: .instagram)
            }
        }
        if let media = OgParser.findMediaURL(in: html, baseURL: url) {
            let reel = url.path.contains("/reel/") || url.path.contains("/tv/")
            if reel && !isVideoURL(media) {
                throw SocialExtractorError.noMedia
            }
            return makeMedia(media, platform: .instagram)
        }
        throw SocialExtractorError.noMedia
    }

    private static func parseX(_ html: String, url: URL) throws -> SocialMedia {
        if let media = OgParser.findMediaURL(in: html, baseURL: url),
           isVideoURL(media) {
            return makeMedia(media, platform: .x)
        }
        let raw = allMatches(
            "video\\.twimg\\.com[^\"'\\s]+?\\.mp4(?:\\?[^\"'\\s]*)?",
            in: html
        )
        for candidate in raw.reversed() {
            if let media = httpURL("https://\(candidate)") {
                return makeMedia(media, platform: .x)
            }
        }
        // Photo tweets have no video; allow their image.
        if let media = OgParser.findMediaURL(in: html, baseURL: url) {
            return makeMedia(media, platform: .x)
        }
        throw SocialExtractorError.noMedia
    }

    private static func makeMedia(
        _ media: URL,
        platform: SocialPlatform
    ) -> SocialMedia {
        let suggested = isVideoURL(media) ? platform.fileNameFallback : nil
        let fileName = MediaTypes.fileName(
            forUrl: media.absoluteString,
            contentType: nil,
            contentDisposition: nil,
            suggestedFilename: suggested,
            fallbackMillis: JobRecord.nowMillis()
        )
        return SocialMedia(
            mediaUrl: media,
            fileName: fileName,
            referer: platform.referer,
            cookie: cookieHeader(for: media)
        )
    }

    private static func cookieHeader(for url: URL) -> String? {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !cookies.isEmpty else { return nil }
        return cookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func scriptJSON(_ html: String, id: String) -> Any? {
        let escaped = NSRegularExpression.escapedPattern(for: id)
        guard let body = firstMatch(
            "<script[^>]+id=\"\(escaped)\"[^>]*>(.*?)</script>",
            in: html
        ), let data = body.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func findImagePost(_ value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let post = dict["imagePost"] as? [String: Any],
               let images = post["images"] as? [[String: Any]] {
                for image in images {
                    if let imageURL = image["imageURL"] as? [String: Any] {
                        if let list = imageURL["urlList"] as? [String],
                           let first = list.first(where: { !$0.isEmpty }) {
                            return first
                        }
                        if let raw = imageURL["url"] as? String, !raw.isEmpty {
                            return raw
                        }
                    }
                    if let raw = image["displayImage"] as? String, !raw.isEmpty {
                        return raw
                    }
                }
            }
            for child in dict.values {
                if let found = findImagePost(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findImagePost(child) { return found }
            }
        }
        return nil
    }

    private static func findVideo(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            if dict["playAddr"] is String || dict["downloadAddr"] is String {
                return dict
            }
            for child in dict.values {
                if let found = findVideo(child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findVideo(child) { return found }
            }
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let found = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[found])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let found = Range(match.range, in: text) else { return nil }
            return String(text[found])
        }
    }

    private static func httpURL(_ raw: String) -> URL? {
        let cleaned = unescape(raw)
        guard let url = URL(string: cleaned),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003d", with: "=")
            .replacingOccurrences(of: "\\u0025", with: "%")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    private static func isVideoURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v", "webm"].contains(ext) { return true }
        let value = url.absoluteString.lowercased()
        return value.contains("video") || value.contains("mime_type=video")
    }
}
