package enum PluginIdentity {
    // Breeze identities are opaque strings, including IDs that are not RFC UUIDs.
    // They also become local filenames, so accept only a bounded safe alphabet.
    package static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}
