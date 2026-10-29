import Foundation

/// Finds a direct media URL in page metadata so sharing a page still works.
enum OgParser {
    private static let metaTag = try! NSRegularExpression(
        pattern: "<meta\\b[^>]*>",
        options: [.caseInsensitive]
    )
    private static let mediaTag = try! NSRegularExpression(
        pattern: "<(?:video|source)\\b[^>]*>",
        options: [.caseInsensitive]
    )
    private static let attribute = try! NSRegularExpression(
        pattern: "([\\w:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s\"'>]+))"
    )

    private static let priority = [
        "og:video:secure_url",
        "og:video:url",
        "og:video",
        "twitter:player:stream",
        "og:image:secure_url",
        "og:image:url",
        "og:image",
        "twitter:image",
    ]

    static func findMediaURL(in html: String, baseURL: URL) -> URL? {
        var found: [String: String] = [:]
        for match in metaTag.matches(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        ) {
            guard let range = Range(match.range, in: html) else { continue }
            let attributes = attributes(in: String(html[range]))
            let key = (attributes["property"] ?? attributes["name"])?
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard let key, let content = attributes["content"]?
                .trimmingCharacters(in: .whitespaces),
                !content.isEmpty,
                priority.contains(key),
                found[key] == nil
            else { continue }
            found[key] = content
        }
        for key in priority {
            if let value = found[key], let url = absolutize(value, baseURL: baseURL) {
                return url
            }
        }

        for match in mediaTag.matches(
            in: html,
            range: NSRange(html.startIndex..., in: html)
        ) {
            guard let range = Range(match.range, in: html) else { continue }
            let attributes = attributes(in: String(html[range]))
            if let source = attributes["src"],
               let url = absolutize(source, baseURL: baseURL) {
                return url
            }
        }
        return nil
    }

    static func absolutize(_ value: String, baseURL: URL) -> URL? {
        let decoded = decodeEntities(value.trimmingCharacters(in: .whitespaces))
        guard !decoded.isEmpty else { return nil }
        if decoded.hasPrefix("//") {
            let scheme = baseURL.scheme ?? "https"
            return URL(string: "\(scheme):\(decoded)")
        }
        guard let url = URL(string: decoded, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        var result = value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        result = decodeNumericEntities(result)
        return result
    }

    private static func decodeNumericEntities(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "&#x([0-9a-fA-F]+);|&#([0-9]+);"
        ) else { return value }
        let mutable = NSMutableString(string: value)
        let matches = regex.matches(
            in: value,
            range: NSRange(location: 0, length: (value as NSString).length)
        )
        for match in matches.reversed() {
            let hex = match.range(at: 1).location != NSNotFound
                ? (value as NSString).substring(with: match.range(at: 1))
                : nil
            let decimal = match.range(at: 2).location != NSNotFound
                ? (value as NSString).substring(with: match.range(at: 2))
                : nil
            let scalarValue = hex.flatMap { UInt32($0, radix: 16) }
                ?? decimal.flatMap { UInt32($0) }
            guard let scalarValue,
                  let scalar = Unicode.Scalar(scalarValue),
                  let range = Range(match.range, in: value)
            else { continue }
            let replacement = String(Character(scalar))
            mutable.replaceCharacters(
                in: NSRange(range, in: value),
                with: replacement
            )
        }
        return mutable as String
    }

    private static func attributes(in tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let nsTag = tag as NSString
        for match in attribute.matches(
            in: tag,
            range: NSRange(location: 0, length: nsTag.length)
        ) where match.numberOfRanges >= 5 {
            let name = nsTag.substring(with: match.range(at: 1)).lowercased()
            let value: String
            if match.range(at: 2).location != NSNotFound {
                value = nsTag.substring(with: match.range(at: 2))
            } else if match.range(at: 3).location != NSNotFound {
                value = nsTag.substring(with: match.range(at: 3))
            } else {
                value = nsTag.substring(with: match.range(at: 4))
            }
            if result[name] == nil { result[name] = value }
        }
        return result
    }
}
