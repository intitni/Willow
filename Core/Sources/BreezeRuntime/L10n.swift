import Foundation

enum L10n {
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    static func text(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }
}
