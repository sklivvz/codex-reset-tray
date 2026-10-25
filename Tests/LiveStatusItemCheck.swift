import AppKit

/// Writes progress directly to stderr, bypassing stdout buffering, so a hosted
/// CI run that stalls inside AppKit event or menu tracking still shows the
/// stage that was entered and whether it returned.
func writeLiveStatus(_ message: String) {
    FileHandle.standardError.write(Data("[live-status] \(message)\n".utf8))
}

/// `NSApplication.stop(_:)` only sets a flag that `run()` checks after it
/// dispatches an actual event. Stopping from a task or timer without a following
/// event can leave the run loop waiting. Post an application-defined event so
/// the loop wakes, dispatches it, and observes the stop flag.
private func stopLiveApplicationRun(_ application: NSApplication) {
    application.stop(nil)
    guard let wake = NSEvent.otherEvent(
        with: .applicationDefined,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 0,
        data1: 0,
        data2: 0
    ) else {
        writeLiveStatus("application stop: could not create the wake event")
        return
    }
    writeLiveStatus("application stop: posting application-defined wake event")
    application.postEvent(wake, atStart: false)
}

/// Opt-in integration check. Unlike the default offscreen suite, this creates a
/// real status item in the current GUI session and sends synthetic mouse events
/// through a running `NSApplication`. It does not launch the packaged app or use
/// a user's Codex account.
///
/// The checks execute from a main-actor task while `NSApplication.run()` owns
/// the main event loop. A common-mode guard cancels every synthetic menu
/// tracking pass, and a watchdog stops the application with a background escape
/// hatch that exits the process if a nested loop fails to return. Progress is
/// written to stderr before and after each click/menu stage, so this opt-in
/// check reports where it stalled instead of hanging silently.
@MainActor
func runLiveStatusItemCheck() {
    writeLiveStatus("starting live status item check")
    let application = NSApplication.shared
    expect(!application.isRunning, "live check must start with a stopped NSApplication")
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
    let runState = LiveStatusItemRunState()
    let watchdog = LiveStatusItemWatchdog(
        application: application,
        menu: menu,
        timeout: 20
    )

    watchdog.arm()
    Task { @MainActor in
        writeLiveStatus("checks task entered the main actor")
        await performLiveStatusItemChecks(
            application: application,
            host: host,
            source: source,
            menu: menu,
            info: info,
            controller: controller
        )
        runState.completed = true
        writeLiveStatus("checks completed; stopping NSApplication.run()")
        watchdog.disarm()
        stopLiveApplicationRun(application)
        writeLiveStatus("NSApplication.stop() returned")
    }

    // This call blocks this task but runs the real AppKit event loop. The
    // checks above run as main-actor work serviced by that loop, and the
    // watchdog can stop it if any wait or menu-tracking pass gets stuck.
    writeLiveStatus("entering NSApplication.run()")
    application.run()

    writeLiveStatus(
        "returned from NSApplication.run(); completed=\(runState.completed) "
            + "timedOut=\(watchdog.timedOut)"
    )
    watchdog.disarm()
    if !runState.completed && !watchdog.timedOut {
        expect(
            false,
            "NSApplication.run() returned before the live status item checks completed"
        )
    }
    expect(!application.isRunning, "live check must return from NSApplication.run()")
    info.hide()
}

@MainActor
private final class LiveStatusItemRunState {
    var completed = false
}

@MainActor
private func performLiveStatusItemChecks(
    application: NSApplication,
    host: SystemStatusItemHost,
    source: FakeTraySource,
    menu: NSMenu,
    info: TrayInfoPopoverPresenter,
    controller: TrayMenuController
) async {
    expect(application.isRunning, "live status item checks must run inside NSApplication.run()")
    writeLiveStatus("NSApplication.run() event loop is active")
    expect(host.isVisible, "real status item must be visible")
    writeLiveStatus("waiting for the real status button window")
    await waitForLiveCondition(timeout: 3, "real status button window") {
        host.statusButton?.window != nil
    }
    guard let button = host.statusButton, let window = button.window else {
        expect(false, "real status button must be mounted in a window")
        return
    }
    writeLiveStatus("real status button window is available")
    expect(!info.isShown, "real status item must not start with the info popover shown")
    // Let AppKit finish mounting the status-bar window before dispatching a
    // click; without this turn NSPopover cannot anchor to the new window.
    try? await Task.sleep(nanoseconds: 300_000_000)

    // Left click: a transient popover hosted below the real status button.
    writeLiveStatus("left click 1: dispatching mouse-down with queued mouse-up")
    guard sendLeftClick(application, button: button, window: window) else {
        expect(false, "real status-item left-click event must be constructible")
        return
    }
    writeLiveStatus("left click 1: dispatch returned; waiting for the info popover")
    await waitForLiveCondition(timeout: 3, "left-click shows the info popover") {
        info.isShown
    }
    writeLiveStatus("left click 1: info popover shown=\(info.isShown)")
    expect(info.isShown, "real left-click must show the info popover")
    expect(info.anchorButton === button, "info popover must anchor to the real status button")
    expectEqual(info.anchorRect, button.bounds, "info popover must anchor to the button bounds")
    expect(info.popover?.behavior == .transient, "live info popover must use transient behavior")
    let liveInfo = TrayInfoModel.make(state: populatedState())
    expect(
        info.contentView?.model == liveInfo,
        "live info popover must contain the current model"
    )
    let renderedInfo = info.contentView?.renderedTexts ?? []
    let expectedInfoTexts = [
        "Codex Reset Tray",
        "63%",
        "7-day Codex usage",
        "Reset forecast",
        "28%",
        "49%",
        "within 24h",
        "within 48h",
    ]
    expectEqual(
        renderedInfo.sorted(),
        expectedInfoTexts.sorted(),
        "live info popover must render exactly the compact usage and forecast content"
    )
    expect(
        !renderedInfo.contains("Codex usage"),
        "live info popover must not render the removed Codex usage section title"
    )
    for removed in [
        "Latest confirmed reset",
        "Last Codex check:",
        "Menu bar 7d label:",
        "Version ",
        "Notifications are denied",
    ] {
        expect(
            !renderedInfo.contains { $0.contains(removed) },
            "live info popover must not render removed content '\(removed)'"
        )
    }
    expectEqual(
        info.contentView?.forecastValues,
        ["28%", "49%"],
        "live info popover must render two forecast percentages"
    )
    await waitForLiveCondition(timeout: 3, "shown info popover window") {
        info.contentView?.window != nil
    }

    if let popoverWindow = info.contentView?.window {
        let buttonRect = window.convertToScreen(button.convert(button.bounds, to: nil))
        await waitForLiveCondition(timeout: 2, "anchored info popover window") {
            let popoverFrame = popoverWindow.frame
            return popoverWindow.isVisible
                && popoverFrame.minX <= buttonRect.maxX
                && popoverFrame.maxX >= buttonRect.minX
                && popoverFrame.maxY <= buttonRect.maxY + 1
        }
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
    writeLiveStatus("live update: posting an error state to the open popover")
    source.setState(errorState)
    await flushMainQueue()
    await waitForLiveCondition(timeout: 3, "open live popover follows source updates") {
        info.contentView?.model == TrayInfoModel.make(state: errorState)
    }
    expect(
        info.contentView?.model == TrayInfoModel.make(state: errorState),
        "open live popover must follow source updates"
    )
    writeLiveStatus("live update: open popover followed the source update")

    // Right-click while the info popover is open: it must close before/while
    // the native actions menu opens, not remain visible above menu tracking.
    writeLiveStatus("right click: preparing; info popover shown=\(info.isShown)")
    expect(info.isShown, "right-click check must start with the info popover open")
    var popoverShownWhenMenuOpened: Bool?
    let rightClickGuard = LiveMenuTrackingGuard(menu: menu, stage: "right click")
    source.onMenuDidOpen = {
        rightClickGuard.noteMenuWillOpen()
        popoverShownWhenMenuOpened = info.isShown
        writeLiveStatus(
            "right click: menuWillOpen probe sees info popover shown=\(info.isShown)"
        )
    }
    // NSMenu.popUp enters a tracking loop; the guard cancels every open so
    // this check cannot wait for a human click or a stray second tracking pass.
    let menuOpensBeforeRightClick = source.menuDidOpenCount
    rightClickGuard.arm()
    writeLiveStatus("right click: posting right mouse-down")
    guard postRightClick(application, button: button, window: window) else {
        rightClickGuard.disarm()
        source.onMenuDidOpen = nil
        expect(false, "real status-item right-click event must be constructible")
        return
    }
    writeLiveStatus("right click: mouse-down posted; waiting for the actions menu")
    await waitForLiveCondition(timeout: 3, "right-click opens the actions menu") {
        rightClickGuard.menuWillOpenCount > 0
            && source.menuDidOpenCount == menuOpensBeforeRightClick + 1
    }
    writeLiveStatus(
        "right click: menu opened; menuDidOpenCount=\(source.menuDidOpenCount)"
    )
    rightClickGuard.disarm()
    source.onMenuDidOpen = nil
    expectEqual(
        source.menuDidOpenCount,
        menuOpensBeforeRightClick + 1,
        "real right-click must open the actions menu"
    )
    expect(
        popoverShownWhenMenuOpened == false,
        "right-click must close the info popover before/while the actions menu opens"
    )
    expect(!info.isShown, "right-click must leave the info popover closed")
    let expectedActions = TrayMenuModel.make(state: source.menuState)
    expectEqual(
        menu.items.count,
        expectedActions.items.count,
        "opened actions menu must match the action-only model"
    )
    expectEqual(
        menu.items.filter { !$0.isSeparatorItem }.count,
        8,
        "opened actions menu must contain exactly the eight configuration/actions rows"
    )
    for item in menu.items where !item.isSeparatorItem {
        expect(item.isEnabled, "opened actions menu must not render gray informational text")
        expect(item.attributedTitle == nil, "opened actions menu must use plain native titles")
        expect(item.target === controller, "opened actions menu item must target the controller")
        expect(item.action != nil, "opened actions menu item must have an action")
        for fragment in [
            "7-day Codex usage",
            "Forecast",
            "Codex error",
            "Baseline",
            "Latest confirmed reset",
            "denied in System Settings",
        ] {
            expect(
                !item.title.contains(fragment),
                "opened actions menu must not contain informational row '\(item.title)'"
            )
        }
    }
    expect(menu.items.contains { $0.title == "Enable Notifications" },
           "opened actions menu must contain Enable Notifications")
    expect(menu.items.contains { $0.title == "About Codex Reset Tray" },
           "opened actions menu must contain About")
    expect(menu.items.contains { $0.title == "Quit Codex Reset Tray" },
           "opened actions menu must contain Quit")

    // Separately post a control-left mouse-down through NSApplication's event
    // queue. It must take the secondary route, open the menu, and never show a
    // popover.
    writeLiveStatus("control-left click: preparing; info popover shown=\(info.isShown)")
    expect(!info.isShown, "control-left check must start with the info popover hidden")
    var popoverShownWhenControlMenuOpened: Bool?
    let controlClickGuard = LiveMenuTrackingGuard(
        menu: menu,
        stage: "control-left click"
    )
    source.onMenuDidOpen = {
        controlClickGuard.noteMenuWillOpen()
        popoverShownWhenControlMenuOpened = info.isShown
        writeLiveStatus(
            "control-left click: menuWillOpen probe sees info popover shown=\(info.isShown)"
        )
    }
    let menuOpensBeforeControlClick = source.menuDidOpenCount
    controlClickGuard.arm()
    writeLiveStatus("control-left click: posting control-left mouse-down")
    guard postControlLeftClick(application, button: button, window: window) else {
        controlClickGuard.disarm()
        source.onMenuDidOpen = nil
        expect(false, "real status-item control-left click event must be constructible")
        return
    }
    writeLiveStatus("control-left click: mouse-down posted; waiting for the actions menu")
    await waitForLiveCondition(timeout: 3, "control-left click opens the actions menu") {
        controlClickGuard.menuWillOpenCount > 0
            && source.menuDidOpenCount == menuOpensBeforeControlClick + 1
    }
    writeLiveStatus(
        "control-left click: menu opened; menuDidOpenCount=\(source.menuDidOpenCount)"
    )
    controlClickGuard.disarm()
    source.onMenuDidOpen = nil
    expectEqual(
        source.menuDidOpenCount,
        menuOpensBeforeControlClick + 1,
        "control-left click through NSApplication must open the actions menu"
    )
    expect(
        popoverShownWhenControlMenuOpened == false,
        "control-left click must not present a popover before/while the menu opens"
    )
    expect(!info.isShown, "control-left click must leave the info popover hidden")
    expectEqual(
        menu.items.filter { !$0.isSeparatorItem }.count,
        8,
        "control-left menu must still contain exactly the eight configuration/actions rows"
    )

    // Left click reopens the popover, then a second left click toggles it shut.
    writeLiveStatus("left click reopen: dispatching mouse-down with queued mouse-up")
    guard sendLeftClick(application, button: button, window: window) else {
        expect(false, "real status-item reopen click event must be constructible")
        return
    }
    writeLiveStatus("left click reopen: dispatch returned; waiting for the info popover")
    await waitForLiveCondition(timeout: 3, "left-click reopens the info popover") {
        info.isShown
    }
    writeLiveStatus("left click reopen: info popover shown=\(info.isShown)")
    expect(info.isShown, "left-click after the actions menu must reopen the info popover")
    writeLiveStatus("left click close: dispatching mouse-down with queued mouse-up")
    guard sendLeftClick(application, button: button, window: window) else {
        expect(false, "real status-item toggle-close event must be constructible")
        return
    }
    writeLiveStatus("left click close: dispatch returned; waiting for the popover to hide")
    await waitForLiveCondition(timeout: 3, "second left click hides the info popover") {
        !info.isShown
    }
    writeLiveStatus("left click close: info popover shown=\(info.isShown)")
    expect(!info.isShown, "second real left-click must hide the info popover")

    // Transient behavior: reopen, then a click outside the popover closes it.
    writeLiveStatus("outside click setup: dispatching mouse-down with queued mouse-up")
    guard sendLeftClick(application, button: button, window: window) else {
        expect(false, "real status-item outside-click setup event must be constructible")
        return
    }
    writeLiveStatus("outside click setup: dispatch returned; waiting for the info popover")
    await waitForLiveCondition(timeout: 3, "left-click reopens for outside-click check") {
        info.isShown
    }
    writeLiveStatus("outside click setup: info popover shown=\(info.isShown)")
    expect(info.isShown, "left-click after the toggle must reopen the info popover")
    if let popoverWindow = info.contentView?.window {
        guard let outsideDown = statusOutsideMouseEvent(
            .leftMouseDown,
            button: button,
            window: window
        ), let outsideUp = statusOutsideMouseEvent(
            .leftMouseUp,
            button: button,
            window: window
        ) else {
            expect(false, "outside-click events must be constructible")
            return
        }
        writeLiveStatus("outside click: posting outside mouse-down and mouse-up")
        application.postEvent(outsideUp, atStart: false)
        application.postEvent(outsideDown, atStart: true)
        await waitForLiveCondition(timeout: 4, "outside click closes the transient popover") {
            !info.isShown
        }
        writeLiveStatus("outside click: info popover shown=\(info.isShown)")
        expect(
            !info.isShown,
            "outside click must transiently close the info popover"
        )
        expect(!popoverWindow.isVisible, "transiently closed popover window must be hidden")
    } else {
        expect(false, "reopened info popover must be hosted in a window")
    }
    info.hide()
    writeLiveStatus("all live status item stages completed")
}

/// Keeps synthetic actions-menu tracking bounded. The repeating timer runs in
/// common modes, so it is serviced inside the event-tracking mode used by
/// `NSMenu.popUp`, and it cancels every tracking pass started while armed. A
/// queued mouse event that opens a second menu therefore cannot outlive the
/// click stage that dispatched it.
@MainActor
private final class LiveMenuTrackingGuard: NSObject {
    private let menu: NSMenu
    private let stage: String
    private let cancelInterval: TimeInterval
    private var timer: Timer?
    private(set) var menuWillOpenCount = 0

    init(menu: NSMenu, stage: String, cancelInterval: TimeInterval = 0.4) {
        self.menu = menu
        self.stage = stage
        self.cancelInterval = cancelInterval
    }

    func arm() {
        disarm()
        menuWillOpenCount = 0
        writeLiveStatus("\(stage): arming menu-tracking guard every \(cancelInterval)s")
        let timer = Timer(
            timeInterval: cancelInterval,
            target: self,
            selector: #selector(cancelTracking(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func noteMenuWillOpen() {
        menuWillOpenCount += 1
        writeLiveStatus("\(stage): menu tracking opened (open #\(menuWillOpenCount))")
    }

    func disarm() {
        guard timer != nil else { return }
        timer?.invalidate()
        timer = nil
        writeLiveStatus(
            "\(stage): disarmed menu-tracking guard after \(menuWillOpenCount) open(s)"
        )
    }

    @objc private func cancelTracking(_ timer: Timer) {
        writeLiveStatus("\(stage): requesting menu tracking cancellation")
        menu.cancelTrackingWithoutAnimation()
        menu.cancelTracking()
        writeLiveStatus("\(stage): menu tracking cancellation requested")
    }
}

/// Stops `NSApplication.run()` on a bounded timeout. A background escape hatch
/// exits the process if the main event loop cannot service even the escape
/// timer, so a wedged run loop cannot leave the opt-in check hanging.
private final class LiveStatusItemWatchdog: NSObject {
    private let application: NSApplication
    private let menu: NSMenu
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private var timeoutTimer: Timer?
    private var escapeTimer: Timer?
    private var backgroundEscape: DispatchWorkItem?
    private(set) var timedOut = false

    init(application: NSApplication, menu: NSMenu, timeout: TimeInterval) {
        self.application = application
        self.menu = menu
        self.timeout = timeout
    }

    func arm() {
        writeLiveStatus(
            "watchdog: armed for a \(timeout)s application-run timeout "
                + "(background escape at \(timeout + 5)s)"
        )
        let timer = Timer(
            timeInterval: timeout,
            target: self,
            selector: #selector(handleTimeout(_:)),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(timer, forMode: .common)
        timeoutTimer = timer

        let escape = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cancelled = self.cancelled
            self.lock.unlock()
            guard !cancelled else { return }
            writeLiveStatus(
                "FAIL: live status item check hard timeout after \(self.timeout)s; "
                    + "the main run loop did not service the watchdog; exiting"
            )
            exit(2)
        }
        backgroundEscape = escape
        DispatchQueue.global().asyncAfter(
            deadline: .now() + timeout + 5,
            execute: escape
        )
    }

    func disarm() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        escapeTimer?.invalidate()
        escapeTimer = nil
        backgroundEscape?.cancel()
        backgroundEscape = nil
        if !wasCancelled {
            writeLiveStatus("watchdog: disarmed")
        }
    }

    @objc private func handleTimeout(_ timer: Timer) {
        timedOut = true
        writeLiveStatus(
            "watchdog: \(Int(timeout))s application-run timeout; the last stage "
                + "before this line is where the harness stalled"
        )
        expect(
            false,
            "live status item check exceeded \(Int(timeout))s; watchdog stopped NSApplication.run()"
        )
        writeLiveStatus("watchdog: cancelling menu tracking and stopping NSApplication")
        menu.cancelTrackingWithoutAnimation()
        menu.cancelTracking()
        stopLiveApplicationRun(application)
        let escape = Timer(
            timeInterval: 2,
            target: self,
            selector: #selector(forceExit(_:)),
            userInfo: nil,
            repeats: false
        )
        RunLoop.main.add(escape, forMode: .common)
        escapeTimer = escape
    }

    @objc private func forceExit(_ timer: Timer) {
        writeLiveStatus(
            "FAIL: live status item check did not return from NSApplication.run(); exiting"
        )
        exit(2)
    }
}

@MainActor
private func waitForLiveCondition(
    timeout: TimeInterval,
    _ description: String,
    _ predicate: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    expect(predicate(), "timed out after \(timeout)s waiting for \(description)")
}

/// A click in the status-bar window but outside the status button, matching a
/// user clicking the menu bar away from the popover. Posting it through the
/// event queue lets NSPopover's transient-close handling observe a real event
/// instead of only the presenter's forced-close path.
@MainActor
private func statusOutsideMouseEvent(
    _ type: NSEvent.EventType,
    button: NSStatusBarButton,
    window: NSWindow
) -> NSEvent? {
    let location = button.convert(
        NSPoint(x: button.bounds.maxX + 80, y: button.bounds.midY),
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

/// Posts the right mouse-down that the local event monitor must route to the
/// actions menu. The menu opens asynchronously after `close()` finishes, so the
/// caller waits for the `menuWillOpen` stage callback instead of expecting
/// `postEvent` to block.
@MainActor
private func postRightClick(
    _ application: NSApplication,
    button: NSStatusBarButton,
    window: NSWindow
) -> Bool {
    postStatusMouseDown(
        .rightMouseDown,
        application: application,
        button: button,
        window: window
    )
}

/// Posts the control-left down that the local event monitor must classify as a
/// secondary click. `NSApplication.run()` delivers it on the main event loop;
/// calling `sendEvent` from the checks task would enter menu tracking
/// synchronously and reentrantly. The down is the event that decides the route,
/// so it is posted alone: a separate up queued before the deferred menu would
/// be delivered as an unpaired button-up and could start a second action.
@MainActor
private func postControlLeftClick(
    _ application: NSApplication,
    button: NSStatusBarButton,
    window: NSWindow
) -> Bool {
    postStatusMouseDown(
        .leftMouseDown,
        modifiers: [.control],
        application: application,
        button: button,
        window: window
    )
}

@MainActor
private func postStatusMouseDown(
    _ type: NSEvent.EventType,
    modifiers: NSEvent.ModifierFlags = [],
    application: NSApplication,
    button: NSStatusBarButton,
    window: NSWindow
) -> Bool {
    guard let down = statusMouseEvent(
        type,
        modifiers: modifiers,
        button: button,
        window: window
    ) else {
        return false
    }
    application.postEvent(down, atStart: false)
    return true
}

@MainActor
private func statusMouseEvent(
    _ type: NSEvent.EventType,
    modifiers: NSEvent.ModifierFlags = [],
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
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}
