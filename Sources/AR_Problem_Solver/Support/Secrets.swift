import Foundation

/// Build-time configuration, populated from `Secrets.xcconfig` via Info.plist
/// `$(VAR)` substitution. Runtime overrides (e.g. the Keychain-stored API key)
/// are handled by their own stores — this type only exposes the baked-in values.
enum Secrets {
    /// Anthropic API key from `Secrets.xcconfig`. Empty when not configured at
    /// build time (the expected case when the key is entered in-app instead).
    static var anthropicAPIKey: String {
        value(for: "ANTHROPIC_API_KEY")
    }

    private static func value(for key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unexpanded `$(VAR)` placeholders count as "not set".
        return trimmed.hasPrefix("$(") ? "" : trimmed
    }
}
