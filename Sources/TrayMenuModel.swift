import Foundation

enum TrayMenuAction: Hashable {
    case refresh
    case copyStatus
    case toggleMenuBarUsage
    case openWebsite
    case donate
    case quit
}

/// The right-click menu is deliberately limited to configuration and actions.
/// It has no informational cases: status, usage, reset, notification, and
/// forecast content lives in `TrayInfoModel` and the left-click popover.
enum TrayMenuItemRole: Hashable {
    case separator
    case action(TrayMenuAction)
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
        showsUsageInMenuBar: Bool = true
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
    }
}

/// Pure representation of the right-click actions menu. Keeping the
/// presentation here makes the always-available configuration and actions
/// testable without opening a GUI. Informational rows are intentionally absent,
/// so the native menu cannot regress into a second status surface.
struct TrayMenuModel: Equatable {
    static let websiteURL = URL(string: "https://codexreset.org/")!
    static let donationURL = URL(string: "https://paypal.me/sklivvz")!

    let items: [TrayMenuItem]

    func item(withRole role: TrayMenuItemRole) -> TrayMenuItem? {
        items.first { $0.role == role }
    }

    static func make(state: TrayMenuState) -> TrayMenuModel {
        // A separator before Quit is the one native menu convention retained:
        // it keeps the terminating action apart from configuration and links.
        // There is no heading, because the menu is not an information panel.
        let items: [TrayMenuItem] = [
            TrayMenuItem(
                role: .action(.toggleMenuBarUsage),
                title: state.showsUsageInMenuBar ? "Hide 7d Label" : "Show 7d Label",
                isEnabled: true,
                toolTip: state.showsUsageInMenuBar
                    ? "Hide the 7d usage percentage in the menu bar. The icon remains visible."
                    : "Show the 7d usage percentage next to the menu bar icon. The icon is always visible.",
                isChecked: state.showsUsageInMenuBar
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
                role: .action(.quit),
                title: "Quit Codex Reset Tray",
                isEnabled: true,
                toolTip: "Quit Codex Reset Tray."
            ),
        ]
        return TrayMenuModel(items: items)
    }

    /// Plain-text status for the Copy Status Summary action. It deliberately
    /// mirrors the information popover's rows and footer (plus the public
    /// version), drops exact duplicate lines, and never includes app-server
    /// account identifiers or credentials.
    static func statusSummary(for state: TrayMenuState) -> String {
        let info = TrayInfoModel.make(state: state)
        var lines = [
            "Codex Reset Tray \(AppBuildInfo.version) (build \(AppBuildInfo.build))",
            "Project: \(AppBuildInfo.projectURL.absoluteString)",
        ]
        var seen = Set(lines)
        for line in info.allRows.map(\.text) + info.footer {
            if seen.insert(line).inserted {
                lines.append(line)
            }
        }
        lines.append("This summary contains no account ID, credential, or local file path.")
        return lines.joined(separator: "\n")
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
