import Foundation
import Photos

/// App-side queue owner. A process lease prevents attaching to a URLSession
/// that is still owned by a running or suspended share extension.
final class DownloadCoordinator {
    static let shared = DownloadCoordinator()

    private let store = JobStore.shared
    private var handlers: [String: BackgroundSessionHandler] = [:]
    private var pendingPermissionJobs = Set<String>()

    /// Always invoked on the main queue.
    var onJobUpdate: ((JobRecord) -> Void)?

    private init() {}

    func start() {
        reconcile()
    }

    @discardableResult
    func handleEventsForBackgroundURLSession(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) -> Bool {
        guard identifier == SharedConfig.appSessionIdentifier
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
        let access = try photoAccess()
        let handler = try appHandler()
        let job = JobFactory.create(url: url, origin: origin)
        try store.save(job)
        return try startOrRequestAccess(job, using: handler, access: access)
    }

    @discardableResult
    func retry(id: String) throws -> JobRecord {
        guard let existing = store.get(id: id) else {
            throw LinkError(code: "not_found", message: "That download is no longer in the list.")
        }
        if existing.isActive { return existing }
        let access = try photoAccess()
        let handler = try appHandler()
        guard let job = try store.update(id: id, { current in
            guard !current.isActive else { return false }
            current.status = "queued"
            current.error = nil
            current.remoteId = nil
            current.mediaUrl = nil
            current.hops = 0
            current.bytesReceived = 0
            current.totalBytes = -1
            current.sessionIdentifier = SharedConfig.appSessionIdentifier
            current.transferToken = UUID().uuidString
            current.updatedAt = JobRecord.nowMillis()
            return true
        }) else { return store.get(id: id) ?? existing }
        store.removeIncomingFiles(for: id)
        return try startOrRequestAccess(job, using: handler, access: access)
    }

    func cancel(id: String) throws {
        guard let canceled = try store.update(id: id, { current in
            // Photos changes cannot be canceled once submitted. Keep the
            // authoritative saving state until its real completion arrives.
            guard current.isActive, current.status != "saving" else { return false }
            current.status = "canceled"
            current.error = nil
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
        try cancel(id: id)
        try store.remove(id: id)
        store.removeIncomingFiles(for: id)
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
        guard identifier == SharedConfig.appSessionIdentifier
            || SharedConfig.isShareSessionIdentifier(identifier)
        else { return nil }
        guard let handler = try BackgroundSessionHandler(identifier: identifier)
        else { return nil }
        handler.onJobUpdate = { [weak self] job in self?.emit(job) }
        handlers[identifier] = handler
        return handler
    }

    private func emit(_ job: JobRecord) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.store.get(id: job.id) else { return }
            self.onJobUpdate?(current)
        }
    }

    /// Only inspect sessions we can safely own. Include asynchronous Photos
    /// work and permission prompts, and recheck the record before repairing it.
    func reconcile() {
        _ = try? ensureHandler(identifier: SharedConfig.appSessionIdentifier)
        let snapshot = store.all().filter { $0.isActive }
        for identifier in Set(snapshot.map { $0.sessionIdentifier }) {
            do {
                _ = try ensureHandler(identifier: identifier)
            } catch {
                NSLog("maiDL could not inspect background session: %@", error.localizedDescription)
            }
        }
        let owned = handlers
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
                        current.updatedAt = JobRecord.nowMillis()
                        return true
                    }) {
                        self.emit(failed)
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
