import Foundation

enum TrayInfoTone: Equatable {
    case normal
    case error
}

/// Identifies an informational row in the left-click popover. These cases are
/// intentionally separate from `TrayMenuItemRole`: they can never be added to
/// the right-click menu model.
enum TrayInfoRowRole: Hashable {
    case codexStatus
    case codexWindows
    case codexMeta
    case notificationStatus
    case forecastSummary
    case forecastDetail
}

struct TrayInfoRow: Equatable {
    let role: TrayInfoRowRole
    let text: String
    let tone: TrayInfoTone
    let toolTip: String?
}

struct TrayInfoSection: Equatable {
    let title: String
    let rows: [TrayInfoRow]
}

/// Pure representation of the information popover opened by a left click on the
/// status icon. It contains every status, usage, reset, notification, and
/// forecast value; the actions menu intentionally contains none of them.
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

    var allRows: [TrayInfoRow] {
        sections.flatMap { $0.rows }
    }

    func row(withRole role: TrayInfoRowRole) -> TrayInfoRow? {
        for section in sections {
            if let row = section.rows.first(where: { $0.role == role }) {
                return row
            }
        }
        return nil
    }

    static func make(state: TrayMenuState) -> TrayInfoModel {
        let weekly = state.snapshot?.weeklyWindow
        var footer: [String] = []
        if let lastCheck = state.lastCodexCheck {
            footer.append("Last Codex check: \(dateText(lastCheck))")
        }
        if let lastCheck = state.lastForecastCheck {
            footer.append("Last forecast check: \(dateText(lastCheck))")
        }
        footer.append("Menu bar 7d label: \(state.showsUsageInMenuBar ? "shown" : "hidden")")
        if let snapshot = state.snapshot {
            footer.append("Ordinary usage allowed: \(allowedText(snapshot.ordinaryUsageAllowed))")
            footer.append("Codex read at: \(dateText(snapshot.observedAt))")
        }
        if let scheduledAt = state.lastNotificationScheduledAt {
            footer.append(
                "Last reset notification request: \(dateText(scheduledAt)) "
                    + "(visual delivery not confirmed)"
            )
        }
        if let lastSuccess = state.lastForecastSuccess {
            footer.append("Forecast last updated: \(dateText(lastSuccess))")
        }

        return TrayInfoModel(
            title: "Codex Reset Tray",
            version: "Version \(AppBuildInfo.version) (build \(AppBuildInfo.build))",
            usageValue: weekly.map { percent($0.usedPercent) } ?? "--",
            usageCaption: weekly == nil ? "7-day Codex usage unavailable" : "7-day Codex usage",
            usageFraction: weekly.map { min(max($0.usedPercent / 100, 0), 1) },
            sections: [
                TrayInfoSection(
                    title: "Codex usage",
                    rows: [
                        codexStatusRow(state),
                        codexWindowsRow(state),
                        codexMetaRow(state),
                        notificationStatusRow(state),
                    ]
                ),
                TrayInfoSection(
                    title: "Reset forecast",
                    rows: [
                        forecastSummaryRow(state),
                        forecastDetailRow(state),
                    ]
                ),
            ],
            footer: footer
        )
    }

    private static func codexStatusRow(_ state: TrayMenuState) -> TrayInfoRow {
        if let error = state.codexError {
            return TrayInfoRow(
                role: .codexStatus,
                text: "Codex error: \(error)",
                tone: .error,
                toolTip: nil
            )
        }

        if let weekly = state.snapshot?.weeklyWindow {
            var text = "7-day Codex usage: \(percent(weekly.usedPercent))"
            if let resetsAt = weekly.resetsAt {
                text += " · resets \(dateText(resetsAt))"
            }
            return TrayInfoRow(
                role: .codexStatus,
                text: text,
                tone: .normal,
                toolTip: "Codex app-server is the source of truth for usage alerts."
            )
        }

        if state.snapshot != nil {
            return TrayInfoRow(
                role: .codexStatus,
                text: "Codex returned no 7-day usage window.",
                tone: .error,
                toolTip: nil
            )
        }

        if state.isPollingCodex {
            return TrayInfoRow(
                role: .codexStatus,
                text: "Codex: reading usage…",
                tone: .normal,
                toolTip: nil
            )
        }

        return TrayInfoRow(
            role: .codexStatus,
            text: "Codex: no usage has been read yet.",
            tone: .normal,
            toolTip: nil
        )
    }

    private static func codexWindowsRow(_ state: TrayMenuState) -> TrayInfoRow {
        guard let snapshot = state.snapshot else {
            return TrayInfoRow(
                role: .codexWindows,
                text: state.isPollingCodex
                    ? "Waiting for Codex app-server…"
                    : "Codex usage details are unavailable.",
                tone: .normal,
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
        return TrayInfoRow(
            role: .codexWindows,
            text: windows.isEmpty ? "No usage windows were reported." : windows.joined(separator: " · "),
            tone: .normal,
            toolTip: nil
        )
    }

    private static func codexMetaRow(_ state: TrayMenuState) -> TrayInfoRow {
        var text: String
        if let baseline = state.baseline {
            text = "Baseline: \(percent(baseline.usedPercent))"
            if let resetsAt = baseline.resetsAt {
                text += " · prior reset \(dateText(resetsAt))"
            } else {
                text += " · no prior reset deadline"
            }
        } else if let snapshot = state.snapshot {
            text = "Ordinary usage allowed: \(allowedText(snapshot.ordinaryUsageAllowed))"
        } else if let lastCheck = state.lastCodexCheck {
            text = "Last Codex check: \(dateText(lastCheck))"
        } else {
            text = "No Codex baseline yet."
        }

        var toolTipParts: [String] = []
        if let snapshot = state.snapshot {
            toolTipParts.append("Ordinary usage allowed: \(allowedText(snapshot.ordinaryUsageAllowed))")
            toolTipParts.append("Codex read at \(dateText(snapshot.observedAt))")
        }
        if let scheduledAt = state.lastNotificationScheduledAt {
            toolTipParts.append(
                "Reset notification request scheduled at \(dateText(scheduledAt)); "
                    + "visual delivery is controlled by macOS."
            )
        }
        if let notificationStatus = state.notificationStatus {
            toolTipParts.append(notificationStatus)
        }
        return TrayInfoRow(
            role: .codexMeta,
            text: text,
            tone: .normal,
            toolTip: toolTipParts.isEmpty ? nil : toolTipParts.joined(separator: "\n")
        )
    }

    private static func notificationStatusRow(_ state: TrayMenuState) -> TrayInfoRow {
        TrayInfoRow(
            role: .notificationStatus,
            text: state.notificationStatus ?? "Notifications: permission has not been checked yet.",
            tone: state.notificationStatusIsError ? .error : .normal,
            toolTip: "Notification permission and scheduling state for reset alerts. "
                + "Scheduling a request does not confirm that a banner was displayed."
        )
    }

    private static func forecastSummaryRow(_ state: TrayMenuState) -> TrayInfoRow {
        if let forecast = state.forecast {
            let stale = state.forecastError != nil
            let freshness = stale
                ? " (stale, updated \(state.lastForecastSuccess.map(dateText) ?? "time unknown"))"
                : ""
            return TrayInfoRow(
                role: .forecastSummary,
                text: "Forecast\(freshness): \(forecast.probability24h)% within 24h · "
                    + "\(forecast.probability48h)% within 48h",
                tone: stale ? .error : .normal,
                toolTip: stale
                    ? "\(forecast.forecastSummary)\nLast updated: "
                        + "\(state.lastForecastSuccess.map(dateText) ?? "unknown")"
                    : forecast.forecastSummary
            )
        }

        if let error = state.forecastError {
            return TrayInfoRow(
                role: .forecastSummary,
                text: "Forecast error: \(error)",
                tone: .error,
                toolTip: nil
            )
        }

        return TrayInfoRow(
            role: .forecastSummary,
            text: state.isFetchingForecast
                ? "Forecast: fetching from codexreset.org…"
                : "Forecast: not loaded yet.",
            tone: .normal,
            toolTip: "The information popover fetches the forecast when it opens."
        )
    }

    private static func forecastDetailRow(_ state: TrayMenuState) -> TrayInfoRow {
        if let forecast = state.forecast {
            if let error = state.forecastError {
                return TrayInfoRow(
                    role: .forecastDetail,
                    text: "Forecast refresh failed: \(error)",
                    tone: .error,
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
            return TrayInfoRow(
                role: .forecastDetail,
                text: "Latest confirmed reset: \(dateText(forecast.resetAt)) · \(forecast.resetStatus)",
                tone: .normal,
                toolTip: toolTipParts.joined(separator: "\n")
            )
        }

        return TrayInfoRow(
            role: .forecastDetail,
            text: "Site forecasts are informational only and never trigger alerts.",
            tone: .normal,
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

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    static func allowedText(_ allowed: Bool?) -> String {
        switch allowed {
        case .some(true): return "yes"
        case .some(false): return "no"
        case .none: return "unknown"
        }
    }

    static func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
