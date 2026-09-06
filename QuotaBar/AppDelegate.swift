import AppKit
import Observation
import SwiftUI

/// SwiftUI's `MenuBarExtra` gives no control over where the item lands, and on
/// a notched display macOS parked it dead centre — behind the notch, present
/// in the accessibility tree but never drawn. A plain `NSStatusItem` has an
/// `autosaveName`, so its position is ours to seed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let autosaveName = "QuotaBarStatusItem"
    /// Points from the right screen edge for the very first launch — far
    /// enough right to clear the notch on a 14" MacBook Pro.
    private static let initialPositionFromRight = 240.0

    private let store = UsageStore(providers: [
        ClaudeUsageProvider(),
        GrokUsageProvider()
    ])

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        seedPreferredPosition()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = Self.autosaveName
        item.button?.title = "…"
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let controller = NSHostingController(rootView: PopoverView(store: store))
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.behavior = .transient

        observeLabel()
    }

    /// Only seeds a position the user has never chosen — once they drag the
    /// item, macOS stores their choice under the same key and we leave it be.
    private func seedPreferredPosition() {
        let key = "NSStatusItem Preferred Position \(Self.autosaveName)"
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(Self.initialPositionFromRight, forKey: key)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Let the content refresh its clock before it becomes visible.
            NotificationCenter.default.post(name: .popoverWillShow, object: nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// `withObservationTracking` fires once, so re-arm it after every change.
    private func observeLabel() {
        withObservationTracking {
            _ = store.headlinePercent
            _ = store.hasFailure
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateTitle()
                self?.observeLabel()
            }
        }
        updateTitle()
    }

    private func updateTitle() {
        if let percent = store.headlinePercent {
            statusItem?.button?.title = SnapshotRow.percentFormat(percent)
        } else {
            statusItem?.button?.title = store.hasFailure ? "–%" : "…"
        }
    }
}

extension Notification.Name {
    static let popoverWillShow = Notification.Name("QuotaBarPopoverWillShow")
}
