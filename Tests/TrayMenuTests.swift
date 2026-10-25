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
        .action(.enableNotifications),
        .action(.refresh),
        .action(.copyStatus),
        .action(.openWebsite),
        .action(.donate),
        .separator,
        .action(.about),
        .action(.quit),
    ]

    static func main() {
        testActionsMenuOnlyContainsConfigurationAndActions()
        testQuitAndRequiredActionsAreAlwaysAvailable()
        testMenuStructureIsStable()
        testMenuNeverCarriesInformationalRows()
        testOnlySeparatorsAreDisabled()
        testNotificationPermissionCheckmark()
        testInfoCompactCurrentForecast()
        testInfoCompactLoadingAndAbsentUsage()
        testInfoForecastErrorRendering()
        testInfoCachedForecastAndFreshErrorBothRender()
        testInfoRemovedContentAbsent()
        testWebsiteURL()
        testDonationLink()
        testNotificationSettingsURL()
        testMenuBarUsageToggleModel()
        testCopyStatusSummaryPreservesDiagnostics()
        testAccessibilityDescription()
        testInfoModel()

        if menuTestFailures > 0 {
            FileHandle.standardError.write(Data("\(menuTestFailures) menu test assertion(s) failed\n".utf8))
            exit(1)
        }
        print("Tray actions menu and compact information popover model tests passed")
    }

    private static func testActionsMenuOnlyContainsConfigurationAndActions() {
        let model = TrayMenuModel.make(state: populatedState())
        expectEqual(
            model.items.map(\.role),
            actionOnlyRoles,
            "right-click menu must contain only configuration, actions, and the native separator"
        )
        expectEqual(
            model.items.filter { $0.isAction }.count,
            8,
            "all eight configuration/action rows must be present"
        )
        expect(
            model.items.allSatisfy { $0.isAction || $0.role == .separator },
            "the actions menu model must not contain informational roles"
        )
        expectEqual(
            model.items.filter { !$0.isAction && $0.role != .separator }.count,
            0,
            "no informational rows may be added to the actions menu"
        )
    }

    private static func testQuitAndRequiredActionsAreAlwaysAvailable() {
        let states: [(String, TrayMenuState)] = [
            ("empty", TrayMenuState()),
            ("polling", TrayMenuState(isPollingCodex: true, isFetchingForecast: true)),
            ("codex error", TrayMenuState(codexError: "Codex app-server is unavailable.")),
            ("forecast error", TrayMenuState(forecastError: "codexreset.org returned HTTP 503.")),
            ("notifications allowed", TrayMenuState(notificationPermission: .allowed)),
            ("notifications denied", TrayMenuState(notificationPermission: .denied)),
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
                "Show 7d Label",
                "\(label): menu-bar 7d label toggle always uses the exact title"
            )
            expect(toggle?.isEnabled == true, "\(label): menu-bar usage toggle must be enabled")
            expectEqual(
                toggle?.isChecked,
                state.showsUsageInMenuBar,
                "\(label): menu-bar usage toggle checked state"
            )
            let notifications = model.item(withRole: .action(.enableNotifications))
            expectEqual(
                notifications?.title,
                "Enable Notifications",
                "\(label): notification permission title"
            )
            expect(
                notifications?.isEnabled == true,
                "\(label): notification permission item must remain actionable"
            )
            expectEqual(
                notifications?.isChecked,
                state.notificationPermission.allowsDelivery,
                "\(label): notification check mark follows authorization"
            )
            expectEqual(
                model.item(withRole: .action(.about))?.title,
                "About Codex Reset Tray",
                "\(label): About title"
            )
            expect(
                model.item(withRole: .action(.about))?.isEnabled == true,
                "\(label): About must be available"
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
            TrayMenuState(notificationPermission: .notDetermined),
            TrayMenuState(notificationPermission: .denied),
            TrayMenuState(notificationPermission: .allowed),
        ]
        let expected = TrayMenuModel.make(state: states[0]).items.map(\.role)
        for state in states {
            let actual = TrayMenuModel.make(state: state).items.map(\.role)
            expectEqual(actual, expected, "menu roles must stay stable for in-place updates")
        }
    }

    private static func testMenuNeverCarriesInformationalRows() {
        // Every status/usage/reset/forecast fact belongs to the compact
        // left-click popover. None may leak back into the right-click menu.
        let states: [(String, TrayMenuState)] = [
            ("empty", TrayMenuState()),
            ("polling", TrayMenuState(isPollingCodex: true, isFetchingForecast: true)),
            ("codex error", TrayMenuState(snapshot: snapshot(), codexError: "Codex unavailable")),
            ("forecast error", TrayMenuState(forecastError: "HTTP 503")),
            ("denied notifications", TrayMenuState(notificationPermission: .denied)),
            ("populated", populatedState()),
        ]
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

            let info = TrayInfoModel.make(state: state)
            expectEqual(info.title, "Codex Reset Tray", "\(label): compact popover title")
            expectEqual(
                info.forecastFigures.count,
                2,
                "\(label): compact popover keeps exactly two forecast figures"
            )
            expect(
                info.forecastStatus?.text.contains("Latest confirmed reset") != true,
                "\(label): compact popover must not carry the latest confirmed reset row"
            )
            expect(
                info.forecastStatus?.text.contains("Notifications") != true,
                "\(label): compact popover must not carry notification prose"
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
            ("denied notifications", TrayMenuState(notificationPermission: .denied)),
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

    private static func testNotificationPermissionCheckmark() {
        let cases: [(TrayNotificationPermission, Bool)] = [
            (.allowed, true),
            (.notDetermined, false),
            (.denied, false),
            (.unknown, false),
        ]
        for (permission, checked) in cases {
            let model = TrayMenuModel.make(
                state: TrayMenuState(notificationPermission: permission)
            )
            let item = model.item(withRole: .action(.enableNotifications))
            expectEqual(item?.isChecked, checked, "permission \(permission) check mark")
            expect(item?.isEnabled == true, "permission \(permission) item stays actionable")
            expect(
                item?.toolTip?.isEmpty == false,
                "permission \(permission) item has an explanatory tooltip"
            )
        }
        expectEqual(
            TrayMenuModel.make(state: TrayMenuState(notificationPermission: .notDetermined))
                .item(withRole: .action(.enableNotifications))?.toolTip,
            "Ask macOS for permission to show reset notifications.",
            "undetermined tooltip describes the prompt route"
        )
        expectEqual(
            TrayMenuModel.make(state: TrayMenuState(notificationPermission: .denied))
                .item(withRole: .action(.enableNotifications))?.toolTip,
            "Notifications are disabled. Open System Settings > Notifications.",
            "denied tooltip describes the settings route"
        )
        expectEqual(
            TrayMenuModel.make(state: TrayMenuState(notificationPermission: .allowed))
                .item(withRole: .action(.enableNotifications))?.toolTip,
            "Notifications are allowed. Open System Settings > Notifications.",
            "allowed tooltip keeps the settings action meaningful"
        )
    }

    private static func testInfoCompactCurrentForecast() {
        let info = TrayInfoModel.make(state: populatedState())

        expectEqual(info.title, "Codex Reset Tray", "popover title")
        expectEqual(info.usageValue, "63%", "popover keeps the usage headline")
        expectEqual(info.usageCaption, "7-day Codex usage", "popover keeps the usage caption")
        expectEqual(info.usageFraction, 0.63, "popover keeps the usage meter")
        expectEqual(
            info.forecastFigures,
            [
                TrayForecastFigure(horizon: "24h", value: "28%", caption: "within 24h"),
                TrayForecastFigure(horizon: "48h", value: "49%", caption: "within 48h"),
            ],
            "popover replaces the forecast sentence with two large figures"
        )
        expectEqual(info.forecastState, .current, "current forecast state")
        expect(info.forecastStatus == nil, "current forecast adds no status line")
        expect(
            info.forecastToolTip?.contains("28% within 24 hours") == true,
            "forecast detail stays available in the tooltip"
        )
    }

    private static func testInfoCompactLoadingAndAbsentUsage() {
        let idle = TrayInfoModel.make(state: TrayMenuState())
        expectEqual(idle.usageValue, "--", "unknown usage headline")
        expectEqual(idle.usageCaption, "7-day Codex usage unavailable", "unknown usage caption")
        expectEqual(idle.usageFraction, nil, "unknown usage hides the meter")
        expectEqual(idle.forecastFigures.map(\.value), ["--", "--"], "loading figures are placeholders")
        expectEqual(idle.forecastState, .loading, "idle forecast is a loading state")
        expectEqual(idle.forecastStatus?.text, "Forecast not loaded yet.", "idle status text")
        expectEqual(idle.forecastStatus?.tone, .normal, "idle status is normal, not disabled gray")

        let fetching = TrayInfoModel.make(
            state: TrayMenuState(isPollingCodex: true, isFetchingForecast: true)
        )
        expectEqual(fetching.forecastStatus?.text, "Loading forecast…", "fetching status text")
        expectEqual(fetching.forecastStatus?.tone, .normal, "loading status is normal, not gray")
        expect(
            fetching.forecastFigures.allSatisfy { $0.value == "--" },
            "fetching state keeps the two-column figure layout"
        )
    }

    private static func testInfoForecastErrorRendering() {
        let message = "codexreset.org returned HTTP 503."
        let info = TrayInfoModel.make(
            state: TrayMenuState(forecastError: message, lastForecastCheck: menuTestNow)
        )

        expectEqual(
            info.forecastState,
            .unavailable(error: message),
            "forecast failure without cached data is unavailable"
        )
        expectEqual(info.forecastStatus?.tone, .error, "forecast failure uses the error tone")
        expectEqual(
            info.forecastStatus?.text,
            "Forecast unavailable: codexreset.org returned HTTP 503.",
            "forecast error status text"
        )
        expectEqual(
            info.forecastFigures.map(\.value),
            ["--", "--"],
            "an unavailable forecast still shows both figure columns"
        )
        expect(
            info.forecastToolTip?.contains("Refresh failed: \(message)") == true,
            "forecast error remains in the tooltip"
        )
    }

    private static func testInfoCachedForecastAndFreshErrorBothRender() {
        let message = "codexreset.org returned HTTP 503."
        let success = menuTestNow.addingTimeInterval(-120)
        let info = TrayInfoModel.make(
            state: TrayMenuState(
                forecast: forecast(),
                forecastError: message,
                lastForecastSuccess: success
            )
        )

        expectEqual(info.forecastFigures.map(\.value), ["28%", "49%"], "cached figures stay visible")
        expectEqual(
            info.forecastState,
            .stale(updated: TrayInfoModel.dateText(success), error: message),
            "cached forecast with a fresh error is stale"
        )
        expectEqual(info.forecastStatus?.tone, .error, "stale forecast is not gray informational text")
        expect(
            info.forecastStatus?.text.contains("Stale forecast · updated") == true,
            "stale forecast shows its freshness"
        )
        expect(
            info.forecastStatus?.text.contains(message) == true,
            "stale forecast keeps the refresh error"
        )
        expect(
            info.forecastToolTip?.contains("Refresh failed: \(message)") == true,
            "stale tooltip keeps the refresh error"
        )
    }

    private static func testInfoRemovedContentAbsent() {
        let state = TrayMenuState(
            snapshot: snapshot(),
            codexError: "Codex app-server did not respond within 10 seconds.",
            baseline: baseline(),
            lastNotificationScheduledAt: menuTestNow.addingTimeInterval(-900),
            notificationStatus: "Notifications are denied in System Settings.",
            notificationStatusIsError: true,
            forecast: forecast(),
            lastCodexCheck: menuTestNow,
            lastForecastCheck: menuTestNow,
            lastForecastSuccess: menuTestNow,
            showsUsageInMenuBar: false
        )
        let info = TrayInfoModel.make(state: state)
        let description = String(describing: info)

        for removed in [
            "Latest confirmed reset",
            "Last Codex check",
            "Last forecast check",
            "Menu bar 7d label",
            "Ordinary usage allowed",
            "Notifications are denied",
            "Version ",
        ] {
            expect(
                !description.contains(removed),
                "compact popover model must not retain '\(removed)' (got \(description))"
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

    private static func testNotificationSettingsURL() {
        expectEqual(
            TrayMenuModel.notificationSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "denied/allowed notification clicks must open the Notifications pane"
        )
    }

    private static func testMenuBarUsageToggleModel() {
        let shown = TrayMenuModel.make(state: TrayMenuState())
        let shownItem = shown.item(withRole: .action(.toggleMenuBarUsage))
        expectEqual(shownItem?.title, "Show 7d Label", "visible label must keep the exact toggle title")
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
        expectEqual(hiddenItem?.title, "Show 7d Label", "hidden label must keep the exact toggle title")
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
        expectEqual(errorItem?.title, "Show 7d Label", "toggle title must stay exact in error states")
        expectEqual(errorItem?.isChecked, false, "toggle state must survive error states")
    }

    private static func testCopyStatusSummaryPreservesDiagnostics() {
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
        expect(summary.contains("Latest confirmed reset:"), "summary keeps reset detail")
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
        expectEqual(populated.forecastFigures.count, 2, "info forecast figure count")
        expectEqual(populated.forecastState, .current, "info current forecast")

        let hidden = TrayInfoModel.make(state: TrayMenuState(showsUsageInMenuBar: false))
        expectEqual(hidden.usageValue, "--", "unknown usage headline")
        expectEqual(hidden.usageFraction, nil, "unknown usage hides the meter")

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
            lastForecastCheck: menuTestNow,
            notificationPermission: .allowed
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
