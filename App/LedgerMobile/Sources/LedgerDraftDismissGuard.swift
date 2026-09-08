import SwiftUI
import UIKit

extension View {
    func ledgerDraftDismissGuard(isDisabled: Bool, onAttempt: @escaping () -> Void) -> some View {
        background(LedgerDraftDismissObserver(isDisabled: isDisabled, onAttempt: onAttempt))
    }
}

private struct LedgerDraftDismissObserver: UIViewControllerRepresentable {
    let isDisabled: Bool
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> ObserverController {
        ObserverController()
    }

    func updateUIViewController(_ controller: ObserverController, context: Context) {
        controller.isDismissDisabled = isDisabled
        controller.onAttempt = onAttempt
        controller.installDelegate()
        // The representable can update before SwiftUI attaches it to its sheet host.
        DispatchQueue.main.async { [weak controller] in controller?.installDelegate() }
    }

    static func dismantleUIViewController(_ controller: ObserverController, coordinator: ()) {
        controller.restoreDelegate()
    }

    final class ObserverController: UIViewController, UIAdaptivePresentationControllerDelegate {
        var isDismissDisabled = false
        var onAttempt: () -> Void = {}
        private weak var observedPresentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installDelegate()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installDelegate()
        }

        func installDelegate() {
            var candidate: UIViewController? = self
            while let controller = candidate {
                if controller.presentingViewController != nil, let presentation = controller.presentationController {
                    if observedPresentation !== presentation {
                        restoreDelegate()
                        observedPresentation = presentation
                    }
                    if presentation.delegate !== self {
                        previousDelegate = presentation.delegate
                        presentation.delegate = self
                    }
                    return
                }
                candidate = controller.parent
            }
        }

        func restoreDelegate() {
            if observedPresentation?.delegate === self {
                observedPresentation?.delegate = previousDelegate
            }
            observedPresentation = nil
            previousDelegate = nil
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !isDismissDisabled && (previousDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true)
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            if isDismissDisabled { onAttempt() }
            previousDelegate?.presentationControllerDidAttemptToDismiss?(presentationController)
        }

        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerWillDismiss?(presentationController)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            previousDelegate?.presentationControllerDidDismiss?(presentationController)
        }
    }
}
