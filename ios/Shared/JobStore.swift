import Darwin
import Foundation

/// Atomic records plus a cross-process mutation lock. Uses the App Group when
/// the signature grants one, otherwise the app's own Application Support
/// directory so downloads entered in the app still work.
final class JobStore {
    static let shared = JobStore()

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "app.maidl.jobstore")
    private let rootOverride: (() throws -> URL)?

    /// The override exists so the macOS storage smoke can exercise both root
    /// branches deterministically; the app always uses the default root.
    init(rootOverride: (() throws -> URL)? = nil) {
        self.rootOverride = rootOverride
    }

    private func root() throws -> URL {
        if let rootOverride {
            return try rootOverride()
        }
        return try Self.storageDirectory(
            container: fileManager.containerURL(
                forSecurityApplicationGroupIdentifier: SharedConfig.appGroup
            )
        )
    }

    static func storageDirectory(container: URL?) throws -> URL {
        let fileManager = FileManager.default
        let directory: URL
        if let container {
            directory = container.appendingPathComponent(
                "Library/Application Support/maidl", isDirectory: true
            )
        } else {
            directory = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appendingPathComponent("maidl", isDirectory: true)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func settingsData() -> Data? {
        queue.sync {
            guard let directory = try? root() else { return nil }
            return try? Data(
                contentsOf: directory.appendingPathComponent("resolver-settings.json")
            )
        }
    }

    func saveSettingsData(_ data: Data) throws {
        try queue.sync {
            let url = try root().appendingPathComponent("resolver-settings.json")
            try data.write(to: url, options: .atomic)
        }
    }

    private func jobsDirectory() throws -> URL {
        try root().appendingPathComponent("jobs", isDirectory: true)
    }

    func incomingDirectory() throws -> URL {
        let directory = try root().appendingPathComponent("incoming", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func jobURL(_ id: String) throws -> URL {
        try jobsDirectory().appendingPathComponent("\(id).json")
    }

    private func loadAll() -> [JobRecord] {
        guard let directory = try? jobsDirectory(),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              )
        else { return [] }
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(JobRecord.self, from: data)
        }.sorted { lhs, rhs in
            if lhs.isActive != rhs.isActive { return lhs.isActive }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func all() -> [JobRecord] {
        queue.sync { loadAll() }
    }

    private func load(id: String) -> JobRecord? {
        guard let url = try? jobURL(id),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(JobRecord.self, from: data)
    }

    func get(id: String) -> JobRecord? {
        queue.sync { load(id: id) }
    }

    private func persist(_ job: JobRecord) throws {
        let directory = try jobsDirectory()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(job)
        try data.write(to: jobURL(job.id), options: .atomic)
    }

    private func withMutationLock<T>(_ body: () throws -> T) throws -> T {
        let url = try root().appendingPathComponent("store.lock")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    func save(_ job: JobRecord) throws {
        try queue.sync {
            try withMutationLock { try persist(job) }
        }
    }

    /// Rechecks the current record while holding the interprocess lock, so a
    /// late progress/completion callback cannot undo cancel, remove, or retry.
    @discardableResult
    func update(
        id: String,
        _ change: (inout JobRecord) throws -> Bool
    ) throws -> JobRecord? {
        try queue.sync {
            try withMutationLock {
                guard var job = load(id: id), try change(&job) else { return nil }
                try persist(job)
                return job
            }
        }
    }

    func remove(id: String) throws {
        try queue.sync {
            try withMutationLock {
                if load(id: id)?.status == "saving" {
                    throw LinkError(
                        code: "saving_in_progress",
                        message: "Photos is already saving this item. Wait for it to finish."
                    )
                }
                let url = try jobURL(id)
                if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            }
        }
    }

    func clearFinished() throws {
        try queue.sync {
            try withMutationLock {
                for job in loadAll() where !job.isActive {
                    try fileManager.removeItem(at: jobURL(job.id))
                }
            }
        }
    }

    func activeDuplicate(url: String) -> JobRecord? {
        all().first { $0.isActive && $0.url == url }
    }

    func removeIncomingFiles(for id: String, transferToken: String? = nil) {
        guard let directory = try? incomingDirectory(),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
              )
        else { return }
        let prefix = transferToken.map { "\(id).\($0)." } ?? "\(id)."
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: url)
        }
    }

    func pendingSourceURL(for job: JobRecord) throws -> URL {
        guard let name = job.pendingSourceFile,
              (name as NSString).lastPathComponent == name,
              name.hasPrefix("\(job.id).\(job.transferToken)."),
              !name.contains("/") && !name.contains("\\")
        else {
            throw LinkError(
                code: "video_source_missing",
                message: "The downloaded video is unavailable. Tap Try again."
            )
        }
        return try incomingDirectory().appendingPathComponent(name)
    }

    /// A suspended extension still owns its URLSession. Only attach after its
    /// process exits (which releases this lock), or after session invalidation.
    func claimSession(identifier: String) throws -> SessionOwnership? {
        let directory = try root().appendingPathComponent("sessions", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return try SessionOwnership(url: directory.appendingPathComponent(identifier))
    }
}

final class SessionOwnership {
    private let descriptor: Int32

    init?(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        self.descriptor = descriptor
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
