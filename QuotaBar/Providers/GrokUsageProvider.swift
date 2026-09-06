import Foundation

/// Reads the Grok Build CLI's OIDC credentials from ~/.grok/auth.json and asks
/// the billing endpoint for the shared weekly pool.
///
/// Since June 2026 one weekly pool is spent across Chat, Imagine, Voice, Build
/// and API, so the pool is the headline number and the per-product split is
/// only context.
struct GrokUsageProvider: UsageProvider {
    let id = "grok"
    let displayName = "Grok"

    private static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private static let issuerPrefix = "https://auth.x.ai"
    private static let defaultBackoff: TimeInterval = 15 * 60

    var authFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".grok/auth.json")
    }

    func fetch() async throws -> [UsageSnapshot] {
        let token = try accessToken()

        var request = URLRequest(url: Self.billingURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("build", forHTTPHeaderField: "x-grok-client-mode")
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse }

        if http.statusCode == 429 {
            throw ProviderError.rateLimited(until: http.retryAfterDate(default: Self.defaultBackoff))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw ProviderError.credentialsExpired("`grok` im Terminal starten und neu anmelden")
        }
        guard http.statusCode == 200 else { throw ProviderError.httpStatus(http.statusCode) }

        guard let payload = try? JSONDecoder().decode(BillingResponse.self, from: data) else {
            throw ProviderError.malformedResponse
        }
        guard let snapshot = Self.snapshot(from: payload.config, capturedAt: Date()) else {
            throw ProviderError.noQuotaData
        }
        return [snapshot]
    }

    private func accessToken() throws -> String {
        guard let data = try? Data(contentsOf: authFileURL) else {
            throw ProviderError.noCredentials("~/.grok/auth.json nicht lesbar")
        }
        guard let entries = try? JSONDecoder().decode([String: AuthEntry].self, from: data) else {
            throw ProviderError.malformedResponse
        }
        // The key is "<oidc_issuer>::<client-id>" — match on the issuer field
        // rather than hardcoding the composed key.
        guard let entry = entries.values.first(where: {
            $0.oidcIssuer?.hasPrefix(Self.issuerPrefix) == true
        }) ?? entries.values.first else {
            throw ProviderError.noCredentials("kein x.ai-Eintrag in auth.json")
        }
        if let expiry = DateParsing.iso8601(entry.expires_at), expiry < Date() {
            throw ProviderError.credentialsExpired("`grok` im Terminal starten, das erneuert den Token")
        }
        guard let token = entry.key, !token.isEmpty else {
            throw ProviderError.noCredentials("kein Token in auth.json")
        }
        return token
    }

    static func snapshot(from config: BillingResponse.Config, capturedAt: Date) -> UsageSnapshot? {
        guard let used = config.creditUsagePercent else { return nil }

        let split = (config.productUsage ?? [])
            .compactMap { product -> String? in
                guard let percent = product.usagePercent, percent > 0 else { return nil }
                let name = (product.product ?? "").replacingOccurrences(of: "Grok", with: "")
                guard !name.isEmpty else { return nil }
                return "\(name) \(Int(percent.rounded()))%"
            }
            .joined(separator: " · ")

        return UsageSnapshot(
            percentUsed: used,
            resetsAt: DateParsing.iso8601(config.currentPeriod?.end ?? config.billingPeriodEnd),
            windowLabel: "Woche",
            capturedAt: capturedAt,
            detail: split.isEmpty ? nil : split
        )
    }
}

// MARK: - Wire format

struct BillingResponse: Decodable, Sendable {
    struct Config: Decodable, Sendable {
        struct Period: Decodable, Sendable {
            let start: String?
            let end: String?
        }
        struct Product: Decodable, Sendable {
            let product: String?
            let usagePercent: Double?
        }
        let currentPeriod: Period?
        let creditUsagePercent: Double?
        let productUsage: [Product]?
        let billingPeriodEnd: String?
    }
    let config: Config
}

private struct AuthEntry: Decodable {
    let key: String?
    let refresh_token: String?
    let expires_at: String?
    let oidcIssuer: String?

    enum CodingKeys: String, CodingKey {
        case key, refresh_token, expires_at
        case oidcIssuer = "oidc_issuer"
    }
}
