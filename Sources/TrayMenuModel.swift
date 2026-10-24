import Foundation

enum TrayMenuAction: Hashable {
    case refresh
    case copyStatus
    case toggleMenuBarUsage
    case openWebsite
    case quit
}

enum TrayMenuItemRole: Hashable {
    case heading
    case codexStatus
    case codexWindows
    case codexMeta
    case separator
    case forecastSummary
    case forecastDetail
    case action(TrayMenuAction)
}

enum TrayMenuTone: Equatable {
    case normal
    case error
}

struct TrayMenuItem: Equatable {
    let role: TrayMenuItemRole
    let title: String
    let tone: TrayMenuTone
    let isEnabled: Bool
    let toolTip: String?
    var isChecked: Bool = false
}

struct TrayMenuState: Equatable {
    var snapshot: CodexRateLimitSnapshot?
    var codexError: String?
    var isPollingCodex: Bool
    var baseline: WeeklyUsageBaseline?
    var lastAlertAt: Date?
    var notificationStatus: String?
    var forecast: ResetSnapshot?
    var forecastError: String?
    var isFetchingForecast: Bool
    var lastCodexCheck: Date?
    var lastForecastCheck: Date?
    var showsUsageInMenuBar: Bool

    init(
        snapshot: CodexRateLimitSnapshot? = nil,
        codexError: String? = nil,
        isPollingCodex: Bool = false,
        baseline: WeeklyUsageBaseline? = nil,
        lastAlertAt: Date? = nil,
        notificationStatus: String? = nil,
        forecast: ResetSnapshot? = nil,
        forecastError: String? = nil,
        isFetchingForecast: Bool = false,
        lastCodexCheck: Date? = nil,
        lastForecastCheck: Date? = nil,
        showsUsageInMenuBar: Bool = true
    ) {
        self.snapshot = snapshot
        self.codexError = codexError
        self.isPollingCodex = isPollingCodex
        self.baseline = baseline
        self.lastAlertAt = lastAlertAt
        self.notificationStatus = notificationStatus
        self.forecast = forecast
        self.forecastError = forecastError
        self.isFetchingForecast = isFetchingForecast
        self.lastCodexCheck = lastCodexCheck
        self.lastForecastCheck = lastForecastCheck
        self.showsUsageInMenuBar = showsUsageInMenuBar
    }
}

/// Pure representation of the status menu. Keeping the presentation here makes
/// the always-available actions and every loading/error branch testable without
/// opening a GUI.
struct TrayMenuModel: Equatable {
    static let websiteURL = URL(string: "https://codexreset.org/")!

    let items: [TrayMenuItem]

    func item(withRole role: TrayMenuItemRole) -> TrayMenuItem? {
        items.first { $0.role == role }
    }

    static func make(state: TrayMenuState) -> TrayMenuModel {
        var items: [TrayMenuItem] = [
            TrayMenuItem(
                role: .heading,
                title: "Codex Reset Tray",
                tone: .normal,
                isEnabled: false,
                toolTip: nil
            ),
            codexStatusItem(state),
            codexWindowsItem(state),
            codexMetaItem(state),
            TrayMenuItem(role: .separator, title: "", tone: .normal, isEnabled: false, toolTip: nil),
            forecastSummaryItem(state),
            forecastDetailItem(state),
            TrayMenuItem(role: .separator, title: "", tone: .normal, isEnabled: false, toolTip: nil),
        ]

        // These actions are never conditional. In particular, Quit must remain
        // enabled in every loading, empty, success, and error state.
        items.append(
            TrayMenuItem(
                role: .action(.refresh),
                title: "Refresh",
                tone: .normal,
                isEnabled: true,
                toolTip: "Re-read Codex usage and the codexreset.org forecast."
            )
        )
        items.append(
            TrayMenuItem(
                role: .action(.copyStatus),
                title: "Copy Status Summary",
                tone: .normal,
                isEnabled: true,
                toolTip: "Copy a privacy-safe status summary for a bug report."
            )
        )
        items.append(
            TrayMenuItem(
                role: .action(.toggleMenuBarUsage),
                title: "Show Usage in Menu Bar",
                tone: .normal,
                isEnabled: true,
                toolTip: "Show the 7-day usage text next to the menu bar icon. The icon is always visible.",
                isChecked: state.showsUsageInMenuBar
            )
        )
        items.append(
            TrayMenuItem(
                role: .action(.openWebsite),
                title: "Open codexreset.org",
                tone: .normal,
                isEnabled: true,
                toolTip: Self.websiteURL.absoluteString
            )
        )
        items.append(
            TrayMenuItem(
                role: .action(.quit),
                title: "Quit Codex Reset Tray",
                tone: .normal,
                isEnabled: true,
                toolTip: "Quit Codex Reset Tray."
            )
        )

        return TrayMenuModel(items: items)
    }

    /// Plain-text status for the Copy Status Summary action. It deliberately
    /// contains only values already shown in the menu (plus the public version)
    /// and never includes app-server account identifiers or credentials.
    static func statusSummary(for state: TrayMenuState) -> String {
        var lines = [
            "Codex Reset Tray \(AppBuildInfo.version) (build \(AppBuildInfo.build))",
            "Project: \(AppBuildInfo.projectURL.absoluteString)",
        ]

        let model = make(state: state)
        for role in [
            TrayMenuItemRole.codexStatus,
            .codexWindows,
            .codexMeta,
            .forecastSummary,
            .forecastDetail,
        ] {
            if let item = model.item(withRole: role) {
                lines.append(item.title)
            }
        }

        if let snapshot = state.snapshot {
            lines.append("Ordinary usage allowed: \(allowedText(snapshot.ordinaryUsageAllowed))")
        }
        if let lastCheck = state.lastCodexCheck {
            lines.append("Last Codex check: \(dateText(lastCheck))")
        }
        if let lastCheck = state.lastForecastCheck {
            lines.append("Last forecast check: \(dateText(lastCheck))")
        }
        if let notificationStatus = state.notificationStatus {
            lines.append("Notifications: \(notificationStatus)")
        }
        lines.append("Menu bar usage text: \(state.showsUsageInMenuBar ? "shown" : "hidden")")
        lines.append("This summary contains no account ID, credential, or local file path.")
        return lines.joined(separator: "\n")
    }

    /// Compact label for the status item and its VoiceOver help text.
    static func accessibilityDescription(for state: TrayMenuState) -> String {
        var parts = ["Codex Reset Tray"]
        if let weekly = state.snapshot?.weeklyWindow {
            parts.append("7-day Codex usage \(percent(weekly.usedPercent))")
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

    private static func codexStatusItem(_ state: TrayMenuState) -> TrayMenuItem {
        if let error = state.codexError {
            return TrayMenuItem(
                role: .codexStatus,
                title: "Codex error: \(error)",
                tone: .error,
                isEnabled: false,
                toolTip: nil
            )
        }

        if let weekly = state.snapshot?.weeklyWindow {
            var title = "7-day Codex usage: \(percent(weekly.usedPercent))"
            if let resetsAt = weekly.resetsAt {
                title += " · resets \(dateText(resetsAt))"
            }
            return TrayMenuItem(
                role: .codexStatus,
                title: title,
                tone: .normal,
                isEnabled: false,
                toolTip: "Codex app-server is the source of truth for usage alerts."
            )
        }

        if state.snapshot != nil {
            return TrayMenuItem(
                role: .codexStatus,
                title: "Codex returned no 7-day usage window.",
                tone: .error,
                isEnabled: false,
                toolTip: nil
            )
        }

        if state.isPollingCodex {
            return TrayMenuItem(
                role: .codexStatus,
                title: "Codex: reading usage…",
                tone: .normal,
                isEnabled: false,
                toolTip: nil
            )
        }

        return TrayMenuItem(
            role: .codexStatus,
            title: "Codex: no usage has been read yet.",
            tone: .normal,
            isEnabled: false,
            toolTip: nil
        )
    }

    private static func codexWindowsItem(_ state: TrayMenuState) -> TrayMenuItem {
        guard let snapshot = state.snapshot else {
            return TrayMenuItem(
                role: .codexWindows,
                title: state.isPollingCodex ? "Waiting for Codex app-server…" : "Codex usage details are unavailable.",
                tone: .normal,
                isEnabled: false,
                toolTip: nil
            )
        }

        var windows: [String] = []
        if let primary = snapshot.primary {
            windows.append(windowText("Primary", window: primary))
        }
        if let secondary = snapshot.secondary {
            windows.append(windowText("Secondary", window: secondary))
        }
        return TrayMenuItem(
            role: .codexWindows,
            title: windows.isEmpty ? "No usage windows were reported." : windows.joined(separator: " · "),
            tone: .normal,
            isEnabled: false,
            toolTip: nil
        )
    }

    private static func codexMetaItem(_ state: TrayMenuState) -> TrayMenuItem {
        var title: String
        if let baseline = state.baseline {
            title = "Baseline: \(percent(baseline.usedPercent))"
            if let resetsAt = baseline.resetsAt {
                title += " · prior reset \(dateText(resetsAt))"
            } else {
                title += " · no prior reset deadline"
            }
        } else if let snapshot = state.snapshot {
            title = "Ordinary usage allowed: \(allowedText(snapshot.ordinaryUsageAllowed))"
        } else if let lastCheck = state.lastCodexCheck {
            title = "Last Codex check: \(dateText(lastCheck))"
        } else {
            title = "No Codex baseline yet."
        }

        var toolTipParts: [String] = []
        if let snapshot = state.snapshot {
            toolTipParts.append("Ordinary usage allowed: \(allowedText(snapshot.ordinaryUsageAllowed))")
            toolTipParts.append("Codex read at \(dateText(snapshot.observedAt))")
        }
        if let lastAlertAt = state.lastAlertAt {
            toolTipParts.append("Early-restoration alert sent at \(dateText(lastAlertAt))")
        }
        if let notificationStatus = state.notificationStatus {
            toolTipParts.append(notificationStatus)
        }
        return TrayMenuItem(
            role: .codexMeta,
            title: title,
            tone: .normal,
            isEnabled: false,
            toolTip: toolTipParts.isEmpty ? nil : toolTipParts.joined(separator: "\n")
        )
    }

    private static func forecastSummaryItem(_ state: TrayMenuState) -> TrayMenuItem {
        if let forecast = state.forecast {
            return TrayMenuItem(
                role: .forecastSummary,
                title: "Forecast: \(forecast.probability24h)% within 24h · \(forecast.probability48h)% within 48h",
                tone: .normal,
                isEnabled: false,
                toolTip: forecast.forecastSummary
            )
        }

        if let error = state.forecastError {
            return TrayMenuItem(
                role: .forecastSummary,
                title: "Forecast error: \(error)",
                tone: .error,
                isEnabled: false,
                toolTip: nil
            )
        }

        return TrayMenuItem(
            role: .forecastSummary,
            title: state.isFetchingForecast
                ? "Forecast: fetching from codexreset.org…"
                : "Forecast: not loaded yet.",
            tone: .normal,
            isEnabled: false,
            toolTip: "This menu fetches the forecast when it opens."
        )
    }

    private static func forecastDetailItem(_ state: TrayMenuState) -> TrayMenuItem {
        if let forecast = state.forecast {
            if let error = state.forecastError {
                return TrayMenuItem(
                    role: .forecastDetail,
                    title: "Forecast error: \(error)",
                    tone: .error,
                    isEnabled: false,
                    toolTip: nil
                )
            }

            var toolTipParts = [forecast.restorationStatus, forecast.forecastSummary]
            if let lastCheck = state.lastForecastCheck {
                toolTipParts.append("Forecast read at \(dateText(lastCheck))")
            }
            return TrayMenuItem(
                role: .forecastDetail,
                title: "Latest restoration: \(dateText(forecast.resetAt)) · \(forecast.resetStatus)",
                tone: .normal,
                isEnabled: false,
                toolTip: toolTipParts.joined(separator: "\n")
            )
        }

        return TrayMenuItem(
            role: .forecastDetail,
            title: "Site forecasts are informational only and never trigger alerts.",
            tone: .normal,
            isEnabled: false,
            toolTip: nil
        )
    }

    private static func windowText(_ slot: String, window: CodexRateLimitWindow) -> String {
        var text = "\(slot) \(window.durationLabel): \(percent(window.usedPercent))"
        if let resetsAt = window.resetsAt {
            text += " (resets \(dateText(resetsAt)))"
        }
        return text
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func allowedText(_ allowed: Bool?) -> String {
        switch allowed {
        case .some(true): return "yes"
        case .some(false): return "no"
        case .none: return "unknown"
        }
    }

    private static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
