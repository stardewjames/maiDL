import UIKit
import UniformTypeIdentifiers

/// Share sheet entry point.
///
/// It extracts the link, persists a job in the App Group, starts a background
/// transfer, and dismisses itself. The containing app is relaunched by iOS when
/// the transfer finishes, then adds the file to Photos.
final class ShareViewController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private var handler: BackgroundSessionHandler?
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
        extractLink()
    }

    private func configureView() {
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 340, height: 200)

        titleLabel.text = "Saving to maiDL"
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontForContentSizeCategory = true

        messageLabel.text = "Looking for a video or image link…"
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 4

        doneButton.setTitle("Done", for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        doneButton.addTarget(self, action: #selector(dismissSheet), for: .touchUpInside)
        doneButton.isHidden = true

        spinner.hidesWhenStopped = true
        spinner.startAnimating()

        let stack = UIStackView(
            arrangedSubviews: [spinner, titleLabel, messageLabel, doneButton]
        )
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    // MARK: - Extraction

    private func extractLink() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let urlProvider = providers.first {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        let textProvider = providers.first {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }

        if let urlProvider {
            urlProvider.loadItem(
                forTypeIdentifier: UTType.url.identifier,
                options: nil
            ) { [weak self] item, _ in
                guard let self else { return }
                if let url = Self.url(from: item) {
                    self.handleRawText(url.absoluteString)
                } else {
                    self.loadText(from: textProvider, fallback: items)
                }
            }
        } else {
            loadText(from: textProvider, fallback: items)
        }
    }

    private func loadText(
        from provider: NSItemProvider?,
        fallback items: [NSExtensionItem]
    ) {
        guard let provider else {
            handleRawText(
                items.compactMap { $0.attributedContentText?.string }
                    .joined(separator: " ")
            )
            return
        }
        provider.loadItem(
            forTypeIdentifier: UTType.plainText.identifier,
            options: nil
        ) { [weak self] item, _ in
            guard let self else { return }
            let text: String?
            if let value = item as? String {
                text = value
            } else if let value = item as? NSAttributedString {
                text = value.string
            } else if let value = item as? Data {
                text = String(data: value, encoding: .utf8)
            } else if let value = item as? URL {
                text = value.absoluteString
            } else {
                text = nil
            }
            self.handleRawText(text ?? "")
        }
    }

    private func handleRawText(_ text: String) {
        DispatchQueue.main.async {
            do {
                let url = try LinkExtractor.parse(text)
                self.beginDownload(url)
            } catch let error as LinkError {
                self.showError(error.message)
            } catch {
                self.showError("That link could not be read.")
            }
        }
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let string = item as? String { return LinkExtractor.firstURL(in: string) }
        return nil
    }

    // MARK: - Transfer

    private func beginDownload(_ url: URL) {
        DispatchQueue.main.async {
            let access = PhotoLibrarySaver.accessStatus()
            if access == "denied" {
                self.showError(
                    "Photos access is off. Open maiDL, allow Photos access, "
                        + "then share again."
                )
                return
            }
            if access == "notDetermined" {
                self.messageLabel.text = "Allow Photos access to finish saving."
                PhotoLibrarySaver.requestAccess { status in
                    DispatchQueue.main.async {
                        if status == "granted" {
                            self.startTransfer(url: url)
                        } else {
                            self.showError(
                                "maiDL needs permission to add items to Photos."
                            )
                        }
                    }
                }
                return
            }
            self.startTransfer(url: url)
        }
    }

    private func startTransfer(url: URL) {
        let normalized = LinkExtractor.normalize(url)
        if JobStore.shared.activeDuplicate(url: normalized.absoluteString) != nil {
            complete()
            return
        }

        var job = JobFactory.create(url: normalized, origin: "share")
        job.sessionIdentifier = SharedConfig.shareSessionIdentifierPrefix + UUID().uuidString
        do {
            guard let handler = try BackgroundSessionHandler(
                identifier: job.sessionIdentifier
            ) else {
                throw LinkError(
                    code: "download_busy", message: "The download session is unavailable."
                )
            }
            self.handler = handler
            // Never dismiss with success until the job is durably recorded.
            try JobStore.shared.save(job)
            guard handler.enqueue(jobId: job.id) else {
                throw LinkError(
                    code: "download_failed", message: "The link could not be downloaded."
                )
            }
        } catch {
            do {
                try JobStore.shared.update(id: job.id) { current in
                    guard current.isActive else { return false }
                    current.status = "failed"
                    current.error = error.localizedDescription
                    current.updatedAt = JobRecord.nowMillis()
                    return true
                }
            } catch {
                NSLog("maiDL could not persist share failure: %@", error.localizedDescription)
            }
            handler?.finishIfIdle()
            showError(error.localizedDescription)
            return
        }

        titleLabel.text = "Download queued"
        messageLabel.text = "You can close this sheet. Open maiDL to finish preparing the video if iOS pauses it."
        spinner.stopAnimating()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.complete()
        }
    }

    private func showError(_ message: String) {
        spinner.stopAnimating()
        titleLabel.text = "Couldn't save that link"
        messageLabel.text = message
        doneButton.isHidden = false
    }

    @objc private func dismissSheet() {
        complete()
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        let context = extensionContext
        let dismiss: () -> Void = {
            context?.completeRequest(returningItems: [], completionHandler: nil)
        }
        if let handler {
            handler.afterCurrentWork(dismiss)
        } else {
            dismiss()
        }
    }
}
