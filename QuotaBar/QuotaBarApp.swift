import SwiftUI

@main
struct QuotaBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The status item lives in AppDelegate; this scene exists only because
        // an App needs one. LSUIElement keeps it out of the Dock and the
        // window never opens by itself.
        Settings { EmptyView() }
    }
}
