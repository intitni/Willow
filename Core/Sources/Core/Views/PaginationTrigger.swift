import CoreStorage
import SwiftUI

/// A new footer observes its own position after each batch is laid out.
struct PaginationTrigger: View {
    let itemCount: Int
    let load: () -> Void

    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding()
            .accessibilityLabel(L10n.text("Text.LoadingMore"))
            .onScrollVisibilityChange(threshold: 0.1) { visible in
                if visible { load() }
            }
            .id(itemCount)
    }
}
