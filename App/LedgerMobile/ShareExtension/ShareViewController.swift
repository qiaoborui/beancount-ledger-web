import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let progress = UIActivityIndicatorView(style: .medium)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "tray.and.arrow.down"))
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        statusLabel.font = .preferredFont(forTextStyle: .title2)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.text = "正在保存账单"
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center
        detailLabel.text = "文件将保存在 Ledger 的待导入收件箱。"
        doneButton.configuration = .filled()
        doneButton.setTitle("完成", for: .normal)
        doneButton.isHidden = true
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)
        progress.startAnimating()
        let stack = UIStackView(arrangedSubviews: [icon, statusLabel, detailLabel, progress, doneButton])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        Task { await saveAttachments() }
    }

    private func saveAttachments() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= LedgerSharedImportInbox.maximumSharedItems else {
            showResult(saved: 0, failure: "每次请选择 1–5 个账单文件。")
            return
        }
        var saved = 0
        do {
            let inbox = try LedgerSharedImportInbox.live()
            for provider in providers {
                try await save(provider, to: inbox)
                saved += 1
            }
            showResult(saved: saved, failure: nil)
        } catch {
            showResult(saved: saved, failure: error.localizedDescription)
        }
    }

    private func save(_ provider: NSItemProvider, to inbox: LedgerSharedImportInbox) async throws {
        let preferredName = provider.suggestedName.flatMap { name in
            LedgerSharedImportInbox.supportedExtensions.contains((name as NSString).pathExtension.lowercased()) ? name : nil
        }
        // File URLs are loaded as local URLs; ordinary web URLs are never fetched.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                    do {
                        if let error { throw error }
                        guard let url = value as? URL, url.isFileURL else { throw LedgerSharedImportInbox.InboxError.invalidFile }
                        try inbox.enqueue(fileURL: url, originalName: preferredName)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return
        }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier), let ext = type.preferredFilenameExtension else { return false }
            return type.conforms(to: .data) && LedgerSharedImportInbox.supportedExtensions.contains(ext.lowercased())
        }) else { throw LedgerSharedImportInbox.InboxError.unsupported }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                // The provider's temporary URL is valid only inside this callback.
                do {
                    if let error { throw error }
                    guard let url else { throw LedgerSharedImportInbox.InboxError.invalidFile }
                    try inbox.enqueue(fileURL: url, originalName: preferredName)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func showResult(saved: Int, failure: String?) {
        progress.stopAnimating()
        progress.isHidden = true
        statusLabel.text = saved > 0 ? "已保存 \(saved) 个账单文件" : "未能保存账单"
        detailLabel.text = [saved > 0 ? "请打开 Ledger，在「导入」的待导入收件箱中核对并提交。" : nil, failure]
            .compactMap { $0 }.joined(separator: "\n\n")
        doneButton.isHidden = false
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
