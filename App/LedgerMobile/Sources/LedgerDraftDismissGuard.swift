import SwiftUI
import UIKit

extension View {
    func ledgerDraftDismissGuard(isDisabled: Bool, onAttempt: @escaping () -> Void) -> some View {
        background(LedgerDraftDismissObserver(isDisabled: isDisabled, onAttempt: onAttempt))
            // Keep draft protection owned by SwiftUI even when it replaces its presentation delegate.
            .interactiveDismissDisabled(isDisabled)
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
        controller.stopObserving()
    }

    final class ObserverController: UIViewController, UIAdaptivePresentationControllerDelegate {
        var isDismissDisabled = false
        var onAttempt: () -> Void = {}
        private weak var observedPresentation: UIPresentationController?
        private weak var previousDelegate: (any UIAdaptivePresentationControllerDelegate)?
        private weak var observedTransition: (any UIViewControllerTransitionCoordinator)?
        private var isObserving = true

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            installDelegate()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            installDelegate()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installDelegate()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            installDelegate()
        }

        func installDelegate() {
            guard isObserving else { return }
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
                    observeTransition(of: controller)
                    return
                }
                candidate = controller.parent
            }
        }

        private func observeTransition(of sheet: UIViewController) {
            // Alerts and nested sheets can replace SwiftUI's delegate during their transitions.
            // Reattach after that transition finishes rather than relying on a draft value change.
            let transition = sheet.presentedViewController?.transitionCoordinator ?? sheet.transitionCoordinator
            guard let transition, observedTransition !== transition else { return }
            observedTransition = transition
            transition.animate(alongsideTransition: nil) { [weak self] _ in
                self?.installDelegate()
            }
        }

        func stopObserving() {
            isObserving = false
            observedTransition = nil
            restoreDelegate()
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
