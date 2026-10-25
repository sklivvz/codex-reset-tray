import Foundation

enum TrayInfoTone: Equatable {
    case normal
    case error
}

/// One of the two large forecast figures. The popover renders the value at a
/// display size and the caption beneath it.
struct TrayForecastFigure: Equatable {
    let horizon: String
    let value: String
    let caption: String
}

/// The forecast area is intentionally small: two probabilities plus one short
/// state line. Loading and stale states use the same two figures so the layout
/// never jumps between an empty sentence and the data.
enum TrayForecastState: Equatable {
    case loading
    case current
    case stale(updated: String?, error: String?)
    case unavailable(error: String)
}

struct TrayInfoMessage: Equatable {
    let text: String
    let tone: TrayInfoTone
}

/// Compact representation of the left-click data popover. The popover keeps
/// only the usage headline/meter and the two 24h/48h forecast figures. Codex
/// windows, baseline, notification prose, reset confirmation, check times,
/// version/build, and the old footer are deliberately absent; the copied
/// diagnostic report remains the full record.
struct TrayInfoModel: Equatable {
    let title: String
    let usageValue: String
    let usageCaption: String
    /// 0...1 when a 7-day window is known; `nil` hides the meter.
    let usageFraction: Double?
    let forecastFigures: [TrayForecastFigure]
    let forecastState: TrayForecastState
    /// A short loading/stale/error line, or `nil` for a current forecast.
    let forecastStatus: TrayInfoMessage?
    let forecastToolTip: String?

    static func make(state: TrayMenuState) -> TrayInfoModel {
        let weekly = state.snapshot?.weeklyWindow
        let figures = [
            forecastFigure(horizon: "24h", probability: state.forecast?.probability24h),
            forecastFigure(horizon: "48h", probability: state.forecast?.probability48h),
        ]
        let forecastState = makeForecastState(state)
        return TrayInfoModel(
            title: "Codex Reset Tray",
            usageValue: weekly.map { percent($0.usedPercent) } ?? "--",
            usageCaption: weekly == nil
                ? "7-day Codex usage unavailable"
                : "7-day Codex usage",
            usageFraction: weekly.map { min(max($0.usedPercent / 100, 0), 1) },
            forecastFigures: figures,
            forecastState: forecastState,
            forecastStatus: makeForecastStatus(for: state, forecastState: forecastState),
            forecastToolTip: makeForecastToolTip(for: state)
        )
    }

    private static func forecastFigure(
        horizon: String,
        probability: Int?
    ) -> TrayForecastFigure {
        TrayForecastFigure(
            horizon: horizon,
            value: probability.map { "\($0)%" } ?? "--",
            caption: "within \(horizon)"
        )
    }

    private static func makeForecastState(_ state: TrayMenuState) -> TrayForecastState {
        if state.forecast != nil {
            if let error = state.forecastError {
                return .stale(
                    updated: state.lastForecastSuccess.map(dateText),
                    error: error
                )
            }
            return .current
        }
        if let error = state.forecastError {
            return .unavailable(error: error)
        }
        return .loading
    }

    private static func makeForecastStatus(
        for state: TrayMenuState,
        forecastState: TrayForecastState
    ) -> TrayInfoMessage? {
        switch forecastState {
        case .current:
            return nil
        case .loading:
            return TrayInfoMessage(
                text: state.isFetchingForecast
                    ? "Loading forecast…"
                    : "Forecast not loaded yet.",
                tone: .normal
            )
        case .stale(let updated, let error):
            var text = "Stale forecast · updated \(updated ?? "time unknown")"
            if let error {
                text += " · \(error)"
            }
            return TrayInfoMessage(text: text, tone: .error)
        case .unavailable(let error):
            return TrayInfoMessage(
                text: "Forecast unavailable: \(error)",
                tone: .error
            )
        }
    }

    private static func makeForecastToolTip(for state: TrayMenuState) -> String? {
        var parts: [String] = []
        if let forecast = state.forecast {
            parts.append(forecast.forecastSummary)
            parts.append(forecast.restorationStatus)
        }
        if let lastSuccess = state.lastForecastSuccess {
            parts.append("Forecast updated \(dateText(lastSuccess))")
        }
        if let lastCheck = state.lastForecastCheck {
            parts.append("Forecast checked \(dateText(lastCheck))")
        }
        if let error = state.forecastError {
            parts.append("Refresh failed: \(error)")
        }
        if parts.isEmpty {
            parts.append("The forecast is fetched when the popover opens.")
        }
        return parts.joined(separator: "\n")
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
