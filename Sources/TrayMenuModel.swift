import Foundation

enum TrayMenuAction: Hashable {
    case refresh
    case copyStatus
    case toggleMenuBarUsage
    case enableNotifications
    case openWebsite
    case donate
    case about
    case quit
}

/// The right-click menu is deliberately limited to configuration and actions.
/// It has no informational cases: status, usage, reset, notification, and
/// forecast content lives in `TrayInfoModel` and the left-click popover.
enum TrayMenuItemRole: Hashable {
    case separator
    case action(TrayMenuAction)
}

/// The subset of notification authorization the menu needs. The check mark is
/// on only when macOS reports a status that actually allows delivery.
enum TrayNotificationPermission: Equatable {
    case unknown
    case notDetermined
    case denied
    case allowed

    var allowsDelivery: Bool { self == .allowed }
}

struct TrayMenuItem: Equatable {
    let role: TrayMenuItemRole
    let title: String
    /// `false` is reserved for controls that are genuinely unavailable (and for
    /// separators). It is never used to de-emphasize information, because the
    /// actions menu contains no informational rows.
    let isEnabled: Bool
    let toolTip: String?
    var isChecked: Bool = false

    var isAction: Bool {
        if case .action = role { return true }
        return false
    }
}

struct TrayMenuState: Equatable {
    var snapshot: CodexRateLimitSnapshot?
    var codexError: String?
    var isPollingCodex: Bool
    var baseline: WeeklyUsageBaseline?
    var lastNotificationScheduledAt: Date?
    var notificationStatus: String?
    var notificationStatusIsError: Bool
    var forecast: ResetSnapshot?
    var forecastError: String?
    var isFetchingForecast: Bool
    var lastCodexCheck: Date?
    var lastForecastCheck: Date?
    var lastForecastSuccess: Date?
    var showsUsageInMenuBar: Bool
    var notificationPermission: TrayNotificationPermission

    init(
        snapshot: CodexRateLimitSnapshot? = nil,
        codexError: String? = nil,
        isPollingCodex: Bool = false,
        baseline: WeeklyUsageBaseline? = nil,
        lastNotificationScheduledAt: Date? = nil,
        notificationStatus: String? = nil,
        notificationStatusIsError: Bool = false,
        forecast: ResetSnapshot? = nil,
        forecastError: String? = nil,
        isFetchingForecast: Bool = false,
        lastCodexCheck: Date? = nil,
        lastForecastCheck: Date? = nil,
        lastForecastSuccess: Date? = nil,
        showsUsageInMenuBar: Bool = true,
        notificationPermission: TrayNotificationPermission = .unknown
    ) {
        self.snapshot = snapshot
        self.codexError = codexError
        self.isPollingCodex = isPollingCodex
        self.baseline = baseline
        self.lastNotificationScheduledAt = lastNotificationScheduledAt
        self.notificationStatus = notificationStatus
        self.notificationStatusIsError = notificationStatusIsError
        self.forecast = forecast
        self.forecastError = forecastError
        self.isFetchingForecast = isFetchingForecast
        self.lastCodexCheck = lastCodexCheck
        self.lastForecastCheck = lastForecastCheck
        self.lastForecastSuccess = lastForecastSuccess
        self.showsUsageInMenuBar = showsUsageInMenuBar
        self.notificationPermission = notificationPermission
    }
}

/// Pure representation of the right-click actions menu. Keeping the
/// presentation here makes the always-available configuration and actions
/// testable without opening a GUI. Informational rows are intentionally absent,
/// so the native menu cannot regress into a second status surface.
struct TrayMenuModel: Equatable {
    static let websiteURL = URL(string: "https://codexreset.org/")!
    static let donationURL = URL(string: "https://paypal.me/sklivvz")!
    static let notificationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!

    let items: [TrayMenuItem]

    func item(withRole role: TrayMenuItemRole) -> TrayMenuItem? {
        items.first { $0.role == role }
    }

    static func make(state: TrayMenuState) -> TrayMenuModel {
        // A separator before About/Quit is the native menu convention retained:
        // it keeps the terminating action apart from configuration, links, and
        // the About panel. There is no heading because the menu is not an
        // information panel.
        let items: [TrayMenuItem] = [
            TrayMenuItem(
                role: .action(.toggleMenuBarUsage),
                title: "Show 7d Label",
                isEnabled: true,
                toolTip: state.showsUsageInMenuBar
                    ? "Hide the 7d usage percentage in the menu bar. The icon remains visible."
                    : "Show the 7d usage percentage next to the menu bar icon. The icon is always visible.",
                isChecked: state.showsUsageInMenuBar
            ),
            TrayMenuItem(
                role: .action(.enableNotifications),
                title: "Enable Notifications",
                isEnabled: true,
                toolTip: notificationToolTip(for: state.notificationPermission),
                isChecked: state.notificationPermission.allowsDelivery
            ),
            // These actions are never conditional. In particular, Quit must
            // remain enabled in every loading, empty, success, and error state.
            TrayMenuItem(
                role: .action(.refresh),
                title: "Refresh",
                isEnabled: true,
                toolTip: "Re-read Codex usage and the codexreset.org forecast."
            ),
            TrayMenuItem(
                role: .action(.copyStatus),
                title: "Copy Status Summary",
                isEnabled: true,
                toolTip: "Copy a privacy-safe status summary for a bug report."
            ),
            TrayMenuItem(
                role: .action(.openWebsite),
                title: "Open codexreset.org",
                isEnabled: true,
                toolTip: Self.websiteURL.absoluteString
            ),
            TrayMenuItem(
                role: .action(.donate),
                title: "Support this project",
                isEnabled: true,
                toolTip: "Open PayPal.Me in your browser to support this project."
            ),
            TrayMenuItem(
                role: .separator,
                title: "",
                isEnabled: false,
                toolTip: nil
            ),
            TrayMenuItem(
                role: .action(.about),
                title: "About Codex Reset Tray",
                isEnabled: true,
                toolTip: "Show version, build, and copyright information."
            ),
            TrayMenuItem(
                role: .action(.quit),
                title: "Quit Codex Reset Tray",
                isEnabled: true,
                toolTip: "Quit Codex Reset Tray."
            ),
        ]
        return TrayMenuModel(items: items)
    }

    private static func notificationToolTip(
        for permission: TrayNotificationPermission
    ) -> String {
        switch permission {
        case .allowed:
            return "Notifications are allowed. Open System Settings > Notifications."
        case .denied:
            return "Notifications are disabled. Open System Settings > Notifications."
        case .notDetermined:
            return "Ask macOS for permission to show reset notifications."
        case .unknown:
            return "Check notification permission and open System Settings if needed."
        }
    }

    /// Plain-text diagnostic report for the Copy Status Summary action. Unlike
    /// the compact popover, this intentionally keeps the full usage windows,
    /// baseline, notification scheduling state, reset confirmation, and check
    /// times. It never includes app-server account identifiers or credentials.
    static func statusSummary(for state: TrayMenuState) -> String {
        var lines = [
            "Codex Reset Tray \(AppBuildInfo.version) (build \(AppBuildInfo.build))",
            "Project: \(AppBuildInfo.projectURL.absoluteString)",
        ]
        var seen = Set(lines)
        for line in diagnosticLines(for: state) {
            if seen.insert(line).inserted {
                lines.append(line)
            }
        }
        lines.append("This summary contains no account ID, credential, or local file path.")
        return lines.joined(separator: "\n")
    }

    private static func diagnosticLines(for state: TrayMenuState) -> [String] {
        var lines = [
            codexStatusLine(state),
            codexWindowsLine(state),
            codexMetaLine(state),
            notificationStatusLine(state),
            forecastSummaryLine(state),
            forecastDetailLine(state),
        ]
        if let lastCheck = state.lastCodexCheck {
            lines.append("Last Codex check: \(TrayInfoModel.dateText(lastCheck))")
        }
        if let lastCheck = state.lastForecastCheck {
            lines.append("Last forecast check: \(TrayInfoModel.dateText(lastCheck))")
        }
        lines.append(
            "Menu bar 7d label: \(state.showsUsageInMenuBar ? "shown" : "hidden")"
        )
        if let snapshot = state.snapshot {
            lines.append(
                "Ordinary usage allowed: \(TrayInfoModel.allowedText(snapshot.ordinaryUsageAllowed))"
            )
            lines.append("Codex read at: \(TrayInfoModel.dateText(snapshot.observedAt))")
        }
        if let scheduledAt = state.lastNotificationScheduledAt {
            lines.append(
                "Last reset notification request: \(TrayInfoModel.dateText(scheduledAt)) "
                    + "(visual delivery not confirmed)"
            )
        }
        if let lastSuccess = state.lastForecastSuccess {
            lines.append(
                "Forecast last updated: \(TrayInfoModel.dateText(lastSuccess))"
            )
        }
        return lines
    }

    private static func codexStatusLine(_ state: TrayMenuState) -> String {
        if let error = state.codexError {
            return "Codex error: \(error)"
        }
        if let weekly = state.snapshot?.weeklyWindow {
            var text = "7-day Codex usage: \(TrayInfoModel.percent(weekly.usedPercent))"
            if let resetsAt = weekly.resetsAt {
                text += " · resets \(TrayInfoModel.dateText(resetsAt))"
            }
            return text
        }
        if state.snapshot != nil {
            return "Codex returned no 7-day usage window."
        }
        if state.isPollingCodex {
            return "Codex: reading usage…"
        }
        return "Codex: no usage has been read yet."
    }

    private static func codexWindowsLine(_ state: TrayMenuState) -> String {
        guard let snapshot = state.snapshot else {
            return state.isPollingCodex
                ? "Waiting for Codex app-server…"
                : "Codex usage details are unavailable."
        }
        var windows: [String] = []
        if let primary = snapshot.primary {
            windows.append(windowText("Primary", window: primary))
        }
        if let secondary = snapshot.secondary {
            windows.append(windowText("Secondary", window: secondary))
        }
        return windows.isEmpty
            ? "No usage windows were reported."
            : windows.joined(separator: " · ")
    }

    private static func codexMetaLine(_ state: TrayMenuState) -> String {
        if let baseline = state.baseline {
            var text = "Baseline: \(TrayInfoModel.percent(baseline.usedPercent))"
            if let resetsAt = baseline.resetsAt {
                text += " · prior reset \(TrayInfoModel.dateText(resetsAt))"
            } else {
                text += " · no prior reset deadline"
            }
            return text
        }
        if let snapshot = state.snapshot {
            return "Ordinary usage allowed: "
                + "\(TrayInfoModel.allowedText(snapshot.ordinaryUsageAllowed))"
        }
        if let lastCheck = state.lastCodexCheck {
            return "Last Codex check: \(TrayInfoModel.dateText(lastCheck))"
        }
        return "No Codex baseline yet."
    }

    private static func notificationStatusLine(_ state: TrayMenuState) -> String {
        state.notificationStatus
            ?? "Notifications: permission has not been checked yet."
    }

    private static func forecastSummaryLine(_ state: TrayMenuState) -> String {
        if let forecast = state.forecast {
            let stale = state.forecastError != nil
            let freshness = stale
                ? " (stale, updated "
                    + "\(state.lastForecastSuccess.map(TrayInfoModel.dateText) ?? "time unknown"))"
                : ""
            return "Forecast\(freshness): \(forecast.probability24h)% within 24h · "
                + "\(forecast.probability48h)% within 48h"
        }
        if let error = state.forecastError {
            return "Forecast error: \(error)"
        }
        return state.isFetchingForecast
            ? "Forecast: fetching from codexreset.org…"
            : "Forecast: not loaded yet."
    }

    private static func forecastDetailLine(_ state: TrayMenuState) -> String {
        if let forecast = state.forecast {
            if let error = state.forecastError {
                return "Forecast refresh failed: \(error)"
            }
            return "Latest confirmed reset: \(TrayInfoModel.dateText(forecast.resetAt)) · "
                + "\(forecast.resetStatus)"
        }
        return "Site forecasts are informational only and never trigger alerts."
    }

    private static func windowText(
        _ slot: String,
        window: CodexRateLimitWindow
    ) -> String {
        var text = "\(slot) \(window.durationLabel): "
            + "\(TrayInfoModel.percent(window.usedPercent))"
        if let resetsAt = window.resetsAt {
            text += " (resets \(TrayInfoModel.dateText(resetsAt)))"
        }
        return text
    }

    /// Compact label for the status item and its VoiceOver help text.
    static func accessibilityDescription(for state: TrayMenuState) -> String {
        var parts = ["Codex Reset Tray"]
        if let weekly = state.snapshot?.weeklyWindow {
            parts.append("7-day Codex usage \(TrayInfoModel.percent(weekly.usedPercent))")
        } else if state.isPollingCodex {
            parts.append("reading Codex usage")
        } else {
            parts.append("Codex usage not loaded")
        }
        if let error = state.codexError {
            parts.append("error: \(error)")
        }
        return parts.joined(separator: ", ")
    }
}
