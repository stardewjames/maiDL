import Foundation

enum ResolverMode: String, Codable {
    case off
    case ytdlp
}

struct ResolverSettings: Codable, Equatable {
    var mode: ResolverMode
    var ytdlpUrl: String

    static let disabled = ResolverSettings()

    init(mode: ResolverMode = .off, ytdlpUrl: String = "") {
        self.mode = mode
        self.ytdlpUrl = ytdlpUrl
    }

    init(payload: [String: Any]) {
        mode = ResolverMode(rawValue: payload["mode"] as? String ?? "off") ?? .off
        ytdlpUrl = (payload["ytdlpUrl"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var payload: [String: Any] {
        ["mode": mode.rawValue, "ytdlpUrl": ytdlpUrl]
    }

    var endpoint: URL? {
        let raw: String
        switch mode {
        case .off: return nil
        case .ytdlp: raw = ytdlpUrl
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    var isEnabled: Bool { mode != .off && endpoint != nil }

    enum CodingKeys: String, CodingKey {
        case mode, ytdlpUrl
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawMode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "off"
        mode = ResolverMode(rawValue: rawMode) ?? .off
        ytdlpUrl = try container.decodeIfPresent(String.self, forKey: .ytdlpUrl) ?? ""
    }
}

struct ResolverResult {
    let mediaUrl: URL
    let fileName: String?
}

enum ResolverError: LocalizedError {
    case notConfigured
    case unreachable(String)
    case http(Int)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Add a resolver URL in Settings → Social links."
        case .unreachable:
            return "The resolver could not be reached. Check its URL and connection."
        case .http(let code):
            return "The resolver returned HTTP \(code)."
        case .badResponse(let message):
            return message
        }
    }
}

/// Resolves social links through a user-configured yt-dlp service.
enum LinkResolver {
    /// Only these hosts are sent to the resolver. Matching is suffix-based so
    /// www/mobile/subdomains are covered.
    private static let supportedSuffixes = [
        "tiktok.com",
        "instagram.com",
        "youtube.com",
        "youtu.be",
        "twitter.com",
        "x.com",
        "t.co",
    ]

    static func isSupported(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return supportedSuffixes.contains { suffix in
            host == suffix || host.hasSuffix(".\(suffix)")
        }
    }

    static func resolve(
        _ url: URL,
        settings: ResolverSettings,
        completion: @escaping (Result<ResolverResult, Error>) -> Void
    ) {
        guard let base = settings.endpoint else {
            completion(.failure(ResolverError.notConfigured))
            return
        }
        guard settings.mode == .ytdlp else {
            completion(.failure(ResolverError.notConfigured))
            return
        }
        var endpoint = base
        endpoint.appendPathComponent("resolve")
        guard let scheme = endpoint.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              endpoint.host != nil
        else {
            completion(.failure(ResolverError.notConfigured))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "url": url.absoluteString,
        ]) else {
            completion(.failure(ResolverError.badResponse("The link could not be sent to the resolver.")))
            return
        }
        request.httpBody = body

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if error != nil {
                completion(.failure(ResolverError.unreachable("")))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(ResolverError.badResponse("The resolver sent no response.")))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(ResolverError.http(http.statusCode)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                completion(.failure(ResolverError.badResponse("The resolver returned unreadable data.")))
                return
            }
            do {
                completion(.success(try parse(json, mode: settings.mode)))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    private static func parse(
        _ json: [String: Any],
        mode: ResolverMode
    ) throws -> ResolverResult {
        guard mode == .ytdlp else {
            throw ResolverError.notConfigured
        }
        guard let raw = json["url"] as? String,
              let media = mediaURL(raw)
        else {
            throw ResolverError.badResponse(
                "The yt-dlp service did not return a media URL."
            )
        }
        return ResolverResult(
            mediaUrl: media,
            fileName: (json["fileName"] as? String) ?? (json["filename"] as? String)
        )
    }

    private static func mediaURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }
}

/// Settings live next to the job queue, so the share extension sees them when
/// an App Group is available.
enum ResolverSettingsStore {
    static func load() -> ResolverSettings {
        guard let data = JobStore.shared.settingsData(),
              let settings = try? JSONDecoder().decode(ResolverSettings.self, from: data)
        else { return .disabled }
        return settings
    }

    static func save(_ settings: ResolverSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try JobStore.shared.saveSettingsData(data)
    }
}
