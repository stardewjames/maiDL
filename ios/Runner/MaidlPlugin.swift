import Flutter
import UIKit

/// Flutter bridge. Implements the contract documented in
/// lib/src/core/downloads_api.dart.
final class MaidlPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel: FlutterEventChannel?

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = MaidlPlugin()
        plugin.setUp(with: registrar)
        // The engine registry retains the bridge for exactly its lifetime.
        registrar.publish(plugin)
    }

    private func setUp(with registrar: FlutterPluginRegistrar) {
        let coordinator = DownloadCoordinator.shared
        coordinator.start()
        coordinator.onJobUpdate = { [weak self] job in
            guard let self, let eventSink = self.eventSink else { return }
            eventSink(job.payload())
        }

        let method = FlutterMethodChannel(
            name: "app.maidl/downloads",
            binaryMessenger: registrar.messenger()
        )
        method.setMethodCallHandler { [weak self] call, result in
            self?.handle(call, result: result)
        }
        methodChannel = method

        let events = FlutterEventChannel(
            name: "app.maidl/download_events",
            binaryMessenger: registrar.messenger()
        )
        events.setStreamHandler(self)
        eventChannel = events
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        eventSink = events
        let coordinator = DownloadCoordinator.shared
        coordinator.start()
        for job in coordinator.jobsPayload() {
            events(job)
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let coordinator = DownloadCoordinator.shared
        let arguments = call.arguments as? [String: Any] ?? [:]

        switch call.method {
        case "initialize":
            coordinator.start()
            let snapshot: [String: Any] = [
                "jobs": coordinator.jobsPayload(),
                "platform": "ios",
                "photos": PhotoLibrarySaver.accessStatus(),
                "notifications": "unsupported",
                "canOpenSaved": false,
                "resolver": ResolverSettingsStore.load().payload,
            ]
            result(snapshot)

        case "history":
            coordinator.reconcile()
            result(coordinator.jobsPayload())

        case "enqueue":
            guard let url = arguments["url"] as? String, !url.isEmpty else {
                result(
                    FlutterError(
                        code: "invalid_link",
                        message: "No link was provided.",
                        details: nil
                    )
                )
                return
            }
            let origin = (arguments["origin"] as? String) == "share" ? "share" : "manual"
            run(result: result) {
                try coordinator.enqueue(rawLink: url, origin: origin)
            }

        case "retry":
            guard let id = arguments["id"] as? String else {
                result(FlutterError(code: "not_found", message: "No download was specified.", details: nil))
                return
            }
            run(result: result) {
                try coordinator.retry(id: id)
            }

        case "cancel":
            runCommand(result: result) {
                if let id = arguments["id"] as? String {
                    try coordinator.cancel(id: id)
                }
            }

        case "remove":
            runCommand(result: result) {
                if let id = arguments["id"] as? String {
                    try coordinator.remove(id: id)
                }
            }

        case "clearHistory":
            runCommand(result: result) {
                try coordinator.clearHistory()
            }

        case "openSaved":
            // The Photos app cannot be opened per-item from a public API.
            result(false)

        case "requestPhotoAccess":
            coordinator.requestPhotoAccess { status in
                result(status)
            }

        case "requestNotifications":
            result(false)

        case "getResolverSettings":
            result(ResolverSettingsStore.load().payload)

        case "setResolverSettings":
            do {
                try ResolverSettingsStore.save(ResolverSettings(payload: arguments))
                result(nil)
            } catch {
                result(
                    FlutterError(
                        code: "settings_failed",
                        message: "The resolver settings could not be saved.",
                        details: nil
                    )
                )
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func run(
        result: @escaping FlutterResult,
        action: () throws -> JobRecord
    ) {
        do {
            result(try action().payload())
        } catch let error as LinkError {
            result(FlutterError(code: error.code, message: error.message, details: nil))
        } catch {
            result(
                FlutterError(
                    code: "download_failed",
                    message: error.localizedDescription,
                    details: nil
                )
            )
        }
    }

    private func runCommand(
        result: @escaping FlutterResult,
        action: () throws -> Void
    ) {
        do {
            try action()
            result(nil)
        } catch let error as LinkError {
            result(FlutterError(code: error.code, message: error.message, details: nil))
        } catch {
            result(FlutterError(
                code: "storage_failed", message: error.localizedDescription, details: nil
            ))
        }
    }
}
