import CoreStorage
import Observation

@MainActor @Observable
final class ThirdPartyLicensesViewModel {
    fileprivate(set) var entries: [ThirdPartyLicense] = []
    fileprivate(set) var loading = true
    var error: String?
}

@MainActor
final class ThirdPartyLicensesModel {
    let viewModel = ThirdPartyLicensesViewModel()
    private let catalog = ThirdPartyLicenseCatalog()

    func load() async {
        defer { viewModel.loading = false }
        do { viewModel.entries = try await catalog.load() }
        catch { viewModel.error = error.localizedDescription }
    }
}
