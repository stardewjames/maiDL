import Foundation

struct LinkError: LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

/// Link parsing shared by the app and the share extension.
enum LinkExtractor {
    private static let httpURL = try! NSRegularExpression(
        pattern: "https?://[^\\s<>\"]+",
        options: [.caseInsensitive]
    )
    private static let bareHost = try! NSRegularExpression(
        pattern: "^(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}(?::\\d+)?(?:[/?#].*)?$",
        options: [.caseInsensitive]
    )
    private static let trailingCharacters = ".,;:!?]}>'\""

    static func parse(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw LinkError(
                code: "invalid_link",
                message: "Paste a video or image link first."
            )
        }
        if let found = firstURL(in: text) {
            return normalize(found)
        }
        if !text.contains(where: { $0.isWhitespace }),
           matches(bareHost, text),
           let url = URL(string: "https://\(text)") {
            return normalize(url)
        }
        throw LinkError(
            code: "invalid_link",
            message: "That doesn't look like an http or https link."
        )
    }

    static func firstURL(in text: String) -> URL? {
        let nsText = text as NSString
        let matches = httpURL.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        for match in matches {
            let candidate = trim(nsText.substring(with: match.range))
            if let url = URL(string: candidate),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                return url
            }
        }
        return nil
    }

    static func normalize(_ url: URL) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else { return url }
        components.fragment = nil
        return components.url ?? url
    }

    private static func trim(_ value: String) -> String {
        var candidate = value
        while let last = candidate.last {
            if trailingCharacters.contains(last) {
                candidate.removeLast()
                continue
            }
            if last == ")", candidate.reduce(0, { balance, character in
                balance + (character == "(" ? 1 : character == ")" ? -1 : 0)
            }) < 0 {
                candidate.removeLast()
                continue
            }
            break
        }
        return candidate
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }
}
