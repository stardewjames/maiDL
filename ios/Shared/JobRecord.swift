import Foundation

/// One download. Persisted as a JSON file in the App Group so the extension,
/// the app, and background relaunches all see the same queue.
struct JobRecord: Codable, Equatable {
    var id: String
    var url: String
    var kind: String
    var fileName: String
    var status: String
    var origin: String
    var createdAt: Int64
    var updatedAt: Int64
    var bytesReceived: Int64
    var totalBytes: Int64
    var error: String?
    var remoteId: String?
    var mimeType: String?

    /// Populated after a page link is resolved to its media URL. `url` keeps
    /// the link the user shared so history stays recognisable.
    var mediaUrl: String?
    var hops: Int
    var sessionIdentifier: String
    var transferToken: String

    var isActive: Bool {
        status == "queued" || status == "downloading" || status == "saving"
    }

    static func nowMillis() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    init(
        id: String,
        url: String,
        kind: String,
        fileName: String,
        status: String,
        origin: String,
        createdAt: Int64,
        updatedAt: Int64,
        bytesReceived: Int64 = 0,
        totalBytes: Int64 = -1,
        error: String? = nil,
        remoteId: String? = nil,
        mimeType: String? = nil,
        mediaUrl: String? = nil,
        hops: Int = 0,
        sessionIdentifier: String = SharedConfig.appSessionIdentifier,
        transferToken: String = UUID().uuidString
    ) {
        self.id = id
        self.url = url
        self.kind = kind
        self.fileName = fileName
        self.status = status
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.error = error
        self.remoteId = remoteId
        self.mimeType = mimeType
        self.mediaUrl = mediaUrl
        self.hops = hops
        self.sessionIdentifier = sessionIdentifier
        self.transferToken = transferToken
    }

    enum CodingKeys: String, CodingKey {
        case id, url, kind, fileName, status, origin, createdAt, updatedAt
        case bytesReceived, totalBytes, error, remoteId, mimeType, mediaUrl, hops
        case sessionIdentifier, transferToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        url = try container.decode(String.self, forKey: .url)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "unknown"
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName) ?? "media"
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "queued"
        origin = try container.decodeIfPresent(String.self, forKey: .origin) ?? "manual"
        createdAt = try container.decodeIfPresent(Int64.self, forKey: .createdAt)
            ?? JobRecord.nowMillis()
        updatedAt = try container.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? createdAt
        bytesReceived = try container.decodeIfPresent(Int64.self, forKey: .bytesReceived) ?? 0
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? -1
        error = try container.decodeIfPresent(String.self, forKey: .error)
        remoteId = try container.decodeIfPresent(String.self, forKey: .remoteId)
        mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
        mediaUrl = try container.decodeIfPresent(String.self, forKey: .mediaUrl)
        hops = try container.decodeIfPresent(Int.self, forKey: .hops) ?? 0
        sessionIdentifier = try container.decode(String.self, forKey: .sessionIdentifier)
        transferToken = try container.decode(String.self, forKey: .transferToken)
    }

    /// Contract shared with lib/src/core/downloads_api.dart.
    func payload() -> [String: Any] {
        var dict: [String: Any] = [
            "id": id,
            "url": url,
            "kind": kind,
            "fileName": fileName,
            "status": status,
            "origin": origin,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "bytesReceived": bytesReceived,
            "totalBytes": totalBytes,
        ]
        if let error { dict["error"] = error }
        if let remoteId { dict["remoteId"] = remoteId }
        return dict
    }
}

enum JobFactory {
    static func create(url: URL, origin: String) -> JobRecord {
        let now = JobRecord.nowMillis()
        return JobRecord(
            id: UUID().uuidString,
            url: url.absoluteString,
            kind: MediaTypes.kind(forUrl: url.absoluteString).rawValue,
            fileName: MediaTypes.fileName(
                forUrl: url.absoluteString,
                contentType: nil,
                contentDisposition: nil,
                suggestedFilename: nil,
                fallbackMillis: now
            ),
            status: "queued",
            origin: origin,
            createdAt: now,
            updatedAt: now
        )
    }
}
