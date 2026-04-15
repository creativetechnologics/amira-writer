import Foundation
import Security

@available(macOS 26.0, *)
struct RunPodCredentialStore: Sendable {
    private let service = "com.amira.writer.animate"
    private let account = "runpod-api-key"

    func loadAPIKey() -> String {
        if let fromEnvironment = ProcessInfo.processInfo.environment["RUNPOD_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromEnvironment.isEmpty {
            return fromEnvironment
        }

        let localFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lora-maker/runpod_api_key")
        if let data = try? Data(contentsOf: localFile),
           let fromFile = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromFile.isEmpty {
            return fromFile
        }

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
        else { return "" }
        return key
    }

    func saveAPIKey(_ apiKey: String) {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        deleteAPIKey()
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
