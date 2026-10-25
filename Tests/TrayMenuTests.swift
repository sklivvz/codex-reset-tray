import Foundation

var menuTestFailures = 0
let menuTestNow = Date(timeIntervalSince1970: 1_800_000_000)

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        menuTestFailures += 1
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    if actual != expected {
        menuTestFailures += 1
        FileHandle.standardError.write(
            Data("FAIL line \(line): \(message) (got \(actual), expected \(expected))\n".utf8)
        )
    }
}

@main
struct TrayMenuTests {
    static func main() {
        testQuitAndRequiredActionsAreAlwaysAvailable()
        testMenuStructureIsStable()
        testForecastRendering()
        testForecastErrorRendering()
        testCachedForecastAndFreshErrorBothRender()
        testCodexErrorRendering()
        testLoadingRendering()
        testWebsiteURL()
        testMenuBarUsageToggleModel()
        testCopyStatusSummary()
        testAccessibilityDescription()

        if menuTestFailures > 0 {
            FileHandle.standardError.write(Data("\(menuTestFailures) menu test assertion(s) failed\n".utf8))
            exit(1)
        }
        print("Tray menu model tests passed")
    }

    private static func testQuitAndRequiredActionsAreAlwaysAvailable() {
        let states: [(String, TrayMenuState)] = [
            ("empty", TrayMenuState()),
            ("polling", TrayMenuState(isPollingCodex: true, isFetchingForecast: true)),
            ("codex error", TrayMenuState(codexError: "Codex app-server is unavailable.")),
            ("forecast error", TrayMenuState(forecastError: "codexreset.org returned HTTP 503.")),
            ("populated", TrayMenuState(snapshot: snapshot(), forecast: forecast())),
        ]

        for (label, state) in states {
            let model = TrayMenuModel.make(state: state)

            guard let quit = model.item(withRole: .action(.quit)) else {
                expect(false, "\(label): Quit must always be in the menu")
                continue
            }
            expectEqual(quit.title, "Quit Codex Reset Tray", "\(label): Quit title")
            expect(quit.isEnabled, "\(label): Quit must always be enabled")
            expectEqual(model.items.last?.role, .action(.quit), "\(label): Quit must remain the last item")

            expect(
                model.item(withRole: .action(.refresh))?.isEnabled == true,
                "\(label): Refresh must be available"
            )
            expect(
                model.item(withRole: .action(.copyStatus))?.isEnabled == true,
                "\(label): Copy Status Summary must be available"
            )
            let toggle = model.item(withRole: .action(.toggleMenuBarUsage))
            expectEqual(toggle?.title, "Show Usage in Menu Bar", "\(label): menu-bar usage toggle title")
            expect(toggle?.isEnabled == true, "\(label): menu-bar usage toggle must be enabled")
            expectEqual(
                toggle?.isChecked,
                state.showsUsageInMenuBar,
                "\(label): menu-bar usage toggle checked state"
            )
            let website = model.item(withRole: .action(.openWebsite))
            expectEqual(website?.title, "Open codexreset.org", "\(label): website action title")
            expect(website?.isEnabled == true, "\(label): website action must be enabled")
        }
    }

    private static func testMenuStructureIsStable() {
        // The AppKit controller updates item titles in place while the menu is
        // open. A state change must never add or remove rows.
        let states = [
            TrayMenuState(),
            TrayMenuState(isPollingCodex: true, isFetchingForecast: true),
            TrayMenuState(snapshot: snapshot(), forecast: forecast()),
            TrayMenuState(codexError: "Codex unavailable", forecastError: "Forecast unavailable"),
            TrayMenuState(showsUsageInMenuBar: false),
        ]
        let expected = TrayMenuModel.make(state: states[0]).items.map(\.role)
        for state in states {
            let actual = TrayMenuModel.make(state: state).items.map(\.role)
            expectEqual(actual, expected, "menu roles must stay stable for in-place updates")
        }
    }

    private static func testForecastRendering() {
        let model = TrayMenuModel.make(
            state: TrayMenuState(
                snapshot: snapshot(),
                forecast: forecast(),
                lastForecastCheck: menuTestNow
            )
        )

        let status = model.item(withRole: .codexStatus)
        expect(status?.title.contains("63%") == true, "Codex status should render the 7-day percentage")
        expect(status?.title.contains("7-day") == true, "Codex status should identify the 7-day window")

        let summary = model.item(withRole: .forecastSummary)
        expectEqual(summary?.tone, .normal, "available forecast should not render as an error")
        expect(summary?.title.contains("28% within 24h") == true, "forecast should render 24h probability")
        expect(summary?.title.contains("49% within 48h") == true, "forecast should render 48h probability")
        expect(summary?.toolTip?.contains("28% within 24 hours") == true, "forecast summary tooltip")

        let detail = model.item(withRole: .forecastDetail)
        expect(detail?.title.contains("Latest restoration") == true, "forecast detail should render")
        expect(detail?.title.contains("Quota restored") == true, "restoration status should render")
    }

    private static func testForecastErrorRendering() {
        let message = "codexreset.org returned HTTP 503."
        let model = TrayMenuModel.make(
            state: TrayMenuState(forecastError: message, lastForecastCheck: menuTestNow)
        )

        let summary = model.item(withRole: .forecastSummary)
        expectEqual(summary?.tone, .error, "forecast failure should be marked as an error")
        expect(summary?.title.contains("Forecast error") == true, "forecast error label")
        expect(summary?.title.contains(message) == true, "forecast error message should render")
        expect(
            model.item(withRole: .action(.quit))?.isEnabled == true,
            "Quit remains available when the forecast fails"
        )
    }

    private static func testCachedForecastAndFreshErrorBothRender() {
        let message = "codexreset.org returned HTTP 503."
        let model = TrayMenuModel.make(
            state: TrayMenuState(forecast: forecast(), forecastError: message, lastForecastSuccess: menuTestNow)
        )

        let summary = model.item(withRole: .forecastSummary)
        expectEqual(summary?.tone, .error, "stale probabilities should be marked")
        expect(summary?.title.contains("28% within 24h") == true, "cached 24h probability")
        expect(summary?.title.contains("stale, updated") == true, "cached forecast needs a freshness label")

        let detail = model.item(withRole: .forecastDetail)
        expectEqual(detail?.tone, .error, "fresh forecast error should render on the detail line")
        expect(detail?.title.contains(message) == true, "fresh forecast error message")
    }

    private static func testCodexErrorRendering() {
        let message = "Codex app-server did not respond within 10 seconds."
        let model = TrayMenuModel.make(
            state: TrayMenuState(
                snapshot: snapshot(),
                codexError: message,
                lastCodexCheck: menuTestNow
            )
        )

        let status = model.item(withRole: .codexStatus)
        expectEqual(status?.tone, .error, "Codex failure should be marked as an error")
        expect(status?.title.contains(message) == true, "Codex error message should render")
        expect(
            model.item(withRole: .codexWindows)?.title.contains("63%") == true,
            "last known usage remains visible with an error"
        )
    }

    private static func testLoadingRendering() {
        let model = TrayMenuModel.make(
            state: TrayMenuState(isPollingCodex: true, isFetchingForecast: true)
        )
        expect(
            model.item(withRole: .codexStatus)?.title.contains("reading usage") == true,
            "loading Codex state should render"
        )
        expect(
            model.item(withRole: .forecastSummary)?.title.contains("fetching") == true,
            "fetching forecast state should render"
        )
    }

    private static func testWebsiteURL() {
        expectEqual(
            TrayMenuModel.websiteURL.absoluteString,
            "https://codexreset.org/",
            "Open codexreset.org must use the project URL"
        )
    }

    private static func testMenuBarUsageToggleModel() {
        let shown = TrayMenuModel.make(state: TrayMenuState())
        let shownItem = shown.item(withRole: .action(.toggleMenuBarUsage))
        expectEqual(shownItem?.title, "Show Usage in Menu Bar", "toggle must use the requested native title")
        expectEqual(shownItem?.isChecked, true, "usage text is visible by default")
        expect(shownItem?.isEnabled == true, "toggle must always be enabled")
        expect(shownItem?.toolTip?.contains("icon is always visible") == true, "toggle tooltip must explain the icon remains")

        let hidden = TrayMenuModel.make(
            state: TrayMenuState(showsUsageInMenuBar: false)
        )
        expectEqual(
            hidden.item(withRole: .action(.toggleMenuBarUsage))?.isChecked,
            false,
            "hiding usage text must clear the check mark"
        )

        // The toggle is independent of usage/forecast failures.
        let errorState = TrayMenuState(
            codexError: "Codex app-server is unavailable.",
            forecastError: "codexreset.org returned HTTP 503.",
            showsUsageInMenuBar: false
        )
        expectEqual(
            TrayMenuModel.make(state: errorState).item(withRole: .action(.toggleMenuBarUsage))?.isChecked,
            false,
            "toggle state must survive error states"
        )
    }

    private static func testCopyStatusSummary() {
        let state = TrayMenuState(
            snapshot: snapshot(),
            baseline: WeeklyUsageBaseline(
                usedPercent: 72,
                resetsAt: menuTestNow.addingTimeInterval(86_400),
                capturedAt: menuTestNow.addingTimeInterval(-600),
                alertedResetsAt: nil
            ),
            notificationStatus: "Notifications are allowed.",
            forecast: forecast(),
            lastCodexCheck: menuTestNow,
            lastForecastCheck: menuTestNow
        )
        let summary = TrayMenuModel.statusSummary(for: state)
        expect(summary.contains("Codex Reset Tray \(AppBuildInfo.version)"), "summary version")
        expect(summary.contains("7-day Codex usage: 63%"), "summary 7-day usage")
        expect(summary.contains("Baseline: 72%"), "summary baseline")
        expect(summary.contains("Forecast: 28% within 24h"), "summary forecast")
        expect(summary.contains("Notifications: Notifications are allowed."), "summary notifications")
        expect(summary.contains("Menu bar usage text: shown"), "summary menu-bar visibility")
        expect(summary.contains("no account ID, credential, or local file path"), "summary privacy note")
        expect(!summary.localizedCaseInsensitiveContains("accountId"), "summary must not include accountId")
        expect(!summary.contains("/Users/"), "summary must not include local user paths")

        let emptySummary = TrayMenuModel.statusSummary(for: TrayMenuState())
        expect(emptySummary.contains("no usage has been read yet"), "empty summary status")
        expect(emptySummary.contains("no account ID, credential, or local file path"), "empty summary privacy note")
    }

    private static func testAccessibilityDescription() {
        let populated = TrayMenuModel.accessibilityDescription(
            for: TrayMenuState(snapshot: snapshot())
        )
        expect(populated.contains("Codex Reset Tray"), "accessibility label app name")
        expect(populated.contains("7-day Codex usage 63%"), "accessibility label usage")

        let error = TrayMenuModel.accessibilityDescription(
            for: TrayMenuState(codexError: "Codex app-server is unavailable.")
        )
        expect(error.contains("usage not loaded"), "accessibility label empty state")
        expect(error.contains("error: Codex app-server is unavailable."), "accessibility label error")
    }

    private static func snapshot() -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            ordinaryUsageAllowed: true,
            primary: CodexRateLimitWindow(
                usedPercent: 40,
                windowDurationMins: 300,
                resetsAt: menuTestNow.addingTimeInterval(3_600)
            ),
            secondary: CodexRateLimitWindow(
                usedPercent: 63,
                windowDurationMins: 10_080,
                resetsAt: menuTestNow.addingTimeInterval(86_400)
            ),
            observedAt: menuTestNow
        )
    }

    private static func forecast() -> ResetSnapshot {
        ResetSnapshot(
            resetAt: menuTestNow.addingTimeInterval(-1_800),
            resetStatus: "Quota restored",
            restorationStatus: "Monitored account: 75% → 100%.",
            probability24h: 28,
            probability48h: 49,
            forecastSummary: "28% within 24 hours, 49% within 48 hours, based on recent resets."
        )
    }
}
