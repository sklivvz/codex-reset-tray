import AppKit

/// Opt-in integration check. Unlike the default offscreen suite, this briefly
/// creates a real status item in the current GUI session. It does not launch
/// the packaged app or use a user's Codex account.
@MainActor
func runLiveStatusItemCheck() async {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.finishLaunching()

    let host = SystemStatusItemHost()
    defer { host.remove() }
    let source = FakeTraySource(state: populatedState())
    let menu = NSMenu()
    let info = FakeInfoPresenter()
    let controller = TrayMenuController(
        source: source,
        statusItem: host,
        menu: menu,
        terminate: {},
        openURL: { _ in },
        infoPresenter: info,
        writeToPasteboard: { _ in }
    )
    expect(host.isVisible, "real status item must be visible")
    await waitUntil(timeout: 3) { host.statusButton?.window != nil }
    guard let button = host.statusButton, let window = button.window else {
        expect(false, "real status button must be mounted in a window")
        return
    }
    let location = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    guard let event = NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    ) else {
        expect(false, "real status-item right-click event must be constructible")
        return
    }

    // NSMenu.popUp enters a tracking loop; cancel it automatically so this
    // check cannot wait for a human click.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { menu.cancelTracking() }
    withExtendedLifetime(controller) { application.sendEvent(event) }
    expectEqual(source.menuDidOpenCount, 1, "real right-click event must open the actions menu")
    expect(menu.items.contains { $0.title == "Quit Codex Reset Tray" },
           "opened actions menu must contain Quit")
    expect(!info.isShown, "right-click must not open the info window")
}
