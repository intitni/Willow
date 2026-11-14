import CoreStorage
import SwiftUI

struct ThirdPartyLicensesView: View {
    @State private var model = ThirdPartyLicensesModel()

    var body: some View {
        @Bindable var state = model.viewModel
        List(state.entries) { entry in
            NavigationLink {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(entry.version).font(.caption).foregroundStyle(.secondary)
                        Link(L10n.text("Text.LicenseSourceCode"), destination: entry.source)
                        Text(verbatim: entry.text).font(.footnote).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .navigationTitle(entry.name)
            } label: {
                VStack(alignment: .leading) {
                    Text(verbatim: entry.name)
                    Text(verbatim: entry.license).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if state.loading { ProgressView() } }
        .navigationTitle(L10n.text("Text.OpenSourceLicenses"))
        .task { await model.load() }
        .modifier(ErrorAlert(error: $state.error))
    }
}
