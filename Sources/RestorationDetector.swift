import Foundation

struct WeeklyUsageBaseline: Codable, Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date?
    var capturedAt: Date
    /// The reset deadline of a window for which an early-restoration alert was
    /// already evaluated. This prevents repeat notifications for the same window.
    var alertedResetsAt: Date?
}

struct RestorationAlert: Equatable, Sendable {
    let previousPercent: Double
    let currentPercent: Double
    let resetsAt: Date
    let capturedAt: Date
    /// Backend permission is reported with the alert but is not required as
    /// evidence that the quota itself was restored.
    let ordinaryUsageAllowed: Bool?
}

struct RestorationEvaluation: Equatable, Sendable {
    let baseline: WeeklyUsageBaseline
    let alert: RestorationAlert?
}

extension WeeklyUsageBaseline {
    /// The alert marker is committed only after the notification request has
    /// been accepted by the system scheduler.
    func markingAlerted(resetsAt deadline: Date) -> WeeklyUsageBaseline {
        var updated = self
        updated.alertedResetsAt = deadline
        return updated
    }
}

enum RestorationDetector {
    /// Usage at or below this level is consistent with a freshly restored quota.
    /// It deliberately does not require exactly zero: usage can be consumed again
    /// before the next poll.
    static let restoredUsageCeilingPercent = 25.0
    /// A drop to this level from at least `nearZeroDropPoints` is treated as a
    /// cleared quota even when the absolute drop is small.
    static let nearZeroPercent = 1.0
    static let nearZeroDropPoints = 2.0
    /// A material drop is at least this many percentage points and at least half
    /// of the prior usage. This ignores tiny fluctuations while still catching
    /// resets when the prior usage was small.
    static let materialDropPoints = 3.0
    static let materialDropFraction = 0.5
    /// A new reset deadline this far ahead of the prior one is evidence of a new
    /// window rather than a small backend clock adjustment.
    static let newWindowAdvance: TimeInterval = 5 * 60
    /// Do not treat a rollover this close to the scheduled deadline as an early
    /// restoration. This prevents a backend that rolls the window a few seconds
    /// early from producing a scheduled-reset notification.
    static let scheduledResetMargin: TimeInterval = 5 * 60

    /// The first successful reading of a launch only establishes current state.
    /// It never alerts, even when a persisted baseline exists, because that state
    /// may describe a reset that happened while the app was not running.
    static func establishBaseline(
        previous: WeeklyUsageBaseline?,
        current: CodexRateLimitWindow,
        now: Date
    ) -> WeeklyUsageBaseline {
        WeeklyUsageBaseline(
            usedPercent: current.usedPercent,
            resetsAt: current.resetsAt,
            capturedAt: now,
            alertedResetsAt: previous?.alertedResetsAt
        )
    }

    static func evaluate(
        previous: WeeklyUsageBaseline?,
        current: CodexRateLimitWindow,
        ordinaryUsageAllowed: Bool?,
        now: Date
    ) -> RestorationEvaluation {
        let next = establishBaseline(previous: previous, current: current, now: now)

        // The first reading establishes the baseline. Never alert on it.
        guard let previous else {
            return RestorationEvaluation(baseline: next, alert: nil)
        }

        // The prior window's deadline is the only schedule used here. A missing
        // deadline, a reset that is already due or imminent, or an alert already
        // handled for this window all suppress notification.
        guard let deadline = previous.resetsAt,
              deadline.timeIntervalSince(now) > scheduledResetMargin,
              !isSameDeadline(previous.alertedResetsAt, deadline),
              previous.usedPercent > 0 else {
            return RestorationEvaluation(baseline: next, alert: nil)
        }

        let currentIsLow = current.usedPercent <= restoredUsageCeilingPercent
        let drop = previous.usedPercent - current.usedPercent
        let relativeDrop = drop / previous.usedPercent
        let clearedToNearZero = current.usedPercent <= nearZeroPercent
            && drop >= nearZeroDropPoints
        let materialDrop = drop >= materialDropPoints
            && relativeDrop >= materialDropFraction
        // A later deadline while the old deadline is still comfortably in the
        // future means the backend started a new window early.
        let deadlineAdvanced = current.resetsAt.map {
            $0.timeIntervalSince(deadline) >= newWindowAdvance
        } ?? false

        guard currentIsLow,
              deadlineAdvanced || materialDrop || clearedToNearZero else {
            return RestorationEvaluation(baseline: next, alert: nil)
        }

        return RestorationEvaluation(
            baseline: next,
            alert: RestorationAlert(
                previousPercent: previous.usedPercent,
                currentPercent: current.usedPercent,
                resetsAt: deadline,
                capturedAt: now,
                ordinaryUsageAllowed: ordinaryUsageAllowed
            )
        )
    }

    /// Dates persisted through UserDefaults are stored at second precision. The
    /// app-server reports reset deadlines in Unix seconds, so compare at the same
    /// precision rather than letting a subsecond round-trip defeat the marker.
    private static func isSameDeadline(_ lhs: Date?, _ rhs: Date) -> Bool {
        guard let lhs else { return false }
        return Int(lhs.timeIntervalSince1970.rounded())
            == Int(rhs.timeIntervalSince1970.rounded())
    }
}

struct CodexPollResult: Equatable, Sendable {
    let snapshot: CodexRateLimitSnapshot?
    let baseline: WeeklyUsageBaseline?
    let alert: RestorationAlert?
    let errorMessage: String?
    /// Present only when this response contained a readable 7-day window.
    let observedWeekly: CodexRateLimitWindow?
}

enum CodexPoller {
    /// Pure poll processing so failure paths can be tested: a failed or unreadable
    /// response preserves the existing baseline and can never produce an alert.
    static func apply(
        _ fetch: Result<CodexRateLimitSnapshot, Error>,
        baseline: WeeklyUsageBaseline?,
        now: Date
    ) -> CodexPollResult {
        switch fetch {
        case .failure(let error):
            return CodexPollResult(
                snapshot: nil,
                baseline: baseline,
                alert: nil,
                errorMessage: error.localizedDescription,
                observedWeekly: nil
            )
        case .success(let snapshot):
            guard let weekly = snapshot.weeklyWindow else {
                return CodexPollResult(
                    snapshot: snapshot,
                    baseline: baseline,
                    alert: nil,
                    errorMessage: "Codex returned no 7-day usage window; no restoration alert was evaluated.",
                    observedWeekly: nil
                )
            }
            let evaluation = RestorationDetector.evaluate(
                previous: baseline,
                current: weekly,
                ordinaryUsageAllowed: snapshot.ordinaryUsageAllowed,
                now: now
            )
            return CodexPollResult(
                snapshot: snapshot,
                baseline: evaluation.baseline,
                alert: evaluation.alert,
                errorMessage: nil,
                observedWeekly: weekly
            )
        }
    }
}

struct BaselineStore {
    static let key = "codexWeeklyUsageBaselineV2"
    let defaults: UserDefaults

    func load() -> WeeklyUsageBaseline? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WeeklyUsageBaseline.self, from: data)
    }

    func save(_ baseline: WeeklyUsageBaseline?) {
        guard let baseline else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(baseline) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
