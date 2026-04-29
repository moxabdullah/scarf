import Foundation

/// Pre-flight check used before opening an ACP session. Hermes resolves the
/// model+provider from `config.yaml` at session boot; on a fresh install that
/// file is missing or has neither key set, and the chat fails with an opaque
/// "Model parameter is required" 400 from the upstream provider only after the
/// user has typed a prompt and hit send. Catching the missing config here lets
/// the UI surface a real "pick a model" sheet before any ACP work starts.
///
/// `HermesConfig.empty` (returned on read failure) and the YAML parser's
/// missing-key fallback both use the literal string `"unknown"`, so the check
/// has to treat `""` and `"unknown"` as equivalent. Anything else is
/// considered configured — we don't try to validate the model against the
/// provider's catalog here; that happens later in `ModelPickerSheet`.
public enum ModelPreflight: Sendable {
    public enum Result: Equatable, Sendable {
        case configured
        case missingModel
        case missingProvider
        case missingBoth

        public var isConfigured: Bool {
            self == .configured
        }

        /// Short user-facing reason. Long enough to be honest, short enough
        /// for a sheet header — full messaging belongs to the picker UI.
        public var reason: String {
            switch self {
            case .configured:     return ""
            case .missingModel:   return "No primary model is set in this server's config."
            case .missingProvider:return "No primary provider is set in this server's config."
            case .missingBoth:    return "No model is configured on this server yet."
            }
        }
    }

    /// Treat `""` and the YAML parser's `"unknown"` fallback as missing.
    /// Trim whitespace so a stray newline in a hand-edited config.yaml
    /// doesn't read as "configured."
    public static func check(_ config: HermesConfig) -> Result {
        let modelMissing = isUnset(config.model)
        let providerMissing = isUnset(config.provider)
        switch (modelMissing, providerMissing) {
        case (true, true):   return .missingBoth
        case (true, false):  return .missingModel
        case (false, true):  return .missingProvider
        case (false, false): return .configured
        }
    }

    private static func isUnset(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.isEmpty || trimmed == "unknown"
    }
}
