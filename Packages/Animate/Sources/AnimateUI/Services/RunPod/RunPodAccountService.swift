import Foundation

@available(macOS 26.0, *)
struct RunPodAccountService: Sendable {
    struct AccountSummary: Sendable {
        let clientBalance: Double
        let currentSpendPerHr: Double
        let underBalance: Bool
        let minBalance: Double?
    }

    struct GPUPriceSummary: Sendable {
        let displayName: String
        let communityPrice: Double?
        let securePrice: Double?
        let communitySpotPrice: Double?
        let secureSpotPrice: Double?
    }

    enum AccountError: LocalizedError {
        case missingAPIKey
        case unauthorized
        case invalidResponse(String)
        case transport(String)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "RunPod API key not set."
            case .unauthorized:
                return "RunPod rejected this API key (403 Forbidden)."
            case .invalidResponse(let detail):
                return detail
            case .transport(let detail):
                return detail
            }
        }
    }

    func fetchAccountSummary(apiKey: String) async throws -> AccountSummary {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AccountError.missingAPIKey }

        let query = """
        query {
          myself {
            clientBalance
            currentSpendPerHr
            underBalance
            minBalance
          }
        }
        """

        var request = URLRequest(url: URL(string: "https://api.runpod.io/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AccountError.invalidResponse("RunPod returned a non-HTTP response.")
        }
        if http.statusCode == 403 {
            throw AccountError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AccountError.invalidResponse("RunPod account query failed with HTTP \(http.statusCode). \(body)")
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountError.invalidResponse("RunPod returned unreadable JSON.")
        }

        if let errors = payload["errors"] as? [[String: Any]],
           !errors.isEmpty {
            let message = errors.compactMap { $0["message"] as? String }.joined(separator: " | ")
            throw AccountError.invalidResponse(message.isEmpty ? "RunPod returned a GraphQL error." : message)
        }

        guard let dataObject = payload["data"] as? [String: Any],
              let myself = dataObject["myself"] as? [String: Any],
              let clientBalance = myself["clientBalance"] as? Double,
              let currentSpendPerHr = myself["currentSpendPerHr"] as? Double,
              let underBalance = myself["underBalance"] as? Bool else {
            throw AccountError.invalidResponse("RunPod account data was missing expected fields.")
        }

        let minBalance = myself["minBalance"] as? Double
        return AccountSummary(
            clientBalance: clientBalance,
            currentSpendPerHr: currentSpendPerHr,
            underBalance: underBalance,
            minBalance: minBalance
        )
    }

    func fetchGPUPrices(apiKey: String) async throws -> [GPUPriceSummary] {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { throw AccountError.missingAPIKey }

        let query = """
        query {
          gpuTypes {
            displayName
            communityPrice
            securePrice
            communitySpotPrice
            secureSpotPrice
          }
        }
        """

        var request = URLRequest(url: URL(string: "https://api.runpod.io/graphql")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AccountError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AccountError.invalidResponse("RunPod returned a non-HTTP response.")
        }
        if http.statusCode == 403 {
            throw AccountError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AccountError.invalidResponse("RunPod GPU pricing query failed with HTTP \(http.statusCode). \(body)")
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AccountError.invalidResponse("RunPod returned unreadable JSON.")
        }

        if let errors = payload["errors"] as? [[String: Any]],
           !errors.isEmpty {
            let message = errors.compactMap { $0["message"] as? String }.joined(separator: " | ")
            throw AccountError.invalidResponse(message.isEmpty ? "RunPod returned a GraphQL error." : message)
        }

        guard let dataObject = payload["data"] as? [String: Any],
              let gpuTypes = dataObject["gpuTypes"] as? [[String: Any]] else {
            throw AccountError.invalidResponse("RunPod GPU pricing data was missing expected fields.")
        }

        return gpuTypes.compactMap { gpu in
            guard let displayName = gpu["displayName"] as? String, !displayName.isEmpty else { return nil }
            return GPUPriceSummary(
                displayName: displayName,
                communityPrice: gpu["communityPrice"] as? Double,
                securePrice: gpu["securePrice"] as? Double,
                communitySpotPrice: gpu["communitySpotPrice"] as? Double,
                secureSpotPrice: gpu["secureSpotPrice"] as? Double
            )
        }
    }
}
