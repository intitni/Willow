import BreezePlugins
import CoreStorage
import SwiftData
import SwiftUI

extension FollowedComicRecord {
    var comicSummary: ComicSummary {
        ComicSummary(id: comicID, title: title, coverURL: URL(string: coverURL), author: author, summary: summary)
    }
}

struct FollowedComicsView: View {
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    @Environment(SyncSettingsModel.self) private var sync
    @Query(filter: #Predicate<FollowedComicRecord> { $0.isFollowing }, sort: \FollowedComicRecord.title)
    private var records: [FollowedComicRecord]
    private let showsCovers: Bool

    init(showsCovers: Bool = true) {
        self.showsCovers = showsCovers
    }

    var body: some View {
        let visible = records.filter { !hiddenSources.contains($0.sourceID) }
        Group {
            if showsCovers {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 192), spacing: 14)], spacing: 18) {
                        ForEach(visible, id: \.id) { record in
                            NavigationLink {
                                ComicDetailView(sourceID: record.sourceID, summary: record.comicSummary)
                            } label: {
                                DiscoverComicTile(comic: record.comicSummary, sourceID: record.sourceID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                }
            } else {
                List(visible, id: \.id) { record in
                    NavigationLink {
                        ComicDetailView(sourceID: record.sourceID, summary: record.comicSummary)
                    } label: {
                        HStack {
                            Text(record.title)
                            if record.hasUnreadUpdate { UnreadComicUpdateDot() }
                        }
                    }
                }
            }
        }
        .overlay {
            if visible.isEmpty {
                ContentUnavailableView(L10n.text("Following.EmptyTitle"), systemImage: "bell",
                                       description: Text(L10n.text("Following.EmptyDescription")))
            }
        }
        .navigationTitle(L10n.text("Following.Title"))
        .refreshable { await sync.reconcile() }
    }
}

struct UnreadComicUpdateDot: View {
    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 9, height: 9)
            .accessibilityLabel(L10n.text("Following.UnreadUpdate"))
    }
}
