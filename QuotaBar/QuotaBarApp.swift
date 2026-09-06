import SwiftUI

@main
struct QuotaBarApp: App {
    @State private var store = UsageStore(providers: [
        ClaudeUsageProvider(),
        GrokUsageProvider()
    ])

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store)
        } label: {
            Text(menuBarLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: String {
        if let percent = store.headlinePercent {
            return SnapshotRow.percentFormat(percent)
        }
        return store.hasFailure ? "–%" : "…"
    }
}
