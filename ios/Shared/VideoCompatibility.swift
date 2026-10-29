import AVFoundation
import Foundation

/// One preparation owns only its newly generated output, never the source.
/// Inspection, exporting and completion all run away from the main queue.
final class VideoPreparation {
    private let queue = DispatchQueue(label: "app.maidl.video-preparation", qos: .utility)
    private let cancellationLock = NSLock()
    private var canceled = false
    private var completed = false
    private var asset: AVURLAsset?
    private var exporter: AVAssetExportSession?
    private var ownsOutput = false
    private let input: URL
    private let output: URL
    private var completion: ((Result<URL, Error>) -> Void)?

    fileprivate init(
        input: URL,
        output: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        self.input = input
        self.output = output
        self.completion = completion
    }

    fileprivate func start() {
        queue.async { [self] in
            guard !isCanceled else { finish(.failure(PreparationError.canceled)); return }
            guard input.isFileURL, output.isFileURL,
                  input.standardizedFileURL.resolvingSymlinksInPath()
                    != output.standardizedFileURL.resolvingSymlinksInPath()
            else {
                finish(.failure(PreparationError.invalidOutput))
                return
            }
            // Never overwrite a caller's file, including a hard link to input.
            guard !FileManager.default.fileExists(atPath: output.path) else {
                finish(.failure(PreparationError.existingOutput))
                return
            }
            inspect(input) { [self] result in
                switch result {
                case .failure(let error): finish(.failure(error))
                case .success(let inspected):
                    if inspected.compatible && Self.isMP4(input) {
                        finish(.success(input))
                    } else {
                        export(inspected, passthrough: inspected.compatible)
                    }
                }
            }
        }
    }

    func cancel() {
        cancellationLock.lock()
        canceled = true
        cancellationLock.unlock()
        queue.async { [self] in
            guard !completed else { return }
            asset?.cancelLoading()
            if let exporter {
                // Wait for its terminal callback before unlinking a file it
                // might still be writing, and before reporting cancellation.
                exporter.cancelExport()
            } else {
                finish(.failure(PreparationError.canceled))
            }
        }
    }

    private var isCanceled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return canceled
    }

    private struct Inspected {
        let asset: AVURLAsset
        let compatible: Bool
        let hasAudio: Bool
        let displayAspect: CGFloat
    }

    private func inspect(
        _ url: URL,
        completion: @escaping (Result<Inspected, Error>) -> Void
    ) {
        let inspectedAsset = AVURLAsset(
            url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        asset = inspectedAsset
        let keys = ["playable", "tracks", "duration", "hasProtectedContent"]
        inspectedAsset.loadValuesAsynchronously(forKeys: keys) { [self] in
            queue.async { [self] in
                guard !completed else { return }
                guard !isCanceled else { finish(.failure(PreparationError.canceled)); return }
                do {
                    for key in keys {
                        var error: NSError?
                        guard inspectedAsset.statusOfValue(forKey: key, error: &error) == .loaded
                        else { throw PreparationError.unreadable(error?.localizedDescription) }
                    }
                    guard !inspectedAsset.hasProtectedContent else {
                        throw PreparationError.protectedVideo
                    }
                    let duration = CMTimeGetSeconds(inspectedAsset.duration)
                    let videos = inspectedAsset.tracks(withMediaType: .video)
                    let audio = inspectedAsset.tracks(withMediaType: .audio)
                    guard inspectedAsset.isPlayable, !videos.isEmpty,
                          duration.isFinite, duration > 0,
                          videos.allSatisfy({ track in
                              let size = track.naturalSize
                              let display = CGRect(origin: .zero, size: size)
                                  .applying(track.preferredTransform)
                              let seconds = CMTimeGetSeconds(track.timeRange.duration)
                              return size.width.isFinite && size.height.isFinite
                                  && size.width > 0 && size.height > 0
                                  && display.width.isFinite && display.height.isFinite
                                  && display.width > 0 && display.height > 0
                                  && seconds.isFinite && seconds > 0
                                  && !track.formatDescriptions.isEmpty
                          })
                    else { throw PreparationError.invalidVideo }
                    let compatible = videos.allSatisfy {
                        Self.hasCodec($0, codec: kCMVideoCodecType_H264)
                    } && audio.allSatisfy {
                        Self.hasCodec($0, codec: kAudioFormatMPEG4AAC)
                    }
                    let display = CGRect(origin: .zero, size: videos[0].naturalSize)
                        .applying(videos[0].preferredTransform)
                    completion(.success(Inspected(
                        asset: inspectedAsset, compatible: compatible,
                        hasAudio: !audio.isEmpty, displayAspect: display.width / display.height
                    )))
                } catch {
                    completion(.failure(error))
                }
            }
        }
    }

    private static func hasCodec(_ track: AVAssetTrack, codec: FourCharCode) -> Bool {
        let formats = track.formatDescriptions as! [CMFormatDescription]
        return !formats.isEmpty && formats.allSatisfy {
            CMFormatDescriptionGetMediaSubType($0) == codec
        }
    }

    private func export(_ source: Inspected, passthrough: Bool) {
        guard !isCanceled else { finish(.failure(PreparationError.canceled)); return }
        let presets = AVAssetExportSession.exportPresets(compatibleWith: source.asset)
        let candidates = passthrough ? [AVAssetExportPresetPassthrough] : [
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPreset960x540,
            AVAssetExportPreset640x480,
        ]
        guard let preset = candidates.first(where: { presets.contains($0) }),
              let session = AVAssetExportSession(asset: source.asset, presetName: preset),
              session.supportedFileTypes.contains(.mp4)
        else {
            if passthrough { export(source, passthrough: false) }
            else { finish(.failure(PreparationError.unsupportedVideo)) }
            return
        }
        exporter = session
        session.outputURL = output
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        ownsOutput = true
        // Standard (not HEVC) presets preserve the asset's orientation and
        // audio while encoding H.264/AAC at no more than 1920 x 1080.
        session.exportAsynchronously { [self] in
            queue.async { [self] in
                exporter = nil
                guard !completed else { return }
                guard !isCanceled else { finish(.failure(PreparationError.canceled)); return }
                guard session.status == .completed else {
                    if passthrough {
                        do {
                            if FileManager.default.fileExists(atPath: output.path) {
                                try FileManager.default.removeItem(at: output)
                            }
                            ownsOutput = false
                            export(source, passthrough: false)
                        } catch {
                            finish(.failure(error))
                        }
                    } else {
                        finish(.failure(PreparationError.exportFailed(session.error?.localizedDescription)))
                    }
                    return
                }
                inspect(output) { [self] result in
                    switch result {
                    case .failure(let error): finish(.failure(error))
                    case .success(let prepared):
                        let withinSizeLimit = passthrough || prepared.asset.tracks(withMediaType: .video)
                            .allSatisfy {
                                let size = $0.naturalSize
                                return max(size.width, size.height) <= 1920
                                    && min(size.width, size.height) <= 1080
                            }
                        guard prepared.compatible, Self.isMP4(output), withinSizeLimit,
                              prepared.hasAudio == source.hasAudio,
                              abs(prepared.displayAspect / source.displayAspect - 1) < 0.02
                        else {
                            finish(.failure(PreparationError.invalidOutputVideo))
                            return
                        }
                        finish(.success(output))
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !completed else { return }
        cancellationLock.lock()
        let finalResult: Result<URL, Error> = canceled ? .failure(PreparationError.canceled) : result
        completed = true
        cancellationLock.unlock()
        asset = nil
        exporter = nil
        if case .failure = finalResult, ownsOutput {
            try? FileManager.default.removeItem(at: output)
        }
        let callback = completion
        completion = nil
        callback?(finalResult)
    }

    /// Check the actual ISO base-media file-type box, not the name or MIME.
    /// QuickTime's `qt  ` brand is deliberately not accepted as MP4.
    private static func isMP4(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            var offset: UInt64 = 0
            while offset + 8 <= length && offset < 1_048_576 {
                try handle.seek(toOffset: offset)
                let header = try handle.read(upToCount: 16) ?? Data()
                guard header.count >= 8 else { return false }
                func number(_ range: Range<Int>) -> UInt64 {
                    header[range].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                }
                let size32 = number(0..<4)
                let extended = size32 == 1
                guard !extended || header.count == 16 else { return false }
                let size = extended ? number(8..<16) : (size32 == 0 ? length - offset : size32)
                let headerSize: UInt64 = extended ? 16 : 8
                guard size >= headerSize, size <= length - offset else { return false }
                if String(data: header[4..<8], encoding: .ascii) == "ftyp" {
                    guard size >= headerSize + 8, size <= 4096 else { return false }
                    try handle.seek(toOffset: offset + headerSize)
                    let brand = try handle.read(upToCount: 4) ?? Data()
                    guard let major = String(data: brand, encoding: .ascii) else { return false }
                    return ["isom", "iso2", "iso3", "iso4", "iso5", "iso6", "iso7", "iso8", "iso9",
                            "mp41", "mp42", "avc1", "M4V ", "M4VH", "M4VP", "MSNV"].contains(major)
                }
                offset += size
            }
        } catch { return false }
        return false
    }

    private enum PreparationError: LocalizedError {
        case canceled, invalidOutput, existingOutput, protectedVideo, invalidVideo
        case unsupportedVideo, invalidOutputVideo
        case unreadable(String?), exportFailed(String?)

        var errorDescription: String? {
            switch self {
            case .canceled: return "Video preparation was canceled."
            case .invalidOutput: return "The prepared video must use a different local file from its source."
            case .existingOutput: return "The prepared video's destination already exists."
            case .protectedVideo: return "Protected videos cannot be converted or saved."
            case .invalidVideo: return "This file is not a playable video, or it is damaged."
            case .unsupportedVideo:
                return "iOS cannot convert this video's format to H.264/AAC MP4. Try another source format."
            case .invalidOutputVideo:
                return "iOS could not produce a playable H.264/AAC MP4 with the original audio."
            case .unreadable(let detail), .exportFailed(let detail):
                let message = "iOS could not read or convert this video to H.264/AAC MP4."
                return detail.map { "\(message) \($0)" } ?? message
            }
        }
    }
}

enum VideoCompatibility {
    @discardableResult
    static func prepare(
        input: URL,
        output: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) -> VideoPreparation {
        let preparation = VideoPreparation(input: input, output: output, completion: completion)
        preparation.start()
        return preparation
    }
}
