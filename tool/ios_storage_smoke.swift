import Foundation

/// Compiles the shipping SharedConfig, JobRecord, JobStore and LinkExtractor on
/// macOS and proves both storage roots plus the local job round-trip.
@main
struct StorageSmoke {
    static func main() {
        let fileManager = FileManager.default

        do {
            // No App Group container: the app's own Application Support path.
            let local = try JobStore.storageDirectory(container: nil)
            guard local.path.contains("/Application Support/maidl") else {
                fputs("storage smoke: unexpected local root \(local.path)\n", stderr)
                exit(1)
            }

            // App Group container: the shared Library path.
            let container = fileManager.temporaryDirectory
                .appendingPathComponent("maidl-container-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: container) }
            let shared = try JobStore.storageDirectory(container: container)
            guard shared.path
                == container.appendingPathComponent(
                    "Library/Application Support/maidl", isDirectory: true
                ).path
            else {
                fputs("storage smoke: unexpected shared root \(shared.path)\n", stderr)
                exit(1)
            }

            // Round-trip records through the local fallback path.
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("maidl-storage-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: root) }
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let store = JobStore(rootOverride: { root })
            let id = UUID().uuidString
            let now = JobRecord.nowMillis()
            let job = JobRecord(
                id: id,
                url: "https://example.com/video.mp4",
                kind: "video",
                fileName: "video.mp4",
                status: "queued",
                origin: "manual",
                createdAt: now,
                updatedAt: now
            )

            try store.save(job)
            guard let loaded = store.get(id: id),
                  loaded.url == job.url,
                  loaded.transferToken == job.transferToken
            else {
                fputs("storage smoke: job did not round-trip\n", stderr)
                exit(1)
            }
            try store.remove(id: id)
            guard store.get(id: id) == nil else {
                fputs("storage smoke: job was not removed\n", stderr)
                exit(1)
            }
        } catch {
            fputs("storage smoke failed: \(error)\n", stderr)
            exit(1)
        }

        print("storage smoke passed")
    }
}
