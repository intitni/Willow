import CoreToast
import CoreStorage
import SwiftUI
import UIKit

struct RetryView: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "exclamationmark.circle")
        } description: {
            Text(message)
        } actions: {
            Button(L10n.text("Text.Retry"), action: retry).buttonStyle(.glass)
        }
    }
}

struct ErrorAlert: ViewModifier {
    @Binding var error: String?
    @State private var scope = UUID()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) { ToastHost(scope: scope) }
            .task(id: error) {
                guard let message = error else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                Toast.error(message, scope: scope)
                error = nil
            }
    }
}

struct ComicCover: View {
    let url: URL?
    var cachePolicy: ImageCache.Policy = .byURL
    var refreshID = 0

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                CachedImage(url: url, thumbnail: true, cachePolicy: cachePolicy, refreshID: refreshID) { image in
                    GeometryReader { geometry in
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                } placeholder: { error in
                    if let error {
                        VStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text(L10n.text("Cover.TapToRetry")).font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.text("Cover.RetryAccessibilityLabel"))
                        .accessibilityHint(error)
                    } else if url != nil {
                        ProgressView().accessibilityLabel(L10n.text("Cover.Loading"))
                    } else {
                        Image(systemName: "book.closed").foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 12))

    }
}

struct CachedImage<ImageContent: View, Placeholder: View>: View {
    let url: URL?
    var thumbnail = false
    var cachePolicy: ImageCache.Policy = .byURL
    var refreshID = 0
    @ViewBuilder let content: (UIImage) -> ImageContent
    @ViewBuilder let placeholder: (String?) -> Placeholder
    @State private var model = CachedImageModel()
    @State private var attempt = 0
    @State private var isVisible = false

    private struct Request: Hashable {
        let url: URL?
        let cachePolicy: ImageCache.Policy
        let refreshID: Int
        let attempt: Int
        let isVisible: Bool
    }

    var body: some View {
        let image = model.viewModel.image
        let error = model.viewModel.error
        Group {
            if let image {
                content(image)
                    .overlay(alignment: .bottomTrailing) {
                        if let error {
                            Button {
                                attempt += 1
                            } label: {
                                Label(L10n.text("Cover.RetryLoading"), systemImage: "arrow.clockwise")
                                    .labelStyle(.iconOnly)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .accessibilityHint(error)
                            .padding(4)
                        }
                    }
            } else {
                placeholder(error)
                    .onTapGesture {
                        if error != nil { attempt += 1 }
                    }
                    .accessibilityAction(named: Text(L10n.text("Cover.RetryLoading"))) {
                        if error != nil { attempt += 1 }
                    }
            }
        }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: Request(url: url, cachePolicy: cachePolicy, refreshID: refreshID, attempt: attempt, isVisible: isVisible)) {
            guard isVisible else { return }
            await model.load(url: url, policy: cachePolicy, thumbnail: thumbnail)
        }
    }
}

struct CompactActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

enum WillowTheme {
    static let accent = Color("WillowAccent", bundle: .module)
}
