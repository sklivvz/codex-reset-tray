import AppKit

/// Opt-in integration check. Unlike the default offscreen suite, this briefly
/// creates a real status item in the current GUI session and sends synthetic
/// mouse events through `NSApplication`. It does not launch the packaged app or
/// use a user's Codex account.
@MainActor
func runLiveStatusItemCheck() async {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.finishLaunching()

    let host = SystemStatusItemHost()
    defer { host.remove() }
    let source = FakeTraySource(state: populatedState())
    let menu = NSMenu()
    let info = TrayInfoPopoverPresenter(appIconProvider: { packagedAppIcon() })
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
    expect(!info.isShown, "real status item must not start with the info popover shown")
    // Let AppKit finish mounting the status-bar window before dispatching a
    // click; without this turn NSPopover cannot anchor to the new window.
    pumpMainRunLoop(for: 0.3)

    // Left click: a transient popover hosted below the real status button.
    guard sendLeftClick(application, button: button, window: window) else {
        expect(false, "real status-item left-click event must be constructible")
        return
    }
    waitPumpingMainRunLoop(timeout: 2) { info.isShown }
    expect(info.isShown, "real left-click must show the info popover")
    expect(info.anchorButton === button, "info popover must anchor to the real status button")
    expectEqual(info.anchorRect, button.bounds, "info popover must anchor to the button bounds")
    expect(info.popover?.behavior == .transient, "live info popover must use transient behavior")
    expect(
        info.contentView?.model == TrayInfoModel.make(state: populatedState()),
        "live info popover must contain the current model"
    )

    if let popoverWindow = info.contentView?.window {
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        let popoverFrame = popoverWindow.frame
        expect(popoverWindow.isVisible, "shown info popover must have a visible window")
        expect(
            popoverFrame.minX <= buttonRect.maxX && popoverFrame.maxX >= buttonRect.minX,
            "info popover window must be horizontally anchored near the status button"
        )
        expect(
            popoverFrame.maxY <= buttonRect.maxY + 1,
            "info popover window must be placed below the menu-bar status button"
        )
    } else {
        expect(false, "shown info popover must be hosted in a window")
    }

    // Live source updates must reach the real popover's content view.
    let errorState = TrayMenuState(
        snapshot: snapshot(),
        codexError: "Codex app-server did not respond within 10 seconds.",
        forecastError: "codexreset.org returned HTTP 503.",
        lastCodexCheck: runtimeNow
    )
    source.setState(errorState)
    await flushMainQueue()
    pumpMainRunLoop(for: 0.1)
    expect(
        info.contentView?.model == TrayInfoModel.make(state: errorState),
        "open live popover must follow source updates"
    )

    // A second left click toggles the popover closed.
    guard sendLeftClick(application, button: button, window: window) else {
        expect(false, "second real status-item left-click event must be constructible")
        return
    }
    waitPumpingMainRunLoop(timeout: 2) { !info.isShown }
    expect(!info.isShown, "second real left-click must hide the info popover")

    // Right click: the actions menu opens and no info popover is presented.
    guard let rightClick = statusMouseEvent(
        .rightMouseDown,
        button: button,
        window: window
    ) else {
        expect(false, "real status-item right-click event must be constructible")
        return
    }
    // NSMenu.popUp enters a tracking loop; cancel it automatically so this
    // check cannot wait for a human click.
    let menuOpensBeforeRightClick = source.menuDidOpenCount
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { menu.cancelTracking() }
    withExtendedLifetime(controller) { application.sendEvent(rightClick) }
    expectEqual(
        source.menuDidOpenCount,
        menuOpensBeforeRightClick + 1,
        "real right-click must open the actions menu"
    )
    expect(menu.items.contains { $0.title == "Quit Codex Reset Tray" },
           "opened actions menu must contain Quit")
    expect(!info.isShown, "right-click must not present the info popover")

    info.hide()
}

@MainActor
private func pumpMainRunLoop(for seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

@MainActor
private func waitPumpingMainRunLoop(
    timeout: TimeInterval,
    _ predicate: () -> Bool
) {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        pumpMainRunLoop(for: 0.02)
    }
}

@MainActor
private func sendLeftClick(
    _ application: NSApplication,
    button: NSStatusBarButton,
    window: NSWindow
) -> Bool {
    guard let down = statusMouseEvent(.leftMouseDown, button: button, window: window),
          let up = statusMouseEvent(.leftMouseUp, button: button, window: window) else {
        return false
    }
    // Queue the matching mouse-up before dispatching mouse-down: the status
    // button tracks the click and dispatches its action on mouse-up.
    application.postEvent(up, atStart: false)
    application.sendEvent(down)
    return true
}

@MainActor
private func statusMouseEvent(
    _ type: NSEvent.EventType,
    button: NSStatusBarButton,
    window: NSWindow
) -> NSEvent? {
    let location = button.convert(
        NSPoint(x: button.bounds.midX, y: button.bounds.midY),
        to: nil
    )
    return NSEvent.mouseEvent(
        with: type,
        location: location,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}
