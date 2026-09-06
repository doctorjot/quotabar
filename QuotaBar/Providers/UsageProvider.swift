import Foundation

/// A source of subscription quota information.
/// One provider may report several windows (Claude: session + week).
protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    func fetch() async throws -> [UsageSnapshot]
}
