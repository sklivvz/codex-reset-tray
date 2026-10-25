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
    case notificationStatus
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
    /// `false` is reserved for controls that are genuinely unavailable (and for
    /// separators). Informational rows are enabled so they render in the normal
    /// label color; they are non-interactive because they have no action.
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
    var lastAlertAt: Date?
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
        lastAlertAt: Date? = nil,
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
        self.lastAlertAt = lastAlertAt
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
                isEnabled: true,
                toolTip: nil
            ),
            // Keep the label toggle immediately below the heading so it is
            // discoverable without scanning the status, forecast, and actions.
            TrayMenuItem(
                role: .action(.toggleMenuBarUsage),
                title: state.showsUsageInMenuBar ? "Hide 7d Label" : "Show 7d Label",
                tone: .normal,
                isEnabled: true,
                toolTip: state.showsUsageInMenuBar
                    ? "Hide the 7d usage percentage in the menu bar. The icon remains visible."
                    : "Show the 7d usage percentage next to the menu bar icon. The icon is always visible.",
                isChecked: state.showsUsageInMenuBar
            ),
            codexStatusItem(state),
            codexWindowsItem(state),
            codexMetaItem(state),
            notificationStatusItem(state),
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
            .notificationStatus,
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
        if let lastSuccess = state.lastForecastSuccess {
            lines.append("Forecast last updated: \(dateText(lastSuccess))")
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
                isEnabled: true,
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
                isEnabled: true,
                toolTip: "Codex app-server is the source of truth for usage alerts."
            )
        }

        if state.snapshot != nil {
            return TrayMenuItem(
                role: .codexStatus,
                title: "Codex returned no 7-day usage window.",
                tone: .error,
                isEnabled: true,
                toolTip: nil
            )
        }

        if state.isPollingCodex {
            return TrayMenuItem(
                role: .codexStatus,
                title: "Codex: reading usage…",
                tone: .normal,
                isEnabled: true,
                toolTip: nil
            )
        }

        return TrayMenuItem(
            role: .codexStatus,
            title: "Codex: no usage has been read yet.",
            tone: .normal,
            isEnabled: true,
            toolTip: nil
        )
    }

    private static func codexWindowsItem(_ state: TrayMenuState) -> TrayMenuItem {
        guard let snapshot = state.snapshot else {
            return TrayMenuItem(
                role: .codexWindows,
                title: state.isPollingCodex ? "Waiting for Codex app-server…" : "Codex usage details are unavailable.",
                tone: .normal,
                isEnabled: true,
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
            isEnabled: true,
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
            isEnabled: true,
            toolTip: toolTipParts.isEmpty ? nil : toolTipParts.joined(separator: "\n")
        )
    }

    private static func notificationStatusItem(_ state: TrayMenuState) -> TrayMenuItem {
        TrayMenuItem(
            role: .notificationStatus,
            title: state.notificationStatus ?? "Notifications: permission has not been requested yet.",
            tone: state.notificationStatusIsError ? .error : .normal,
            isEnabled: true,
            toolTip: "Notification permission and delivery state for early-restoration alerts."
        )
    }

    private static func forecastSummaryItem(_ state: TrayMenuState) -> TrayMenuItem {
        if let forecast = state.forecast {
            let stale = state.forecastError != nil
            let freshness = stale ? " (stale, updated \(state.lastForecastSuccess.map(dateText) ?? "time unknown"))" : ""
            return TrayMenuItem(
                role: .forecastSummary,
                title: "Forecast\(freshness): \(forecast.probability24h)% within 24h · \(forecast.probability48h)% within 48h",
                tone: stale ? .error : .normal,
                isEnabled: true,
                toolTip: stale ? "\(forecast.forecastSummary)\nLast updated: \(state.lastForecastSuccess.map(dateText) ?? "unknown")" : forecast.forecastSummary
            )
        }

        if let error = state.forecastError {
            return TrayMenuItem(
                role: .forecastSummary,
                title: "Forecast error: \(error)",
                tone: .error,
                isEnabled: true,
                toolTip: nil
            )
        }

        return TrayMenuItem(
            role: .forecastSummary,
            title: state.isFetchingForecast
                ? "Forecast: fetching from codexreset.org…"
                : "Forecast: not loaded yet.",
            tone: .normal,
            isEnabled: true,
            toolTip: "This menu fetches the forecast when it opens."
        )
    }

    private static func forecastDetailItem(_ state: TrayMenuState) -> TrayMenuItem {
        if let forecast = state.forecast {
            if let error = state.forecastError {
                return TrayMenuItem(
                    role: .forecastDetail,
                    title: "Forecast refresh failed: \(error)",
                    tone: .error,
                    isEnabled: true,
                    toolTip: nil
                )
            }

            var toolTipParts = [forecast.restorationStatus, forecast.forecastSummary]
            if let lastCheck = state.lastForecastCheck {
                toolTipParts.append("Forecast read at \(dateText(lastCheck))")
            }
            if let lastSuccess = state.lastForecastSuccess {
                toolTipParts.append("Forecast updated at \(dateText(lastSuccess))")
            }
            return TrayMenuItem(
                role: .forecastDetail,
                title: "Latest restoration: \(dateText(forecast.resetAt)) · \(forecast.resetStatus)",
                tone: .normal,
                isEnabled: true,
                toolTip: toolTipParts.joined(separator: "\n")
            )
        }

        return TrayMenuItem(
            role: .forecastDetail,
            title: "Site forecasts are informational only and never trigger alerts.",
            tone: .normal,
            isEnabled: true,
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

    fileprivate static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private static func allowedText(_ allowed: Bool?) -> String {
        switch allowed {
        case .some(true): return "yes"
        case .some(false): return "no"
        case .none: return "unknown"
        }
    }

    fileprivate static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct TrayInfoRow: Equatable {
    let text: String
    let tone: TrayMenuTone
    let toolTip: String?
}

struct TrayInfoSection: Equatable {
    let title: String
    let rows: [TrayInfoRow]
}

/// Pure representation of the information window opened by a left click on the
/// status icon. It is derived from the same `TrayMenuState` and the same row
/// text as the menu, so the window and the menu can never disagree.
struct TrayInfoModel: Equatable {
    let title: String
    let version: String
    /// Large headline: the 7-day usage percentage, or "--" when it is unknown.
    let usageValue: String
    let usageCaption: String
    /// 0...1 when a 7-day window is known; `nil` hides the meter.
    let usageFraction: Double?
    let sections: [TrayInfoSection]
    let footer: [String]

    static func make(state: TrayMenuState) -> TrayInfoModel {
        let menu = TrayMenuModel.make(state: state)
        func rows(_ roles: [TrayMenuItemRole]) -> [TrayInfoRow] {
            roles.compactMap { menu.item(withRole: $0) }.map {
                TrayInfoRow(text: $0.title, tone: $0.tone, toolTip: $0.toolTip)
            }
        }

        let weekly = state.snapshot?.weeklyWindow
        var footer: [String] = []
        if let lastCheck = state.lastCodexCheck {
            footer.append("Last Codex check: \(TrayMenuModel.dateText(lastCheck))")
        }
        if let lastCheck = state.lastForecastCheck {
            footer.append("Last forecast check: \(TrayMenuModel.dateText(lastCheck))")
        }
        footer.append("Menu bar 7d label: \(state.showsUsageInMenuBar ? "shown" : "hidden")")

        return TrayInfoModel(
            title: "Codex Reset Tray",
            version: "Version \(AppBuildInfo.version) (build \(AppBuildInfo.build))",
            usageValue: weekly.map { TrayMenuModel.percent($0.usedPercent) } ?? "--",
            usageCaption: weekly == nil ? "7-day Codex usage unavailable" : "7-day Codex usage",
            usageFraction: weekly.map { min(max($0.usedPercent / 100, 0), 1) },
            sections: [
                TrayInfoSection(
                    title: "Codex usage",
                    rows: rows([.codexStatus, .codexWindows, .codexMeta, .notificationStatus])
                ),
                TrayInfoSection(
                    title: "Reset forecast",
                    rows: rows([.forecastSummary, .forecastDetail])
                ),
            ],
            footer: footer
        )
    }
}
