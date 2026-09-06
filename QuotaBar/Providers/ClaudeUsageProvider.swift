import Foundation

/// Reads Claude Code's OAuth token from the Keychain and asks Anthropic's
/// usage endpoint for the current quota windows.
///
/// The token is only read, never refreshed: redeeming the refresh token could
/// rotate it and sign Claude Code itself out.
struct ClaudeUsageProvider: UsageProvider {
    let id = "claude"
    let displayName = "Claude"

    private static let keychainService = "Claude Code-credentials"
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The endpoint has been observed handing out hour-long Retry-After
    /// windows, so back off generously when it does not say how long.
    private static let defaultBackoff: TimeInterval = 30 * 60

    /// Reading the Keychain can prompt, so the token is held in memory until
    /// it expires — one prompt per app launch instead of one per refresh.
    private static let tokenCache = TokenCache()

    func fetch() async throws -> [UsageSnapshot] {
        let token: String
        if let cached = await Self.tokenCache.valid() {
            token = cached
        } else {
            let fresh = try accessToken()
            await Self.tokenCache.store(fresh.token, expiresAt: fresh.expiresAt)
            token = fresh.token
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("QuotaBar", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.malformedResponse }

        if http.statusCode == 429 {
            throw ProviderError.rateLimited(until: http.retryAfterDate(default: Self.defaultBackoff))
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            // Claude Code may have rotated the token — drop ours so the next
            // run reads the Keychain again.
            await Self.tokenCache.clear()
            throw ProviderError.credentialsExpired("in Claude Code neu anmelden")
        }
        guard http.statusCode == 200 else { throw ProviderError.httpStatus(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(UsageResponse.self, from: data) else {
            throw ProviderError.malformedResponse
        }

        let snapshots = Self.snapshots(from: payload, capturedAt: Date())
        guard !snapshots.isEmpty else { throw ProviderError.noQuotaData }
        return snapshots
    }

    private func accessToken() throws -> (token: String, expiresAt: Date?) {
        guard let data = Keychain.genericPassword(service: Self.keychainService) else {
            throw ProviderError.noCredentials("Keychain-Eintrag „\(Self.keychainService)\" nicht lesbar")
        }
        guard let stored = try? JSONDecoder().decode(StoredCredentials.self, from: data) else {
            throw ProviderError.malformedResponse
        }
        let oauth = stored.claudeAiOauth
        let expiry = oauth.expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
        if let expiry, expiry < Date() {
            throw ProviderError.credentialsExpired("in Claude Code neu anmelden")
        }
        let token = oauth.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ProviderError.noCredentials("Token im Keychain ist leer")
        }
        return (token, expiry)
    }

    /// Prefers the generic `limits` array — model-scoped quotas appear only
    /// there — and falls back to the older dedicated fields.
    static func snapshots(from payload: UsageResponse, capturedAt: Date) -> [UsageSnapshot] {
        if let limits = payload.limits, !limits.isEmpty {
            let mapped = limits.compactMap { entry -> UsageSnapshot? in
                guard let percentUsed = entry.percent else { return nil }
                return UsageSnapshot(
                    percentUsed: percentUsed,
                    resetsAt: DateParsing.iso8601(entry.resetsAt),
                    windowLabel: label(for: entry),
                    capturedAt: capturedAt
                )
            }
            if !mapped.isEmpty { return mapped }
        }

        return [
            (payload.fiveHour, "Session"),
            (payload.sevenDay, "Woche"),
            (payload.sevenDayOpus, "Woche Opus"),
            (payload.sevenDaySonnet, "Woche Sonnet")
        ].compactMap { quota, label in
            guard let utilization = quota?.utilization else { return nil }
            return UsageSnapshot(
                percentUsed: utilization,
                resetsAt: DateParsing.iso8601(quota?.resetsAt),
                windowLabel: label,
                capturedAt: capturedAt
            )
        }
    }

    private static func label(for entry: UsageResponse.LimitEntry) -> String {
        switch entry.kind {
        case "session": "Session"
        case "weekly_all": "Woche"
        case "weekly_scoped":
            if let model = entry.scope?.model?.displayName { "Woche \(model)" } else { "Woche (Modell)" }
        default: entry.kind ?? "Kontingent"
        }
    }
}

/// Holds the access token for the lifetime of the process.
private actor TokenCache {
    private var token: String?
    private var expiresAt: Date?

    func valid() -> String? {
        guard let token else { return nil }
        // Retire it a minute early so a request cannot start on a token that
        // expires mid-flight.
        if let expiresAt, expiresAt.addingTimeInterval(-60) < Date() { return nil }
        return token
    }

    func store(_ token: String, expiresAt: Date?) {
        self.token = token
        self.expiresAt = expiresAt
    }

    func clear() {
        token = nil
        expiresAt = nil
    }
}

// MARK: - Wire format

struct UsageResponse: Decodable, Sendable {
    struct Quota: Decodable, Sendable {
        let utilization: Double?
        let resetsAt: String?
    }

    struct LimitEntry: Decodable, Sendable {
        struct Scope: Decodable, Sendable {
            struct Model: Decodable, Sendable { let displayName: String? }
            let model: Model?
        }
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: Scope?
    }

    let fiveHour: Quota?
    let sevenDay: Quota?
    let sevenDayOpus: Quota?
    let sevenDaySonnet: Quota?
    let limits: [LimitEntry]?
}

private struct StoredCredentials: Decodable {
    struct OAuth: Decodable {
        let accessToken: String
        let expiresAt: Double?
    }
    let claudeAiOauth: OAuth
}
