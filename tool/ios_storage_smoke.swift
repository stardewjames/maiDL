import Foundation

/// Compiles the shipping SharedConfig, JobRecord, JobStore and LinkExtractor on
/// macOS and proves the no-App-Group fallback can persist and remove a job.
@main
struct StorageSmoke {
    static func main() {
        guard !SharedConfig.hasAppGroup else {
            fputs("storage smoke: expected an unsigned CLI without an App Group\n", stderr)
            exit(1)
        }

        let store = JobStore.shared
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

        do {
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

        print("local storage smoke passed")
    }
}
