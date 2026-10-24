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
}

struct RestorationEvaluation: Equatable, Sendable {
    let baseline: WeeklyUsageBaseline
    let alert: RestorationAlert?
}

enum RestorationDetector {
    /// "Near zero" avoids treating an ordinary one-point quota refresh as an
    /// early restoration.
    static let nearZeroPercent = 1.0
    /// A material drop is at least this many percentage points. This intentionally
    /// ignores tiny movements such as 1% -> 0%.
    static let materialDropPoints = 5.0

    static func evaluate(
        previous: WeeklyUsageBaseline?,
        current: CodexRateLimitWindow,
        ordinaryUsageAllowed: Bool?,
        now: Date
    ) -> RestorationEvaluation {
        let next = WeeklyUsageBaseline(
            usedPercent: current.usedPercent,
            resetsAt: current.resetsAt,
            capturedAt: now,
            alertedResetsAt: previous?.alertedResetsAt
        )

        // The first successful reading establishes the baseline. Never alert on it.
        guard let previous else {
            return RestorationEvaluation(baseline: next, alert: nil)
        }

        // The prior window's deadline is the only schedule used here. A missing
        // deadline, a scheduled reset that has already arrived, or an alert already
        // handled for this window all suppress notification.
        guard let deadline = previous.resetsAt,
              now < deadline,
              previous.alertedResetsAt != deadline else {
            return RestorationEvaluation(baseline: next, alert: nil)
        }

        // Backend permission is supporting evidence for a restored account. False or
        // unavailable evidence never produces an alert.
        guard ordinaryUsageAllowed == true else {
            return RestorationEvaluation(baseline: next, alert: nil)
        }

        let drop = previous.usedPercent - current.usedPercent
        guard previous.usedPercent > 0,
              current.usedPercent <= nearZeroPercent,
              drop >= materialDropPoints else {
            return RestorationEvaluation(baseline: next, alert: nil)
        }

        var alerted = next
        alerted.alertedResetsAt = deadline
        return RestorationEvaluation(
            baseline: alerted,
            alert: RestorationAlert(
                previousPercent: previous.usedPercent,
                currentPercent: current.usedPercent,
                resetsAt: deadline,
                capturedAt: now
            )
        )
    }
}

struct CodexPollResult: Equatable, Sendable {
    let snapshot: CodexRateLimitSnapshot?
    let baseline: WeeklyUsageBaseline?
    let alert: RestorationAlert?
    let errorMessage: String?
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
                errorMessage: error.localizedDescription
            )
        case .success(let snapshot):
            guard let weekly = snapshot.weeklyWindow else {
                return CodexPollResult(
                    snapshot: snapshot,
                    baseline: baseline,
                    alert: nil,
                    errorMessage: "Codex returned no 7-day usage window; no restoration alert was evaluated."
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
                errorMessage: nil
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
