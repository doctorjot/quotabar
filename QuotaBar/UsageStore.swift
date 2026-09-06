import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private(set) var results: [ProviderResult]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?

    /// Which window drives the menu bar number. Empty means "whichever is
    /// fullest". Otherwise "<providerID>|<windowLabel>".
    var menuBarSelection: String {
        didSet { UserDefaults.standard.set(menuBarSelection, forKey: Self.selectionKey) }
    }

    private static let selectionKey = "MenuBarSelection"
    private let providers: [any UsageProvider]
    /// Anthropic's usage endpoint throttles aggressively — hour-long
    /// Retry-After windows have been seen after a single call. 15 minutes
    /// keeps the numbers current without provoking it.
    private let refreshInterval: TimeInterval = 900
    private var autoRefreshTask: Task<Void, Never>?

    init(providers: [any UsageProvider]) {
        self.providers = providers
        self.results = providers.map {
            ProviderResult(id: $0.id, displayName: $0.displayName, state: .loading)
        }
        self.menuBarSelection = UserDefaults.standard.string(forKey: Self.selectionKey) ?? ""
        startAutoRefresh()
    }

    /// What the menu bar shows: the chosen window, or the fullest one.
    /// Falls back to the maximum when the chosen window has disappeared.
    var headlinePercent: Double? {
        if let selected = selectedSnapshot() { return selected.percentUsed }
        return results.flatMap { $0.state.snapshots }.map(\.percentUsed).max()
    }

    /// Options for the menu bar picker, rebuilt from whatever data is loaded.
    var menuBarOptions: [MenuBarOption] {
        [MenuBarOption(id: "", title: "Höchster Wert")] + results.flatMap { result in
            result.state.snapshots.map { snapshot in
                MenuBarOption(
                    id: Self.key(providerID: result.id, windowLabel: snapshot.windowLabel),
                    title: "\(result.displayName) · \(snapshot.windowLabel)"
                )
            }
        }
    }

    private func selectedSnapshot() -> UsageSnapshot? {
        guard !menuBarSelection.isEmpty else { return nil }
        for result in results {
            for snapshot in result.state.snapshots
            where Self.key(providerID: result.id, windowLabel: snapshot.windowLabel) == menuBarSelection {
                return snapshot
            }
        }
        return nil
    }

    private static func key(providerID: String, windowLabel: String) -> String {
        "\(providerID)|\(windowLabel)"
    }

    var hasFailure: Bool {
        results.contains { if case .failed = $0.state { return true } else { return false } }
    }

    func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                guard let interval = self?.refreshInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let now = Date()
        // Skip providers we are still locked out of, so a manual tap cannot
        // hammer a throttled endpoint either.
        let due = providers.enumerated().filter { index, _ in
            guard let blocked = results[index].throttledUntil else { return true }
            return blocked <= now
        }
        guard !due.isEmpty else { return }

        let outcomes = await withTaskGroup(of: (Int, ProviderState, Date?).self) { group in
            for (index, provider) in due {
                group.addTask {
                    do {
                        return (index, .ok(try await provider.fetch()), nil)
                    } catch let error as ProviderError {
                        if case .rateLimited(let until) = error {
                            return (index, .failed(error.localizedDescription), until)
                        }
                        return (index, .failed(error.localizedDescription), nil)
                    } catch {
                        return (index, .failed(error.localizedDescription), nil)
                    }
                }
            }
            var collected = [(Int, ProviderState, Date?)]()
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        for (index, state, throttledUntil) in outcomes {
            guard results.indices.contains(index) else { continue }
            results[index].throttledUntil = throttledUntil
            // Being throttled is not a data problem: keep the last good
            // numbers on screen — they grey out by themselves once stale.
            if throttledUntil != nil, case .ok = results[index].state { continue }
            results[index].state = state
        }
        lastRefresh = Date()
    }
}
