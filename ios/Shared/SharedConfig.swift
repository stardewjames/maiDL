import Foundation

enum SharedConfig {
    /// App Group shared by the app and the share extension. Both targets must
    /// declare it in their entitlements.
    static let appGroup = "group.app.maidl"

    /// Identifier for downloads started from the app UI.
    static let appSessionIdentifier = "app.maidl.downloads.app"

    /// Each share owns a fresh session; a later extension invocation must not
    /// attach to a session that the containing app has already adopted.
    static let shareSessionIdentifierPrefix = "app.maidl.downloads.share."

    static func isShareSessionIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix(shareSessionIdentifierPrefix)
            && UUID(uuidString: String(
                identifier.dropFirst(shareSessionIdentifierPrefix.count)
            )) != nil
    }

    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) " +
        "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 " +
        "Mobile/15E148 Safari/604.1 maiDL/1.0"
}

enum BackgroundSessionConfig {
    static func make(identifier: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sharedContainerIdentifier = SharedConfig.appGroup
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return configuration
    }
}
