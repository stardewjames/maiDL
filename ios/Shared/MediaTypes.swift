import Foundation

enum MediaKind: String {
    case video
    case image
    case unknown
}

enum MediaTypes {
    private static let extensionKind: [String: MediaKind] = [
        "mp4": .video, "m4v": .video, "mov": .video, "webm": .video,
        "mkv": .video, "avi": .video, "3gp": .video, "mpg": .video,
        "mpeg": .video,
        "jpg": .image, "jpeg": .image, "png": .image, "gif": .image,
        "webp": .image, "heic": .image, "heif": .image, "bmp": .image,
        "tif": .image, "tiff": .image,
    ]

    private static let mimeExtension: [String: String] = [
        "video/mp4": "mp4",
        "video/quicktime": "mov",
        "video/webm": "webm",
        "video/x-matroska": "mkv",
        "video/3gpp": "3gp",
        "video/mpeg": "mpg",
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/gif": "gif",
        "image/webp": "webp",
        "image/heic": "heic",
        "image/heif": "heif",
        "image/bmp": "bmp",
        "image/tiff": "tiff",
    ]

    private static let extensionMime: [String: String] = [
        "mp4": "video/mp4",
        "m4v": "video/mp4",
        "mov": "video/quicktime",
        "webm": "video/webm",
        "mkv": "video/x-matroska",
        "3gp": "video/3gpp",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "png": "image/png",
        "gif": "image/gif",
        "webp": "image/webp",
        "heic": "image/heic",
        "heif": "image/heif",
        "bmp": "image/bmp",
        "tiff": "image/tiff",
    ]

    private static let unsafeCharacters = try! NSRegularExpression(
        pattern: "[^A-Za-z0-9._ ()-]"
    )

    static func kind(forMime mime: String?) -> MediaKind {
        guard let type = normalizedMime(mime) else { return .unknown }
        if type.hasPrefix("video/") { return .video }
        if type.hasPrefix("image/") { return .image }
        return .unknown
    }

    static func kind(forUrl url: String) -> MediaKind {
        guard let extensionName = URL(string: url)?.pathExtension.lowercased(),
              !extensionName.isEmpty
        else { return .unknown }
        return extensionKind[extensionName] ?? .unknown
    }

    static func fileExtension(forMime mime: String?) -> String? {
        guard let type = normalizedMime(mime) else { return nil }
        return mimeExtension[type]
    }

    static func extensionOf(_ name: String) -> String? {
        let value = (name as NSString).lastPathComponent
        guard let dot = value.lastIndex(of: "."),
              dot != value.index(before: value.endIndex)
        else { return nil }
        return String(value[value.index(after: dot)...]).lowercased()
    }

    static func contentType(forFileName name: String) -> String {
        guard let extensionName = extensionOf(name) else {
            return "application/octet-stream"
        }
        return extensionMime[extensionName] ?? "application/octet-stream"
    }

    static func isMedia(fileName: String) -> Bool {
        guard let extensionName = extensionOf(fileName) else { return false }
        return extensionKind[extensionName] != nil
    }

    static func isHtml(mime: String?) -> Bool {
        guard let type = normalizedMime(mime) else { return false }
        return type == "text/html" || type == "application/xhtml+xml"
    }

    static func isStreamingPlaylist(mime: String?, url: String) -> Bool {
        if let type = normalizedMime(mime) {
            if type.contains("mpegurl") || type == "application/dash+xml" {
                return true
            }
        }
        let extensionName = URL(string: url)?.pathExtension.lowercased() ?? ""
        return extensionName == "m3u8" || extensionName == "mpd"
    }

    static func fileName(
        forUrl url: String,
        contentType: String?,
        contentDisposition: String?,
        suggestedFilename: String?,
        fallbackMillis: Int64
    ) -> String {
        let headerName = contentDisposition.flatMap(parseContentDispositionName)
        let suggested = suggestedFilename?.isEmpty == false ? suggestedFilename : nil
        let urlName = nameFromUrl(url)
        let candidate = headerName ?? suggested ?? urlName ?? "maiDL_\(fallbackMillis)"

        let mimeExtension = fileExtension(forMime: contentType)
        let candidateExtension = extensionOf(candidate)

        var base = candidate
        if let candidateExtension,
           extensionKind[candidateExtension] != nil,
           let dot = candidate.lastIndex(of: ".") {
            base = String(candidate[..<dot])
        }
        base = sanitize(base)
        if base.isEmpty { base = "maiDL_\(fallbackMillis)" }

        let extensionName = mimeExtension ?? candidateExtension.flatMap { value in
            extensionKind[value] != nil ? value : nil
        }
        guard let extensionName else { return base }
        return "\(base).\(extensionName)"
    }

    static func parseContentDispositionName(_ header: String) -> String? {
        let encodedPattern = "filename\\*\\s*=\\s*(?:[A-Za-z0-9-]+)?'[^']*'([^;]+)"
        if let regex = try? NSRegularExpression(
            pattern: encodedPattern,
            options: [.caseInsensitive]
        ) {
            let text = header as NSString
            if let match = regex.firstMatch(
                in: header,
                range: NSRange(location: 0, length: text.length)
            ), match.numberOfRanges > 1 {
                let raw = text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"\t"))
                if !raw.isEmpty,
                   let decoded = raw.removingPercentEncoding,
                   !decoded.isEmpty {
                    return decoded
                }
            }
        }
        let quotedPattern = "filename\\s*=\\s*\"([^\"]+)\""
        if let regex = try? NSRegularExpression(
            pattern: quotedPattern,
            options: [.caseInsensitive]
        ) {
            let text = header as NSString
            if let match = regex.firstMatch(
                in: header,
                range: NSRange(location: 0, length: text.length)
            ), match.numberOfRanges > 1 {
                return text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let barePattern = "filename\\s*=\\s*([^;]+)"
        if let regex = try? NSRegularExpression(
            pattern: barePattern,
            options: [.caseInsensitive]
        ) {
            let text = header as NSString
            if let match = regex.firstMatch(
                in: header,
                range: NSRange(location: 0, length: text.length)
            ), match.numberOfRanges > 1 {
                return text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"\t\r\n"))
            }
        }
        return nil
    }

    static func sanitize(_ value: String) -> String {
        let range = NSRange(value.startIndex..., in: value)
        let cleaned = unsafeCharacters.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "_"
        )
        return cleaned.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    private static func normalizedMime(_ mime: String?) -> String? {
        guard let mime else { return nil }
        let type = mime.split(separator: ";").first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let type, !type.isEmpty else { return nil }
        return type
    }

    private static func nameFromUrl(_ url: String) -> String? {
        guard let parsed = URL(string: url) else { return nil }
        let last = parsed.lastPathComponent
        guard !last.isEmpty, last != "/" else { return nil }
        return last.removingPercentEncoding ?? last
    }
}
