import BreezePlugins
import SwiftUI

struct DiscoverCartView: View {
    @Environment(DiscoverCartModel.self) private var cart
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    let sourceNames: [String: String]

    var body: some View {
        let items = cart.items.filter { !hiddenSources.contains($0.sourceID) }
        Group {
            if items.isEmpty {
                ContentUnavailableView(
                    L10n.text("DiscoverCart.EmptyTitle"),
                    systemImage: "cart",
                    description: Text(L10n.text("DiscoverCart.EmptyDescription"))
                )
            } else {
                List(items) { item in
                    NavigationLink {
                        ComicDetailView(sourceID: item.sourceID, summary: item.comic)
                    } label: {
                        HStack(spacing: 12) {
                            ComicCover(url: item.comic.coverURL, cachePolicy: .comicCover(id: item.id))
                                .frame(width: 48)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.comic.title)
                                if let source = sourceNames[item.sourceID] {
                                    Text(source).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .swipeActions {
                        Button(L10n.text("Text.Remove"), systemImage: "trash", role: .destructive) { cart.remove(item) }
                    }
                    .modifier(DiscoverCartContextMenu(comic: item.comic, sourceID: item.sourceID))
                }
            }
        }
        .navigationTitle(L10n.text("DiscoverCart.Title"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.text("DiscoverCart.ClearAll"), role: .destructive, action: cart.clear)
                    .disabled(items.isEmpty)
            }
        }
    }
}

struct DiscoverCartToolbarButton: View {
    @Environment(DiscoverCartModel.self) private var cart
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    let action: () -> Void

    var body: some View {
        let count = cart.items.count { !hiddenSources.contains($0.sourceID) }
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: "cart")
                if count > 0 {
                    Text(count, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(L10n.text("DiscoverCart.Title"))
        .accessibilityValue(count > 0 ? count.formatted() : "")
    }
}

struct DiscoverCartContextMenu: ViewModifier {
    @Environment(DiscoverCartModel.self) private var cart: DiscoverCartModel?
    let comic: ComicSummary?
    let sourceID: String

    func body(content: Content) -> some View {
        content.contextMenu {
            if let cart, let comic {
                let item = DiscoverCartItem(sourceID: sourceID, comic: comic)
                if cart.contains(item) {
                    Button(L10n.text("DiscoverCart.Remove"), systemImage: "minus.circle", role: .destructive) {
                        cart.remove(item)
                    }
                } else {
                    Button(L10n.text("DiscoverCart.Add"), systemImage: "cart.badge.plus") { cart.add(item) }
                }
            }
        }
    }
}
