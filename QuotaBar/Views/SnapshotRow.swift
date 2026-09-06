import SwiftUI

struct SnapshotRow: View {
    let providerName: String
    let snapshot: UsageSnapshot
    let now: Date

    private var isStale: Bool { snapshot.isStale(now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(providerName) · \(snapshot.windowLabel)")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(Self.percentFormat(snapshot.percentRemaining))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }

            ProgressView(value: snapshot.percentRemaining, total: 100)
                .progressViewStyle(.linear)
                .tint(isStale ? .secondary : barColor)

            HStack {
                if let resetsAt = snapshot.resetsAt {
                    Text(Self.resetText(from: now, to: resetsAt))
                }
                Spacer()
                if isStale {
                    Text("Daten von \(Self.timeFormatter.string(from: snapshot.capturedAt))")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)

            if let detail = snapshot.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(isStale ? 0.5 : 1)
    }

    private var barColor: Color {
        switch snapshot.percentRemaining {
        case ..<10: .red
        case ..<25: .orange
        default: .accentColor
        }
    }

    static func percentFormat(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func resetText(from now: Date, to resetsAt: Date) -> String {
        let seconds = Int(resetsAt.timeIntervalSince(now))
        guard seconds > 0 else { return "Reset fällig" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            return "Reset in \(days)d \(hours % 24)h"
        }
        return hours > 0 ? "Reset in \(hours)h \(minutes)m" : "Reset in \(minutes)m"
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
