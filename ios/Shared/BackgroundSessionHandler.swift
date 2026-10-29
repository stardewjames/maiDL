import Foundation
import Photos

/// Owns one background URLSession while holding its cross-process lease.
final class BackgroundSessionHandler: NSObject, URLSessionDownloadDelegate {
    let identifier: String

    /// Called on the main queue whenever a job changes.
    var onJobUpdate: ((JobRecord) -> Void)?

    private let store = JobStore.shared
    private var session: URLSession!
    private let stateLock = NSLock()
    private var ownership: SessionOwnership?
    private var invalidating = false
    private var eventsCompletion: (() -> Void)?
    private var eventsFinished = false
    private var pendingJobs = Set<String>()
    private var dismissalCompletion: (() -> Void)?
    private var lastPersist: [String: Int64] = [:]
    private let persistInterval: Int64 = 700

    init?(identifier: String) throws {
        guard let ownership = try JobStore.shared.claimSession(identifier: identifier)
        else { return nil }
        self.ownership = ownership
        self.identifier = identifier
        super.init()
        session = URLSession(
            configuration: BackgroundSessionConfig.make(identifier: identifier),
            delegate: self,
            delegateQueue: nil
        )
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            for task in tasks where task.taskDescription != nil && self.job(for: task) == nil {
                task.cancel()
            }
        }
    }

    // MARK: - Queue operations

    @discardableResult
    func enqueue(jobId: String) -> Bool {
        guard let job = store.get(id: jobId),
              job.isActive, job.status != "saving",
              job.sessionIdentifier == identifier,
              let url = URL(string: job.mediaUrl ?? job.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else { return false }

        var request = URLRequest(url: url)
        request.setValue(SharedConfig.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let task = session.downloadTask(with: request)
        task.taskDescription = "\(jobId)|\(job.transferToken)"
        task.resume()
        return true
    }

    func cancel(job: JobRecord) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == "\(job.id)|\(job.transferToken)" {
                task.cancel()
            }
        }
    }

    /// Includes asynchronous Photos work after the URLSession task disappears.
    func liveTaskIds(completion: @escaping (Set<String>) -> Void) {
        guard let session else {
            completion([])
            return
        }
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            self.stateLock.lock()
            let pending = self.pendingJobs
            self.stateLock.unlock()
            completion(Set(tasks.compactMap { self.job(for: $0)?.id }).union(pending))
        }
    }

    // MARK: - Background launch handshake

    func setEventsCompletion(_ completion: @escaping () -> Void) {
        stateLock.lock()
        eventsCompletion = completion
        let ready = eventsFinished && pendingJobs.isEmpty
        if ready {
            eventsCompletion = nil
            eventsFinished = false
        }
        stateLock.unlock()
        if ready {
            DispatchQueue.main.async { completion() }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        stateLock.lock()
        eventsFinished = true
        let ready = pendingJobs.isEmpty && eventsCompletion != nil
        let completion = ready ? eventsCompletion : nil
        if ready {
            eventsCompletion = nil
            eventsFinished = false
        }
        stateLock.unlock()
        if let completion {
            DispatchQueue.main.async { completion() }
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        ownership = nil
        // Invalidation is also a terminal event drain; preserve the latch if
        // UIKit has not supplied its completion handler yet.
        urlSessionDidFinishEvents(forBackgroundURLSession: session)
    }

    /// A per-share session is never reused. Release its delegate cycle and
    /// process lease after both URLSession and Photos have finished.
    func finishIfIdle() {
        guard SharedConfig.isShareSessionIdentifier(identifier), let session else { return }
        session.getAllTasks { [weak self] tasks in
            guard let self, tasks.isEmpty else { return }
            self.stateLock.lock()
            let ready = self.pendingJobs.isEmpty && !self.invalidating
            if ready { self.invalidating = true }
            self.stateLock.unlock()
            if ready { session.finishTasksAndInvalidate() }
        }
    }

    /// Do not terminate an extension while its already-delivered download is
    /// being moved into shared storage or committed to Photos.
    func afterCurrentWork(_ completion: @escaping () -> Void) {
        stateLock.lock()
        let ready = pendingJobs.isEmpty
        if !ready { dismissalCompletion = completion }
        stateLock.unlock()
        if ready { DispatchQueue.main.async { completion() } }
    }

    private func beginWork(jobId: String) {
        stateLock.lock()
        pendingJobs.insert(jobId)
        stateLock.unlock()
    }

    private func finishWork(jobId: String) {
        stateLock.lock()
        pendingJobs.remove(jobId)
        let ready = eventsFinished && pendingJobs.isEmpty && eventsCompletion != nil
        let completion = ready ? eventsCompletion : nil
        if ready {
            eventsCompletion = nil
            eventsFinished = false
        }
        let dismissal = pendingJobs.isEmpty ? dismissalCompletion : nil
        if pendingJobs.isEmpty { dismissalCompletion = nil }
        stateLock.unlock()
        if let completion {
            DispatchQueue.main.async { completion() }
        }
        if let dismissal {
            DispatchQueue.main.async { dismissal() }
        }
        finishIfIdle()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let job = job(for: downloadTask) else {
            downloadTask.cancel()
            return
        }
        guard job.status != "saving" else { return }
        let now = JobRecord.nowMillis()
        guard now - (lastPersist[job.id] ?? 0) >= persistInterval else { return }
        lastPersist[job.id] = now
        do {
            if let updated = try update(job, change: { current in
                guard current.status != "saving" else { return false }
                current.status = "downloading"
                current.bytesReceived = totalBytesWritten
                current.totalBytes = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : -1
                return true
            }) {
                emit(updated)
            }
        } catch {
            downloadTask.cancel()
            NSLog("maiDL could not persist download progress: %@", error.localizedDescription)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let job = job(for: downloadTask), job.status != "saving" else { return }
        beginWork(jobId: job.id)
        handleDownload(job: job, jobId: job.id, task: downloadTask, location: location)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer { finishIfIdle() }
        guard let error, let job = job(for: task), job.status != "saving" else { return }
        let nsError = error as NSError
        do {
            if let updated = try update(job, change: { current in
                guard current.status != "saving" else { return false }
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    current.status = "canceled"
                    current.error = nil
                } else {
                    current.status = "failed"
                    current.error = Self.message(for: nsError)
                }
                return true
            }) {
                emit(updated)
            }
        } catch {
            NSLog("maiDL could not persist download failure: %@", error.localizedDescription)
        }
    }

    // MARK: - Completion

    private func handleDownload(
        job initialJob: JobRecord,
        jobId: String,
        task: URLSessionDownloadTask,
        location: URL
    ) {
        var job = initialJob
        let fileManager = FileManager.default
        let response = task.response as? HTTPURLResponse

        if let status = response?.statusCode, status >= 400 {
            fail(
                &job,
                message: "The server returned HTTP \(status)."
            )
            return
        }

        let mime = response?.mimeType?.lowercased()
        let finalURL = response?.url?.absoluteString
            ?? task.currentRequest?.url?.absoluteString
            ?? task.originalRequest?.url?.absoluteString
            ?? job.url

        if MediaTypes.isHtml(mime: mime) {
            let baseURL = URL(string: finalURL) ?? URL(string: job.url)
            let nextURL = baseURL.flatMap { base in
                readText(at: location).flatMap {
                    OgParser.findMediaURL(in: $0, baseURL: base)
                }
            }
            try? fileManager.removeItem(at: location)

            guard let nextURL, job.hops < 1 else {
                fail(
                    &job,
                    message: "That page doesn't expose a direct video or image."
                )
                return
            }

            do {
                let queued = try update(job, change: { current in
                    current.mediaUrl = nextURL.absoluteString
                    current.hops += 1
                    current.status = "queued"
                    current.bytesReceived = 0
                    current.totalBytes = -1
                    current.fileName = MediaTypes.fileName(
                        forUrl: nextURL.absoluteString,
                        contentType: nil,
                        contentDisposition: nil,
                        suggestedFilename: nil,
                        fallbackMillis: JobRecord.nowMillis()
                    )
                    return true
                })
                if let queued {
                    emit(queued)
                    if !enqueue(jobId: jobId) {
                        fail(&job, message: "The link could not be downloaded.")
                        return
                    }
                }
                finishWork(jobId: jobId)
            } catch {
                fail(&job, message: "The download couldn't be stored: \(error.localizedDescription)")
            }
            return
        }

        if MediaTypes.isStreamingPlaylist(mime: mime, url: finalURL) {
            fail(
                &job,
                message: "Streaming playlists (HLS/DASH) aren't supported. "
                    + "Share a direct video link."
            )
            return
        }

        let mimeKind = MediaTypes.kind(forMime: mime)
        let kind = mimeKind != .unknown ? mimeKind : MediaTypes.kind(forUrl: finalURL)
        guard kind != .unknown else {
            fail(&job, message: "This link doesn't point to a video or image.")
            return
        }

        let fileName = MediaTypes.fileName(
            forUrl: finalURL,
            contentType: mime,
            contentDisposition: response?.value(forHTTPHeaderField: "Content-Disposition"),
            suggestedFilename: response?.suggestedFilename,
            fallbackMillis: JobRecord.nowMillis()
        )
        let extensionName = MediaTypes.extensionOf(fileName) ?? "bin"
        let incoming: URL
        do {
            incoming = try store.incomingDirectory()
                .appendingPathComponent("\(jobId).\(job.transferToken).\(extensionName)")
            try? fileManager.removeItem(at: incoming)
            try fileManager.moveItem(at: location, to: incoming)
        } catch {
            fail(
                &job,
                message: "The download couldn't be stored: \(error.localizedDescription)"
            )
            return
        }

        let attributes = try? fileManager.attributesOfItem(atPath: incoming.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? job.bytesReceived
        let expected = response?.expectedContentLength ?? -1
        if expected > 0 && size < expected {
            try? fileManager.removeItem(at: incoming)
            fail(
                &job,
                message: "The download didn't finish. Tap Try again."
            )
            return
        }
        do {
            guard let saving = try update(job, change: { current in
                current.kind = kind.rawValue
                current.fileName = fileName
                current.mimeType = mime ?? MediaTypes.contentType(forFileName: fileName)
                current.status = "saving"
                current.bytesReceived = size
                return true
            }) else {
                try? fileManager.removeItem(at: incoming)
                finishWork(jobId: jobId)
                return
            }
            job = saving
            emit(saving)
        } catch {
            try? fileManager.removeItem(at: incoming)
            fail(&job, message: "The download couldn't be stored: \(error.localizedDescription)")
            return
        }

        PhotoLibrarySaver.save(fileURL: incoming, kind: kind.rawValue) { [self] result in
            defer {
                try? fileManager.removeItem(at: incoming)
                finishWork(jobId: jobId)
            }
            do {
                if let finished = try update(job, change: { current in
                    guard current.status == "saving" else { return false }
                    switch result {
                    case .success(let identifier):
                        current.status = "completed"
                        current.remoteId = identifier
                        current.error = nil
                    case .failure(let error):
                        current.status = "failed"
                        current.error = error.localizedDescription
                    }
                    return true
                }) {
                    emit(finished)
                }
            } catch {
                NSLog("maiDL could not persist Photos result: %@", error.localizedDescription)
            }
        }
    }

    private func fail(_ job: inout JobRecord, message: String) {
        defer { finishWork(jobId: job.id) }
        do {
            if let failed = try update(job, change: { current in
                current.status = "failed"
                current.error = message
                return true
            }) {
                emit(failed)
            }
        } catch {
            NSLog("maiDL could not persist download failure: %@", error.localizedDescription)
        }
    }

    private static func jobId(for task: URLSessionTask) -> String? {
        task.taskDescription?.split(separator: "|", maxSplits: 1).first.map(String.init)
    }

    private func job(for task: URLSessionTask) -> JobRecord? {
        guard let description = task.taskDescription,
              let id = Self.jobId(for: task),
              let job = store.get(id: id),
              job.isActive, job.sessionIdentifier == identifier
        else { return nil }
        let parts = description.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let token = String(parts[1])
        return token == job.transferToken ? job : nil
    }

    private func update(
        _ expected: JobRecord,
        change: (inout JobRecord) -> Bool
    ) throws -> JobRecord? {
        try store.update(id: expected.id) { current in
            guard current.isActive, current.sessionIdentifier == identifier,
                  current.transferToken == expected.transferToken
            else { return false }
            guard change(&current) else { return false }
            current.updatedAt = JobRecord.nowMillis()
            return true
        }
    }

    private func emit(_ job: JobRecord) {
        guard let onJobUpdate else { return }
        DispatchQueue.main.async {
            onJobUpdate(job)
        }
    }

    private func readText(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 768 * 1024)) ?? Data()
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
    }

    private static func message(for error: NSError) -> String {
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection. Tap Try again."
        case NSURLErrorTimedOut:
            return "The server took too long to respond."
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost:
            return "The server could not be reached. Tap Try again."
        default:
            return error.localizedDescription
        }
    }
}
