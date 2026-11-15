import SwiftUI
import UIKit

struct SettingsTabLongPress: UIViewRepresentable {
    static let tabIdentifier = "willow.settings-tab"

    let title: String
    let tabTitles: Set<String>
    let action: () -> Void

    func makeUIView(context: Context) -> GestureHost {
        GestureHost()
    }

    func updateUIView(_ view: GestureHost, context: Context) {
        view.title = title
        view.tabTitles = tabTitles
        view.action = action
    }

    static func dismantleUIView(_ view: GestureHost, coordinator: ()) {
        view.detach()
    }

    final class GestureHost: UIView, UIGestureRecognizerDelegate {
        var title = ""
        var tabTitles: Set<String> = []
        var action: (() -> Void)?
        private weak var attachedWindow: UIWindow?
        private weak var touchedTabView: UIView?
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
            touchedTabView = nil
            var view = touch.view
            var matchesSettings = false
            var control: UIControl?
            while let current = view {
                if current.accessibilityIdentifier == SettingsTabLongPress.tabIdentifier {
                    touchedTabView = current
                    return true
                }
                if current is UITabBar || current.accessibilityTraits.contains(.tabBar) {
                    if matchesSettings { touchedTabView = touch.view }
                    return matchesSettings
                }
                if current.accessibilityLabel == title || current.accessibilityUserInputLabels?.contains(title) == true {
                    matchesSettings = true
                }
                if control == nil { control = current as? UIControl }
                view = current.superview
            }
            // The expanded, icon-only tab strip keeps its titles in labels inside each control.
            guard let control, let container = control.superview, control.containsTabTitle(title) else { return false }
            let peerTitles = Set(container.subviews.compactMap { ($0 as? UIControl)?.tabTitle(in: tabTitles) })
            guard peerTitles == tabTitles else { return false }
            touchedTabView = control
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The native tab bar recognizes its own continuous selection and long press gestures.
            guard let touchedTabView, let gestureView = otherGestureRecognizer.view else { return false }
            return touchedTabView.isDescendant(of: gestureView)
        }

        @objc private func pressed(_ gesture: UILongPressGestureRecognizer) {
            if gesture.state == .began { action?() }
        }
    }
}

private extension UIView {
    func containsTabTitle(_ title: String) -> Bool {
        tabTitle(in: [title]) != nil
    }

    func tabTitle(in titles: Set<String>) -> String? {
        if let title = (self as? UILabel)?.text, titles.contains(title) { return title }
        for child in subviews {
            if let title = child.tabTitle(in: titles) { return title }
        }
        return nil
    }
}
