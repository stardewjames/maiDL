import Foundation
import Photos

/// Adds finished files to the Photos library with add-only authorization.
enum PhotoLibrarySaver {
    enum SaveError: LocalizedError {
        case denied
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .denied:
                return "Photos access is off. Open maiDL and allow Photos access."
            case .failed(let message):
                return message
            }
        }
    }

    private final class Placeholder {
        var identifier: String?
    }

    /// Mirrors the Dart PermissionState wire values.
    static func accessStatus() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .addOnly) {
        case .authorized, .limited:
            return "granted"
        case .denied, .restricted:
            return "denied"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "denied"
        }
    }

    static func requestAccess(completion: @escaping (String) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in
            DispatchQueue.main.async {
                completion(accessStatus())
            }
        }
    }

    static func save(
        fileURL: URL,
        kind: String,
        fileName: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard accessStatus() == "granted" else {
            completion(.failure(SaveError.denied))
            return
        }
        let placeholder = Placeholder()
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            if kind == "video" {
                options.originalFilename = fileName
                options.uniformTypeIdentifier = "public.mpeg-4"
            }
            // Move rather than copy: videos can be large, and the temp file is
            // ours to discard.
            options.shouldMoveFile = true
            let resourceType: PHAssetResourceType = kind == "video" ? .video : .photo
            request.addResource(with: resourceType, fileURL: fileURL, options: options)
            placeholder.identifier = request.placeholderForCreatedAsset?.localIdentifier
        }, completionHandler: { success, error in
            if success, let identifier = placeholder.identifier {
                completion(.success(identifier))
            } else {
                completion(
                    .failure(
                        SaveError.failed(
                            error?.localizedDescription
                                ?? "Photos couldn't save this file."
                        )
                    )
                )
            }
        })
    }
}
