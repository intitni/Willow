import Observation

@MainActor @Observable
package final class PluginNoticeViewModel {
    package var message: String?
}

@MainActor
package final class PluginNoticeModel {
    package static let shared = PluginNoticeModel()
    package let viewModel = PluginNoticeViewModel()
    package func receive(_ notices: [JSONValue]) {
        let messages = notices.map { $0["message"].string }.filter { !$0.isEmpty }
        if !messages.isEmpty { viewModel.message = messages.joined(separator: "\n") }
    }
}
