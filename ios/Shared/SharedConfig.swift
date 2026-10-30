import Foundation

enum SharedConfig {
    /// App Group shared by the app and the share extension. Both targets must
    /// declare it in their entitlements.
    static let appGroup = "group.app.maidl"

    /// Set when a signing profile cannot grant App Groups. Job state then lives
    /// in the app's own container, and the extension hands links over through
    /// the pasteboard instead of a shared directory.
    static var hasAppGroup: Bool {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) != nil
    }

    /// Custom pasteboard type used for the share-extension handoff. The app
    /// checks for this type before reading clipboard contents.
    static let handoffPasteboardType = "app.maidl.share-link"

    /// Identifier for downloads started from the app UI. A separate identifier
    /// is used without an App Group so a session created under a different
    /// signing configuration is never silently reused.
    private static let sharedAppSessionIdentifier = "app.maidl.downloads.app"
    private static let localAppSessionIdentifier = "app.maidl.downloads.app.local"

    static var appSessionIdentifier: String {
        hasAppGroup ? sharedAppSessionIdentifier : localAppSessionIdentifier
    }

    static func isAppSessionIdentifier(_ identifier: String) -> Bool {
        identifier == sharedAppSessionIdentifier || identifier == localAppSessionIdentifier
    }

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
        if SharedConfig.hasAppGroup {
            configuration.sharedContainerIdentifier = SharedConfig.appGroup
        }
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return configuration
    }
}
