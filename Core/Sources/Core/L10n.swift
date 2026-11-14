import Foundation

enum L10n {
    static func text(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }

    static func text(_ key: StaticString, defaultValue: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: defaultValue, bundle: .module)
    }

    static func resource(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: .module)
    }

    static func resource(_ key: StaticString, defaultValue: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, defaultValue: defaultValue, bundle: .module)
    }
}
