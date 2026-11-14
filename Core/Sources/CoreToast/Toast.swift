import Foundation
import Observation
import SwiftUI

public enum ToastStyle: Sendable {
    case info
    case warning
    case error

    fileprivate var systemImage: String {
        switch self {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    fileprivate var tint: Color {
        switch self {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

public struct ToastItem: Identifiable, Sendable {
    public let id: UUID
    public let message: String
    public let style: ToastStyle
    public let duration: TimeInterval?

    fileprivate init(
        id: UUID = UUID(),
        message: String,
        style: ToastStyle,
        duration: TimeInterval?
    ) {
        self.id = id
        self.message = message
        self.style = style
        self.duration = duration
    }
}

/// A synchronous, thread-safe entry point for showing transient messages.
///
/// Passing `nil` for `duration` keeps a toast visible until `hide(_:)` is called.
public enum Toast {
    public typealias ID = UUID

    @discardableResult
    public static func info(_ message: String, duration: TimeInterval? = 3, scope: UUID? = nil) -> ID {
        show(message, style: .info, duration: duration, scope: scope)
    }

    @discardableResult
    public static func warning(_ message: String, duration: TimeInterval? = 4, scope: UUID? = nil) -> ID {
        show(message, style: .warning, duration: duration, scope: scope)
    }

    @discardableResult
    public static func error(_ message: String, duration: TimeInterval? = 5, scope: UUID? = nil) -> ID {
        show(message, style: .error, duration: duration, scope: scope)
    }

    public static func hide(_ id: ID) {
        NotificationCenter.default.post(
            name: .toastEvent,
            object: ToastEvent.dismiss(id)
        )
    }

    private static func show(
        _ message: String,
        style: ToastStyle,
        duration: TimeInterval?,
        scope: UUID?
    ) -> ID {
        let toast = ToastItem(message: message, style: style, duration: duration)
        NotificationCenter.default.post(
            name: .toastEvent,
            object: ToastEvent.present(toast, scope: scope)
        )
        return toast.id
    }
}

@MainActor @Observable
final class ToastViewModel {
    fileprivate(set) var toasts: [ToastItem] = []
}

@MainActor
final class ToastCenter {
    let viewModel = ToastViewModel()
    private let scope: UUID?

    init(scope: UUID? = nil) {
        self.scope = scope
    }

    private var expirationTasks: [Toast.ID: Task<Void, Never>] = [:]
    private var observer: ToastObservation?
    private var observationID: UUID?

    func startObserving() {
        guard observer == nil else { return }
        let observationID = UUID()
        self.observationID = observationID
        let token = NotificationCenter.default.addObserver(
            forName: .toastEvent,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.object as? ToastEvent else { return }
            Task { @MainActor [weak self] in
                guard let self, self.observationID == observationID else { return }
                self.handle(event)
            }
        }
        observer = ToastObservation(token: token)
    }

    deinit {
        if let observer {
            observer.cancel()
        }
    }

    func stopObserving() {
        observationID = nil
        observer?.cancel()
        observer = nil
        for task in expirationTasks.values { task.cancel() }
        expirationTasks.removeAll()
        viewModel.toasts.removeAll()
    }

    func hide(_ id: Toast.ID) {
        expirationTasks.removeValue(forKey: id)?.cancel()
        viewModel.toasts.removeAll { $0.id == id }
    }

    private func handle(_ event: ToastEvent) {
        switch event {
        case let .present(toast, scope):
            guard scope == self.scope else { return }
            present(toast)
        case let .dismiss(id):
            hide(id)
        }
    }

    private func present(_ toast: ToastItem) {
        while viewModel.toasts.count >= 3, let oldestToast = viewModel.toasts.first {
            hide(oldestToast.id)
        }

        viewModel.toasts.append(toast)

        guard let duration = toast.duration, duration > 0 else { return }
        expirationTasks[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.hide(toast.id)
        }
    }
}

public struct ToastHost: View {
    @State private var center: ToastCenter

    /// 仅显示相同 scope 的提示；默认接收全局提示，sheet 可使用独立的 UUID。
    public init(scope: UUID? = nil) {
        _center = State(initialValue: ToastCenter(scope: scope))
    }

    public var body: some View {
        VStack(spacing: 10) {
            ForEach(center.viewModel.toasts) { toast in
                ToastRow(toast: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(.snappy(duration: 0.28), value: center.viewModel.toasts.map(\.id))
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .onAppear { center.startObserving() }
        .onDisappear { center.stopObserving() }
    }
}

private struct ToastRow: View {
    let toast: ToastItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: toast.style.systemImage)
                .font(.body.weight(.semibold))
                .padding(.top, 1)

            Text(verbatim: toast.message)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassEffect(
            .regular.tint(toast.style.tint),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .shadow(color: .black.opacity(0.16), radius: 14, y: 7)
        .accessibilityLabel(Text(toast.message))
    }
}

private enum ToastEvent {
    case present(ToastItem, scope: UUID?)
    case dismiss(Toast.ID)
}

private final class ToastObservation: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func cancel() {
        NotificationCenter.default.removeObserver(token)
    }
}

private extension Notification.Name {
    static let toastEvent = Notification.Name("com.intii.Willow.toastEvent")
}
