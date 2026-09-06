import Foundation

enum DateParsing {
    /// Both APIs send microsecond precision ("…:00.329123+00:00"), which
    /// ISO8601DateFormatter rejects when it expects milliseconds. Trim the
    /// fractional part and parse without it.
    static func iso8601(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        // Strip ".123456" between the seconds and the zone offset.
        let stripped = string.replacingOccurrences(
            of: #"\.\d+"#,
            with: "",
            options: .regularExpression
        )
        return plain.date(from: stripped)
    }
}
