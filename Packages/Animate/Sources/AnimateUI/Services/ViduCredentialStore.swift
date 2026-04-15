import Foundation
import Security

/// Vidu API key — reads from project-local JSON first, Keychain as fallback.
/// Writes to both. See ProjectCredentialStore.
@available(macOS 26.0, *)
struct ViduCredentialStore: Sendable {
    private let service = "com.amira.writer.animate"
    private let account = "vidu-api-key"

    func loadAPIKey() -> String {
        if ProjectCredentialStore.shared.isActive() {
            let fromFile = ProjectCredentialStore.shared.viduAPIKey()
            if !fromFile.isEmpty { return fromFile }
        }
        return loadFromKeychain()
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if ProjectCredentialStore.shared.isActive() {
            ProjectCredentialStore.shared.setViduAPIKey(trimmed)
        }
        deleteFromKeychain()
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    func deleteAPIKey() {
        if ProjectCredentialStore.shared.isActive() {
            ProjectCredentialStore.shared.setViduAPIKey("")
        }
        deleteFromKeychain()
    }

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
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else { return "" }
        return key
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
