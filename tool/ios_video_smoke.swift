import Foundation
import AVFoundation
import AudioToolbox

private struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw SmokeFailure(message) }
}

private final class CompletionCounter {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        let current = count
        lock.unlock()
        // A duplicate must fail the process, not resume a continuation twice.
        if current != 1 { fatalError("VideoCompatibility completed more than once") }
    }
}

private struct Probe {
    let format: [String: Any]
    let streams: [[String: Any]]

    var videos: [[String: Any]] { streams.filter { $0["codec_type"] as? String == "video" } }
    var audio: [[String: Any]] { streams.filter { $0["codec_type"] as? String == "audio" } }
}

@main
private enum VideoSmoke {
    static func main() async {
        // A missing callback fails this executable instead of hanging the CI job.
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            fputs("FAIL: native video smoke exceeded 180 seconds\n", stderr)
            exit(1)
        }
        do {
            try require(CommandLine.arguments.count == 3, "Expected fixture directory and ffprobe path")
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let ffprobe = URL(fileURLWithPath: CommandLine.arguments[2])
            try await exercise(directory: directory, ffprobe: ffprobe)
            print("PASS: native video compatibility smoke")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func prepare(_ input: URL, _ output: URL, cancelImmediately: Bool = false) async -> Result<URL, Error> {
        let counter = CompletionCounter()
        var preparation: VideoPreparation?
        let result: Result<URL, Error> = await withCheckedContinuation { continuation in
            preparation = VideoCompatibility.prepare(input: input, output: output) { result in
                counter.record()
                continuation.resume(returning: result)
            }
            if cancelImmediately { preparation?.cancel() }
        }
        withExtendedLifetime(preparation) {}
        return result
    }

    private static func exercise(directory: URL, ffprobe: URL) async throws {
        let cases: [(name: String, video: String, audio: String?, passthrough: Bool, portrait: Bool)] = [
            ("h264-aac.mp4", "h264", "aac", true, false),
            ("h264-aac.mov", "h264", "aac", false, false),
            ("mov-disguised.mp4", "h264", "aac", false, false),
            ("hevc-aac.mp4", "hevc", "aac", false, false),
            ("prores-pcm.mov", "prores", "pcm_s16le", false, false),
            ("prores-pcm-rotated.mov", "prores", "pcm_s16le", false, true),
            ("silent.mov", "h264", nil, false, false),
            ("silent-hevc.mp4", "hevc", nil, false, false),
        ]
        for item in cases {
            let input = directory.appendingPathComponent(item.name)
            let output = directory.appendingPathComponent("prepared-\(item.name).mp4")
            let original = try Data(contentsOf: input)
            let sourceProbe = try probe(input, ffprobe: ffprobe)
            try require(sourceProbe.videos.count == 1, "\(item.name): invalid video fixture")
            try require(sourceProbe.videos[0]["codec_name"] as? String == item.video, "\(item.name): fixture video encoder mismatch")
            try require(sourceProbe.audio.count == (item.audio == nil ? 0 : 1), "\(item.name): fixture audio missing/unexpected")
            if let audio = item.audio {
                try require(sourceProbe.audio[0]["codec_name"] as? String == audio, "\(item.name): fixture audio encoder mismatch")
            }
            let source = AVURLAsset(url: input)
            let sourceTrack = try videoTrack(source, label: item.name)
            let sourceSize = displaySize(sourceTrack)
            try require((sourceSize.height > sourceSize.width) == item.portrait, "\(item.name): fixture display matrix is wrong")

            let result = await prepare(input, output)
            let prepared: URL
            switch result {
            case .success(let url): prepared = url
            case .failure(let error): throw SmokeFailure("\(item.name): prepare failed: \(error)")
            }
            let expected = item.passthrough ? input : output
            try require(prepared.standardizedFileURL == expected.standardizedFileURL, "\(item.name): wrong returned URL")
            let remainingInput = try Data(contentsOf: input)
            try require(remainingInput == original, "\(item.name): input was modified")
            if item.passthrough {
                try require(!FileManager.default.fileExists(atPath: output.path), "\(item.name): fast path generated an unnecessary file")
            }
            try validate(prepared, source: source, sourceSize: sourceSize, hasAudio: item.audio != nil, ffprobe: ffprobe)
            if item.name == "h264-aac.mov" {
                // The encoded video packets must survive a remux without recompression.
                let before = try videoPacketHashes(input, ffprobe: ffprobe)
                let after = try videoPacketHashes(prepared, ffprobe: ffprobe)
                try require(!before.isEmpty && before == after, "H.264/AAC MOV was recompressed instead of remuxed")
            }
            print("PASS: \(item.name)\(item.passthrough ? " (byte-identical fast path)" : " -> H.264/AAC MP4")")
        }

        for name in ["corrupt.mp4", "audio-only.m4a"] {
            let input = directory.appendingPathComponent(name)
            let output = directory.appendingPathComponent("rejected-\(name).mp4")
            let original = try Data(contentsOf: input)
            let result = await prepare(input, output)
            if case .success = result { throw SmokeFailure("\(name): invalid input was accepted") }
            let remainingInput = try Data(contentsOf: input)
            try require(remainingInput == original, "\(name): rejected input was modified/deleted")
            try require(!FileManager.default.fileExists(atPath: output.path), "\(name): failed preparation left generated output")
            print("PASS: rejected \(name) without deleting input")
        }

        let input = directory.appendingPathComponent("prores-pcm.mov")
        let original = try Data(contentsOf: input)
        let sameURL = await prepare(input, input)
        if case .success = sameURL { throw SmokeFailure("Input=output was accepted") }
        let afterSameURL = try Data(contentsOf: input)
        try require(afterSameURL == original, "Input=output rejection damaged input")
        print("PASS: input=output rejected safely")

        let existing = directory.appendingPathComponent("already-exists.mp4")
        let sentinel = Data("existing output must not be overwritten".utf8)
        try sentinel.write(to: existing)
        let existingResult = await prepare(input, existing)
        if case .success = existingResult { throw SmokeFailure("Existing output was accepted") }
        let remainingSentinel = try Data(contentsOf: existing)
        try require(remainingSentinel == sentinel, "Existing output was modified/deleted")
        let afterExisting = try Data(contentsOf: input)
        try require(afterExisting == original, "Existing-output rejection damaged input")
        print("PASS: preexisting output rejected without overwriting")

        // Cancel synchronously while inspection is pending; no scheduler-timed export race.
        let cancelledOutput = directory.appendingPathComponent("cancelled.mp4")
        let cancelled = await prepare(input, cancelledOutput, cancelImmediately: true)
        if case .success = cancelled { throw SmokeFailure("Immediately cancelled preparation succeeded") }
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterCancel = try Data(contentsOf: input)
        try require(afterCancel == original, "Cancellation modified/deleted input")
        try require(!FileManager.default.fileExists(atPath: cancelledOutput.path), "Cancellation left generated output")
        print("PASS: cancellation completes once and leaves no output")
    }

    private static func validate(_ url: URL, source: AVURLAsset, sourceSize: CGSize, hasAudio: Bool, ffprobe: URL) throws {
        let label = url.lastPathComponent
        let asset = AVURLAsset(url: url)
        try require(asset.isPlayable, "\(label): AVFoundation cannot play the result")
        let duration = CMTimeGetSeconds(asset.duration)
        let sourceDuration = CMTimeGetSeconds(source.duration)
        try require(duration.isFinite && duration > 0, "\(label): invalid duration")
        try require(sourceDuration.isFinite && abs(duration - sourceDuration) < 0.25, "\(label): duration was lost/truncated")
        let video = try videoTrack(asset, label: label)
        try require(!video.formatDescriptions.isEmpty, "\(label): missing video format description")
        for format in video.formatDescriptions {
            let description = format as! CMFormatDescription
            try require(CMFormatDescriptionGetMediaSubType(description) == kCMVideoCodecType_H264, "\(label): actual AVFoundation video is not H.264")
        }
        let audio = asset.tracks(withMediaType: .audio)
        try require(audio.count == (hasAudio ? 1 : 0), "\(label): audio was lost or invented")
        for track in audio {
            try require(!track.formatDescriptions.isEmpty, "\(label): missing audio format description")
            let audioDuration = CMTimeGetSeconds(track.timeRange.duration)
            try require(audioDuration.isFinite && audioDuration > 0.5, "\(label): audio was truncated")
            for format in track.formatDescriptions {
                let description = format as! CMFormatDescription
                try require(CMFormatDescriptionGetMediaSubType(description) == kAudioFormatMPEG4AAC, "\(label): actual AVFoundation audio is not AAC")
            }
        }
        let size = displaySize(video)
        let sourceRatio = sourceSize.width / sourceSize.height
        let outputRatio = size.width / size.height
        try require(size.width > 0 && size.height > 0 && abs(sourceRatio - outputRatio) < 0.02, "\(label): orientation/display aspect was lost")
        try require(max(size.width, size.height) <= 1920 && min(size.width, size.height) <= 1080, "\(label): exceeds 1080p output cap")

        // Independently inspect stream codecs and the actual container, not its suffix.
        let info = try probe(url, ffprobe: ffprobe)
        try require(info.videos.count == 1 && info.videos[0]["codec_name"] as? String == "h264", "\(label): ffprobe did not find H.264")
        try require(info.audio.count == (hasAudio ? 1 : 0), "\(label): ffprobe audio count mismatch")
        if hasAudio {
            try require(info.audio[0]["codec_name"] as? String == "aac", "\(label): ffprobe did not find AAC")
        }
        let formats = (info.format["format_name"] as? String ?? "").split(separator: ",")
        let tags = info.format["tags"] as? [String: Any] ?? [:]
        let brand = (tags["major_brand"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let mp4Brands: Set<String> = ["isom", "iso2", "iso4", "iso5", "iso6", "mp41", "mp42", "avc1"]
        try require(formats.contains("mp4") && mp4Brands.contains(brand), "\(label): not an actual MP4 container (brand \(brand))")
    }

    private static func videoTrack(_ asset: AVURLAsset, label: String) throws -> AVAssetTrack {
        let tracks = asset.tracks(withMediaType: .video)
        try require(tracks.count == 1, "\(label): expected exactly one video track")
        return tracks[0]
    }

    private static func displaySize(_ track: AVAssetTrack) -> CGSize {
        let bounds = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        return CGSize(width: abs(bounds.width), height: abs(bounds.height))
    }

    private static func probe(_ url: URL, ffprobe: URL) throws -> Probe {
        let json = try runProbe(ffprobe, arguments: [
            "-v", "error", "-show_entries",
            "format=format_name,duration:format_tags=major_brand:stream=codec_type,codec_name,width,height",
            "-of", "json", url.path,
        ])
        guard let format = json["format"] as? [String: Any], let streams = json["streams"] as? [[String: Any]] else {
            throw SmokeFailure("ffprobe returned no container/stream information for \(url.lastPathComponent)")
        }
        return Probe(format: format, streams: streams)
    }

    private static func videoPacketHashes(_ url: URL, ffprobe: URL) throws -> [String] {
        let json = try runProbe(ffprobe, arguments: [
            "-v", "error", "-select_streams", "v:0", "-show_packets", "-show_data_hash", "sha256",
            "-show_entries", "packet=data_hash", "-of", "json", url.path,
        ])
        let packets = json["packets"] as? [[String: Any]] ?? []
        return packets.compactMap { $0["data_hash"] as? String }
    }

    private static func runProbe(_ executable: URL, arguments: [String]) throws -> [String: Any] {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try require(process.terminationStatus == 0, "ffprobe failed: \(String(decoding: errorData, as: UTF8.self))")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmokeFailure("ffprobe returned invalid JSON")
        }
        return json
    }
}
