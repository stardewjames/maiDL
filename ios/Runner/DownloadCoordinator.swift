import Foundation
import Photos
import UIKit

/// App-side queue owner. A process lease prevents attaching to a URLSession
/// that is still owned by a running or suspended share extension.
final class DownloadCoordinator {
    static let shared = DownloadCoordinator()

    private let store = JobStore.shared
    private var handlers: [String: BackgroundSessionHandler] = [:]
    private var pendingPermissionJobs = Set<String>()
    private var resolvingJobs = Set<String>()

    /// Always invoked on the main queue.
    var onJobUpdate: ((JobRecord) -> Void)?

    private init() {}

    func start() {
        reconcile()
    }

    /// Imports a link handed over by the share extension when App Groups are
    /// unavailable. The extension writes a custom pasteboard type, so the app
    /// only reads clipboard contents after an actual share.
    func importSharedLinkIfNeeded() {
        let pasteboard = UIPasteboard.general
        let type = SharedConfig.handoffPasteboardType
        guard pasteboard.contains(pasteboardTypes: [type]),
              let value = pasteboard.value(forPasteboardType: type)
        else { return }
        let raw = (value as? String)
            ?? (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
        pasteboard.items = []
        guard let link = raw, !link.isEmpty else { return }
        do {
            _ = try enqueue(rawLink: link, origin: "share")
        } catch {
            NSLog("maiDL could not import the shared link: %@", error.localizedDescription)
            if let url = try? LinkExtractor.normalize(LinkExtractor.parse(link)) {
                var failed = JobFactory.create(url: url, origin: "share")
                failed.status = "failed"
                failed.error = error.localizedDescription
                failed.updatedAt = JobRecord.nowMillis()
                if (try? store.save(failed)) != nil {
                    emit(failed)
                }
            }
        }
    }

    @discardableResult
    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard SharedConfig.isAppSessionIdentifier(identifier)
            || SharedConfig.isShareSessionIdentifier(identifier)
        else { return false }
        do {
            guard let handler = try ensureHandler(identifier: identifier) else {
                NSLog("maiDL background session is still owned by the share extension: %@", identifier)
                completionHandler()
                return true
            }
            handler.setEventsCompletion(completionHandler)
        } catch {
            NSLog("maiDL could not restore background session: %@", error.localizedDescription)
            completionHandler()
        }
        return true
    }

    // MARK: - Queue operations

    @discardableResult
    func enqueue(rawLink: String, origin: String) throws -> JobRecord {
        let url = LinkExtractor.normalize(try LinkExtractor.parse(rawLink))
        if let existing = store.activeDuplicate(url: url.absoluteString) {
            return existing
        }
        if SocialExtractor.isYouTube(url) {
            throw LinkError(
                code: "unsupported",
                message: "YouTube links aren't supported by the built-in extractor."
            )
        }
        let access = try photoAccess()
        let job = JobFactory.create(url: url, origin: origin)
        try store.save(job)
        return try begin(job, access: access)
    }

    /// Starts built-in extraction for supported social links, or the transfer
    /// directly. YouTube needs a server-side extractor and is rejected here.
    private func begin(_ job: JobRecord, access: String) throws -> JobRecord {
        guard let url = URL(string: job.url) else {
            throw LinkError(code: "invalid_link", message: "That link could not be read.")
        }
        if SocialExtractor.isYouTube(url) {
            throw LinkError(
                code: "unsupported",
                message: "YouTube links aren't supported by the built-in extractor."
            )
        }
        if SocialExtractor.platform(for: url) != nil {
            return try beginResolution(job, url: url, access: access)
        }
        let handler = try appHandler()
        return try startOrRequestAccess(job, using: handler, access: access)
    }

    private func beginResolution(
        _ job: JobRecord,
        url: URL,
        access: String
    ) throws -> JobRecord {
        var resolving = job
        resolving.status = "resolving"
        resolving.error = nil
        resolving.updatedAt = JobRecord.nowMillis()
        try store.save(resolving)
        emit(resolving)
        resolve(jobId: job.id, url: url, access: access)
        return resolving
    }

    private func resolve(
        jobId: String,
        url: URL,
        access: String
    ) {
        guard resolvingJobs.insert(jobId).inserted else { return }
        SocialExtractor.extract(url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolvingJobs.remove(jobId)
                guard let current = self.store.get(id: jobId),
                      current.status == "resolving"
                else { return }
                switch result {
                case .failure(let error):
                    self.failResolution(jobId, message: error.localizedDescription)
                case .success(let resolved):
                    do {
                        var updated = current
                        updated.mediaUrl = resolved.mediaUrl.absoluteString
                        updated.referer = resolved.referer
                        updated.cookie = resolved.cookie
                        let kindSource = resolved.fileName ?? resolved.mediaUrl.absoluteString
                        updated.kind = MediaTypes.kind(forUrl: kindSource).rawValue
                        let suggested = resolved.fileName?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.fileName = (suggested?.isEmpty == false ? suggested : nil)
                            ?? MediaTypes.fileName(
                                forUrl: resolved.mediaUrl.absoluteString,
                                contentType: nil,
                                contentDisposition: nil,
                                suggestedFilename: nil,
                                fallbackMillis: JobRecord.nowMillis()
                            )
                        updated.status = "queued"
                        updated.error = nil
                        updated.updatedAt = JobRecord.nowMillis()
                        try self.store.save(updated)
                        self.emit(updated)
                        let handler = try self.appHandler()
                        _ = try self.startOrRequestAccess(
                            updated,
                            using: handler,
                            access: access
                        )
                    } catch {
                        self.failResolution(jobId, message: error.localizedDescription)
                    }
                }
            }
        }
    }

    private func failResolution(_ id: String, message: String) {
        guard let failed = try? store.update(id: id, { current in
            guard current.status == "resolving" else { return false }
            current.status = "failed"
            current.error = message
            current.updatedAt = JobRecord.nowMillis()
            return true
        }) else { return }
        emit(failed)
    }

    @discardableResult
    func retry(id: String) throws -> JobRecord {
        guard let existing = store.get(id: id) else {
            throw LinkError(code: "not_found", message: "That download is no longer in the list.")
        }
        if existing.isActive { return existing }
        if let url = URL(string: existing.url), SocialExtractor.isYouTube(url) {
            throw LinkError(
                code: "unsupported",
                message: "YouTube links aren't supported by the built-in extractor."
            )
        }
        let access = try photoAccess()
        guard let job = try store.update(id: id, { current in
            guard !current.isActive else { return false }
            current.status = "queued"
            current.error = nil
            current.remoteId = nil
            current.mediaUrl = nil
            current.referer = nil
            current.cookie = nil
            current.hops = 0
            current.pendingSourceFile = nil
            current.bytesReceived = 0
            current.totalBytes = -1
            current.sessionIdentifier = SharedConfig.appSessionIdentifier
            current.transferToken = UUID().uuidString
            current.updatedAt = JobRecord.nowMillis()
            return true
        }) else { return store.get(id: id) ?? existing }
        store.removeIncomingFiles(for: id, transferToken: existing.transferToken)
        return try begin(job, access: access)
    }

    func cancel(id: String) throws {
        guard let canceled = try store.update(id: id, { current in
            // Photos changes cannot be canceled once submitted. Keep the
            // authoritative saving state until its real completion arrives.
            guard current.isActive, current.status != "saving" else { return false }
            current.status = "canceled"
            current.error = nil
            current.pendingSourceFile = nil
            current.updatedAt = JobRecord.nowMillis()
            return true
        }) else { return }
        pendingPermissionJobs.remove(id)
        emit(canceled)
        // A live extension observes the canceled record itself; never steal
        // its session merely to cancel the network task.
        try ensureHandler(identifier: canceled.sessionIdentifier)?.cancel(job: canceled)
    }

    func remove(id: String) throws {
        let existing = store.get(id: id)
        try cancel(id: id)
        try store.remove(id: id)
        if let existing { cleanupFinishedSource(job: existing) }
    }

    func clearHistory() throws {
        try store.clearFinished()
    }

    func jobsPayload() -> [[String: Any]] {
        store.all().map { $0.payload() }
    }

    func requestPhotoAccess(completion: @escaping (String) -> Void) {
        PhotoLibrarySaver.requestAccess(completion: completion)
    }

    // MARK: - Helpers

    /// Do not unlink a source/output while this or another process is still
    /// exporting it. Its owner cancels and cleans up after export terminates.
    private func cleanupFinishedSource(job: JobRecord) {
        if let handler = handlers[job.sessionIdentifier] {
            handler.cancel(job: job)
        } else if let ownership = try? store.claimSession(identifier: job.sessionIdentifier) {
            withExtendedLifetime(ownership) {
                store.removeIncomingFiles(for: job.id, transferToken: job.transferToken)
            }
        }
    }

    private func photoAccess() throws -> String {
        let access = PhotoLibrarySaver.accessStatus()
        if access == "denied" {
            throw LinkError(
                code: "photos_denied",
                message: "Photos access is off. Allow maiDL to add items in Settings → maiDL → Photos."
            )
        }
        return access
    }

    private func startOrRequestAccess(
        _ job: JobRecord,
        using handler: BackgroundSessionHandler,
        access: String
    ) throws -> JobRecord {
        guard access == "notDetermined" else {
            return try startTransfer(job, using: handler)
        }
        pendingPermissionJobs.insert(job.id)
        PhotoLibrarySaver.requestAccess { [weak self] status in
            guard let self else { return }
            self.pendingPermissionJobs.remove(job.id)
            guard let pending = self.store.get(id: job.id),
                  pending.isActive, pending.transferToken == job.transferToken
            else { return }
            do {
                if status == "granted" {
                    try self.startTransfer(pending, using: handler)
                } else if let failed = try self.store.update(id: job.id, { current in
                    guard current.isActive, current.transferToken == job.transferToken
                    else { return false }
                    current.status = "failed"
                    current.error = "Photos access is off. Allow maiDL to add items in Settings → maiDL → Photos."
                    current.updatedAt = JobRecord.nowMillis()
                    return true
                }) {
                    self.emit(failed)
                }
            } catch {
                NSLog("maiDL could not start the authorized download: %@", error.localizedDescription)
            }
        }
        emit(job)
        return job
    }

    @discardableResult
    private func startTransfer(
        _ job: JobRecord,
        using handler: BackgroundSessionHandler
    ) throws -> JobRecord {
        if handler.enqueue(jobId: job.id) {
            emit(job)
            return job
        }
        if let failed = try store.update(id: job.id, { current in
            guard current.isActive, current.transferToken == job.transferToken
            else { return false }
            current.status = "failed"
            current.error = "The link could not be downloaded."
            current.updatedAt = JobRecord.nowMillis()
            return true
        }) {
            emit(failed)
        }
        throw LinkError(code: "download_failed", message: "The link could not be downloaded.")
    }

    private func appHandler() throws -> BackgroundSessionHandler {
        guard let handler = try ensureHandler(identifier: SharedConfig.appSessionIdentifier)
        else {
            throw LinkError(code: "download_busy", message: "The download session is unavailable.")
        }
        return handler
    }

    private func ensureHandler(identifier: String) throws -> BackgroundSessionHandler? {
        if let handler = handlers[identifier] { return handler }
        guard SharedConfig.isAppSessionIdentifier(identifier)
            || SharedConfig.isShareSessionIdentifier(identifier)
        else { return nil }
        guard let handler = try BackgroundSessionHandler(identifier: identifier)
        else { return nil }
        handler.onJobUpdate = { [weak self] job in self?.emit(job) }
        handlers[identifier] = handler
        // Ownership can become available after the app's initial reconcile,
        // including during a background URLSession relaunch.
        for job in store.all()
            where job.status == "preparing" && job.sessionIdentifier == identifier {
            handler.resumePreparation(job: job)
        }
        return handler
    }

    private func emit(_ job: JobRecord) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.store.get(id: job.id) else { return }
            self.onJobUpdate?(current)
        }
    }

    /// Only inspect sessions we can safely own. Include asynchronous preparation,
    /// Photos work and permission prompts; recheck before repairing a record.
    func reconcile() {
        _ = try? ensureHandler(identifier: SharedConfig.appSessionIdentifier)
        for job in store.all()
            where job.status == "resolving" && !resolvingJobs.contains(job.id) {
            guard let url = URL(string: job.url) else { continue }
            if SocialExtractor.isYouTube(url) {
                failResolution(
                    job.id,
                    message: "YouTube links aren't supported by the built-in extractor."
                )
                continue
            }
            guard SocialExtractor.platform(for: url) != nil else {
                failResolution(
                    job.id,
                    message: "This link is no longer supported by the built-in extractor."
                )
                continue
            }
            do {
                resolve(
                    jobId: job.id,
                    url: url,
                    access: try photoAccess()
                )
            } catch {
                failResolution(job.id, message: error.localizedDescription)
            }
        }
        let records = store.all()
        for job in records where !job.isActive {
            cleanupFinishedSource(job: job)
        }
        let snapshot = records.filter { $0.isActive }
        for identifier in Set(snapshot.map { $0.sessionIdentifier }) {
            do {
                _ = try ensureHandler(identifier: identifier)
            } catch {
                NSLog("maiDL could not inspect background session: %@", error.localizedDescription)
            }
        }
        let owned = handlers
        for job in snapshot where job.status == "preparing" {
            owned[job.sessionIdentifier]?.resumePreparation(job: job)
        }
        let live = LiveIds()
        let group = DispatchGroup()
        for handler in owned.values {
            group.enter()
            handler.liveTaskIds { ids in
                live.insert(ids)
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let liveIds = live.snapshot()
            let now = JobRecord.nowMillis()
            for job in snapshot {
                guard owned[job.sessionIdentifier] != nil,
                      !liveIds.contains(job.id),
                      !self.pendingPermissionJobs.contains(job.id),
                      job.status != "preparing",
                      now - job.updatedAt >= 60_000
                else { continue }
                do {
                    if let failed = try self.store.update(id: job.id, { current in
                        guard current.isActive, current.updatedAt == job.updatedAt,
                              current.transferToken == job.transferToken,
                              current.sessionIdentifier == job.sessionIdentifier
                        else { return false }
                        current.status = "failed"
                        current.error = "The download was interrupted. Tap Try again."
                        current.pendingSourceFile = nil
                        current.updatedAt = JobRecord.nowMillis()
                        return true
                    }) {
                        self.emit(failed)
                        self.store.removeIncomingFiles(for: job.id, transferToken: job.transferToken)
                    }
                } catch {
                    NSLog("maiDL could not repair download history: %@", error.localizedDescription)
                }
            }
        }
    }
}

private final class LiveIds {
    private let lock = NSLock()
    private var ids = Set<String>()

    func insert(_ newIds: Set<String>) {
        lock.lock()
        ids.formUnion(newIds)
        lock.unlock()
    }

    func snapshot() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return ids
    }
}
