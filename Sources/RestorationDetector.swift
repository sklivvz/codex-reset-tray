import Foundation

struct WeeklyUsageBaseline: Codable, Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date?
    var capturedAt: Date
    /// The reset deadline of a window for which an early-restoration alert was
    /// already evaluated. This prevents repeat notifications for the same window.
    var alertedResetsAt: Date?
}

enum ResetTiming: Equatable, Sendable {
    /// The previous window reached its scheduled deadline before Codex reported
    /// the next window.
    case scheduled
    /// Codex reported a new window, or a quota restoration, before the previous
    /// window's deadline.
    case early
}

struct RestorationAlert: Equatable, Sendable {
    let previousPercent: Double
    let currentPercent: Double
    /// The deadline of the window that reset, not the deadline of the new one.
    let resetsAt: Date
    let capturedAt: Date
    let timing: ResetTiming
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
    /// A reset deadline this far ahead of the prior one is evidence of a new
    /// window rather than a small backend clock adjustment. A real new window
    /// advances `resetsAt`, whether it starts at the scheduled deadline or
    /// early: the next deadline is the new window's start plus its duration.
    static let newWindowAdvance: TimeInterval = 5 * 60
    /// A window change at or just before the prior deadline is the normal
    /// scheduled rollover. Codex can roll a window a few seconds early, so use a
    /// small margin when classifying (not suppressing) the transition.
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

        // A missing prior deadline, no observed usage to restore, or an alert
        // already scheduled for that window cannot produce another alert.
        guard let deadline = previous.resetsAt,
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
        // A new deadline is direct evidence that a window boundary happened.
        // This is the only signal that survives when usage has already climbed
        // again before the next poll, and it is how a normal scheduled rollover
        // is detected. Requiring the deadline to advance avoids treating a
        // missing deadline or a small backend timestamp correction as a reset.
        let deadlineAdvanced = current.resetsAt.map {
            $0.timeIntervalSince(deadline) >= newWindowAdvance
        } ?? false
        let atOrPastScheduledDeadline =
            now.timeIntervalSince(deadline) >= -scheduledResetMargin
        let scheduledWindowChange = deadlineAdvanced && atOrPastScheduledDeadline
        let earlyWindowChange = deadlineAdvanced && !atOrPastScheduledDeadline
        // Some early restorations clear usage without advancing the window
        // deadline. A material drop to a low reading is still a reset signal.
        let usageRestoration = currentIsLow && (materialDrop || clearedToNearZero)

        guard scheduledWindowChange || earlyWindowChange || usageRestoration else {
            return RestorationEvaluation(baseline: next, alert: nil)
        }

        // A deadline passing on its own is not enough: there must be a new
        // window or a usage drop. If the only evidence is a drop, it belongs to
        // the scheduled reset when the prior deadline has arrived.
        let timing: ResetTiming
        if scheduledWindowChange {
            timing = .scheduled
        } else if earlyWindowChange {
            timing = .early
        } else {
            timing = atOrPastScheduledDeadline ? .scheduled : .early
        }

        return RestorationEvaluation(
            baseline: next,
            alert: RestorationAlert(
                previousPercent: previous.usedPercent,
                currentPercent: current.usedPercent,
                resetsAt: deadline,
                capturedAt: now,
                timing: timing,
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
