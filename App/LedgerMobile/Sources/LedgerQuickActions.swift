#if os(iOS)
import SwiftUI
import UIKit

/// The menu on a long press of the app icon. Its items are the same
/// `ledger://` links as the 快捷入口 widget, handed to the session like any
/// other deep link, so a protected ledger still unlocks first.
@MainActor
final class LedgerQuickActionCenter: ObservableObject {
    static let shared = LedgerQuickActionCenter()

    /// Four items is what the icon menu shows above the system ones.
    static let menu: [LedgerQuickLink] = [.agent, .capture, .record, .search]

    /// A link from the icon menu that the app has not opened yet.
    @Published var pending: URL?

    /// Dynamic rather than Info.plist items, so the titles follow the app's
    /// language from `String(localized:)`.
    func installShortcutItems() {
        UIApplication.shared.shortcutItems = Self.menu.map { link in
            UIApplicationShortcutItem(
                type: link.shortcutType,
                localizedTitle: link.title,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: link.systemImage),
                userInfo: nil
            )
        }
    }

    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let link = LedgerQuickLink(shortcutType: item.type) else { return false }
        pending = link.url
        return true
    }
}

/// Receives the icon menu's item: at launch in the connection options, and
/// while running through `performActionFor`. SwiftUI keeps its own window
/// management; this delegate only adds these two callbacks.
@MainActor
final class LedgerSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            LedgerQuickActionCenter.shared.handle(item)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(LedgerQuickActionCenter.shared.handle(shortcutItem))
    }
}

extension LedgerBackgroundAppDelegate {
    @MainActor
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = LedgerSceneDelegate.self
        return configuration
    }
}

/// The camera for 拍票据. Falls back to nothing on devices without one; the
/// caller checks `isAvailable` and offers the photo library instead.
struct LedgerCameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: LedgerCameraPicker
        init(_ parent: LedgerCameraPicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
