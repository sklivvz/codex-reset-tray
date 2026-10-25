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
    private static let actionOnlyRoles: [TrayMenuItemRole] = [
        .action(.toggleMenuBarUsage),
        .action(.refresh),
        .action(.copyStatus),
        .action(.openWebsite),
        .action(.donate),
        .separator,
        .action(.quit),
    ]

    static func main() {
        testActionsMenuOnlyContainsConfigurationAndActions()
        testQuitAndRequiredActionsAreAlwaysAvailable()
        testMenuStructureIsStable()
        testMenuNeverCarriesInformationalRows()
        testOnlySeparatorsAreDisabled()
        testInfoForecastRendering()
        testInfoForecastErrorRendering()
        testInfoCachedForecastAndFreshErrorBothRender()
        testInfoCodexErrorRendering()
        testInfoNotificationStatusRendering()
        testInfoLoadingRendering()
        testInfoPreservesAllData()
        testWebsiteURL()
        testDonationLink()
        testMenuBarUsageToggleModel()
        testCopyStatusSummary()
        testAccessibilityDescription()
        testInfoModel()

        if menuTestFailures > 0 {
            FileHandle.standardError.write(Data("\(menuTestFailures) menu test assertion(s) failed\n".utf8))
            exit(1)
        }
        print("Tray actions menu and information popover model tests passed")
    }

    private static func testActionsMenuOnlyContainsConfigurationAndActions() {
        let model = TrayMenuModel.make(state: populatedState())
        expectEqual(
            model.items.map(\.role),
            actionOnlyRoles,
            "right-click menu must contain only configuration, actions, and the native Quit separator"
        )
        expectEqual(
            model.items.filter { $0.isAction }.count,
            6,
            "all six configuration/action rows must be present"
        )
        expect(
            model.items.allSatisfy { $0.isAction || $0.role == .separator },
            "the actions menu model must not contain informational roles"
        )
    }

    private static func testQuitAndRequiredActionsAreAlwaysAvailable() {
        let states: [(String, TrayMenuState)] = [
            ("empty", TrayMenuState()),
            ("polling", TrayMenuState(isPollingCodex: true, isFetchingForecast: true)),
            ("codex error", TrayMenuState(codexError: "Codex app-server is unavailable.")),
            ("forecast error", TrayMenuState(forecastError: "codexreset.org returned HTTP 503.")),
            ("populated", populatedState()),
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
            expectEqual(
                toggle?.title,
                state.showsUsageInMenuBar ? "Hide 7d Label" : "Show 7d Label",
                "\(label): menu-bar 7d label toggle title"
            )
            expect(toggle?.isEnabled == true, "\(label): menu-bar usage toggle must be enabled")
            expectEqual(
                toggle?.isChecked,
                state.showsUsageInMenuBar,
                "\(label): menu-bar usage toggle checked state"
            )
            let website = model.item(withRole: .action(.openWebsite))
            expectEqual(website?.title, "Open codexreset.org", "\(label): website action title")
            expect(website?.isEnabled == true, "\(label): website action must be enabled")
            expect(
                model.item(withRole: .action(.donate))?.isEnabled == true,
                "\(label): support action must be available"
            )
        }
    }

    private static func testMenuStructureIsStable() {
        // The AppKit controller updates item titles in place while the menu is
        // open. A state change must never add or remove rows.
        let states = [
            TrayMenuState(),
            TrayMenuState(isPollingCodex: true, isFetchingForecast: true),
            populatedState(),
            TrayMenuState(codexError: "Codex unavailable", forecastError: "Forecast unavailable"),
            TrayMenuState(showsUsageInMenuBar: false),
        ]
        let expected = TrayMenuModel.make(state: states[0]).items.map(\.role)
        for state in states {
            let actual = TrayMenuModel.make(state: state).items.map(\.role)
            expectEqual(actual, expected, "menu roles must stay stable for in-place updates")
        }
    }

    private static func testMenuNeverCarriesInformationalRows() {
        // Every status/usage/reset/notification/forecast fact belongs to the
        // left-click popover. None may leak back into the right-click menu.
        let states: [(String, TrayMenuState)] = [
            ("empty", TrayMenuState()),
            ("polling", TrayMenuState(isPollingCodex: true, isFetchingForecast: true)),
            ("codex error", TrayMenuState(snapshot: snapshot(), codexError: "Codex unavailable")),
            ("forecast error", TrayMenuState(forecastError: "HTTP 503")),
            ("populated", populatedState()),
        ]
        let forbiddenFragments = [
            "7-day Codex usage",
            "Forecast",
            "Notifications",
            "Codex error",
            "Baseline",
            "Primary",
            "Secondary",
            "Latest confirmed reset",
        ]

        for (label, state) in states {
            let model = TrayMenuModel.make(state: state)
            expectEqual(model.items.map(\.role), actionOnlyRoles, "\(label): menu roles")
            for item in model.items {
                for fragment in forbiddenFragments {
                    expect(
                        !item.title.contains(fragment),
                        "\(label): menu title '\(item.title)' must not contain '\(fragment)'"
                    )
                }
            }

            // The same state still carries every informational row in the
            // popover model, so removing menu rows did not remove data.
            let info = TrayInfoModel.make(state: state)
            expectEqual(
                info.allRows.map(\.role),
                [.codexStatus, .codexWindows, .codexMeta, .notificationStatus,
                 .forecastSummary, .forecastDetail],
                "\(label): information model row roles"
            )
        }
    }

    private static func testOnlySeparatorsAreDisabled() {
        // Gray menu text means "disabled". The actions menu contains no
        // informational rows, and every action is available, so the native
        // menu must never render gray text.
        let states: [(String, TrayMenuState)] = [
            ("empty", TrayMenuState()),
            ("polling", TrayMenuState(isPollingCodex: true, isFetchingForecast: true)),
            ("codex error", TrayMenuState(snapshot: snapshot(), codexError: "Codex unavailable")),
            ("forecast error", TrayMenuState(forecastError: "HTTP 503")),
            ("populated", populatedState()),
        ]
        for (label, state) in states {
            for item in TrayMenuModel.make(state: state).items {
                if item.role == .separator {
                    expect(!item.isEnabled, "\(label): separator must be disabled")
                } else {
                    expect(item.isEnabled, "\(label): action '\(item.title)' must not be disabled")
                }
            }
        }
    }

    private static func testInfoForecastRendering() {
        let info = TrayInfoModel.make(state: populatedState())

        let status = info.row(withRole: .codexStatus)
        expect(status?.text.contains("63%") == true, "Codex status should render the 7-day percentage")
        expect(status?.text.contains("7-day") == true, "Codex status should identify the 7-day window")

        let summary = info.row(withRole: .forecastSummary)
        expectEqual(summary?.tone, .normal, "available forecast should not render as an error")
        expect(summary?.text.contains("28% within 24h") == true, "forecast should render 24h probability")
        expect(summary?.text.contains("49% within 48h") == true, "forecast should render 48h probability")
        expect(summary?.toolTip?.contains("28% within 24 hours") == true, "forecast summary tooltip")

        let detail = info.row(withRole: .forecastDetail)
        expect(detail?.text.contains("Latest confirmed reset") == true, "forecast detail should render")
        expect(detail?.text.contains("Quota restored") == true, "restoration status should render")
        expect(detail?.toolTip?.contains("Monitored account") == true, "restoration detail tooltip")
    }

    private static func testInfoForecastErrorRendering() {
        let message = "codexreset.org returned HTTP 503."
        let info = TrayInfoModel.make(
            state: TrayMenuState(forecastError: message, lastForecastCheck: menuTestNow)
        )

        let summary = info.row(withRole: .forecastSummary)
        expectEqual(summary?.tone, .error, "forecast failure should be marked as an error")
        expect(summary?.text.contains("Forecast error") == true, "forecast error label")
        expect(summary?.text.contains(message) == true, "forecast error message should render")
    }

    private static func testInfoCachedForecastAndFreshErrorBothRender() {
        let message = "codexreset.org returned HTTP 503."
        let info = TrayInfoModel.make(
            state: TrayMenuState(forecast: forecast(), forecastError: message, lastForecastSuccess: menuTestNow)
        )

        let summary = info.row(withRole: .forecastSummary)
        expectEqual(summary?.tone, .error, "stale probabilities should be marked")
        expect(summary?.text.contains("28% within 24h") == true, "cached 24h probability")
        expect(summary?.text.contains("stale, updated") == true, "cached forecast needs a freshness label")

        let detail = info.row(withRole: .forecastDetail)
        expectEqual(detail?.tone, .error, "fresh forecast error should render on the detail line")
        expect(detail?.text.contains(message) == true, "fresh forecast error message")
    }

    private static func testInfoCodexErrorRendering() {
        let message = "Codex app-server did not respond within 10 seconds."
        let info = TrayInfoModel.make(
            state: TrayMenuState(
                snapshot: snapshot(),
                codexError: message,
                lastCodexCheck: menuTestNow
            )
        )

        let status = info.row(withRole: .codexStatus)
        expectEqual(status?.tone, .error, "Codex failure should be marked as an error")
        expect(status?.text.contains(message) == true, "Codex error message should render")
        expect(
            info.row(withRole: .codexWindows)?.text.contains("63%") == true,
            "last known usage remains visible with an error"
        )
    }

    private static func testInfoNotificationStatusRendering() {
        let allowed = TrayInfoModel.make(
            state: TrayMenuState(notificationStatus: "Notifications are allowed.")
        )
        let allowedRow = allowed.row(withRole: .notificationStatus)
        expectEqual(allowedRow?.text, "Notifications are allowed.", "allowed status is visible")
        expectEqual(allowedRow?.tone, .normal, "allowed status is not an error")

        let denied = TrayInfoModel.make(
            state: TrayMenuState(
                notificationStatus: "Notifications are denied in System Settings; reset alerts cannot be scheduled.",
                notificationStatusIsError: true
            )
        )
        let deniedRow = denied.row(withRole: .notificationStatus)
        expectEqual(deniedRow?.tone, .error, "denied notifications render as an error")
        expect(
            deniedRow?.text.contains("denied in System Settings") == true,
            "denied notification status is visible in the popover"
        )

        let scheduled = TrayInfoModel.make(
            state: TrayMenuState(
                notificationStatus: "Reset notification scheduled. Visual delivery depends on macOS settings."
            )
        )
        let scheduledRow = scheduled.row(withRole: .notificationStatus)
        expectEqual(
            scheduledRow?.text,
            "Reset notification scheduled. Visual delivery depends on macOS settings.",
            "scheduled request is distinguished from visual delivery"
        )
        expect(
            scheduledRow?.toolTip?.contains("does not confirm that a banner was displayed") == true,
            "notification tooltip explains that scheduling is not proof of display"
        )
    }

    private static func testInfoLoadingRendering() {
        let info = TrayInfoModel.make(
            state: TrayMenuState(isPollingCodex: true, isFetchingForecast: true)
        )
        expect(
            info.row(withRole: .codexStatus)?.text.contains("reading usage") == true,
            "loading Codex state should render"
        )
        expect(
            info.row(withRole: .forecastSummary)?.text.contains("fetching") == true,
            "fetching forecast state should render"
        )
    }

    private static func testInfoPreservesAllData() {
        let scheduledAt = menuTestNow.addingTimeInterval(-900)
        let lastSuccess = menuTestNow.addingTimeInterval(-120)
        let state = TrayMenuState(
            snapshot: snapshot(),
            baseline: baseline(),
            lastNotificationScheduledAt: scheduledAt,
            notificationStatus: "Notifications are allowed.",
            forecast: forecast(),
            lastCodexCheck: menuTestNow,
            lastForecastCheck: menuTestNow,
            lastForecastSuccess: lastSuccess
        )
        let info = TrayInfoModel.make(state: state)

        expect(info.row(withRole: .codexStatus)?.text.contains("7-day Codex usage: 63%") == true,
               "popover keeps status usage")
        expect(info.row(withRole: .codexWindows)?.text.contains("Primary 5-hour: 40%") == true,
               "popover keeps primary usage window")
        expect(info.row(withRole: .codexWindows)?.text.contains("Secondary 7-day: 63%") == true,
               "popover keeps secondary usage window")
        expect(info.row(withRole: .codexMeta)?.text.hasPrefix("Baseline: 72%") == true,
               "popover keeps baseline and reset deadline")
        expect(info.row(withRole: .notificationStatus)?.text == "Notifications are allowed.",
               "popover keeps notification permission state")
        expect(info.row(withRole: .forecastSummary)?.text.contains("28% within 24h") == true,
               "popover keeps forecast probabilities")
        expect(info.row(withRole: .forecastDetail)?.text.contains("Latest confirmed reset") == true,
               "popover keeps reset detail")

        let metaToolTip = info.row(withRole: .codexMeta)?.toolTip
        expect(metaToolTip?.contains("Ordinary usage allowed: yes") == true,
               "popover keeps ordinary usage allowance")
        expect(metaToolTip?.contains("Codex read at") == true,
               "popover keeps Codex observation time")
        expect(metaToolTip?.contains("Reset notification request scheduled at") == true,
               "popover keeps scheduled notification request")
        expect(info.row(withRole: .forecastSummary)?.toolTip == forecast().forecastSummary,
               "popover keeps forecast summary")
        expect(info.row(withRole: .forecastDetail)?.toolTip?.contains("Monitored account") == true,
               "popover keeps restoration detail")

        for expected in [
            "Last Codex check:",
            "Last forecast check:",
            "Menu bar 7d label: shown",
            "Ordinary usage allowed: yes",
            "Codex read at:",
            "Last reset notification request:",
            "Forecast last updated:",
        ] {
            expect(
                info.footer.contains { $0.hasPrefix(expected) },
                "popover footer must keep '\(expected)' (got \(info.footer))"
            )
        }
    }

    private static func testDonationLink() {
        let destination = TrayMenuModel.donationURL
        expectEqual(destination.absoluteString, "https://paypal.me/sklivvz",
                    "donation URL must target the verified recipient")
        let model = TrayMenuModel.make(state: TrayMenuState())
        expectEqual(model.item(withRole: .action(.donate))?.title, "Support this project",
                    "donation row title")
        expect(model.item(withRole: .action(.donate))?.isEnabled == true,
               "donation row is actionable")
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
        expectEqual(shownItem?.title, "Hide 7d Label", "visible label must offer a clear hide action")
        expectEqual(shownItem?.isChecked, true, "usage label is visible by default")
        expect(shownItem?.isEnabled == true, "toggle must always be enabled")
        expect(
            shownItem?.toolTip?.contains("icon remains visible") == true,
            "hide tooltip must explain the icon remains"
        )
        expectEqual(
            shown.items.first?.role,
            .action(.toggleMenuBarUsage),
            "toggle must be the first action, with no informational heading above it"
        )

        let hidden = TrayMenuModel.make(
            state: TrayMenuState(showsUsageInMenuBar: false)
        )
        let hiddenItem = hidden.item(withRole: .action(.toggleMenuBarUsage))
        expectEqual(hiddenItem?.title, "Show 7d Label", "hidden label must offer a clear show action")
        expectEqual(hiddenItem?.isChecked, false, "hiding the label must clear the check mark")
        expect(
            hiddenItem?.toolTip?.contains("icon is always visible") == true,
            "show tooltip must explain the icon remains"
        )

        // The toggle is independent of usage/forecast failures.
        let errorState = TrayMenuState(
            codexError: "Codex app-server is unavailable.",
            forecastError: "codexreset.org returned HTTP 503.",
            showsUsageInMenuBar: false
        )
        let errorItem = TrayMenuModel.make(state: errorState)
            .item(withRole: .action(.toggleMenuBarUsage))
        expectEqual(errorItem?.title, "Show 7d Label", "toggle title must survive error states")
        expectEqual(errorItem?.isChecked, false, "toggle state must survive error states")
    }

    private static func testCopyStatusSummary() {
        let state = TrayMenuState(
            snapshot: snapshot(),
            baseline: baseline(),
            lastNotificationScheduledAt: menuTestNow.addingTimeInterval(-900),
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
        expect(summary.contains("Notifications are allowed."), "summary notifications")
        expect(
            summary.contains("Last reset notification request:")
                && summary.contains("visual delivery not confirmed"),
            "summary distinguishes scheduled notification from visual delivery"
        )
        expect(summary.contains("Menu bar 7d label: shown"), "summary menu-bar visibility")
        expect(summary.contains("no account ID, credential, or local file path"), "summary privacy note")
        expect(!summary.localizedCaseInsensitiveContains("accountId"), "summary must not include accountId")
        expect(!summary.contains("/Users/"), "summary must not include local user paths")
        let summaryLines = summary.split(separator: "\n").map { String($0) }
        expectEqual(
            summaryLines.count,
            Set(summaryLines).count,
            "summary must not repeat a row or footer line"
        )

        // Both overlap paths used to duplicate a detail line: codexMeta can
        // repeat the ordinary-usage footer value, and a check-only state can
        // repeat the last-Codex-check footer line.
        let snapshotOverlap = TrayMenuModel.statusSummary(
            for: TrayMenuState(snapshot: snapshot(), lastCodexCheck: menuTestNow)
        )
        expectEqual(
            snapshotOverlap.components(separatedBy: "Ordinary usage allowed: yes").count - 1,
            1,
            "summary must print the ordinary-usage detail once"
        )
        let checkOverlap = TrayMenuModel.statusSummary(
            for: TrayMenuState(lastCodexCheck: menuTestNow)
        )
        expectEqual(
            checkOverlap.components(separatedBy: "Last Codex check:").count - 1,
            1,
            "summary must print the last-Codex-check detail once"
        )

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

    private static func testInfoModel() {
        let populated = TrayInfoModel.make(
            state: TrayMenuState(
                snapshot: snapshot(),
                forecast: forecast(),
                lastCodexCheck: menuTestNow,
                lastForecastCheck: menuTestNow
            )
        )
        expectEqual(populated.title, "Codex Reset Tray", "info title")
        expectEqual(populated.usageValue, "63%", "info headline")
        expectEqual(populated.usageFraction, 0.63, "info meter fraction")
        expectEqual(populated.sections.map(\.title), ["Codex usage", "Reset forecast"], "info sections")
        expectEqual(
            populated.sections[0].rows.map(\.role),
            [.codexStatus, .codexWindows, .codexMeta, .notificationStatus],
            "info Codex row roles"
        )
        expectEqual(
            populated.sections[1].rows.map(\.role),
            [.forecastSummary, .forecastDetail],
            "info forecast row roles"
        )
        expect(populated.footer.contains { $0.hasPrefix("Last Codex check:") }, "info footer Codex check")
        expect(populated.footer.contains { $0.hasPrefix("Last forecast check:") }, "info footer forecast check")
        expect(populated.footer.contains("Menu bar 7d label: shown"), "info footer label state")

        let hidden = TrayInfoModel.make(state: TrayMenuState(showsUsageInMenuBar: false))
        expect(hidden.footer.contains("Menu bar 7d label: hidden"), "info footer hidden label state")
        expectEqual(hidden.usageValue, "--", "unknown usage headline")
        expectEqual(hidden.usageFraction, nil, "unknown usage hides the meter")

        let errors = TrayInfoModel.make(
            state: TrayMenuState(
                snapshot: snapshot(),
                codexError: "Codex unavailable",
                forecastError: "HTTP 503"
            )
        )
        expectEqual(errors.row(withRole: .codexStatus)?.tone, .error,
                    "Codex error row keeps the error tone")
        expectEqual(errors.row(withRole: .forecastSummary)?.tone, .error,
                    "forecast error row keeps the error tone")
        expect(errors.row(withRole: .codexStatus)?.text.contains("Codex unavailable") == true,
               "Codex error text")

        let overflow = TrayInfoModel.make(
            state: TrayMenuState(
                snapshot: CodexRateLimitSnapshot(
                    ordinaryUsageAllowed: true,
                    primary: nil,
                    secondary: CodexRateLimitWindow(
                        usedPercent: 140,
                        windowDurationMins: 10_080,
                        resetsAt: nil
                    ),
                    observedAt: menuTestNow
                )
            )
        )
        expectEqual(overflow.usageFraction, 1.0, "meter fraction is clamped")
    }

    private static func populatedState() -> TrayMenuState {
        TrayMenuState(
            snapshot: snapshot(),
            baseline: baseline(),
            lastNotificationScheduledAt: menuTestNow.addingTimeInterval(-900),
            notificationStatus: "Notifications are allowed.",
            forecast: forecast(),
            lastCodexCheck: menuTestNow,
            lastForecastCheck: menuTestNow
        )
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

    private static func baseline() -> WeeklyUsageBaseline {
        WeeklyUsageBaseline(
            usedPercent: 72,
            resetsAt: menuTestNow.addingTimeInterval(86_400),
            capturedAt: menuTestNow.addingTimeInterval(-600),
            alertedResetsAt: nil
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
