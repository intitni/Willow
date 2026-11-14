import Foundation

enum L10n {
    static let bundle = Bundle.module

    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: bundle)
    }
}
