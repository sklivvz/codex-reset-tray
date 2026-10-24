import AppKit
import Combine
import Foundation

// This executable is an offscreen AppKit integration test. It constructs the
// real TrayMenuController around a fake menu source and an unmounted NSButton.
// It never creates an NSStatusItem, shows a window, activates the application,
// starts a run loop, or launches the app bundle.
//
// NSApplication.shared is instantiated only because NSMenu dispatches item
// actions through the application object; -run and -finishLaunching are never
// called. On a command-line process its activation policy is .prohibited, so
// no Dock tile or UI is created.

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

    init(state: TrayMenuState) {
        self.state = state
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

    func menuDidOpen() {
        menuDidOpenCount += 1
    }

    func refreshAll() async {
        refreshAllCount += 1
    }
}

@MainActor
final class FakeStatusItemHost: TrayStatusItemHost {
    var isVisible = false
    var menu: NSMenu?
    let button = NSButton()
    var statusButton: NSButton? { button }
}

@MainActor
final class ActionRecorder {
    var terminatedCount = 0
    var openedURL: URL?
    var copiedText: String?
}

@MainActor
final class Harness {
    let source: FakeTraySource
    let statusItem = FakeStatusItemHost()
    let menu = NSMenu()
    let recorder = ActionRecorder()
    private(set) var controller: TrayMenuController!

    init(state: TrayMenuState) {
        source = FakeTraySource(state: state)
        controller = TrayMenuController(
            source: source,
            statusItem: statusItem,
            menu: menu,
            terminate: { [recorder] in recorder.terminatedCount += 1 },
            openURL: { [recorder] in recorder.openedURL = $0 },
            writeToPasteboard: { [recorder] in recorder.copiedText = $0 }
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

        if case .action = expected.role {
            expect(actual.target === harness.controller, "\(label): action \(index) must target the controller")
            expect(actual.action != nil, "\(label): action \(index) must have a selector")
        } else {
            expect(actual.target == nil, "\(label): non-action \(index) must not have a target")
            expect(actual.action == nil, "\(label): non-action \(index) must not have an action")
        }

        switch expected.tone {
        case .error:
            let color = actual.attributedTitle?.attribute(
                .foregroundColor,
                at: 0,
                effectiveRange: nil
            ) as? NSColor
            expect(
                colorsEqual(color, .systemOrange),
                "\(label): error row \(index) must render with the orange error color"
            )
        case .normal:
            if expected.role == .heading {
                let font = actual.attributedTitle?.attribute(
                    .font,
                    at: 0,
                    effectiveRange: nil
                ) as? NSFont
                expect(font != nil, "\(label): heading \(index) must use an attributed title")
            } else {
                expect(
                    actual.attributedTitle == nil,
                    "\(label): normal row \(index) must use a plain title"
                )
            }
        }
    }
}

@MainActor
func testFirstOpenHasNonemptyMenuAndVisibleStatusIcon() {
    let harness = Harness(state: TrayMenuState())

    expect(harness.statusItem.isVisible, "status item host must be made visible")
    expect(harness.statusItem.menu === harness.menu, "status item must own the controller menu")
    expect(harness.menu.delegate === harness.controller, "controller must be the menu delegate")
    expectEqual(harness.menu.accessibilityLabel(), "Codex Reset Tray menu", "menu accessibility label")
    expect(!harness.menu.autoenablesItems, "the controller owns item enablement")
    expectEqual(harness.menu.minimumWidth, 340, "menu minimum width")

    // The menu is populated before the first delegate callback, so the first
    // open can never show an empty NSMenu.
    expect(!harness.menu.items.isEmpty, "first-open menu must not be empty")
    expectEqual(harness.menu.items.count, harness.model.items.count, "initial item count")

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
    expect(image.isTemplate, "status icon must be a template image")
    expect(image.tiffRepresentation?.isEmpty == false, "status icon must contain image data")
    let opaquePixels = renderedOpaquePixelCount(image)
    expect(opaquePixels > 0, "status icon must render nontransparent pixels (got \(opaquePixels))")

    expectEqual(button.title, harness.source.menuBarTitle, "status button title")
    expectEqual(
        button.toolTip,
        "Codex Reset Tray — \(harness.source.menuBarTitle). Click for usage, forecast, and actions.",
        "status tooltip"
    )
    expectEqual(
        button.accessibilityLabel(),
        TrayMenuModel.accessibilityDescription(for: harness.source.menuState),
        "status accessibility label"
    )
    expectEqual(
        button.accessibilityHelp(),
        "Open the Codex Reset Tray menu.",
        "status accessibility help"
    )
    expectEqual(button.imagePosition, .imageLeading, "status image position")
    expectEqual(button.imageScaling, .scaleProportionallyDown, "status image scaling")
    expectEqual(button.font?.pointSize, 11, "status font size")
}

@MainActor
func testForecastStatusAndMetaRows() {
    let harness = Harness(state: populatedState())
    assertMenuMatchesModel(harness, "populated")

    guard let status = harness.item(for: .codexStatus),
          let windows = harness.item(for: .codexWindows),
          let meta = harness.item(for: .codexMeta),
          let summary = harness.item(for: .forecastSummary),
          let detail = harness.item(for: .forecastDetail) else {
        expect(false, "populated menu is missing expected rows")
        return
    }

    expect(status.title.contains("7-day Codex usage: 63%"), "status row weekly percentage")
    expect(status.title.contains("resets"), "status row reset deadline")
    expect(windows.title.contains("Primary 5-hour: 40%"), "primary usage row")
    expect(windows.title.contains("Secondary 7-day: 63%"), "secondary usage row")
    expect(meta.title.hasPrefix("Baseline: 72%"), "baseline row")
    expect(meta.toolTip?.contains("Ordinary usage allowed: yes") == true, "usage permission tooltip")
    expect(meta.toolTip?.contains("Codex read at") == true, "read time tooltip")
    expect(meta.toolTip?.contains("Early-restoration alert sent at") == true, "alert tooltip")
    expect(meta.toolTip?.contains("Notifications are allowed.") == true, "notification status tooltip")

    expect(summary.title.contains("28% within 24h"), "24-hour forecast row")
    expect(summary.title.contains("49% within 48h"), "48-hour forecast row")
    expect(summary.toolTip == forecast().forecastSummary, "forecast summary tooltip")
    expect(detail.title.contains("Latest restoration"), "forecast detail row")
    expect(detail.title.contains("Quota restored"), "forecast restoration status")

    expectEqual(harness.item(for: .action(.refresh))?.title, "Refresh", "Refresh row")
    expectEqual(
        harness.item(for: .action(.openWebsite))?.title,
        "Open codexreset.org",
        "Open site row"
    )
    expectEqual(
        harness.item(for: .action(.quit))?.title,
        "Quit Codex Reset Tray",
        "Quit row"
    )
    expect(harness.item(for: .action(.quit))?.isEnabled == true, "Quit is enabled")
}

@MainActor
func testErrorRows() {
    let codexMessage = "Codex app-server did not respond within 10 seconds."
    let codexHarness = Harness(
        state: TrayMenuState(
            snapshot: snapshot(),
            codexError: codexMessage,
            lastCodexCheck: runtimeNow
        )
    )
    assertMenuMatchesModel(codexHarness, "codex error")
    let codexStatus = codexHarness.item(for: .codexStatus)
    expect(codexStatus?.title.contains("Codex error: \(codexMessage)") == true, "Codex error row title")
    expect(codexStatus?.isEnabled == false, "Codex error row is informational")
    expect(
        codexHarness.item(for: .codexWindows)?.title.contains("63%") == true,
        "last known usage remains visible beside a Codex error"
    )
    expect(
        codexHarness.item(for: .action(.quit))?.isEnabled == true,
        "Quit remains enabled in a Codex error state"
    )

    let forecastMessage = "codexreset.org returned HTTP 503."
    let forecastHarness = Harness(
        state: TrayMenuState(forecastError: forecastMessage, lastForecastCheck: runtimeNow)
    )
    assertMenuMatchesModel(forecastHarness, "forecast error")
    let forecastSummary = forecastHarness.item(for: .forecastSummary)
    expect(
        forecastSummary?.title.contains("Forecast error: \(forecastMessage)") == true,
        "forecast error row title"
    )
    expect(forecastSummary?.isEnabled == false, "forecast error row is informational")
    expect(
        forecastHarness.item(for: .action(.quit))?.isEnabled == true,
        "Quit remains enabled in a forecast error state"
    )

    let cachedHarness = Harness(
        state: TrayMenuState(
            snapshot: snapshot(),
            forecast: forecast(),
            forecastError: forecastMessage,
            lastForecastCheck: runtimeNow
        )
    )
    assertMenuMatchesModel(cachedHarness, "cached forecast with fresh error")
    expect(
        cachedHarness.item(for: .forecastSummary)?.title.contains("28% within 24h") == true,
        "cached probabilities stay visible"
    )
    expect(
        cachedHarness.item(for: .forecastDetail)?.title.contains(forecastMessage) == true,
        "fresh forecast error renders on the detail row"
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
    expect(copied.contains("Notifications: Notifications are allowed."), "copied summary notifications")
    expect(!copied.contains("accountId"), "copied summary must not contain account IDs")
    expect(!copied.contains("/Users/"), "copied summary must not contain local paths")
    expectEqual(harness.recorder.terminatedCount, 0, "Copy Status Summary must not terminate")
    expect(harness.recorder.openedURL == nil, "Copy Status Summary must not open a site")
}

@MainActor
func testMenuBarUsageToggleOffscreen() async {
    let harness = Harness(state: populatedState())
    guard let index = harness.index(of: .action(.toggleMenuBarUsage)),
          let toggle = harness.item(for: .action(.toggleMenuBarUsage)) else {
        expect(false, "Show Usage in Menu Bar row must exist")
        return
    }

    expectEqual(toggle.title, "Show Usage in Menu Bar", "toggle title")
    expect(toggle.isEnabled, "toggle must be enabled")
    expectEqual(toggle.state, .on, "usage text must be checked by default")
    expectEqual(toggle.keyEquivalent, "", "toggle must not have a shortcut")
    expect(toggle.target === harness.controller, "toggle must target the controller")
    expect(toggle.action != nil, "toggle must have an action selector")
    expectEqual(harness.statusItem.button.title, "7d 63%", "usage text starts visible")

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
    expectEqual(harness.statusItem.button.title, "", "hidden state must clear the menu-bar text")
    expectEqual(
        harness.item(for: .action(.toggleMenuBarUsage))?.state,
        .off,
        "hidden state must clear the native check mark"
    )
    expect(harness.statusItem.isVisible, "status item must remain visible when text is hidden")
    guard let hiddenImage = harness.statusItem.button.image else {
        expect(false, "hidden state must keep the menu-bar icon")
        return
    }
    expect(hiddenImage.isTemplate, "hidden state icon must remain a template image")
    expect(
        renderedOpaquePixelCount(hiddenImage) > 0,
        "hidden state icon must still render nontransparent pixels"
    )
    expectEqual(
        harness.statusItem.button.toolTip,
        "Codex Reset Tray — usage text hidden in the menu bar. Click for usage, forecast, and actions.",
        "hidden state tooltip"
    )

    harness.menu.performActionForItem(at: index)
    expectEqual(harness.source.showsUsageInMenuBar, true, "second toggle must show usage text")
    expectEqual(harness.statusItem.button.title, "7d 63%", "menu-bar text must return")
    expectEqual(
        harness.item(for: .action(.toggleMenuBarUsage))?.state,
        .on,
        "shown state must restore the native check mark"
    )
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

    guard let statusBefore = harness.item(for: .codexStatus),
          let firstItemBefore = harness.menu.items.first else {
        expect(false, "initial menu rows must exist")
        return
    }
    let oldTitle = statusBefore.title
    let oldCount = harness.menu.items.count

    harness.source.setState(populatedState())
    expectEqual(statusBefore.title, oldTitle, "open menu must not mutate before the main queue runs")

    // menuNeedsUpdate is ignored while open; the queued publisher update must
    // edit the existing items instead of replacing the open item list.
    harness.controller.menuNeedsUpdate(harness.menu)
    expectEqual(statusBefore.title, oldTitle, "menuNeedsUpdate must be ignored while open")

    await flushMainQueue()
    expectEqual(harness.menu.items.count, oldCount, "open menu item count must stay stable")
    expect(harness.menu.items.first === firstItemBefore, "open menu items must not be replaced")
    expect(harness.item(for: .codexStatus) === statusBefore, "open status row identity")
    expectEqual(
        statusBefore.title,
        harness.model.item(withRole: .codexStatus)?.title,
        "open status row must update in place"
    )

    harness.controller.menuDidClose(harness.menu)
    assertMenuMatchesModel(harness, "after close")
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
        lastAlertAt: runtimeNow.addingTimeInterval(-900),
        notificationStatus: "Notifications are allowed.",
        forecast: forecast(),
        lastCodexCheck: runtimeNow,
        lastForecastCheck: runtimeNow
    )
}

@main
struct TrayMenuRuntimeTests {
    @MainActor
    static func main() async {
        // Required only so NSMenu can dispatch menu-item actions through the
        // application object. The application is never launched or activated.
        let application = NSApplication.shared
        expect(!application.isRunning, "test harness must not run the application")
        expect(application.windows.isEmpty, "test harness must not create windows")

        testFirstOpenHasNonemptyMenuAndVisibleStatusIcon()
        testForecastStatusAndMetaRows()
        testErrorRows()
        await testRefreshActionWiring()
        testCopyStatusActionWiring()
        testOpenWebsiteActionWiring()
        await testMenuBarUsageToggleOffscreen()
        testMenuBarUsagePreferencePersistence()
        testQuitActionWiring()
        await testOpenMenuUpdatesInPlaceAndCloseRebuilds()

        expect(!application.isRunning, "tests must leave the application unlaunched")
        expect(application.windows.isEmpty, "tests must not create windows")

        if runtimeFailures > 0 {
            FileHandle.standardError.write(
                Data("\(runtimeFailures) AppKit runtime test assertion(s) failed\n".utf8)
            )
            exit(1)
        }
        print("Tray menu AppKit runtime integration tests passed")
        print(
            "Scope: offscreen NSMenu/NSMenuItem wiring with a non-running NSApplication; "
                + "no NSStatusItem, click, window, or screen observation."
        )
    }
}
