import BreezePlugins
import CoreStorage
import SwiftData
import SwiftUI

struct DiscoverCartView: View {
    @Environment(DiscoverCartModel.self) private var cart
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    @Query(filter: #Predicate<PluginRecord> { $0.enabled }) private var plugins: [PluginRecord]

    var body: some View {
        let items = cart.items.filter { !hiddenSources.contains($0.sourceID) }
        let sourceNames = Dictionary(uniqueKeysWithValues: plugins.map { ($0.uuid, $0.name) })
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
                            ComicCover(
                                url: item.comic.coverURL,
                                cachePolicy: .comicCover(id: item.id)
                            )
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
                        Button(L10n.text("Text.Remove"), systemImage: "trash", role: .destructive) {
                            cart.remove(item)
                        }
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
    @ScaledMetric(relativeTo: .caption2) private var badgeDiameter: CGFloat = 20
    let action: () -> Void

    var body: some View {
        let count = cart.items.count { !hiddenSources.contains($0.sourceID) }
        Button(action: action) {
            Image(systemName: "cart")
                .overlay {
                    Text(count, format: .number)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: badgeDiameter)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(height: badgeDiameter)
                        .background(.tint, in: .capsule)
                        .opacity(count > 0 ? 1 : 0)
                        .offset(x: 12, y: -12)
                }
        }
        .accessibilityLabel(L10n.text("DiscoverCart.Title"))
        .accessibilityValue(count > 0 ? count.formatted() : "")
    }
}

struct DiscoverCartToolbar: ViewModifier {
    @Environment(DiscoverCartModel.self) private var cart: DiscoverCartModel?
    @State private var showsCart = false
    var isEnabled = true

    func body(content: Content) -> some View {
        if isEnabled, cart != nil {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        DiscoverCartToolbarButton { showsCart = true }
                    }
                }
                .navigationDestination(isPresented: $showsCart) {
                    DiscoverCartView()
                }
        } else {
            content
        }
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
                    Button(
                        L10n.text("DiscoverCart.Remove"),
                        systemImage: "minus.circle",
                        role: .destructive
                    ) {
                        cart.remove(item)
                    }
                } else {
                    Button(L10n.text("DiscoverCart.Add"), systemImage: "cart.badge.plus") {
                        cart.add(item)
                    }
                }
            }
        }
    }
}

