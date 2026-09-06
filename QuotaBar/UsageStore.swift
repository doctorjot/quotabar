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
    private static let snapshotsKey = "LastSnapshots"
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

        // Show the last known numbers immediately. They grey out on their own
        // once stale, which beats an empty popover while the first fetch runs
        // — or while a rate-limit window blocks it entirely.
        let cached = Self.loadCachedSnapshots()
        for index in results.indices {
            if let snapshots = cached[results[index].id], !snapshots.isEmpty {
                results[index].state = .ok(snapshots)
            }
        }

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
        var options = [MenuBarOption(id: "", title: "Höchster Wert")]
        options += results.flatMap { result in
            result.state.snapshots.map { snapshot in
                MenuBarOption(
                    id: Self.key(providerID: result.id, windowLabel: snapshot.windowLabel),
                    title: "\(result.displayName) · \(snapshot.windowLabel)"
                )
            }
        }
        // A window the user picked may be missing right now — a failing
        // provider, a limit that vanished. Keep offering it, otherwise the
        // picker has no row matching the selection and renders blank.
        if !menuBarSelection.isEmpty,
           !options.contains(where: { $0.id == menuBarSelection }) {
            options.append(MenuBarOption(id: menuBarSelection, title: title(forKey: menuBarSelection)))
        }
        return options
    }

    private func title(forKey key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { return key }
        let name = results.first { $0.id == parts[0] }?.displayName ?? String(parts[0])
        return "\(name) · \(parts[1])"
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
        persistSnapshots()
    }

    private func persistSnapshots() {
        var payload = [String: [UsageSnapshot]]()
        for result in results where !result.state.snapshots.isEmpty {
            payload[result.id] = result.state.snapshots
        }
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.snapshotsKey)
    }

    private static func loadCachedSnapshots() -> [String: [UsageSnapshot]] {
        guard let data = UserDefaults.standard.data(forKey: snapshotsKey),
              let decoded = try? JSONDecoder().decode([String: [UsageSnapshot]].self, from: data)
        else { return [:] }
        return decoded
    }
}
