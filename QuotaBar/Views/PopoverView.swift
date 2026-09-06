import SwiftUI

struct PopoverView: View {
    let store: UsageStore
    /// Ticks once a minute so "Reset in …" and the stale check stay current
    /// while the popover is open.
    @State private var now = Date()

    private static let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.results) { result in
                providerSection(result)
            }

            Divider()

            HStack {
                Button("Jetzt aktualisieren") {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)

                Spacer()

                Button("Beenden") { NSApplication.shared.terminate(nil) }
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .frame(width: 280)
        .onReceive(Self.clock) { now = $0 }
        .onAppear { now = Date() }
    }

    @ViewBuilder
    private func providerSection(_ result: ProviderResult) -> some View {
        switch result.state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("\(result.displayName) wird geladen …")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text(result.displayName)
                    .font(.system(size: 12, weight: .medium))
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        case .ok(let snapshots):
            if snapshots.isEmpty {
                Text("\(result.displayName): keine Daten")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(snapshots, id: \.self) { snapshot in
                        SnapshotRow(
                            providerName: result.displayName,
                            snapshot: snapshot,
                            now: now
                        )
                    }
                    if let until = result.throttledUntil, until > now {
                        Text("Aktualisierung gedrosselt bis \(SnapshotRow.timeFormatter.string(from: until))")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
