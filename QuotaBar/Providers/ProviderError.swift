import Foundation

enum ProviderError: LocalizedError, Sendable {
    case noCredentials(String)
    case credentialsExpired(String)
    case rateLimited(until: Date)
    case httpStatus(Int)
    case malformedResponse
    case noQuotaData

    var errorDescription: String? {
        switch self {
        case .noCredentials(let hint):
            "Keine Anmeldung gefunden — \(hint)"
        case .credentialsExpired(let hint):
            "Zugang abgelaufen — \(hint)"
        case .rateLimited(let until):
            "Gedrosselt bis \(Self.timeFormatter.string(from: until))"
        case .httpStatus(let code):
            "Server antwortete mit HTTP \(code)"
        case .malformedResponse:
            "Antwort nicht lesbar — Format hat sich vermutlich geändert"
        case .noQuotaData:
            "Keine Kontingentdaten in der Antwort"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

extension HTTPURLResponse {
    /// `Retry-After` is either seconds or an HTTP date. Falls back to the
    /// caller's default when absent or unparseable.
    func retryAfterDate(default fallback: TimeInterval) -> Date {
        guard let raw = value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces), !raw.isEmpty
        else { return Date().addingTimeInterval(fallback) }

        if let seconds = TimeInterval(raw) { return Date().addingTimeInterval(seconds) }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) { return date }

        return Date().addingTimeInterval(fallback)
    }
}
