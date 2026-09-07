import Foundation

/// Claude Code's OAuth credentials, and the two places they live.
///
/// Reading Claude Code's own Keychain item prompts every time — it does not
/// accept QuotaBar into its access list, not even via "Always Allow". So the
/// full payload is mirrored into an item we own, which reads back silently.
///
/// The refresh token rotates on every use. Anything we mint therefore has to
/// go back into Claude Code's item as well, or its copy goes stale and the CLI
/// is logged out. The whole JSON is carried around as a dictionary rather than
/// a typed struct so that fields we do not know about — `scopes`,
/// `subscriptionType`, `rateLimitTier` — survive the round trip.
actor ClaudeCredentialStore {
    struct Credentials: Sendable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        /// The complete JSON as read, kept verbatim so writing back cannot
        /// drop fields. Held as Data because [String: Any] is not Sendable.
        var rawJSON: Data

        var isExpired: Bool {
            guard let expiresAt else { return false }
            // A minute of headroom so a request cannot start on a token that
            // dies mid-flight.
            return expiresAt.addingTimeInterval(-60) < Date()
        }
    }

    static let claudeService = "Claude Code-credentials"
    static let mirrorService = "de.whiteroom.QuotaBar.claude-mirror"

    private var cached: Credentials?

    /// Prefers our mirror, falls back to Claude Code's item (which prompts).
    /// A spent mirror is discarded rather than handed out: Claude Code renews
    /// its own token, so its item is the one carrying a usable one.
    func load() throws -> Credentials {
        if let cached, !cached.isExpired { return cached }

        if let data = Keychain.genericPassword(service: Self.mirrorService),
           let credentials = Self.decode(data), !credentials.isExpired {
            cached = credentials
            return credentials
        }

        guard let data = Keychain.genericPassword(service: Self.claudeService) else {
            throw ProviderError.noCredentials("Keychain-Eintrag „\(Self.claudeService)\" nicht lesbar")
        }
        guard let credentials = Self.decode(data) else { throw ProviderError.malformedResponse }
        mirror(credentials)
        cached = credentials
        return credentials
    }

    /// Stores refreshed credentials in both places. Claude Code's item is
    /// updated in place so its access control survives.
    func store(_ credentials: Credentials) {
        cached = credentials
        mirror(credentials)
        Keychain.updateGenericPassword(service: Self.claudeService, data: credentials.rawJSON)
    }

    /// Drops both copies. The mirror has to go too, otherwise the next load
    /// would hand out the same rejected token again.
    func clear() {
        cached = nil
        Keychain.deleteOwnPassword(service: Self.mirrorService)
    }

    private func mirror(_ credentials: Credentials) {
        Keychain.setOwnPassword(service: Self.mirrorService, data: credentials.rawJSON)
    }

    private static func decode(_ data: Data) -> Credentials? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let accessToken = (oauth["accessToken"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !accessToken.isEmpty
        else { return nil }

        return Credentials(
            accessToken: accessToken,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            rawJSON: data
        )
    }

    /// Applies a refresh response onto the existing JSON, touching only the
    /// three fields the server actually replaced.
    static func applying(
        accessToken: String,
        refreshToken: String?,
        expiresIn: Int?,
        to credentials: Credentials
    ) -> Credentials {
        var updated = credentials
        guard var root = try? JSONSerialization.jsonObject(with: credentials.rawJSON) as? [String: Any]
        else { return credentials }
        var oauth = root["claudeAiOauth"] as? [String: Any] ?? [:]

        oauth["accessToken"] = accessToken
        updated.accessToken = accessToken

        if let refreshToken {
            oauth["refreshToken"] = refreshToken
            updated.refreshToken = refreshToken
        }
        if let expiresIn {
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))
            oauth["expiresAt"] = expiry.timeIntervalSince1970 * 1000
            updated.expiresAt = expiry
        }

        root["claudeAiOauth"] = oauth
        guard let encoded = try? JSONSerialization.data(withJSONObject: root) else { return credentials }
        updated.rawJSON = encoded
        return updated
    }
}
