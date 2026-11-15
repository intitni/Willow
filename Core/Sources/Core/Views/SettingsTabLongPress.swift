import SwiftUI
import UIKit

struct SettingsTabLongPress: UIViewRepresentable {
    let title: String
    let action: () -> Void

    func makeUIView(context: Context) -> GestureHost {
        GestureHost()
    }

    func updateUIView(_ view: GestureHost, context: Context) {
        view.title = title
        view.action = action
    }

    static func dismantleUIView(_ view: GestureHost, coordinator: ()) {
        view.detach()
    }

    final class GestureHost: UIView, UIGestureRecognizerDelegate {
        var title = ""
        var action: (() -> Void)?
        private weak var attachedWindow: UIWindow?
        private lazy var longPress: UILongPressGestureRecognizer = {
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(pressed))
            gesture.delegate = self
            return gesture
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            detach()
            window?.addGestureRecognizer(longPress)
            attachedWindow = window
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(longPress)
            attachedWindow = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var view = touch.view
            var matchesSettings = false
            while let current = view {
                if current is UITabBar || current.accessibilityTraits.contains(.tabBar) { return matchesSettings }
                if current.accessibilityLabel == title || current.accessibilityUserInputLabels?.contains(title) == true {
                    matchesSettings = true
                }
                view = current.superview
            }
            return false
        }

        @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { action?() }
        }
    }
}
