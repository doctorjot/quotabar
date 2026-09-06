import Foundation

/// One usage window of one provider (e.g. Claude's 5h session window).
struct UsageSnapshot: Sendable, Hashable {
    /// Consumed quota in percent, 0...100 — same direction as the Claude app.
    let percentUsed: Double
    /// When the window rolls over, if known.
    let resetsAt: Date?
    /// Human readable window name, e.g. "Session" or "Woche".
    let windowLabel: String
    /// When the underlying data was measured.
    let capturedAt: Date
    /// Optional secondary line, e.g. Grok's per-product split.
    let detail: String?

    init(
        percentUsed: Double,
        resetsAt: Date?,
        windowLabel: String,
        capturedAt: Date,
        detail: String? = nil
    ) {
        self.percentUsed = min(max(percentUsed, 0), 100)
        self.resetsAt = resetsAt
        self.windowLabel = windowLabel
        self.capturedAt = capturedAt
        self.detail = detail
    }

    /// Data is considered stale after an hour.
    func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(capturedAt) > 3600
    }
}

/// Result of one provider fetch. Errors are carried as text so the whole
/// value stays `Sendable` and a failing provider never takes down the others.
enum ProviderState: Sendable {
    case loading
    case ok([UsageSnapshot])
    case failed(String)

    var snapshots: [UsageSnapshot] {
        if case .ok(let snapshots) = self { return snapshots }
        return []
    }
}

struct ProviderResult: Sendable, Identifiable {
    let id: String
    let displayName: String
    var state: ProviderState
    /// Set while the provider's endpoint is throttling us.
    var throttledUntil: Date?
}
