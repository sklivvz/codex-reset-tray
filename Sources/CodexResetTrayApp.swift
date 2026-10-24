import AppKit

@main
@MainActor
struct CodexResetTrayApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: ResetStore?
    private var menuController: TrayMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = ResetStore()
        self.store = store
        menuController = TrayMenuController(store: store)
        store.start()
    }
}
