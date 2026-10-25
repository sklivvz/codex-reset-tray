import AppKit
import Foundation

// Offscreen tests for the status icon, the icon-label spacing, the click
// mapping, and the information window. Compiled together with
// TrayMenuRuntimeTests.swift, which owns main() and the shared harness. Nothing
// here creates an NSStatusItem or an NSWindow; clicks are synthetic NSEvents
// delivered to an unmounted NSButton, and the information window is exercised
// through an injected presenter plus the NSView that fills it.

/// Renders `image` into an offscreen RGBA bitmap `points` large at `scale`x.
@MainActor
func renderBitmap(_ image: NSImage, points: NSSize, scale: Int = 2) -> NSBitmapImageRep? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(points.width) * scale,
        pixelsHigh: Int(points.height) * scale,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: representation) else {
        return nil
    }
    representation.size = points
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(
        in: NSRect(origin: .zero, size: points),
        from: .zero,
        operation: .sourceOver,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
    )
    NSGraphicsContext.restoreGraphicsState()
    return representation
}

/// Mean absolute RGBA difference (0...255) over the top-left `width` x `height`
/// pixels of two same-format bitmaps.
func meanPixelDifference(
    _ lhs: NSBitmapImageRep,
    _ rhs: NSBitmapImageRep,
    width: Int,
    height: Int
) -> Double {
    guard let left = lhs.bitmapData, let right = rhs.bitmapData else { return .infinity }
    var total = 0
    for y in 0..<height {
        for x in 0..<width {
            for channel in 0..<4 {
                let a = Int(left[y * lhs.bytesPerRow + x * 4 + channel])
                let b = Int(right[y * rhs.bytesPerRow + x * 4 + channel])
                total += abs(a - b)
            }
        }
    }
    return Double(total) / Double(width * height * 4)
}

/// WCAG contrast between `foreground`, resolved under `appearance`, and an
/// opaque sRGB `background` (0...1 per channel).
@MainActor
func contrastRatio(
    _ foreground: NSColor,
    on background: (Double, Double, Double),
    appearance: NSAppearance.Name
) -> Double {
    func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }
    var resolved: NSColor?
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
        resolved = foreground.usingColorSpace(.sRGB)
    }
    guard let color = resolved else { return 0 }
    let fg = luminance(Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    let bg = luminance(background.0, background.1, background.2)
    return (max(fg, bg) + 0.05) / (min(fg, bg) + 0.05)
}

func rowTitle(_ state: TrayMenuState, _ role: TrayMenuItemRole) -> String {
    TrayMenuModel.make(state: state).item(withRole: role)?.title ?? "<missing \(role)>"
}

func state(weeklyPercent: Double) -> TrayMenuState {
    var next = populatedState()
    next.snapshot = CodexRateLimitSnapshot(
        ordinaryUsageAllowed: true,
        primary: nil,
        secondary: CodexRateLimitWindow(
            usedPercent: weeklyPercent,
            windowDurationMins: 10_080,
            resetsAt: runtimeNow.addingTimeInterval(86_400)
        ),
        observedAt: runtimeNow
    )
    return next
}

@MainActor
func testErrorColorIsReadableInLightAndDark() {
    // Approximate light and dark menu/window backgrounds.
    let light = contrastRatio(TrayPalette.error, on: (0.93, 0.93, 0.93), appearance: .aqua)
    let dark = contrastRatio(TrayPalette.error, on: (0.17, 0.17, 0.17), appearance: .darkAqua)
    expect(light >= 4.5, "error text needs WCAG AA contrast on light backgrounds (got \(light))")
    expect(dark >= 4.5, "error text needs WCAG AA contrast on dark backgrounds (got \(dark))")
    let stock = contrastRatio(NSColor.systemOrange, on: (0.93, 0.93, 0.93), appearance: .aqua)
    expect(stock < 4.5, "sanity: the previous systemOrange fails AA on light (got \(stock))")
}

@MainActor
func testOnlyUnavailableControlsAreDisabled() {
    let states: [(String, TrayMenuState)] = [
        ("empty", TrayMenuState()),
        ("populated", populatedState()),
        ("codex error", TrayMenuState(snapshot: snapshot(), codexError: "boom")),
        ("forecast error", TrayMenuState(forecastError: "HTTP 503")),
        ("hidden label", TrayMenuState(showsUsageInMenuBar: false)),
    ]
    for (label, state) in states {
        let harness = Harness(state: state)
        for (index, item) in harness.model.items.enumerated() where item.role != .separator {
            expect(
                harness.menu.items[index].isEnabled,
                "\(label): row \(index) '\(item.title)' must not be grayed out"
            )
        }
        for role in [TrayMenuItemRole.codexStatus, .codexWindows, .codexMeta, .forecastSummary, .forecastDetail] {
            expect(
                harness.item(for: role)?.isEnabled == true,
                "\(label): \(role) must render in the normal label color"
            )
        }
    }
}

@MainActor
func testStatusIconMatchesPackagedAppIcon() {
    guard let appIcon = packagedAppIcon() else {
        expect(false, "Resources/AppIcon.icns must load from \(packagedAppIconURL.path)")
        return
    }
    let harness = Harness(state: populatedState(), appIcon: appIcon)
    guard let image = harness.statusItem.button.image else {
        expect(false, "status button must have an image")
        return
    }
    expectEqual(harness.controller.statusIconSource, .appIcon, "icon must derive from the app icon")
    expect(!image.isTemplate, "app-icon status image must not be a template")

    let side = TrayStatusLayout.iconSide
    let pixels = Int(side) * 2
    guard let status = renderBitmap(image, points: image.size),
          let reference = renderBitmap(appIcon, points: NSSize(width: side, height: side)) else {
        expect(false, "could not render status icon and reference offscreen")
        return
    }
    let difference = meanPixelDifference(status, reference, width: pixels, height: pixels)
    expect(difference < 1.0, "status icon must match AppIcon.icns pixels (mean difference \(difference))")

    // It is also colored, like the packaged icon: the blue gradient, not a
    // monochrome template glyph.
    var blueDominant = 0
    for y in 0..<pixels {
        for x in 0..<pixels {
            if let color = status.colorAt(x: x, y: y), color.alphaComponent > 0.9,
               color.blueComponent > color.redComponent + 0.2 {
                blueDominant += 1
            }
        }
    }
    expect(blueDominant > 100, "status icon must carry the app icon's blue gradient (got \(blueDominant))")

    // The comparison must be able to fail: the SF Symbol fallback is far away.
    let fallback = Harness(state: populatedState(), appIcon: nil)
    expectEqual(fallback.controller.statusIconSource, .systemSymbol, "fallback icon source")
    guard let fallbackImage = fallback.statusItem.button.image,
          let fallbackBitmap = renderBitmap(fallbackImage, points: fallbackImage.size) else {
        expect(false, "fallback status image must exist")
        return
    }
    let fallbackDifference = meanPixelDifference(fallbackBitmap, reference, width: pixels, height: pixels)
    expect(
        fallbackDifference > 5 * max(difference, 0.5),
        "symbol fallback must differ from AppIcon.icns (difference \(fallbackDifference))"
    )
    expect(fallbackImage.isTemplate, "symbol fallback remains a template image")
    expect(renderedOpaquePixelCount(fallbackImage) > 0, "symbol fallback renders pixels")
}

@MainActor
func testBundledAppIconLookup() {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("CodexResetTrayBundleTest-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let app = root.appendingPathComponent("Test.app", isDirectory: true)
    let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
    do {
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": "test.codex-reset-tray.icon",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
    } catch {
        expect(false, "could not build the test bundle: \(error)")
        return
    }

    guard let bundle = Bundle(url: app) else {
        expect(false, "test bundle must load")
        return
    }
    expect(TrayStatusIcon.bundledAppIcon(bundle: bundle) == nil, "bundle without an icon yields nil")

    do {
        try fileManager.copyItem(at: packagedAppIconURL, to: resources.appendingPathComponent("AppIcon.icns"))
    } catch {
        expect(false, "could not copy AppIcon.icns into the test bundle: \(error)")
        return
    }
    guard let loaded = TrayStatusIcon.bundledAppIcon(bundle: bundle) else {
        expect(false, "bundledAppIcon must load Contents/Resources/AppIcon.icns")
        return
    }
    expect(loaded.size.width > 0 && loaded.size.height > 0, "bundled icon has a size")
    expect(renderedOpaquePixelCount(loaded) > 0, "bundled icon renders pixels")
}

@MainActor
func testIconLabelSpacingIsCompact() {
    expectEqual(TrayStatusLayout.labelGap, 4, "icon-label gap must be a compact 4pt")

    let states: [(String, TrayMenuState)] = [
        ("7d 9%", state(weeklyPercent: 9)),
        ("7d 63%", state(weeklyPercent: 63)),
        ("7d 100%", state(weeklyPercent: 100)),
        ("no usage yet", TrayMenuState()),
    ]
    for (label, state) in states {
        let harness = Harness(state: state)
        let button = harness.statusItem.button
        let text = harness.source.menuBarTitle
        let labelWidth = TrayStatusLayout.labelWidth(for: text)
        guard let image = button.image else {
            expect(false, "\(label): status image must exist")
            continue
        }
        expectEqual(
            image.size.width,
            TrayStatusLayout.iconSide + TrayStatusLayout.labelGap + labelWidth,
            "\(label): canvas is icon + 4pt + label"
        )

        // Lay the button out at its canvas width and measure the real gap
        // between the icon's right edge and the label's left edge.
        button.frame = NSRect(x: 0, y: 0, width: image.size.width, height: 22)
        button.layoutSubtreeIfNeeded()
        let labelView = harness.controller.statusLabelView
        expect(!labelView.isHidden, "\(label): label must be visible")
        expectEqual(labelView.text, text, "\(label): label text")
        let gap = labelView.frame.minX - TrayStatusLayout.iconRect(in: image.size).maxX
        expect(abs(gap - 4) < 0.5, "\(label): measured icon-label gap must be 4pt (got \(gap))")
        expect(
            labelView.frame.maxX <= image.size.width + 0.5,
            "\(label): label must fit in the canvas"
        )
        expect(labelView.hitTest(NSPoint(x: 1, y: 1)) == nil, "\(label): label must not swallow clicks")
    }
}

@MainActor
func testHiddenLabelKeepsIconAndRemovesGap() async {
    let harness = Harness(state: populatedState())
    let button = harness.statusItem.button
    let shownWidth = button.image?.size.width ?? 0
    harness.controller.menuWillOpen(harness.menu)

    guard let index = harness.index(of: .action(.toggleMenuBarUsage)) else {
        expect(false, "toggle must exist")
        return
    }
    harness.menu.performActionForItem(at: index)

    expect(harness.controller.statusLabelView.isHidden, "hidden preference must hide the label view")
    expectEqual(button.title, "", "hidden preference clears the title")
    guard let hidden = button.image else {
        expect(false, "hidden preference must keep the icon")
        return
    }
    expectEqual(hidden.size.width, TrayStatusLayout.iconSide, "no label means no reserved gap")
    expect(hidden.size.width < shownWidth, "hidden canvas is narrower than the shown canvas")
    expect(harness.statusItem.isVisible, "status item stays visible")
    expect(renderedOpaquePixelCount(hidden) > 0, "icon still renders")

    harness.menu.performActionForItem(at: index)
    expect(!harness.controller.statusLabelView.isHidden, "showing the label restores the view")
    expectEqual(button.image?.size.width ?? 0, shownWidth, "canvas returns to icon + gap + label")
    harness.controller.menuDidClose(harness.menu)
    await flushMainQueue()
}

func testClickClassification() {
    expectEqual(TrayStatusClick.classify(type: .leftMouseUp, modifiers: []), .primary, "left click")
    expectEqual(TrayStatusClick.classify(type: .leftMouseDown, modifiers: []), .primary, "left down")
    expectEqual(TrayStatusClick.classify(type: .rightMouseUp, modifiers: []), .secondary, "right click")
    expectEqual(TrayStatusClick.classify(type: .rightMouseDown, modifiers: []), .secondary, "right down")
    expectEqual(
        TrayStatusClick.classify(type: .leftMouseUp, modifiers: [.control]),
        .secondary,
        "control-click is a right click"
    )
    expectEqual(TrayStatusClick.classify(nil), .primary, "no event defaults to the info window")
}

@MainActor
func testLeftClickOpensInfoWindowAndRightClickOpensMenu() async {
    let harness = Harness(state: populatedState())
    let button = harness.statusItem.button
    expect(button.target === harness.controller, "button targets controller")
    let secondaryClick = harness.controller.secondaryClickRecognizer
    expect(secondaryClick != nil, "secondary-click recognizer must be installed")
    expect(
        button.gestureRecognizers.contains { $0 === secondaryClick },
        "status button must own the secondary-click recognizer"
    )
    expectEqual(secondaryClick?.buttonMask, 0x2, "recognizer listens to the right mouse button")
    expect(secondaryClick?.target === harness.controller, "recognizer targets controller")
    expectEqual(
        secondaryClick?.action,
        #selector(TrayMenuController.statusItemSecondaryClicked(_:)),
        "recognizer calls the secondary-click action"
    )

    // Left click: information window, no menu.
    harness.click(.leftMouseUp)
    expectEqual(harness.info.shown.count, 1, "left click must show the info window once")
    expectEqual(harness.info.shown.first, TrayInfoModel.make(state: populatedState()), "info window model")
    expect(harness.statusItem.poppedMenus.isEmpty, "left click must not open the menu")
    expectEqual(harness.source.menuDidOpenCount, 1, "left click must request a fresh forecast")
    expect(harness.controller.isInfoWindowShown, "info window reports shown")

    // A second left click closes it again.
    harness.click(.leftMouseUp)
    expectEqual(harness.info.hideCount, 1, "second left click must hide the info window")
    expect(!harness.controller.isInfoWindowShown, "info window reports hidden")
    expect(harness.statusItem.poppedMenus.isEmpty, "still no menu")

    // Right click: actions menu, no window.
    harness.click(.rightMouseUp)
    expectEqual(harness.statusItem.poppedMenus.count, 1, "right click must open the menu once")
    expect(harness.statusItem.poppedMenus.first === harness.menu, "right click opens the actions menu")
    expectEqual(harness.info.shown.count, 1, "right click must not show the info window")
    assertMenuMatchesModel(harness, "after right click")

    // Control-click behaves as a right click.
    harness.click(.leftMouseUp, modifiers: [.control])
    expectEqual(harness.statusItem.poppedMenus.count, 2, "control-click must open the menu")
    expectEqual(harness.info.shown.count, 1, "control-click must not show the info window")

    // Menu operations still work after the new click handling.
    guard let quit = harness.index(of: .action(.quit)) else {
        expect(false, "Quit must exist")
        return
    }
    harness.menu.performActionForItem(at: quit)
    expectEqual(harness.recorder.terminatedCount, 1, "Quit still terminates")
    await flushMainQueue()
}

@MainActor
func testRightClickShowsCurrentMenuContent() async {
    let harness = Harness(state: TrayMenuState())
    harness.source.setState(populatedState())
    // No main-queue turn has run, so only the right-click path can have
    // refreshed the menu.
    harness.click(.rightMouseUp)
    assertMenuMatchesModel(harness, "right click with pending state")
    expect(
        harness.item(for: .codexStatus)?.title.contains("63%") == true,
        "menu opened by right click must show the latest usage"
    )
    await flushMainQueue()
}

@MainActor
func testInfoWindowTracksSourceUpdates() async {
    let harness = Harness(state: TrayMenuState())

    // Hidden window: source changes must not touch the presenter.
    harness.source.setState(populatedState())
    await flushMainQueue()
    expect(harness.info.updates.isEmpty, "no updates while the window is hidden")

    harness.click(.leftMouseUp)
    expectEqual(harness.info.shown.last, TrayInfoModel.make(state: populatedState()), "opened with latest data")

    // Usage and forecast change while the window is open.
    let errorState = TrayMenuState(
        snapshot: snapshot(),
        codexError: "Codex app-server did not respond within 10 seconds.",
        forecastError: "codexreset.org returned HTTP 503.",
        lastCodexCheck: runtimeNow
    )
    harness.source.setState(errorState)
    expect(harness.info.updates.isEmpty, "window must not change before the main queue runs")
    await flushMainQueue()
    expectEqual(harness.info.updates.last, TrayInfoModel.make(state: errorState), "window follows the source")

    // Toggling the label from the menu also reaches the open window.
    guard let toggle = harness.index(of: .action(.toggleMenuBarUsage)) else {
        expect(false, "toggle must exist")
        return
    }
    harness.menu.performActionForItem(at: toggle)
    await flushMainQueue()
    expect(
        harness.info.updates.last?.footer.contains("Menu bar 7d label: hidden") == true,
        "window reflects the hidden label preference"
    )

    harness.click(.leftMouseUp)
    let updatesAfterHide = harness.info.updates.count
    harness.source.setState(populatedState())
    await flushMainQueue()
    expectEqual(harness.info.updates.count, updatesAfterHide, "no updates after the window is closed")
}

@MainActor
func testInfoViewRendersOffscreen() {
    let application = NSApplication.shared
    let windowsBefore = application.windows.count
    let populated = populatedState()
    let view = TrayInfoView(appIcon: packagedAppIcon())

    view.update(with: TrayInfoModel.make(state: populated))
    let texts = view.renderedTexts
    for expected in [
        "Codex Reset Tray",
        "63%",
        "7-day Codex usage",
        "Codex usage",
        "Reset forecast",
        rowTitle(populated, .codexStatus),
        rowTitle(populated, .codexWindows),
        rowTitle(populated, .forecastSummary),
        rowTitle(populated, .forecastDetail),
        "Menu bar 7d label: shown",
    ] {
        expect(texts.contains(expected), "info view must show '\(expected)' (got \(texts))")
    }
    expect(view.meterFraction.map { abs($0 - 0.63) < 0.001 } == true, "meter shows 63%")
    expectEqual(view.fittingSize.width, TrayInfoView.contentWidth, "info view width")
    expect(view.fittingSize.height > 150, "info view must size to its content (got \(view.fittingSize.height))")

    // Offscreen render: real pixels, no window.
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    if let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: representation)
        var painted = 0
        for y in stride(from: 0, to: representation.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: representation.pixelsWide, by: 2) {
                if let color = representation.colorAt(x: x, y: y), color.alphaComponent > 0.01 {
                    painted += 1
                }
            }
        }
        expect(painted > 0, "info view must paint pixels offscreen")
    } else {
        expect(false, "info view must provide an offscreen bitmap")
    }

    // Normal rows use the label color; none is secondary/disabled gray.
    for text in texts {
        guard let field = view.field(showing: text) else { continue }
        expect(
            colorsEqual(field.textColor, .labelColor) || colorsEqual(field.textColor, TrayPalette.error),
            "'\(text)' must use the label or error color, not a gray"
        )
    }

    // Errors: readable error color, text intact, last-known data still present.
    let codexMessage = "Codex error: Codex app-server did not respond within 10 seconds."
    let errorState = TrayMenuState(
        snapshot: snapshot(),
        codexError: "Codex app-server did not respond within 10 seconds.",
        forecastError: "codexreset.org returned HTTP 503."
    )
    view.update(with: TrayInfoModel.make(state: errorState))
    for message in [codexMessage, "Forecast error: codexreset.org returned HTTP 503."] {
        guard let field = view.field(showing: message) else {
            expect(false, "info view must show error '\(message)'")
            continue
        }
        expect(
            colorsEqual(field.textColor, TrayPalette.error),
            "error '\(message)' must use the readable error color"
        )
    }

    // Unknown usage: placeholder headline, no meter, stale rows replaced.
    view.update(with: TrayInfoModel.make(state: TrayMenuState()))
    expect(view.renderedTexts.contains("--"), "unknown usage headline")
    expect(view.meterFraction == nil, "meter hidden without a 7-day window")
    expect(!view.renderedTexts.contains(codexMessage), "old rows are replaced")
    expectEqual(view.updateCount, 3, "view update count")

    expectEqual(application.windows.count, windowsBefore, "rendering the info view must not create a window")
}

@MainActor
func testInfoWindowPresenterIsLazy() {
    let application = NSApplication.shared
    let windowsBefore = application.windows.count
    let presenter = TrayInfoWindowPresenter(appIconProvider: { nil })
    expect(!presenter.isShown, "a new presenter shows nothing")
    presenter.update(TrayInfoModel.make(state: TrayMenuState()))
    presenter.hide()
    expect(!presenter.isShown, "update/hide before show stay hidden")
    expectEqual(application.windows.count, windowsBefore, "presenter must not create a window until shown")
}

@MainActor
func runStatusRuntimeTests() async {
    testErrorColorIsReadableInLightAndDark()
    testOnlyUnavailableControlsAreDisabled()
    testStatusIconMatchesPackagedAppIcon()
    testBundledAppIconLookup()
    testIconLabelSpacingIsCompact()
    await testHiddenLabelKeepsIconAndRemovesGap()
    testClickClassification()
    await testLeftClickOpensInfoWindowAndRightClickOpensMenu()
    await testRightClickShowsCurrentMenuContent()
    await testInfoWindowTracksSourceUpdates()
    testInfoViewRendersOffscreen()
    testInfoWindowPresenterIsLazy()
}
