import Foundation
import Security

/// Credential store for the Gemini API key.
///
/// Storage precedence:
///   1. `<project>/config/api-credentials.json` (via ProjectCredentialStore)
///      — synced between machines by Syncthing.
///   2. macOS Keychain (legacy / fallback when no project is loaded).
///
/// Writes go to BOTH paths so either can be trusted if the other is missing.
@available(macOS 26.0, *)
struct GeminiCredentialStore: Sendable {
    private let service = "com.amira.writer.animate"
    private let account = "gemini-api-key"

    func loadAPIKey() -> String {
        if ProjectCredentialStore.shared.isActive() {
            let fromFile = ProjectCredentialStore.shared.geminiAPIKey()
            if !fromFile.isEmpty { return fromFile }
        }
        return loadFromKeychain()
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if ProjectCredentialStore.shared.isActive() {
            ProjectCredentialStore.shared.setGeminiAPIKey(trimmed)
        }
        saveToKeychain(trimmed)
    }

    func clearAPIKey() {
        if ProjectCredentialStore.shared.isActive() {
            ProjectCredentialStore.shared.setGeminiAPIKey("")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Keychain helpers

    private func loadFromKeychain() -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return key
    }

    private func saveToKeychain(_ trimmed: String) {
        guard !trimmed.isEmpty else {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SecItemDelete(deleteQuery as CFDictionary)
            return
        }

        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertQuery = query
            insertQuery[kSecValueData as String] = data
            SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }
}
