import UIKit
import UniformTypeIdentifiers

/// The share sheet asks where the files go: straight to 账本助手, which opens
/// a new conversation with them attached, or into the import inbox for 导入.
@MainActor
final class ShareViewController: UIViewController, UITextFieldDelegate {
    private let icon = UIImageView(image: UIImage(systemName: "square.and.arrow.down.on.square"))
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let noteField = UITextField()
    private let agentButton = UIButton(type: .system)
    private let importButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let progress = UIActivityIndicatorView(style: .medium)
    private var providers: [NSItemProvider] = []
    private var saving = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 44).isActive = true
        statusLabel.font = .preferredFont(forTextStyle: .title2)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        detailLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.textAlignment = .center

        noteField.placeholder = String(localized: "想让账本助手做什么？（可选）")
        noteField.borderStyle = .roundedRect
        noteField.font = .preferredFont(forTextStyle: .body)
        noteField.adjustsFontForContentSizeCategory = true
        noteField.returnKeyType = .send
        noteField.clearButtonMode = .whileEditing
        noteField.delegate = self
        noteField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        var agent = UIButton.Configuration.filled()
        agent.title = String(localized: "发给账本助手")
        agent.image = UIImage(systemName: "sparkles")
        agent.imagePadding = 8
        agent.buttonSize = .large
        agentButton.configuration = agent
        agentButton.addTarget(self, action: #selector(sendToAgent), for: .touchUpInside)

        var save = UIButton.Configuration.tinted()
        save.title = String(localized: "存到待导入收件箱")
        save.image = UIImage(systemName: "tray.and.arrow.down")
        save.imagePadding = 8
        save.buttonSize = .large
        importButton.configuration = save
        importButton.addTarget(self, action: #selector(saveForImport), for: .touchUpInside)

        cancelButton.configuration = .plain()
        cancelButton.setTitle(String(localized: "取消"), for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        doneButton.configuration = .filled()
        doneButton.setTitle(String(localized: "完成"), for: .normal)
        doneButton.isHidden = true
        doneButton.addTarget(self, action: #selector(finish), for: .touchUpInside)
        progress.hidesWhenStopped = true

        let stack = UIStackView(arrangedSubviews: [icon, statusLabel, detailLabel, noteField, agentButton, importButton,
                                                   cancelButton, progress, doneButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(24, after: detailLabel)
        stack.setCustomSpacing(8, after: agentButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        // Centred in the space the keyboard leaves, so the field and the
        // buttons stay in view while the user types.
        let free = UILayoutGuide()
        view.addLayoutGuide(free)
        let centred = stack.centerYAnchor.constraint(equalTo: free.centerYAnchor)
        centred.priority = .defaultHigh
        NSLayoutConstraint.activate([
            free.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            free.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -12),
            centred,
            stack.topAnchor.constraint(greaterThanOrEqualTo: free.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: free.bottomAnchor, constant: -12),
        ])

        providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        showChoice()
    }

    /// What was shared and the two places it can go. Photos and screenshots
    /// can only go to the assistant: 导入 reads bill files.
    private func showChoice() {
        guard !providers.isEmpty, providers.count <= LedgerSharedImportInbox.maximumSharedItems else {
            showResult(title: String(localized: "未能保存"), detail: String(localized: "每次请选择 1–5 个文件。"))
            return
        }
        statusLabel.text = String(localized: "发送 \(providers.count) 个文件")
        let names = providers.enumerated().map { index, provider in
            provider.suggestedName ?? String(localized: "第 \(index + 1) 个文件")
        }
        detailLabel.text = names.joined(separator: "\n")
        importButton.isHidden = providers.contains(where: Self.isImage)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendToAgent()
        return false
    }

    @objc private func sendToAgent() {
        let note = noteField.text
        save(to: .agent, note: note)
    }

    @objc private func saveForImport() {
        save(to: .imports, note: nil)
    }

    private func save(to purpose: LedgerSharedImportInbox.Purpose, note: String?) {
        guard !saving else { return }
        saving = true
        noteField.resignFirstResponder()
        for control in [noteField, agentButton, importButton, cancelButton] as [UIView] { control.isHidden = true }
        statusLabel.text = purpose == .agent ? String(localized: "正在发给账本助手") : String(localized: "正在保存账单")
        detailLabel.text = nil
        progress.startAnimating()
        Task { await saveAttachments(to: purpose, note: note) }
    }

    private func saveAttachments(to purpose: LedgerSharedImportInbox.Purpose, note: String?) async {
        var saved = 0
        do {
            let inbox = try LedgerSharedImportInbox.live(purpose)
            for (index, provider) in providers.enumerated() {
                try await save(provider, index: index, to: inbox, note: note)
                saved += 1
            }
        } catch {
            showSaved(saved, purpose: purpose, failure: error.localizedDescription)
            return
        }
        // The app takes the files into a new conversation as soon as it is in
        // front; when the system does not let the extension open it, the
        // files wait until the user does.
        if purpose == .agent, openHostApp(URL(string: "ledger://agent")!) {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        showSaved(saved, purpose: purpose, failure: nil)
    }

    private func save(_ provider: NSItemProvider, index: Int, to inbox: LedgerSharedImportInbox, note: String?) async throws {
        let suggested = provider.suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferredName = suggested.flatMap { inbox.accepts(name: $0) ? $0 : nil }
        // File URLs are loaded as local URLs; ordinary web URLs are never fetched.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                    do {
                        if let error { throw error }
                        guard let url = value as? URL, url.isFileURL else { throw LedgerSharedImportInbox.InboxError.invalidFile }
                        try inbox.enqueue(fileURL: url, originalName: preferredName, note: note)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
            return
        }
        guard let identifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier), let ext = type.preferredFilenameExtension else { return false }
            return type.conforms(to: .data) && inbox.accepts(name: "file." + ext)
        }), let type = UTType(identifier) else {
            throw inbox.purpose == .agent ? LedgerSharedImportInbox.InboxError.agentUnsupported
                : LedgerSharedImportInbox.InboxError.unsupported
        }
        // A photo or a screenshot often has no extension in its name; the
        // name it is kept under gets the one its type implies.
        let ext = type.preferredFilenameExtension ?? "dat"
        let name = preferredName ?? suggested.flatMap { base -> String? in
            guard !base.isEmpty else { return nil }
            let candidate = (base as NSString).pathExtension.isEmpty ? base + "." + ext : base
            return inbox.accepts(name: candidate) ? candidate : nil
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                    // The provider's temporary URL is valid only inside this callback.
                    do {
                        if let error { throw error }
                        guard let url else { throw LedgerSharedImportInbox.InboxError.invalidFile }
                        try inbox.enqueue(fileURL: url, originalName: name, note: note)
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } catch {
            // A screenshot straight from the markup editor is an image in
            // memory with no file behind it; keep its bytes instead.
            guard type.conforms(to: .image) else { throw error }
            let data = try await imageData(of: provider, identifier: identifier)
            let fallback = name ?? String(localized: "图片\(index + 1)") + "." + ext
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let file = temporary.appendingPathComponent("payload." + ext)
            try data.write(to: file)
            try inbox.enqueue(fileURL: file, originalName: fallback, note: note)
        }
    }

    private func imageData(of provider: NSItemProvider, identifier: String) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { value, error in
                if let data = value as? Data {
                    continuation.resume(returning: data)
                } else if let image = value as? UIImage, let data = image.pngData() {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: error ?? LedgerSharedImportInbox.InboxError.invalidFile)
                }
            }
        }
    }

    /// Photos and screenshots: shared as images, not as files with a name.
    private static func isImage(_ provider: NSItemProvider) -> Bool {
        if let name = provider.suggestedName,
           let type = UTType(filenameExtension: (name as NSString).pathExtension) {
            return type.conforms(to: .image)
        }
        return !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            && provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    /// Asks the system to bring Ledger forward. An extension has no
    /// `UIApplication.shared`, but the application object is on the responder
    /// chain; its open method is called through the runtime because the SDK
    /// marks it unavailable to extensions.
    private func openHostApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    private func showSaved(_ saved: Int, purpose: LedgerSharedImportInbox.Purpose, failure: String?) {
        let title: String
        var lines: [String] = []
        switch purpose {
        case .agent:
            title = saved > 0 ? String(localized: "已发给账本助手") : String(localized: "未能发给账本助手")
            if saved > 0 { lines.append(String(localized: "打开 Ledger，账本助手会在新对话里带上这些文件。")) }
        case .imports:
            title = saved > 0 ? String(localized: "已保存 \(saved) 个账单文件") : String(localized: "未能保存账单")
            if saved > 0 {
                lines.append(String(localized: "请打开 Ledger，在「导入」的待导入收件箱中核对并提交。"))
                lines.append(String(localized: "也可以在账本助手里点 ＋，从待导入收件箱选它来对账。"))
            }
        }
        if let failure { lines.append(failure) }
        showResult(title: title, detail: lines.joined(separator: "\n\n"))
    }

    private func showResult(title: String, detail: String) {
        progress.stopAnimating()
        for control in [noteField, agentButton, importButton, cancelButton] as [UIView] { control.isHidden = true }
        statusLabel.text = title
        detailLabel.text = detail
        doneButton.isHidden = false
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    @objc private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
