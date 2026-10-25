import AppKit
import Combine
import Foundation
import UserNotifications

// By default this executable is an offscreen AppKit integration test. It
// constructs the real TrayMenuController around a fake menu source and an
// unmounted NSStatusBarButton. It never creates an NSStatusItem, shows a window
// or popover, activates the application, starts a run loop, or launches the app
// bundle.
//
// NSApplication.shared is instantiated only because NSMenu dispatches item
// actions through the application object; -run and -finishLaunching are never
// called. On a command-line process its activation policy is .prohibited, so
// no Dock tile or UI is created.
//
// Passing --live-status-item switches to the opt-in GUI check in
// LiveStatusItemCheck.swift, which does create a real NSStatusItem and runs its
// assertions under an actual NSApplication.run() event loop with a bounded
// watchdog.

var runtimeFailures = 0
let runtimeNow = Date(timeIntervalSince1970: 1_800_000_000)

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        runtimeFailures += 1
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: String,
    line: Int = #line
) {
    if actual != expected {
        runtimeFailures += 1
        FileHandle.standardError.write(
            Data("FAIL line \(line): \(message) (got \(actual), expected \(expected))\n".utf8)
        )
    }
}

@MainActor
final class FakeTraySource: ObservableObject, TrayMenuSource {
    @Published private(set) var state: TrayMenuState
    private(set) var menuDidOpenCount = 0
    private(set) var refreshAllCount = 0
    private(set) var refreshNotificationAuthorizationCount = 0
    private(set) var requestNotificationAuthorizationCount = 0
    /// The authorization the fake system reports from a read-only refresh.
    var notificationAuthorization: NotificationAuthorization = .authorized
    /// The result of the explicit menu request. `nil` keeps the current value.
    var notificationAuthorizationAfterRequest: NotificationAuthorization?
    /// Optional probe run from `menuWillOpen`, before native menu tracking
    /// begins. The live check uses it to observe the popover state at open time.
    var onMenuDidOpen: (@MainActor () -> Void)?

    init(state: TrayMenuState) {
        self.state = state
        notificationAuthorization = state.notificationPermission.testAuthorization
    }

    var menuState: TrayMenuState { state }

    var menuBarTitle: String {
        guard state.showsUsageInMenuBar else { return "" }
        let base: String
        if let weekly = state.snapshot?.weeklyWindow {
            base = "7d \(Int(weekly.usedPercent.rounded()))%"
        } else if state.isPollingCodex {
            base = "Codex…"
        } else {
            base = "Codex"
        }
        return state.codexError == nil ? base : "\(base) !"
    }

    var menuBarSystemImage: String {
        state.codexError == nil ? "chart.bar.fill" : "exclamationmark.triangle.fill"
    }

    var showsUsageInMenuBar: Bool {
        state.showsUsageInMenuBar
    }

    var changePublisher: AnyPublisher<Void, Never> {
        objectWillChange.map { _ in () }.eraseToAnyPublisher()
    }

    func setShowsUsageInMenuBar(_ visible: Bool) {
        var next = state
        next.showsUsageInMenuBar = visible
        state = next
    }

    func setState(_ newState: TrayMenuState) {
        state = newState
    }

    /// Updates both the fake system authorization and the published menu state,
    /// as a real authorization refresh would.
    func setNotificationAuthorization(_ authorization: NotificationAuthorization) {
        notificationAuthorization = authorization
        var next = state
        next.notificationPermission = trayPermission(for: authorization)
        state = next
    }

    func menuDidOpen() {
        menuDidOpenCount += 1
        onMenuDidOpen?()
    }

    func refreshAll() async {
        refreshAllCount += 1
    }

    func refreshNotificationAuthorization() async -> NotificationAuthorization {
        refreshNotificationAuthorizationCount += 1
        let authorization = notificationAuthorization
        var next = state
        next.notificationPermission = trayPermission(for: authorization)
        state = next
        return authorization
    }

    func requestNotificationAuthorization() async -> NotificationAuthorization {
        requestNotificationAuthorizationCount += 1
        if let notificationAuthorizationAfterRequest {
            notificationAuthorization = notificationAuthorizationAfterRequest
            notificationAuthorizationAfterRequest = nil
        }
        let authorization = notificationAuthorization
        var next = state
        next.notificationPermission = trayPermission(for: authorization)
        state = next
        return authorization
    }
}

func trayPermission(
    for authorization: NotificationAuthorization
) -> TrayNotificationPermission {
    switch authorization {
    case .authorized, .provisional, .ephemeral:
        return .allowed
    case .notDetermined:
        return .notDetermined
    case .denied:
        return .denied
    case .error:
        return .unknown
    }
}

private extension TrayNotificationPermission {
    var testAuthorization: NotificationAuthorization {
        switch self {
        case .allowed:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .unknown:
            return .error("test authorization unavailable")
        }
    }
}

@MainActor
final class FakeStatusItemHost: TrayStatusItemHost {
    var isVisible = false
    let button = NSStatusBarButton()
    /// Menus the controller asked the (fake) status item to show.
    private(set) var poppedMenus: [NSMenu] = []
    /// Optional probe run at the moment the controller asks to pop the menu.
    var onPopUp: (@MainActor () -> Void)?
    var statusButton: NSStatusBarButton? { button }

    func popUp(_ menu: NSMenu) {
        poppedMenus.append(menu)
        onPopUp?()
    }
}

/// Stands in for the information popover: records what the controller asked it
/// to do, including the anchor, and never creates or shows an NSPopover.
@MainActor
final class FakeInfoPresenter: TrayInfoPresenting {
    private(set) var isShown = false
    private(set) var shown: [TrayInfoModel] = []
    private(set) var anchors: [NSStatusBarButton] = []
    private(set) var updates: [TrayInfoModel] = []
    private(set) var hideCount = 0

    func show(_ model: TrayInfoModel, relativeTo statusButton: NSStatusBarButton) {
        isShown = true
        shown.append(model)
        anchors.append(statusButton)
    }

    func update(_ model: TrayInfoModel) {
        updates.append(model)
    }

    func hide() {
        isShown = false
        hideCount += 1
    }
}

@MainActor
final class FakeAboutPresenter: AboutPresenting {
    private(set) var showCount = 0

    func show() {
        showCount += 1
    }
}

@MainActor
final class ActionRecorder {
    var terminatedCount = 0
    var openedURL: URL?
    var copiedText: String?
    /// The event `NSApp.currentEvent` would report during a status-item click.
    var nextEvent: NSEvent?
}

@MainActor
final class Harness {
    let source: FakeTraySource
    let statusItem = FakeStatusItemHost()
    let menu = NSMenu()
    let recorder = ActionRecorder()
    let info = FakeInfoPresenter()
    let about = FakeAboutPresenter()
    private var clickWindow: NSWindow?
    private(set) var controller: TrayMenuController!

    convenience init(state: TrayMenuState) {
        self.init(state: state, appIcon: packagedAppIcon())
    }

    init(state: TrayMenuState, appIcon: NSImage?) {
        source = FakeTraySource(state: state)
        controller = TrayMenuController(
            source: source,
            statusItem: statusItem,
            menu: menu,
            terminate: { [recorder] in recorder.terminatedCount += 1 },
            openURL: { [recorder] in recorder.openedURL = $0 },
            appIconProvider: { appIcon },
            infoPresenter: info,
            aboutPresenter: about,
            currentEvent: { [recorder] in recorder.nextEvent },
            writeToPasteboard: { [recorder] in recorder.copiedText = $0 }
        )
    }

    /// Delivers ordinary clicks through target/action and secondary clicks
    /// through the local monitor's event handler, with a real offscreen window
    /// number and hit-tested button bounds. It never displays the window.
    func click(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) {
        let button = statusItem.button
        if type == .rightMouseUp || modifiers.contains(.control) {
            let downType: NSEvent.EventType = type == .rightMouseUp ? .rightMouseDown : .leftMouseDown
            guard let event = statusEvent(downType, modifiers: modifiers) else {
                expect(false, "secondary click event must be constructible")
                return
            }
            expect(controller.handleStatusMouseDown(event), "secondary event must be consumed")
            return
        }
        recorder.nextEvent = mouseEvent(type, modifiers: modifiers)
        _ = button.sendAction(button.action, to: button.target)
    }

    func statusEvent(
        _ type: NSEvent.EventType,
        modifiers: NSEvent.ModifierFlags = [],
        inside: Bool = true,
        otherWindow: Bool = false
    ) -> NSEvent? {
        if clickWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            let button = statusItem.button
            button.frame = NSRect(x: 0, y: 0, width: button.image?.size.width ?? 40, height: 22)
            window.contentView?.addSubview(button)
            clickWindow = window
        }
        guard let window = clickWindow else { return nil }
        let button = statusItem.button
        let point = inside
            ? button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            : NSPoint(x: window.contentView?.bounds.maxX ?? 200, y: 30)
        return NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber + (otherWindow ? 1 : 0),
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    var model: TrayMenuModel {
        TrayMenuModel.make(state: source.menuState)
    }

    func index(of role: TrayMenuItemRole) -> Int? {
        model.items.firstIndex { $0.role == role }
    }

    func item(for role: TrayMenuItemRole) -> NSMenuItem? {
        guard let index = index(of: role) else { return nil }
        return menu.items[index]
    }
}

/// The packaged icon, read from the same `Resources/AppIcon.icns` that
/// build.sh copies into the app bundle.
let packagedAppIconURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/AppIcon.icns")

@MainActor
func packagedAppIcon() -> NSImage? {
    NSImage(contentsOf: packagedAppIconURL)
}

func mouseEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
    NSEvent.mouseEvent(
        with: type,
        location: .zero,
        modifierFlags: modifiers,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
    )
}

@MainActor
func flushMainQueue() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@MainActor
func waitUntil(
    timeout: TimeInterval = 1,
    _ predicate: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate() && Date() < deadline {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

enum StubFetchError: Error {
    case noMoreSnapshots
}

/// Deterministic stand-in for the app-server fetch. The closure is `@Sendable`
/// because ResetStore owns it beyond the main actor.
final class StubRateLimitFetcher: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<CodexRateLimitSnapshot, Error>]

    init(_ results: [Result<CodexRateLimitSnapshot, Error>]) {
        self.results = results
    }

    func next() throws -> CodexRateLimitSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else { throw StubFetchError.noMoreSnapshots }
        return try results.removeFirst().get()
    }
}

/// Deterministic stand-in for UserNotifications. It records every scheduling
/// attempt and never asks the system, prompts, or displays anything.
final class StubNotificationScheduler: NotificationScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var currentAuthorization: NotificationAuthorization
    private var requestResults: [NotificationAuthorization]
    private var scheduleResults: [NotificationDeliveryResult]
    private var recordedAlerts: [RestorationAlert] = []
    private var authorizationRequestCount = 0
    private var authorizationStatusCheckCount = 0

    init(
        authorization: NotificationAuthorization = .authorized,
        requestResults: [NotificationAuthorization] = [],
        scheduleResults: [NotificationDeliveryResult] = [.scheduled]
    ) {
        currentAuthorization = authorization
        self.requestResults = requestResults
        self.scheduleResults = scheduleResults
    }

    var scheduledAlerts: [RestorationAlert] {
        withLock { recordedAlerts }
    }

    var scheduleCallCount: Int {
        withLock { recordedAlerts.count }
    }

    var requestAuthorizationCallCount: Int {
        withLock { authorizationRequestCount }
    }

    var authorizationStatusCallCount: Int {
        withLock { authorizationStatusCheckCount }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        withLock {
            authorizationStatusCheckCount += 1
            return currentAuthorization
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        withLock {
            authorizationRequestCount += 1
            if !requestResults.isEmpty {
                currentAuthorization = requestResults.removeFirst()
            }
            return currentAuthorization
        }
    }

    func schedule(_ alert: RestorationAlert) async -> NotificationDeliveryResult {
        withLock {
            recordedAlerts.append(alert)
            guard !scheduleResults.isEmpty else {
                return .failed("stub scheduler has no queued result")
            }
            let result = scheduleResults.removeFirst()
            if result == .scheduled {
                currentAuthorization = .authorized
            }
            return result
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Deterministic stand-in for `UNUserNotificationCenter`. It records requests
/// and can inject authorization/add errors without contacting the system.
final class StubUserNotificationCenter: UserNotificationCenterClient, @unchecked Sendable {
    private let lock = NSLock()
    private var currentStatus: UNAuthorizationStatus
    private var statusAfterRequest: UNAuthorizationStatus
    private var requestError: Error?
    private var addError: Error?
    private var recordedRequests: [UNNotificationRequest] = []
    private var authorizationRequestCount = 0
    var delegate: (any UNUserNotificationCenterDelegate)?

    init(
        status: UNAuthorizationStatus = .authorized,
        statusAfterRequest: UNAuthorizationStatus = .authorized,
        requestError: Error? = nil,
        addError: Error? = nil
    ) {
        currentStatus = status
        self.statusAfterRequest = statusAfterRequest
        self.requestError = requestError
        self.addError = addError
    }

    var addedRequests: [UNNotificationRequest] {
        withLock { recordedRequests }
    }

    var requestAuthorizationCallCount: Int {
        withLock { authorizationRequestCount }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        withLock { currentStatus }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        let error: Error? = withLock {
            authorizationRequestCount += 1
            return requestError
        }
        if let error { throw error }
        return withLock {
            currentStatus = statusAfterRequest
            return statusAfterRequest == .authorized
                || statusAfterRequest == .provisional
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        let error: Error? = withLock {
            recordedRequests.append(request)
            return addError
        }
        if let error { throw error }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

func resetAlert(timing: ResetTiming = .scheduled) -> RestorationAlert {
    RestorationAlert(
        previousPercent: 80,
        currentPercent: 6,
        resetsAt: runtimeNow.addingTimeInterval(86_400),
        capturedAt: runtimeNow,
        timing: timing,
        ordinaryUsageAllowed: true
    )
}

func weeklySnapshot(
    usedPercent: Double,
    resetsAt: Date,
    allowed: Bool? = true
) -> CodexRateLimitSnapshot {
    CodexRateLimitSnapshot(
        ordinaryUsageAllowed: allowed,
        primary: CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: 10_080,
            resetsAt: resetsAt
        ),
        secondary: nil,
        observedAt: Date()
    )
}

func makeStoreDefaults(_ label: String) -> (defaults: UserDefaults, suite: String) {
    let suite = "CodexResetTrayRuntime.\(label).\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}

func colorsEqual(_ lhs: NSColor?, _ rhs: NSColor) -> Bool {
    guard let lhs,
          let left = lhs.usingColorSpace(.sRGB),
          let right = rhs.usingColorSpace(.sRGB) else {
        return false
    }
    return abs(left.redComponent - right.redComponent) < 0.001
        && abs(left.greenComponent - right.greenComponent) < 0.001
        && abs(left.blueComponent - right.blueComponent) < 0.001
        && abs(left.alphaComponent - right.alphaComponent) < 0.001
}

/// Draws the image into an offscreen RGBA bitmap and counts pixels with alpha.
/// This verifies the status image contains renderable data, not merely a
/// non-nil NSImage wrapper.
@MainActor
func renderedOpaquePixelCount(_ image: NSImage) -> Int {
    let width = 32
    let height = 32
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
        return 0
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(
        in: NSRect(x: 0, y: 0, width: width, height: height),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    var opaquePixels = 0
    for y in 0..<height {
        for x in 0..<width {
            if let color = representation.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                opaquePixels += 1
            }
        }
    }
    return opaquePixels
}

@MainActor
func assertMenuMatchesModel(_ harness: Harness, _ label: String) {
    let model = harness.model
    expectEqual(harness.menu.items.count, model.items.count, "\(label): menu item count")

    for (index, expected) in model.items.enumerated() where index < harness.menu.items.count {
        let actual = harness.menu.items[index]

        if expected.role == .separator {
            expect(actual.isSeparatorItem, "\(label): item \(index) should be a separator")
            expect(!actual.isEnabled, "\(label): separator \(index) must be disabled")
            continue
        }

        expect(!actual.isSeparatorItem, "\(label): item \(index) should not be a separator")
        expectEqual(actual.title, expected.title, "\(label): item \(index) title")
        expectEqual(actual.isEnabled, expected.isEnabled, "\(label): item \(index) enabled state")
        expectEqual(actual.toolTip, expected.toolTip, "\(label): item \(index) tooltip")
        expectEqual(
            actual.state,
            expected.isChecked ? .on : .off,
            "\(label): item \(index) check state"
        )
        expect(actual.attributedTitle == nil, "\(label): action \(index) must be a plain native title")

        guard case .action = expected.role else {
            expect(false, "\(label): item \(index) must be an action or separator")
            continue
        }
        expect(actual.target === harness.controller, "\(label): action \(index) must target the controller")
        expect(actual.action != nil, "\(label): action \(index) must have a selector")
    }
}

@MainActor
func testFirstOpenHasNonemptyMenuAndVisibleStatusIcon() {
    let harness = Harness(state: TrayMenuState())

    expect(harness.statusItem.isVisible, "status item host must be made visible")
    expect(harness.statusItem.poppedMenus.isEmpty, "the menu must not open without a right click")
    expect(harness.menu.delegate === harness.controller, "controller must be the menu delegate")
    expectEqual(harness.menu.accessibilityLabel(), "Codex Reset Tray actions", "menu accessibility label")
    expect(
        harness.menu.accessibilityHelp()?.contains("Configuration and actions") == true,
        "menu accessibility help describes the actions-only surface"
    )
    expect(!harness.menu.autoenablesItems, "the controller owns item enablement")

    // The menu is populated before the first delegate callback, so the first
    // open can never show an empty NSMenu.
    expect(!harness.menu.items.isEmpty, "first-open menu must not be empty")
    expectEqual(harness.menu.items.count, harness.model.items.count, "initial item count")
    expectEqual(
        harness.menu.items.filter { !$0.isSeparatorItem }.count,
        8,
        "first-open menu must contain exactly the eight actions"
    )

    harness.controller.menuNeedsUpdate(harness.menu)
    expect(!harness.menu.items.isEmpty, "menu must be nonempty after menuNeedsUpdate")
    harness.controller.menuWillOpen(harness.menu)
    expect(!harness.menu.items.isEmpty, "menu must be nonempty on first open")
    expectEqual(harness.source.menuDidOpenCount, 1, "first open must trigger menuDidOpen")
    assertMenuMatchesModel(harness, "first open")

    expectEqual(
        harness.menu.items.last?.title,
        "Quit Codex Reset Tray",
        "Quit must be the final first-open row"
    )
    expect(harness.menu.items.last?.isEnabled == true, "Quit must be enabled on first open")

    guard let button = harness.statusItem.statusButton else {
        expect(false, "status button must exist")
        return
    }
    guard let image = button.image else {
        expect(false, "status button must have an image")
        return
    }

    expect(image.size.width > 0 && image.size.height > 0, "status icon must have a visible size")
    expect(image.isTemplate, "the app-derived status image is a menu-bar template")
    expectEqual(harness.controller.statusIconSource, .appIcon, "status icon source")
    expect(image.tiffRepresentation?.isEmpty == false, "status icon must contain image data")
    let opaquePixels = renderedOpaquePixelCount(image)
    expect(opaquePixels > 0, "status icon must render nontransparent pixels (got \(opaquePixels))")

    expectEqual(button.title, "", "status button does not draw a duplicate title")
    expectEqual(harness.controller.statusLabelView.text, harness.source.menuBarTitle, "status label text")
    expectEqual(
        button.toolTip,
        "Codex Reset Tray — \(harness.source.menuBarTitle). Left-click for details, right-click for actions.",
        "status tooltip"
    )
    expectEqual(
        button.accessibilityLabel(),
        TrayMenuModel.accessibilityDescription(for: harness.source.menuState),
        "status accessibility label"
    )
    expectEqual(
        button.accessibilityHelp(),
        "Click to show Codex usage details. Right-click to open the actions menu.",
        "status accessibility help"
    )
    expect(button.target === harness.controller, "status button must target the controller")
    expect(button.action != nil, "status button must have a click action")
    expectEqual(button.imagePosition, .imageOnly, "status image position")
    expectEqual(button.imageScaling, .scaleNone, "status image scaling")
    expectEqual(button.font?.pointSize, 11, "status font size")
}

@MainActor
func testActionsMenuHasNoInformationalRows() {
    let harness = Harness(state: populatedState())
    assertMenuMatchesModel(harness, "populated")

    expectEqual(
        harness.model.items.map(\.role),
        [
            .action(.toggleMenuBarUsage),
            .action(.enableNotifications),
            .action(.refresh),
            .action(.copyStatus),
            .action(.openWebsite),
            .action(.donate),
            .separator,
            .action(.about),
            .action(.quit),
        ],
        "right-click menu must contain only configuration, actions, and native separation"
    )
    expectEqual(
        harness.menu.items.filter { !$0.isSeparatorItem }.map(\.title),
        [
            "Show 7d Label",
            "Enable Notifications",
            "Refresh",
            "Copy Status Summary",
            "Open codexreset.org",
            "Support this project",
            "About Codex Reset Tray",
            "Quit Codex Reset Tray",
        ],
        "right-click menu must contain exactly the eight configuration/action titles"
    )

    let forbiddenFragments = [
        "7-day Codex usage",
        "Forecast",
        "Codex error",
        "Baseline",
        "Primary",
        "Secondary",
        "Latest confirmed reset",
        "denied in System Settings",
    ]
    for item in harness.menu.items where !item.isSeparatorItem {
        expect(item.isEnabled, "'\(item.title)' action must not be grayed out")
        expect(item.target === harness.controller, "'\(item.title)' must target the controller")
        expect(item.action != nil, "'\(item.title)' must have an action selector")
        expect(item.attributedTitle == nil, "'\(item.title)' must use a plain native title")
        for fragment in forbiddenFragments {
            expect(
                !item.title.contains(fragment),
                "actions menu must not contain informational title '\(item.title)'"
            )
        }
    }

    expectEqual(harness.item(for: .action(.refresh))?.title, "Refresh", "Refresh row")
    expectEqual(
        harness.item(for: .action(.enableNotifications))?.title,
        "Enable Notifications",
        "Enable Notifications row"
    )
    expectEqual(
        harness.item(for: .action(.enableNotifications))?.state,
        .on,
        "allowed notifications show the native check mark"
    )
    expectEqual(
        harness.item(for: .action(.openWebsite))?.title,
        "Open codexreset.org",
        "Open site row"
    )
    expectEqual(
        harness.item(for: .action(.about))?.title,
        "About Codex Reset Tray",
        "About row"
    )
    expectEqual(
        harness.item(for: .action(.quit))?.title,
        "Quit Codex Reset Tray",
        "Quit row"
    )
    expect(harness.item(for: .action(.quit))?.isEnabled == true, "Quit is enabled")
}

@MainActor
func testErrorDataStaysInPopoverAndActionsStayAvailable() {
    let codexMessage = "Codex app-server did not respond within 10 seconds."
    let codexHarness = Harness(
        state: TrayMenuState(
            snapshot: snapshot(),
            codexError: codexMessage,
            lastCodexCheck: runtimeNow
        )
    )
    assertMenuMatchesModel(codexHarness, "codex error")
    for item in codexHarness.menu.items where !item.isSeparatorItem {
        expect(!item.title.contains(codexMessage), "Codex error must not leak into the actions menu")
        expect(item.isEnabled, "actions must stay enabled in a Codex error state")
    }
    let codexInfo = TrayInfoModel.make(state: codexHarness.source.menuState)
    expectEqual(codexInfo.usageValue, "63%", "last known usage remains in the compact popover")
    expect(
        !String(describing: codexInfo).contains(codexMessage),
        "the removed Codex usage section must not leak its error into the popover"
    )

    let forecastMessage = "codexreset.org returned HTTP 503."
    let forecastHarness = Harness(
        state: TrayMenuState(forecastError: forecastMessage, lastForecastCheck: runtimeNow)
    )
    assertMenuMatchesModel(forecastHarness, "forecast error")
    for item in forecastHarness.menu.items where !item.isSeparatorItem {
        expect(!item.title.contains(forecastMessage), "forecast error must not leak into the actions menu")
        expect(item.isEnabled, "actions must stay enabled in a forecast error state")
    }
    let forecastInfo = TrayInfoModel.make(state: forecastHarness.source.menuState)
    expectEqual(forecastInfo.forecastState, .unavailable(error: forecastMessage),
                "forecast error belongs to the compact popover state")
    expectEqual(forecastInfo.forecastStatus?.tone, .error,
                "popover keeps the forecast error tone")

    let cachedHarness = Harness(
        state: TrayMenuState(
            snapshot: snapshot(),
            forecast: forecast(),
            forecastError: forecastMessage,
            lastForecastCheck: runtimeNow,
            lastForecastSuccess: runtimeNow.addingTimeInterval(-3600)
        )
    )
    assertMenuMatchesModel(cachedHarness, "cached forecast with fresh error")
    let cachedInfo = TrayInfoModel.make(state: cachedHarness.source.menuState)
    expectEqual(cachedInfo.forecastFigures.map(\.value), ["28%", "49%"],
                "cached probabilities stay visible in the popover")
    expect(
        cachedInfo.forecastStatus?.text.contains("Stale forecast · updated") == true,
        "cached forecast shows freshness in the popover"
    )
    expect(
        cachedInfo.forecastStatus?.text.contains(forecastMessage) == true,
        "fresh forecast error renders in the stale status line"
    )

    guard let image = codexHarness.statusItem.statusButton?.image else {
        expect(false, "error state must still have a status icon image")
        return
    }
    expect(
        renderedOpaquePixelCount(image) > 0,
        "error state status icon must still render nontransparent pixels"
    )
}

@MainActor
func testRefreshActionWiring() async {
    let harness = Harness(state: populatedState())
    guard let index = harness.index(of: .action(.refresh)),
          let item = harness.item(for: .action(.refresh)) else {
        expect(false, "Refresh row must exist")
        return
    }

    expect(item.isEnabled, "Refresh must be enabled")
    expectEqual(item.keyEquivalent, "r", "Refresh shortcut")
    expectEqual(item.keyEquivalentModifierMask, .command, "Refresh shortcut modifier")
    expect(item.action != nil, "Refresh must have an action selector")
    expect(item.target === harness.controller, "Refresh must target the controller")
    expectEqual(harness.source.refreshAllCount, 0, "Refresh should not run before invocation")

    // This goes through the real NSMenu dispatch path in NSApplication.
    harness.menu.performActionForItem(at: index)
    await waitUntil { harness.source.refreshAllCount == 1 }
    expectEqual(harness.source.refreshAllCount, 1, "Refresh must call refreshAll exactly once")
    expectEqual(harness.recorder.terminatedCount, 0, "Refresh must not terminate")
    expect(harness.recorder.openedURL == nil, "Refresh must not open a site")
}

@MainActor
func testOpenWebsiteActionWiring() {
    let harness = Harness(state: populatedState())
    guard let index = harness.index(of: .action(.openWebsite)),
          let item = harness.item(for: .action(.openWebsite)) else {
        expect(false, "Open site row must exist")
        return
    }

    expect(item.isEnabled, "Open site must be enabled")
    expectEqual(item.keyEquivalent, "", "Open site should have no shortcut")
    expectEqual(item.toolTip, "https://codexreset.org/", "Open site tooltip")
    expect(item.target === harness.controller, "Open site must target the controller")
    expect(item.action != nil, "Open site must have an action selector")

    harness.menu.performActionForItem(at: index)
    expectEqual(
        harness.recorder.openedURL,
        TrayMenuModel.websiteURL,
        "Open site must pass the project URL to the opener"
    )
    expectEqual(harness.recorder.terminatedCount, 0, "Open site must not terminate")
}

@MainActor
func testDonationActionWiring() {
    let destination = TrayMenuModel.donationURL
    let harness = Harness(state: populatedState())
    guard let index = harness.index(of: .action(.donate)),
          let item = harness.item(for: .action(.donate)) else {
        expect(false, "configured donation row must exist")
        return
    }
    expect(item.isEnabled, "donation row must be enabled")
    expect(item.target === harness.controller, "donation row must target controller")
    harness.menu.performActionForItem(at: index)
    expectEqual(harness.recorder.openedURL, destination,
                "donation action must open the configured URL")
    expectEqual(harness.recorder.terminatedCount, 0, "donation action must not terminate")
}

@MainActor
func testCopyStatusActionWiring() {
    let harness = Harness(state: populatedState())
    guard let index = harness.index(of: .action(.copyStatus)),
          let item = harness.item(for: .action(.copyStatus)) else {
        expect(false, "Copy Status Summary row must exist")
        return
    }

    expect(item.isEnabled, "Copy Status Summary must be enabled")
    expectEqual(item.keyEquivalent, "c", "Copy Status Summary shortcut")
    expectEqual(item.keyEquivalentModifierMask, .command, "Copy Status Summary shortcut modifier")
    expectEqual(
        item.toolTip,
        "Copy a privacy-safe status summary for a bug report.",
        "Copy Status Summary tooltip"
    )
    expect(item.target === harness.controller, "Copy Status Summary must target the controller")
    expect(item.action != nil, "Copy Status Summary must have an action selector")
    expect(harness.recorder.copiedText == nil, "Copy Status Summary should wait for invocation")

    harness.menu.performActionForItem(at: index)
    guard let copied = harness.recorder.copiedText else {
        expect(false, "Copy Status Summary must write text")
        return
    }
    expect(copied.contains("7-day Codex usage: 63%"), "copied summary usage")
    expect(copied.contains("Notifications are allowed."), "copied summary notifications")
    expect(!copied.contains("accountId"), "copied summary must not contain account IDs")
    expect(!copied.contains("/Users/"), "copied summary must not contain local paths")
    expectEqual(harness.recorder.terminatedCount, 0, "Copy Status Summary must not terminate")
    expect(harness.recorder.openedURL == nil, "Copy Status Summary must not open a site")
}

@MainActor
func testNotificationMenuItemStates() {
    let permissions: [TrayNotificationPermission] = [
        .unknown, .notDetermined, .denied, .allowed,
    ]
    for permission in permissions {
        var state = populatedState()
        state.notificationPermission = permission
        let harness = Harness(state: state)
        guard let item = harness.item(for: .action(.enableNotifications)) else {
            expect(false, "\(permission): Enable Notifications row must exist")
            continue
        }
        expectEqual(item.title, "Enable Notifications", "\(permission): notification title")
        expect(item.isEnabled, "\(permission): notification action stays enabled")
        expectEqual(
            item.state,
            permission.allowsDelivery ? .on : .off,
            "\(permission): notification check mark is on only when allowed"
        )
        expect(item.toolTip?.isEmpty == false, "\(permission): notification tooltip")
    }
}

@MainActor
func testNotificationActionRequestsWhenUndetermined() async {
    let harness = Harness(state: TrayMenuState(notificationPermission: .notDetermined))
    harness.source.notificationAuthorizationAfterRequest = .authorized
    guard let index = harness.index(of: .action(.enableNotifications)),
          let item = harness.item(for: .action(.enableNotifications)) else {
        expect(false, "Enable Notifications row must exist")
        return
    }

    expectEqual(item.state, .off, "undetermined permission starts unchecked")
    harness.menu.performActionForItem(at: index)
    await waitUntil { harness.source.requestNotificationAuthorizationCount == 1 }
    await waitUntil {
        harness.item(for: .action(.enableNotifications))?.state == .on
    }

    expectEqual(
        harness.source.requestNotificationAuthorizationCount,
        1,
        "undetermined click must call requestAuthorization exactly once"
    )
    expectEqual(
        harness.source.refreshNotificationAuthorizationCount,
        1,
        "the click checks current authorization before routing"
    )
    expect(harness.recorder.openedURL == nil, "a permission prompt must not also open settings")
    expectEqual(
        harness.item(for: .action(.enableNotifications))?.state,
        .on,
        "granted permission updates the native check mark"
    )
    expectEqual(harness.recorder.terminatedCount, 0, "notification action must not terminate")
}

@MainActor
func testNotificationActionOpensSettingsWhenDenied() async {
    let harness = Harness(state: TrayMenuState(notificationPermission: .denied))
    guard let index = harness.index(of: .action(.enableNotifications)) else {
        expect(false, "Enable Notifications row must exist")
        return
    }

    harness.menu.performActionForItem(at: index)
    await waitUntil { harness.recorder.openedURL != nil }

    expectEqual(
        harness.source.requestNotificationAuthorizationCount,
        0,
        "denied permission must never be requested again"
    )
    expectEqual(
        harness.recorder.openedURL,
        TrayMenuModel.notificationSettingsURL,
        "denied click opens System Settings > Notifications"
    )
    expectEqual(harness.source.refreshNotificationAuthorizationCount, 1, "denied click refreshes state")
}

@MainActor
func testNotificationActionOpensSettingsWhenAllowed() async {
    let harness = Harness(state: TrayMenuState(notificationPermission: .allowed))
    guard let index = harness.index(of: .action(.enableNotifications)) else {
        expect(false, "Enable Notifications row must exist")
        return
    }

    harness.menu.performActionForItem(at: index)
    await waitUntil { harness.recorder.openedURL != nil }

    expectEqual(
        harness.source.requestNotificationAuthorizationCount,
        0,
        "allowed permission must not be requested again"
    )
    expectEqual(
        harness.recorder.openedURL,
        TrayMenuModel.notificationSettingsURL,
        "allowed click keeps the checked item meaningful by opening settings"
    )
}

@MainActor
func testMenuOpeningRefreshesNotificationAuthorization() async {
    let harness = Harness(state: TrayMenuState(notificationPermission: .allowed))
    guard let item = harness.item(for: .action(.enableNotifications)) else {
        expect(false, "Enable Notifications row must exist")
        return
    }
    expectEqual(item.state, .on, "allowed permission starts checked")

    // Simulate a change made in System Settings while the app was inactive.
    harness.source.notificationAuthorization = .denied
    harness.controller.menuWillOpen(harness.menu)
    await waitUntil { item.state == .off }

    expectEqual(item.state, .off, "menu open must refresh the permission check mark")
    expectEqual(
        harness.source.refreshNotificationAuthorizationCount,
        1,
        "menu open refreshes authorization exactly once"
    )
    harness.controller.menuDidClose(harness.menu)
}

@MainActor
func testAppFocusRefreshesNotificationAuthorization() async {
    let harness = Harness(state: TrayMenuState(notificationPermission: .denied))
    guard let item = harness.item(for: .action(.enableNotifications)) else {
        expect(false, "Enable Notifications row must exist")
        return
    }
    expectEqual(item.state, .off, "denied permission starts unchecked")

    harness.source.notificationAuthorization = .authorized
    NotificationCenter.default.post(
        name: NSApplication.didBecomeActiveNotification,
        object: nil
    )
    await waitUntil {
        harness.item(for: .action(.enableNotifications))?.state == .on
    }

    expectEqual(
        harness.item(for: .action(.enableNotifications))?.state,
        .on,
        "app focus must refresh the permission check mark"
    )
    expectEqual(
        harness.source.refreshNotificationAuthorizationCount,
        1,
        "app focus refreshes authorization exactly once"
    )
}

@MainActor
func testAboutActionWiring() {
    let harness = Harness(state: populatedState())
    guard let index = harness.index(of: .action(.about)),
          let item = harness.item(for: .action(.about)) else {
        expect(false, "About row must exist")
        return
    }

    expectEqual(item.title, "About Codex Reset Tray", "About title")
    expect(item.isEnabled, "About must be enabled")
    expectEqual(item.keyEquivalent, "", "About must not have a shortcut")
    expectEqual(
        item.toolTip,
        "Show version, build, and copyright information.",
        "About tooltip"
    )
    expect(item.target === harness.controller, "About must target the controller")
    expect(item.action != nil, "About must have an action selector")
    expectEqual(harness.about.showCount, 0, "About must wait for invocation")

    harness.menu.performActionForItem(at: index)
    expectEqual(harness.about.showCount, 1, "About invokes the injected presenter exactly once")
    expect(harness.recorder.openedURL == nil, "About must not open a URL")
    expectEqual(harness.recorder.terminatedCount, 0, "About must not terminate")
}

@MainActor
func testAboutPanelOptionsUseBundleMetadata() {
    let icon = packagedAppIcon()
    let presenter = AboutPanelPresenter(appIconProvider: { icon })
    let options = presenter.panelOptions()

    expectEqual(
        options[.applicationName] as? String,
        AppBuildInfo.name,
        "About panel uses the bundle application name"
    )
    expectEqual(
        options[.applicationVersion] as? String,
        AppBuildInfo.version,
        "About panel uses the bundle version"
    )
    expectEqual(
        options[.version] as? String,
        AppBuildInfo.build,
        "About panel uses the bundle build"
    )
    if let icon {
        expect(
            (options[.applicationIcon] as? NSImage) === icon,
            "About panel uses the injected bundle icon"
        )
    } else {
        expect(false, "packaged app icon must load for the About panel test")
    }

    let withoutIcon = AboutPanelPresenter(appIconProvider: { nil }).panelOptions()
    expect(withoutIcon[.applicationIcon] == nil, "missing icon is omitted instead of forced")
}

@MainActor
func testMenuBarUsageToggleOffscreen() async {
    let harness = Harness(state: populatedState())
    guard let index = harness.index(of: .action(.toggleMenuBarUsage)),
          let toggle = harness.item(for: .action(.toggleMenuBarUsage)) else {
        expect(false, "7d label toggle row must exist")
        return
    }

    expectEqual(index, 0, "7d label toggle must be the first action, with no heading above it")
    expectEqual(toggle.title, "Show 7d Label", "toggle must always use the exact title")
    expect(toggle.isEnabled, "toggle must be enabled")
    expectEqual(toggle.state, .on, "usage label must be checked by default")
    expectEqual(toggle.keyEquivalent, "", "toggle must not have a shortcut")
    expect(toggle.target === harness.controller, "toggle must target the controller")
    expect(toggle.action != nil, "toggle must have an action selector")
    expect(toggle.toolTip?.contains("icon remains visible") == true, "hide tooltip")
    expectEqual(harness.controller.statusLabelView.text, "7d 63%", "usage text starts visible")

    // Mark the menu open so the action exercises the in-place update path used
    // while the real menu is being tracked.
    harness.controller.menuWillOpen(harness.menu)

    guard let visibleImage = harness.statusItem.button.image else {
        expect(false, "visible state must have a menu-bar icon")
        return
    }
    expect(harness.statusItem.isVisible, "status item must be visible while usage text is shown")
    expect(
        renderedOpaquePixelCount(visibleImage) > 0,
        "visible state icon must render nontransparent pixels"
    )

    // Exercise the real NSMenu action dispatch path with a checked native item.
    harness.menu.performActionForItem(at: index)
    expectEqual(harness.source.showsUsageInMenuBar, false, "toggle must hide usage text")
    expectEqual(harness.controller.statusLabelView.text, "", "hidden state must clear the menu-bar text")
    expectEqual(toggle.title, "Show 7d Label", "title must stay exact when the check mark clears")
    expectEqual(toggle.state, .off, "hidden state must clear the native check mark")
    expect(toggle.toolTip?.contains("icon is always visible") == true, "show tooltip")
    expect(harness.statusItem.isVisible, "status item must remain visible when text is hidden")
    guard let hiddenImage = harness.statusItem.button.image else {
        expect(false, "hidden state must keep the menu-bar icon")
        return
    }
    expect(hiddenImage.isTemplate, "hidden state icon remains a menu-bar template")
    expectEqual(
        hiddenImage.size,
        NSSize(width: TrayStatusLayout.iconSide, height: TrayStatusLayout.iconSide),
        "hidden state canvas must be the icon alone"
    )
    expect(
        renderedOpaquePixelCount(hiddenImage) > 0,
        "hidden state icon must still render nontransparent pixels"
    )
    expectEqual(
        harness.statusItem.button.toolTip,
        "Codex Reset Tray — usage text hidden in the menu bar. Left-click for details, right-click for actions.",
        "hidden state tooltip"
    )

    harness.menu.performActionForItem(at: index)
    expectEqual(harness.source.showsUsageInMenuBar, true, "second toggle must show usage text")
    expectEqual(harness.controller.statusLabelView.text, "7d 63%", "menu-bar text must return")
    expectEqual(toggle.title, "Show 7d Label", "title must stay exact when the check mark returns")
    expectEqual(toggle.state, .on, "shown state must restore the native check mark")
    expect(harness.statusItem.isVisible, "status item must remain visible after showing text again")
    guard let restoredImage = harness.statusItem.button.image else {
        expect(false, "restored state must keep the menu-bar icon")
        return
    }
    expect(
        renderedOpaquePixelCount(restoredImage) > 0,
        "restored state icon must render nontransparent pixels"
    )

    harness.controller.menuDidClose(harness.menu)
    assertMenuMatchesModel(harness, "after menu-bar toggle")
    await flushMainQueue()
    print("Menu-bar usage toggle offscreen checks passed: shown, hidden, icon retained")
}

@MainActor
func testMenuBarUsagePreferencePersistence() {
    let suite = "CodexResetTrayMenuBarTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        expect(false, "could not create test defaults")
        return
    }
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }

    let first = ResetStore(defaults: defaults)
    expect(first.showsUsageInMenuBar, "usage text must default to visible with no saved preference")
    expectEqual(first.menuBarTitle, "Codex", "default store menu-bar title")
    expect(defaults.object(forKey: MenuBarVisibilityStore.key) == nil, "default must not write a preference")

    first.setShowsUsageInMenuBar(false)
    expectEqual(first.showsUsageInMenuBar, false, "store must hide usage text")
    expectEqual(first.menuBarTitle, "", "hidden store menu-bar title")
    expectEqual(
        defaults.bool(forKey: MenuBarVisibilityStore.key),
        false,
        "hidden preference must persist in UserDefaults"
    )

    let restarted = ResetStore(defaults: defaults)
    expectEqual(restarted.showsUsageInMenuBar, false, "hidden preference must survive a store restart")
    expectEqual(restarted.menuBarTitle, "", "restarted hidden store menu-bar title")

    restarted.setShowsUsageInMenuBar(true)
    let shownAgain = ResetStore(defaults: defaults)
    expect(shownAgain.showsUsageInMenuBar, "visible preference must survive a store restart")
    expectEqual(shownAgain.menuBarTitle, "Codex", "restarted visible store menu-bar title")
    print("Menu-bar usage UserDefaults persistence checks passed")
}

@MainActor
func testForecastRecoveryAfterTemporaryFailure() async {
    var calls = 0
    let store = ResetStore(fetchForecast: {
        calls += 1
        if calls == 2 { throw ResetPage.FetchError.httpStatus(503) }
        return forecast()
    })
    await store.refreshForecast()
    let firstSuccess = store.lastForecastSuccess
    expect(firstSuccess != nil, "successful forecast records its update time")

    store.menuDidOpen()
    await waitUntil { store.forecastError != nil }
    expectEqual(calls, 2, "menu opening attempts a refresh")
    expect(store.forecast != nil, "failed refresh retains the cached forecast")
    expectEqual(store.lastForecastSuccess, firstSuccess, "failed refresh preserves cached freshness")
    expect(store.menuState.forecastError != nil, "failed refresh surfaces an error")

    store.menuDidOpen()
    await waitUntil { calls == 3 && store.forecastError == nil }
    expectEqual(calls, 3, "menu opening retries immediately after failure")
    expect(store.lastForecastSuccess != nil, "recovery records a successful update")
}

@MainActor
func testQuitActionWiring() {
    let harness = Harness(state: populatedState())
    guard let index = harness.index(of: .action(.quit)),
          let item = harness.item(for: .action(.quit)) else {
        expect(false, "Quit row must exist")
        return
    }

    expectEqual(index, harness.menu.items.count - 1, "Quit must remain the last item")
    expect(item.isEnabled, "Quit must be enabled")
    expectEqual(item.keyEquivalent, "q", "Quit shortcut")
    expectEqual(item.keyEquivalentModifierMask, .command, "Quit shortcut modifier")
    expect(item.target === harness.controller, "Quit must target the controller")
    expect(item.action != nil, "Quit must have an action selector")

    harness.menu.performActionForItem(at: index)
    expectEqual(
        harness.recorder.terminatedCount,
        1,
        "Quit must invoke the termination handler exactly once"
    )
    expect(harness.recorder.openedURL == nil, "Quit must not open a site")
}

@MainActor
func testOpenMenuUpdatesInPlaceAndCloseRebuilds() async {
    let harness = Harness(state: TrayMenuState())
    harness.controller.menuNeedsUpdate(harness.menu)
    harness.controller.menuWillOpen(harness.menu)

    guard let toggleBefore = harness.item(for: .action(.toggleMenuBarUsage)),
          let firstItemBefore = harness.menu.items.first else {
        expect(false, "initial menu rows must exist")
        return
    }
    let oldTitle = toggleBefore.title
    let oldCount = harness.menu.items.count

    harness.source.setShowsUsageInMenuBar(false)
    expectEqual(toggleBefore.title, oldTitle, "open menu must not mutate before the main queue runs")

    // menuNeedsUpdate is ignored while open; the queued publisher update must
    // edit the existing items instead of replacing the open item list.
    harness.controller.menuNeedsUpdate(harness.menu)
    expectEqual(toggleBefore.title, oldTitle, "menuNeedsUpdate must be ignored while open")

    await flushMainQueue()
    expectEqual(harness.menu.items.count, oldCount, "open menu item count must stay stable")
    expect(harness.menu.items.first === firstItemBefore, "open menu items must not be replaced")
    expect(harness.item(for: .action(.toggleMenuBarUsage)) === toggleBefore,
           "open toggle row identity")
    expectEqual(
        toggleBefore.title,
        harness.model.item(withRole: .action(.toggleMenuBarUsage))?.title,
        "open toggle row must update in place"
    )
    expectEqual(toggleBefore.title, "Show 7d Label", "open toggle keeps the exact title while hidden")
    expectEqual(toggleBefore.state, .off, "open toggle clears its check mark in place")

    harness.controller.menuDidClose(harness.menu)
    assertMenuMatchesModel(harness, "after close")
}

@MainActor
func testSystemSchedulerRegistersForegroundDelegateAndSchedules() async {
    let center = StubUserNotificationCenter(status: .authorized)
    let presentation = NotificationPresentationDelegate()
    let scheduler = SystemNotificationScheduler(center: center, presentationDelegate: presentation)

    expect(center.delegate === presentation, "scheduler must install the foreground presentation delegate")
    expect(presentation.options.contains(.banner), "foreground delegate must present a banner")
    expect(presentation.options.contains(.sound), "foreground delegate must present sound")

    let scheduled = await scheduler.schedule(resetAlert(timing: .scheduled))
    expectEqual(scheduled, .scheduled, "authorized scheduling succeeds")
    expectEqual(center.requestAuthorizationCallCount, 0, "already granted permission must not be requested again")
    expectEqual(center.addedRequests.count, 1, "scheduled request reaches the system center")

    guard let scheduledContent = center.addedRequests.first?.content else {
        expect(false, "scheduled request should carry content")
        return
    }
    expectEqual(scheduledContent.title, "Codex 7-day quota reset", "scheduled reset title")
    expect(scheduledContent.body.contains("80%"), "scheduled body carries prior usage")
    expect(scheduledContent.body.contains("6%"), "scheduled body carries current usage")
    expect(scheduledContent.body.contains("scheduled to reset"), "scheduled body explains the normal rollover")

    let early = await scheduler.schedule(resetAlert(timing: .early))
    expectEqual(early, .scheduled, "authorized early scheduling succeeds")
    expectEqual(center.requestAuthorizationCallCount, 0, "scheduling never re-prompts once authorized")
    guard center.addedRequests.count == 2 else {
        expect(false, "both notification requests should be recorded")
        return
    }
    let earlyContent = center.addedRequests[1].content
    expectEqual(earlyContent.title, "Codex 7-day quota restored early", "early reset title")
    expect(earlyContent.body.contains("not due to reset until"), "early body explains the early reset")
}

@MainActor
func testSystemSchedulerRequestsOnlyWhenUndecided() async {
    let deniedCenter = StubUserNotificationCenter(
        status: .notDetermined,
        statusAfterRequest: .denied
    )
    let deniedScheduler = SystemNotificationScheduler(
        center: deniedCenter,
        presentationDelegate: NotificationPresentationDelegate()
    )
    let deniedResult = await deniedScheduler.schedule(resetAlert())
    expectEqual(
        deniedResult,
        .notAuthorized(.notDetermined),
        "scheduling with undecided permission does not prompt"
    )
    expectEqual(
        deniedCenter.requestAuthorizationCallCount,
        0,
        "scheduling must never request permission"
    )
    expectEqual(deniedCenter.addedRequests.count, 0, "undecided permission must not add a request")

    let explicitDenial = await deniedScheduler.requestAuthorization()
    expectEqual(explicitDenial, .denied, "the explicit request prompts and returns denial")
    expectEqual(
        deniedCenter.requestAuthorizationCallCount,
        1,
        "undecided permission is requested exactly once by the menu action"
    )

    let grantedCenter = StubUserNotificationCenter(
        status: .notDetermined,
        statusAfterRequest: .authorized
    )
    let grantedScheduler = SystemNotificationScheduler(
        center: grantedCenter,
        presentationDelegate: NotificationPresentationDelegate()
    )
    let grantedAuthorization = await grantedScheduler.requestAuthorization()
    expectEqual(grantedAuthorization, .authorized, "explicit request grants permission")
    let grantedResult = await grantedScheduler.schedule(resetAlert())
    expectEqual(grantedResult, .scheduled, "scheduling after the menu grant succeeds")
    expectEqual(
        grantedCenter.requestAuthorizationCallCount,
        1,
        "scheduling after a decision never asks again"
    )
    expectEqual(grantedCenter.addedRequests.count, 1, "granted permission adds the request")
}

@MainActor
func testSystemSchedulerReportsSanitizedErrorDomainAndCode() async {
    let unreadableDomain = NSError(
        domain: "/Users/private/UNErrorDomain",
        code: 42,
        userInfo: [NSLocalizedDescriptionKey: "local bundle path must not leak"]
    )
    let requestCenter = StubUserNotificationCenter(
        status: .notDetermined,
        requestError: unreadableDomain
    )
    let requestScheduler = SystemNotificationScheduler(
        center: requestCenter,
        presentationDelegate: NotificationPresentationDelegate()
    )
    let authorization = await requestScheduler.requestAuthorization()
    expectEqual(
        authorization,
        .error("_Users_private_UNErrorDomain code 42"),
        "authorization error keeps the sanitized NSError domain and code"
    )
    expect(
        authorization.explanation.contains("/Users/") == false,
        "authorization diagnostic must not expose a file path"
    )

    let addCenter = StubUserNotificationCenter(
        status: .authorized,
        addError: NSError(domain: "UNErrorDomain", code: 7)
    )
    let addScheduler = SystemNotificationScheduler(
        center: addCenter,
        presentationDelegate: NotificationPresentationDelegate()
    )
    let delivery = await addScheduler.schedule(resetAlert())
    expectEqual(delivery, .failed("UNErrorDomain code 7"), "add error keeps the NSError domain and code")
}

@MainActor
func testScheduledResetSchedulesNotification() async {
    let (defaults, suite) = makeStoreDefaults("scheduled-reset")
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldDeadline = Date().addingTimeInterval(-60)
    let nextDeadline = oldDeadline.addingTimeInterval(7 * 86_400)
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 80, resetsAt: oldDeadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: nextDeadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: nextDeadline)),
    ])
    let scheduler = StubNotificationScheduler()
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()
    expectEqual(store.baseline?.usedPercent, 80, "startup baseline adopts pre-reset usage")
    expectEqual(scheduler.scheduleCallCount, 0, "startup must not notify")

    await store.pollCodex()
    expectEqual(scheduler.scheduleCallCount, 1, "scheduled rollover schedules a notification")
    expectEqual(scheduler.scheduledAlerts.first?.timing, .scheduled, "store carries scheduled timing")
    expectEqual(store.baseline?.usedPercent, 6, "scheduled success adopts the new window")
    expectEqual(store.baseline?.alertedResetsAt, oldDeadline, "scheduled success marks the old deadline")
    expect(store.lastNotificationScheduledAt != nil, "scheduled request time is recorded")
    expect(
        store.notificationStatus?.contains("Visual delivery depends on macOS") == true,
        "status distinguishes scheduling from visual delivery"
    )

    await store.pollCodex()
    expectEqual(scheduler.scheduleCallCount, 1, "the next poll in the same window must not duplicate")
}

@MainActor
func testZeroUsageScheduledRolloverSchedulesNotification() async {
    let (defaults, suite) = makeStoreDefaults("zero-usage-scheduled-reset")
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldDeadline = Date().addingTimeInterval(-60)
    let nextDeadline = oldDeadline.addingTimeInterval(7 * 86_400)
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 0, resetsAt: oldDeadline)),
        .success(weeklySnapshot(usedPercent: 0, resetsAt: nextDeadline)),
        .success(weeklySnapshot(usedPercent: 0, resetsAt: nextDeadline)),
    ])
    let scheduler = StubNotificationScheduler()
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()
    expectEqual(store.baseline?.usedPercent, 0, "startup baseline adopts zero pre-reset usage")
    expectEqual(scheduler.scheduleCallCount, 0, "startup must not notify a zero-usage baseline")

    await store.pollCodex()
    expectEqual(
        scheduler.scheduleCallCount,
        1,
        "zero-usage scheduled rollover schedules a notification"
    )
    expectEqual(
        scheduler.scheduledAlerts.first?.timing,
        .scheduled,
        "store carries scheduled timing for zero prior usage"
    )
    expectEqual(
        scheduler.scheduledAlerts.first?.previousPercent,
        0,
        "zero-usage notification keeps the prior reading"
    )
    expectEqual(store.baseline?.usedPercent, 0, "zero-usage success adopts the new window")
    expectEqual(store.baseline?.resetsAt, nextDeadline, "zero-usage success adopts the new deadline")
    expectEqual(
        store.baseline?.alertedResetsAt,
        oldDeadline,
        "zero-usage success marks the old deadline"
    )

    await store.pollCodex()
    expectEqual(
        scheduler.scheduleCallCount,
        1,
        "the next poll in the zero-usage window must not duplicate"
    )
}

@MainActor
func testNotificationFailureRetriesAndCommitsOnlyAfterSuccess() async {
    let (defaults, suite) = makeStoreDefaults("notification-retry")
    defer { defaults.removePersistentDomain(forName: suite) }
    let deadline = Date().addingTimeInterval(86_400)
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 80, resetsAt: deadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: deadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: deadline)),
    ])
    let scheduler = StubNotificationScheduler(
        scheduleResults: [.failed("simulated scheduling failure"), .scheduled]
    )
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()
    expectEqual(store.baseline?.usedPercent, 80, "first poll establishes the session baseline")
    expectEqual(
        scheduler.requestAuthorizationCallCount,
        0,
        "the first usage fetch must not prompt for notification permission"
    )
    let authorization = await store.refreshNotificationAuthorization()
    expectEqual(authorization, .authorized, "read-only authorization refresh succeeds")
    expectEqual(store.notificationStatus, "Notifications are allowed.", "diagnostic status is available")
    expectEqual(
        scheduler.requestAuthorizationCallCount,
        0,
        "a read-only authorization refresh must never prompt"
    )

    await store.pollCodex()
    expectEqual(store.baseline?.usedPercent, 80, "scheduling failure keeps the pre-reset evidence")
    expect(store.baseline?.alertedResetsAt == nil, "failure must not persist an alert marker")
    expect(store.lastNotificationScheduledAt == nil, "failure must not claim a notification was scheduled")
    expect(store.notificationStatusIsError, "scheduling failure must be visible")
    expect(
        store.notificationStatus?.contains("Could not schedule") == true,
        "scheduling failure status text"
    )
    expectEqual(scheduler.scheduleCallCount, 1, "first restoration attempts scheduling once")
    let failedPersisted = BaselineStore(defaults: defaults).load()
    expectEqual(failedPersisted?.usedPercent, 80, "failure keeps the persisted pre-reset baseline")
    expect(failedPersisted?.alertedResetsAt == nil, "failure persists no alert marker")

    await store.pollCodex()
    expectEqual(store.baseline?.usedPercent, 6, "successful scheduling adopts the current reading")
    expectEqual(store.baseline?.alertedResetsAt, deadline, "success commits the per-deadline marker")
    expect(store.lastNotificationScheduledAt != nil, "success records the scheduled request time")
    expect(!store.notificationStatusIsError, "success is not an error state")
    expectEqual(scheduler.scheduleCallCount, 2, "failed scheduling is retried")

    let persisted = BaselineStore(defaults: defaults).load()
    expectEqual(persisted?.usedPercent, 6, "committed usage is persisted")
    expectEqual(
        persisted?.alertedResetsAt.map { Int($0.timeIntervalSince1970.rounded()) },
        Int(deadline.timeIntervalSince1970.rounded()),
        "committed marker is persisted"
    )

    let alerts = scheduler.scheduledAlerts
    expectEqual(alerts.count, 2, "both attempts used the same restoration evidence")
    expectEqual(alerts.first?.previousPercent, 80, "retry keeps prior usage")
    expectEqual(alerts.first?.currentPercent, 6, "retry keeps post-reset usage")
}

@MainActor
func testDeniedNotificationDoesNotCommitMarker() async {
    let (defaults, suite) = makeStoreDefaults("notification-denied")
    defer { defaults.removePersistentDomain(forName: suite) }
    let deadline = Date().addingTimeInterval(86_400)
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 80, resetsAt: deadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: deadline)),
    ])
    let scheduler = StubNotificationScheduler(
        authorization: .denied,
        requestResults: [.denied],
        scheduleResults: [.notAuthorized(.denied)]
    )
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()
    await store.pollCodex()

    expectEqual(store.baseline?.usedPercent, 80, "denial preserves the pre-reset evidence")
    expect(store.baseline?.alertedResetsAt == nil, "denial must not commit an alert marker")
    expect(store.lastNotificationScheduledAt == nil, "denial must not claim a notification was scheduled")
    expect(store.notificationStatusIsError, "denial must be visible")
    expect(
        store.notificationStatus?.contains("denied in System Settings") == true,
        "denial status must explain the system setting"
    )
    expectEqual(scheduler.scheduleCallCount, 1, "denied delivery was attempted once")
    expectEqual(
        scheduler.requestAuthorizationCallCount,
        0,
        "denied permission must not be requested again"
    )
}

@MainActor
func testUndecidedPermissionIsNotPromptedAutomatically() async {
    let (defaults, suite) = makeStoreDefaults("authorization-undecided")
    defer { defaults.removePersistentDomain(forName: suite) }
    let deadline = Date().addingTimeInterval(86_400)
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 80, resetsAt: deadline)),
        .success(weeklySnapshot(usedPercent: 80, resetsAt: deadline)),
    ])
    let scheduler = StubNotificationScheduler(
        authorization: .notDetermined,
        requestResults: [.denied]
    )
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()
    await store.pollCodex()
    expectEqual(
        scheduler.requestAuthorizationCallCount,
        0,
        "Codex polling must never prompt for notification permission"
    )
    expect(store.notificationAuthorization == nil, "launch does not cache authorization")
    expect(store.notificationStatus == nil, "launch does not invent a permission status")

    // The explicit menu route is the only request path.
    let status = await store.requestNotificationAuthorization()
    expectEqual(status, .denied, "explicit request returns the user's decision")
    expectEqual(
        scheduler.requestAuthorizationCallCount,
        1,
        "the menu action requests permission exactly once"
    )
    expectEqual(store.notificationAuthorization, .denied, "request result is cached for the check mark")
    expect(
        store.notificationStatus?.contains("denied in System Settings") == true,
        "denied diagnostic status remains available for the copied summary"
    )
}

@MainActor
func testUndecidedResetSchedulingDoesNotPrompt() async {
    let (defaults, suite) = makeStoreDefaults("authorization-scheduling-undecided")
    defer { defaults.removePersistentDomain(forName: suite) }
    let deadline = Date().addingTimeInterval(86_400)
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 80, resetsAt: deadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: deadline)),
    ])
    let scheduler = StubNotificationScheduler(
        authorization: .notDetermined,
        requestResults: [.authorized],
        scheduleResults: [.notAuthorized(.notDetermined)]
    )
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()
    await store.pollCodex()

    expectEqual(scheduler.scheduleCallCount, 1, "the reset still attempts scheduling")
    expectEqual(
        scheduler.requestAuthorizationCallCount,
        0,
        "scheduling a reset must not prompt for permission"
    )
    expectEqual(store.baseline?.usedPercent, 80, "unscheduled reset preserves the pre-reset evidence")
    expect(store.baseline?.alertedResetsAt == nil, "unscheduled reset commits no marker")
    expect(
        store.notificationStatus?.contains("not determined") == true,
        "the diagnostic report records the undecided permission"
    )
}

@MainActor
func testStartupHistoricalStateDoesNotAlert() async {
    let (defaults, suite) = makeStoreDefaults("startup-historical")
    defer { defaults.removePersistentDomain(forName: suite) }
    let deadline = Date().addingTimeInterval(86_400)
    BaselineStore(defaults: defaults).save(
        WeeklyUsageBaseline(
            usedPercent: 80,
            resetsAt: deadline,
            capturedAt: Date().addingTimeInterval(-600),
            alertedResetsAt: nil
        )
    )
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 6, resetsAt: deadline)),
    ])
    let scheduler = StubNotificationScheduler()
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()

    expectEqual(store.baseline?.usedPercent, 6, "startup adopts the current reading")
    expect(store.baseline?.alertedResetsAt == nil, "startup does not mark an alert")
    expect(store.lastNotificationScheduledAt == nil, "startup does not alert on historical state")
    expectEqual(scheduler.scheduleCallCount, 0, "startup must not schedule a notification")
}

@MainActor
func testStartupScheduledResetDoesNotAlert() async {
    let (defaults, suite) = makeStoreDefaults("startup-scheduled-reset")
    defer { defaults.removePersistentDomain(forName: suite) }
    let oldDeadline = Date().addingTimeInterval(-60)
    let nextDeadline = oldDeadline.addingTimeInterval(7 * 86_400)
    BaselineStore(defaults: defaults).save(
        WeeklyUsageBaseline(
            usedPercent: 80,
            resetsAt: oldDeadline,
            capturedAt: Date().addingTimeInterval(-600),
            alertedResetsAt: nil
        )
    )
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 6, resetsAt: nextDeadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: nextDeadline)),
    ])
    let scheduler = StubNotificationScheduler()
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()
    await store.pollCodex()

    expectEqual(store.baseline?.usedPercent, 6, "startup adopts current post-reset usage")
    expectEqual(store.baseline?.resetsAt, nextDeadline, "startup adopts the new deadline")
    expect(store.lastNotificationScheduledAt == nil, "historical scheduled reset must not notify")
    expectEqual(scheduler.scheduleCallCount, 0, "historical scheduled reset must not schedule")
}

@MainActor
func testAuthorizationRequestErrorIsVisible() async {
    let (defaults, suite) = makeStoreDefaults("authorization-error")
    defer { defaults.removePersistentDomain(forName: suite) }
    let deadline = Date().addingTimeInterval(86_400)
    let fetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 80, resetsAt: deadline)),
    ])
    let scheduler = StubNotificationScheduler(
        authorization: .notDetermined,
        requestResults: [.error("UNErrorDomain code 1")]
    )
    let store = ResetStore(defaults: defaults, notifications: scheduler, fetchRateLimits: {
        try fetcher.next()
    })

    await store.pollCodex()
    expectEqual(
        scheduler.requestAuthorizationCallCount,
        0,
        "launch must not prompt even when authorization cannot be checked later"
    )

    let status = await store.requestNotificationAuthorization()
    expectEqual(
        status,
        .error("UNErrorDomain code 1"),
        "explicit request reports the sanitized system error"
    )
    expect(store.notificationStatusIsError, "authorization request error must be visible")
    expect(
        store.notificationStatus?.contains("UNErrorDomain code 1") == true,
        "authorization request error includes the sanitized NSError domain and code"
    )
    expectEqual(scheduler.requestAuthorizationCallCount, 1, "explicit menu request runs once")
    expectEqual(scheduler.scheduleCallCount, 0, "authorization failure cannot schedule")
}

@MainActor
func testAlertMarkerSurvivesRestart() async {
    let (defaults, suite) = makeStoreDefaults("marker-restart")
    defer { defaults.removePersistentDomain(forName: suite) }
    let deadline = Date().addingTimeInterval(86_400)
    let firstFetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 80, resetsAt: deadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: deadline)),
    ])
    let firstScheduler = StubNotificationScheduler()
    let firstStore = ResetStore(defaults: defaults, notifications: firstScheduler, fetchRateLimits: {
        try firstFetcher.next()
    })
    await firstStore.pollCodex()
    await firstStore.pollCodex()
    expectEqual(firstStore.baseline?.alertedResetsAt, deadline, "setup commits the marker")

    let restartedFetcher = StubRateLimitFetcher([
        .success(weeklySnapshot(usedPercent: 6, resetsAt: deadline)),
        .success(weeklySnapshot(usedPercent: 6, resetsAt: deadline)),
    ])
    let restartedScheduler = StubNotificationScheduler()
    let restarted = ResetStore(defaults: defaults, notifications: restartedScheduler, fetchRateLimits: {
        try restartedFetcher.next()
    })
    await restarted.pollCodex()
    await restarted.pollCodex()

    expectEqual(
        restarted.baseline?.alertedResetsAt.map { Int($0.timeIntervalSince1970.rounded()) },
        Int(deadline.timeIntervalSince1970.rounded()),
        "marker survives restart"
    )
    expect(restarted.lastNotificationScheduledAt == nil, "restart does not resend an already handled alert")
    expectEqual(restartedScheduler.scheduleCallCount, 0, "restart must not duplicate the alert")
}

func snapshot() -> CodexRateLimitSnapshot {
    CodexRateLimitSnapshot(
        ordinaryUsageAllowed: true,
        primary: CodexRateLimitWindow(
            usedPercent: 40,
            windowDurationMins: 300,
            resetsAt: runtimeNow.addingTimeInterval(3_600)
        ),
        secondary: CodexRateLimitWindow(
            usedPercent: 63,
            windowDurationMins: 10_080,
            resetsAt: runtimeNow.addingTimeInterval(86_400)
        ),
        observedAt: runtimeNow
    )
}

func baseline() -> WeeklyUsageBaseline {
    WeeklyUsageBaseline(
        usedPercent: 72,
        resetsAt: runtimeNow.addingTimeInterval(86_400),
        capturedAt: runtimeNow.addingTimeInterval(-600),
        alertedResetsAt: nil
    )
}

func forecast() -> ResetSnapshot {
    ResetSnapshot(
        resetAt: runtimeNow.addingTimeInterval(-1_800),
        resetStatus: "Quota restored",
        restorationStatus: "Monitored account: 75% → 100%.",
        probability24h: 28,
        probability48h: 49,
        forecastSummary: "28% within 24 hours, 49% within 48 hours, based on recent resets."
    )
}

func populatedState() -> TrayMenuState {
    TrayMenuState(
        snapshot: snapshot(),
        baseline: baseline(),
        lastNotificationScheduledAt: runtimeNow.addingTimeInterval(-900),
        notificationStatus: "Notifications are allowed.",
        forecast: forecast(),
        lastCodexCheck: runtimeNow,
        lastForecastCheck: runtimeNow,
        notificationPermission: .allowed
    )
}

@main
struct TrayMenuRuntimeTests {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--live-status-item") {
            runLiveStatusItemCheck()
            if runtimeFailures > 0 { exit(1) }
            writeLiveStatus(
                "Real NSStatusItem left-click popover, live update, right-click "
                    + "popover-close/menu-open, control-left menu-open, second-click close, "
                    + "outside-click close, and actions-only menu checks passed under "
                    + "NSApplication.run()"
            )
            return
        }
        // Required only so NSMenu can dispatch menu-item actions through the
        // application object. The application is never launched or activated.
        let application = NSApplication.shared
        expect(!application.isRunning, "test harness must not run the application")
        expect(application.windows.isEmpty, "test harness must not display windows")

        testFirstOpenHasNonemptyMenuAndVisibleStatusIcon()
        testActionsMenuHasNoInformationalRows()
        testErrorDataStaysInPopoverAndActionsStayAvailable()
        await testRefreshActionWiring()
        testCopyStatusActionWiring()
        testNotificationMenuItemStates()
        await testNotificationActionRequestsWhenUndetermined()
        await testNotificationActionOpensSettingsWhenDenied()
        await testNotificationActionOpensSettingsWhenAllowed()
        await testMenuOpeningRefreshesNotificationAuthorization()
        await testAppFocusRefreshesNotificationAuthorization()
        testAboutActionWiring()
        testAboutPanelOptionsUseBundleMetadata()
        testOpenWebsiteActionWiring()
        testDonationActionWiring()
        await testMenuBarUsageToggleOffscreen()
        testMenuBarUsagePreferencePersistence()
        await testForecastRecoveryAfterTemporaryFailure()
        testQuitActionWiring()
        await testOpenMenuUpdatesInPlaceAndCloseRebuilds()
        await testSystemSchedulerRegistersForegroundDelegateAndSchedules()
        await testSystemSchedulerRequestsOnlyWhenUndecided()
        await testSystemSchedulerReportsSanitizedErrorDomainAndCode()
        await testScheduledResetSchedulesNotification()
        await testZeroUsageScheduledRolloverSchedulesNotification()
        await testNotificationFailureRetriesAndCommitsOnlyAfterSuccess()
        await testDeniedNotificationDoesNotCommitMarker()
        await testUndecidedPermissionIsNotPromptedAutomatically()
        await testUndecidedResetSchedulingDoesNotPrompt()
        await testStartupHistoricalStateDoesNotAlert()
        await testStartupScheduledResetDoesNotAlert()
        await testAuthorizationRequestErrorIsVisible()
        await testAlertMarkerSurvivesRestart()
        await runStatusRuntimeTests()

        expect(!application.isRunning, "tests must leave the application unlaunched")
        expect(application.windows.allSatisfy { !$0.isVisible }, "tests must not display windows")

        if runtimeFailures > 0 {
            FileHandle.standardError.write(
                Data("\(runtimeFailures) AppKit runtime test assertion(s) failed\n".utf8)
            )
            exit(1)
        }
        print("Tray menu AppKit runtime integration tests passed")
        print(
            "Scope: offscreen NSMenu/NSMenuItem wiring, synthetic click events, and an "
                + "offscreen info view and unshown event window with a non-running NSApplication; "
                + "no NSStatusItem, popover, or screen observation."
        )
    }
}
