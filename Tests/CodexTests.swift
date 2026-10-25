import Foundation

let fixturesDirectory = URL(
    fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Tests/Fixtures",
    isDirectory: true
)
var failures = 0
let testNow = Date(timeIntervalSince1970: 1_800_000_000)

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if !condition() {
        failures += 1
        FileHandle.standardError.write(Data("FAIL line \(line): \(message)\n".utf8))
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String, line: Int = #line) {
    if actual != expected {
        failures += 1
        FileHandle.standardError.write(Data("FAIL line \(line): \(message) (got \(actual), expected \(expected))\n".utf8))
    }
}

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixturesDirectory.appendingPathComponent(name))
}

enum TestError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Test fetch failure" }
}

@main
struct CodexTests {
    static func main() throws {
        try testPrimaryWeeklyJSON()
        try testSecondaryWeeklyJSON()
        try testNoWeeklyWindowJSON()
        try testMalformedJSON()
        try testErrorEnvelope()
        testFirstReadingEstablishesBaseline()
        testEarlyRestorationAlertsOnce()
        testScheduledResetAlerts()
        testScheduledDeadlineWithoutResetEvidenceDoesNotAlert()
        testZeroUsageScheduledRolloverAlerts()
        testZeroUsageEarlyWindowAdvanceAlerts()
        testZeroUsageUnchangedDeadlineDoesNotAlert()
        testEarlyWindowChangeAlertsWhenUsageClimbed()
        testPermissionIsReportedNotRequired()
        testCoverageAfterResetUsageClimbs()
        testSmallPriorUsageResetAlerts()
        testNoAlertWithoutMaterialDrop()
        testNoAlertWithoutPriorDeadline()
        testPostResetUsageIncreaseRequiresAdvancedDeadline()
        testPartialUsageDropDoesNotAlertWithoutNewWindow()
        testBothWeeklySlotsAlert()
        testPollFailurePreservesBaseline()
        try testParsingFailureProducesNoAlert()
        testMissingWeeklyWindowProducesNoAlert()
        testFullTransitionSequence()
        testBaselinePersistence()
        testAlertMarkerPersistsAcrossRestart()

        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) test assertion(s) failed\n".utf8))
            exit(1)
        }
        print("Codex transition and JSON tests passed")
    }

    private static func testPrimaryWeeklyJSON() throws {
        let snapshot = try CodexRateLimitsParser.parse(
            data: fixture("rate-limits-primary-weekly.json"),
            observedAt: testNow
        )
        expectEqual(snapshot.ordinaryUsageAllowed, true, "ordinaryUsageAllowed should parse")
        expectEqual(snapshot.primary?.usedPercent, 82, "primary usedPercent")
        expectEqual(snapshot.primary?.windowDurationMins, 10_080, "primary duration")
        expectEqual(
            snapshot.primary?.resetsAt,
            Date(timeIntervalSince1970: 1_793_382_304),
            "primary resetsAt"
        )
        expect(snapshot.secondary == nil, "secondary should be null")
        expectEqual(snapshot.weeklyWindow, snapshot.primary, "7-day window should be selected by duration")
        expectEqual(snapshot.observedAt, testNow, "observedAt")
    }

    private static func testSecondaryWeeklyJSON() throws {
        let snapshot = try CodexRateLimitsParser.parse(
            data: fixture("rate-limits-secondary-weekly.json"),
            observedAt: testNow
        )
        expectEqual(snapshot.ordinaryUsageAllowed, true, "ordinaryUsageAllowed should parse")
        expectEqual(snapshot.primary?.usedPercent, 40, "primary usedPercent")
        expectEqual(snapshot.primary?.windowDurationMins, 300, "primary duration")
        expectEqual(snapshot.secondary?.usedPercent, 63, "secondary usedPercent")
        expectEqual(snapshot.weeklyWindow, snapshot.secondary, "secondary 7-day window should win")
    }

    private static func testNoWeeklyWindowJSON() throws {
        let snapshot = try CodexRateLimitsParser.parse(
            data: fixture("rate-limits-no-weekly.json"),
            observedAt: testNow
        )
        expect(snapshot.weeklyWindow == nil, "no 7-day window should be reported")
        expectEqual(snapshot.primary?.windowDurationMins, 300, "primary remains readable")
    }

    private static func testMalformedJSON() throws {
        do {
            _ = try CodexRateLimitsParser.parse(data: fixture("rate-limits-malformed.json"))
            expect(false, "malformed window should throw")
        } catch let error as CodexRateLimitsError {
            guard case .malformedWindow = error else {
                expect(false, "expected malformed window error")
                return
            }
        } catch {
            expect(false, "expected CodexRateLimitsError")
        }
    }

    private static func testErrorEnvelope() throws {
        do {
            _ = try CodexRateLimitsParser.parse(data: fixture("rate-limits-error.json"))
            expect(false, "JSON-RPC error should throw")
        } catch let error as CodexRateLimitsError {
            expectEqual(error, .serverError(code: -32601), "JSON-RPC error code should be preserved")
        } catch {
            expect(false, "expected CodexRateLimitsError")
        }
    }

    private static func testFirstReadingEstablishesBaseline() {
        let deadline = testNow.addingTimeInterval(86_400)
        let evaluation = RestorationDetector.evaluate(
            previous: nil,
            current: window(42, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: testNow
        )
        expect(evaluation.alert == nil, "first reading must not alert")
        expectEqual(evaluation.baseline.usedPercent, 42, "baseline usage")
        expectEqual(evaluation.baseline.resetsAt, deadline, "baseline deadline")
        expect(evaluation.baseline.alertedResetsAt == nil, "baseline starts unalerted")
    }

    private static func testEarlyRestorationAlertsOnce() {
        let deadline = testNow.addingTimeInterval(86_400)
        let previous = baseline(80, deadline: deadline)
        let now = deadline.addingTimeInterval(-3_600)
        let evaluation = RestorationDetector.evaluate(
            previous: previous,
            current: window(0, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: now
        )

        guard let alert = evaluation.alert else {
            expect(false, "early restoration should alert")
            return
        }
        expectEqual(alert.previousPercent, 80, "alert prior usage")
        expectEqual(alert.currentPercent, 0, "alert current usage")
        expectEqual(alert.resetsAt, deadline, "alert uses prior deadline")
        expectEqual(alert.ordinaryUsageAllowed, true, "alert carries backend permission")
        expectEqual(alert.timing, .early, "same-deadline restoration is early")
        expect(
            evaluation.baseline.alertedResetsAt == nil,
            "detector must not mark scheduled before the system accepts the request"
        )

        let committed = evaluation.baseline.markingAlerted(resetsAt: deadline)
        let repeated = RestorationDetector.evaluate(
            previous: committed,
            current: window(0, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: now.addingTimeInterval(300)
        )
        expect(repeated.alert == nil, "same window must not alert twice")
    }

    private static func testScheduledResetAlerts() {
        let deadline = testNow.addingTimeInterval(86_400)
        let previous = baseline(80, deadline: deadline)
        let nextDeadline = deadline.addingTimeInterval(7 * 86_400)
        // A normal scheduled rollover is a real reset. Codex may report it a few
        // seconds early, exactly at the deadline, or on the first poll after it.
        for now in [
            deadline.addingTimeInterval(-60),
            deadline,
            deadline.addingTimeInterval(1),
            deadline.addingTimeInterval(3_600),
        ] {
            let evaluation = RestorationDetector.evaluate(
                previous: previous,
                current: window(0, resetsAt: nextDeadline),
                ordinaryUsageAllowed: true,
                now: now
            )
            guard let alert = evaluation.alert else {
                expect(false, "scheduled reset must alert at \(now.timeIntervalSince(deadline))s")
                continue
            }
            expectEqual(alert.timing, .scheduled, "scheduled reset timing")
            expectEqual(alert.resetsAt, deadline, "scheduled alert stores the old deadline")
            expectEqual(alert.previousPercent, 80, "scheduled alert prior usage")
        }

        // A delayed poll can already see usage in the new window. The deadline
        // advance is still unambiguous evidence that the reset happened.
        let climbed = RestorationDetector.evaluate(
            previous: previous,
            current: window(40, resetsAt: nextDeadline),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(1)
        )
        expect(climbed.alert != nil, "scheduled reset must alert even when usage already climbed")
        expectEqual(climbed.alert?.timing, .scheduled, "climbed scheduled reset timing")
    }

    private static func testScheduledDeadlineWithoutResetEvidenceDoesNotAlert() {
        let deadline = testNow.addingTimeInterval(86_400)
        let evaluation = RestorationDetector.evaluate(
            previous: baseline(80, deadline: deadline),
            current: window(80, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(3_600)
        )
        expect(evaluation.alert == nil, "time passing without a new window or usage drop must not alert")
    }

    private static func testZeroUsageScheduledRolloverAlerts() {
        let deadline = testNow.addingTimeInterval(86_400)
        let previous = baseline(0, deadline: deadline)
        let nextDeadline = deadline.addingTimeInterval(7 * 86_400)
        // A 0% baseline must not hide a confirmed scheduled rollover.
        for now in [
            deadline.addingTimeInterval(-60),
            deadline,
            deadline.addingTimeInterval(3_600),
        ] {
            let evaluation = RestorationDetector.evaluate(
                previous: previous,
                current: window(0, resetsAt: nextDeadline),
                ordinaryUsageAllowed: true,
                now: now
            )
            guard let alert = evaluation.alert else {
                expect(
                    false,
                    "zero-usage scheduled rollover must alert at \(now.timeIntervalSince(deadline))s"
                )
                continue
            }
            expectEqual(alert.timing, .scheduled, "zero-usage scheduled rollover timing")
            expectEqual(alert.previousPercent, 0, "zero-usage scheduled alert prior usage")
            expectEqual(alert.currentPercent, 0, "zero-usage scheduled alert current usage")
            expectEqual(alert.resetsAt, deadline, "zero-usage scheduled alert stores the old deadline")
        }

        // New-window usage can appear before the next poll; the deadline advance
        // is still sufficient evidence of the reset.
        let climbed = RestorationDetector.evaluate(
            previous: previous,
            current: window(40, resetsAt: nextDeadline),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(1)
        )
        expect(climbed.alert != nil, "zero-usage rollover must alert even when usage already climbed")
        expectEqual(climbed.alert?.timing, .scheduled, "zero-usage climbed rollover timing")
    }

    private static func testZeroUsageEarlyWindowAdvanceAlerts() {
        let deadline = testNow.addingTimeInterval(86_400)
        let previous = baseline(0, deadline: deadline)
        let nextDeadline = deadline.addingTimeInterval(1_800)
        let now = deadline.addingTimeInterval(-3_600)

        for current in [0.0, 40.0] {
            let evaluation = RestorationDetector.evaluate(
                previous: previous,
                current: window(current, resetsAt: nextDeadline),
                ordinaryUsageAllowed: nil,
                now: now
            )
            guard let alert = evaluation.alert else {
                expect(false, "zero-usage early window advance must alert (current \(current)%)")
                continue
            }
            expectEqual(alert.timing, .early, "zero-usage early window advance timing")
            expectEqual(alert.previousPercent, 0, "zero-usage early alert prior usage")
            expectEqual(alert.currentPercent, current, "zero-usage early alert current usage")
            expectEqual(alert.resetsAt, deadline, "zero-usage early alert stores the old deadline")
        }

        let repeated = RestorationDetector.evaluate(
            previous: previous.markingAlerted(resetsAt: deadline),
            current: window(0, resetsAt: nextDeadline),
            ordinaryUsageAllowed: nil,
            now: now.addingTimeInterval(300)
        )
        expect(repeated.alert == nil, "zero-usage early window must not alert twice")
    }

    private static func testZeroUsageUnchangedDeadlineDoesNotAlert() {
        let deadline = testNow.addingTimeInterval(86_400)
        let previous = baseline(0, deadline: deadline)
        // Time passing with the same deadline must not be mistaken for a reset.
        for now in [
            deadline.addingTimeInterval(-3_600),
            deadline,
            deadline.addingTimeInterval(3_600),
        ] {
            let unchanged = RestorationDetector.evaluate(
                previous: previous,
                current: window(0, resetsAt: deadline),
                ordinaryUsageAllowed: true,
                now: now
            )
            expect(
                unchanged.alert == nil,
                "zero-usage unchanged deadline must not alert at \(now.timeIntervalSince(deadline))s"
            )

            let increased = RestorationDetector.evaluate(
                previous: previous,
                current: window(40, resetsAt: deadline),
                ordinaryUsageAllowed: true,
                now: now
            )
            expect(
                increased.alert == nil,
                "zero-usage usage increase without a new deadline must not alert"
            )
        }

        // A small backend timestamp correction below the new-window threshold is
        // not a new window either.
        let corrected = RestorationDetector.evaluate(
            previous: previous,
            current: window(0, resetsAt: deadline.addingTimeInterval(60)),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(3_600)
        )
        expect(corrected.alert == nil, "zero-usage deadline correction must not alert")
    }

    private static func testEarlyWindowChangeAlertsWhenUsageClimbed() {
        let deadline = testNow.addingTimeInterval(86_400)
        let evaluation = RestorationDetector.evaluate(
            previous: baseline(80, deadline: deadline),
            current: window(60, resetsAt: deadline.addingTimeInterval(1_800)),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(-3_600)
        )
        guard let alert = evaluation.alert else {
            expect(false, "an advanced deadline before the old deadline is an early window change")
            return
        }
        expectEqual(alert.timing, .early, "early window change timing")
        expectEqual(alert.currentPercent, 60, "early window change keeps climbed usage")
    }

    private static func testPermissionIsReportedNotRequired() {
        let deadline = testNow.addingTimeInterval(86_400)
        let previous = baseline(80, deadline: deadline)
        let permissions: [Bool?] = [nil, false]
        for allowed in permissions {
            let evaluation = RestorationDetector.evaluate(
                previous: previous,
                current: window(0, resetsAt: deadline),
                ordinaryUsageAllowed: allowed,
                now: deadline.addingTimeInterval(-3_600)
            )
            expect(evaluation.alert != nil, "strong usage restoration must not depend on permission")
            expectEqual(
                evaluation.alert?.ordinaryUsageAllowed,
                allowed,
                "alert must report the observed permission value"
            )
        }
    }

    private static func testCoverageAfterResetUsageClimbs() {
        // Regression: a reset-credit restoration can be followed by enough usage
        // that the next poll sees 6%, not 0-1%. The old near-zero rule missed it
        // and then overwrote the baseline, losing the evidence.
        let deadline = testNow.addingTimeInterval(86_400)
        let evaluation = RestorationDetector.evaluate(
            previous: baseline(82, deadline: deadline),
            current: window(6, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(-3_600)
        )
        guard let alert = evaluation.alert else {
            expect(false, "82% -> 6% before the prior deadline should alert")
            return
        }
        expectEqual(alert.previousPercent, 82, "regression alert prior usage")
        expectEqual(alert.currentPercent, 6, "regression alert post-reset usage")
        expect(evaluation.baseline.alertedResetsAt == nil, "regression alert is not pre-marked")
    }

    private static func testSmallPriorUsageResetAlerts() {
        let deadline = testNow.addingTimeInterval(86_400)
        let evaluation = RestorationDetector.evaluate(
            previous: baseline(4, deadline: deadline),
            current: window(0, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(-3_600)
        )
        expect(evaluation.alert != nil, "4% -> 0% should alert even though the drop is under five points")
    }

    private static func testNoAlertWithoutMaterialDrop() {
        let deadline = testNow.addingTimeInterval(86_400)
        let now = deadline.addingTimeInterval(-3_600)
        let cases: [(Double, Double)] = [
            (80, 80),       // no change
            (80, 90),       // usage increased without a new deadline
            (1, 0),         // one-point rounding noise
            (30, 20),       // a 10-point drop is only one third of prior usage
            (80, 40),       // still above the restored-usage ceiling
            (80, 26),       // just above the restored-usage ceiling
        ]
        for (prior, current) in cases {
            let evaluation = RestorationDetector.evaluate(
                previous: baseline(prior, deadline: deadline),
                current: window(current, resetsAt: deadline),
                ordinaryUsageAllowed: true,
                now: now
            )
            expect(
                evaluation.alert == nil,
                "non-material drop \(prior)% -> \(current)% must not alert"
            )
        }
    }

    private static func testPostResetUsageIncreaseRequiresAdvancedDeadline() {
        let deadline = testNow.addingTimeInterval(86_400)
        let now = deadline.addingTimeInterval(-3_600)
        let noNewWindow = RestorationDetector.evaluate(
            previous: baseline(4, deadline: deadline),
            current: window(6, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: now
        )
        expect(noNewWindow.alert == nil, "usage growth alone must not alert")

        let newWindow = RestorationDetector.evaluate(
            previous: baseline(4, deadline: deadline),
            current: window(6, resetsAt: deadline.addingTimeInterval(1_800)),
            ordinaryUsageAllowed: nil,
            now: now
        )
        expect(
            newWindow.alert != nil,
            "an advanced deadline with low usage should alert even after usage grows"
        )
    }

    private static func testPartialUsageDropDoesNotAlertWithoutNewWindow() {
        let deadline = testNow.addingTimeInterval(86_400)
        let now = deadline.addingTimeInterval(-3_600)
        for current in [40.0, 26.0] {
            let sameDeadline = RestorationDetector.evaluate(
                previous: baseline(80, deadline: deadline),
                current: window(current, resetsAt: deadline),
                ordinaryUsageAllowed: true,
                now: now
            )
            expect(
                sameDeadline.alert == nil,
                "partial drop to \(current)% without a new window must not alert"
            )
        }
    }

    private static func testBothWeeklySlotsAlert() {
        let deadline = testNow.addingTimeInterval(86_400)
        let primaryFirst = CodexPoller.apply(
            .success(snapshot(primaryUsed: 80, secondaryUsed: nil, resetsAt: deadline)),
            baseline: nil,
            now: testNow
        )
        let secondaryNext = CodexPoller.apply(
            .success(snapshot(primaryUsed: nil, secondaryUsed: 6, resetsAt: deadline)),
            baseline: primaryFirst.baseline,
            now: deadline.addingTimeInterval(-3_600)
        )
        expect(secondaryNext.alert != nil, "primary -> secondary weekly slot still alerts")

        let secondaryFirst = CodexPoller.apply(
            .success(snapshot(primaryUsed: nil, secondaryUsed: 63, resetsAt: deadline)),
            baseline: nil,
            now: testNow
        )
        let primaryNext = CodexPoller.apply(
            .success(snapshot(primaryUsed: 6, secondaryUsed: nil, resetsAt: deadline)),
            baseline: secondaryFirst.baseline,
            now: deadline.addingTimeInterval(-3_600)
        )
        expect(primaryNext.alert != nil, "secondary -> primary weekly slot still alerts")
    }

    private static func testNoAlertWithoutPriorDeadline() {
        let evaluation = RestorationDetector.evaluate(
            previous: baseline(80, deadline: nil),
            current: window(0, resetsAt: testNow.addingTimeInterval(86_400)),
            ordinaryUsageAllowed: true,
            now: testNow
        )
        expect(evaluation.alert == nil, "missing prior deadline must suppress alert")
    }

    private static func testPollFailurePreservesBaseline() {
        let deadline = testNow.addingTimeInterval(86_400)
        let prior = baseline(80, deadline: deadline)
        let outcome = CodexPoller.apply(.failure(TestError.unavailable), baseline: prior, now: testNow)
        expect(outcome.snapshot == nil, "failure does not replace displayed usage")
        expectEqual(outcome.baseline, prior, "failure preserves baseline")
        expect(outcome.alert == nil, "failure cannot alert")
        expect(outcome.observedWeekly == nil, "failure reports no observed window")
        expect(outcome.errorMessage != nil, "failure reports an error")
    }

    private static func testParsingFailureProducesNoAlert() throws {
        let prior = baseline(80, deadline: testNow.addingTimeInterval(86_400))
        let error: Error
        do {
            _ = try CodexRateLimitsParser.parse(data: fixture("rate-limits-malformed.json"))
            error = TestError.unavailable
            expect(false, "fixture should fail parsing")
        } catch let thrown {
            error = thrown
        }
        let outcome = CodexPoller.apply(.failure(error), baseline: prior, now: testNow)
        expect(outcome.alert == nil, "parsing failure cannot alert")
        expectEqual(outcome.baseline, prior, "parsing failure preserves baseline")
        expect(outcome.errorMessage != nil, "parsing failure reports an error")
    }

    private static func testMissingWeeklyWindowProducesNoAlert() {
        let prior = baseline(80, deadline: testNow.addingTimeInterval(86_400))
        let snapshot = CodexRateLimitSnapshot(
            ordinaryUsageAllowed: true,
            primary: CodexRateLimitWindow(
                usedPercent: 10,
                windowDurationMins: 300,
                resetsAt: testNow.addingTimeInterval(3_600)
            ),
            secondary: nil,
            observedAt: testNow
        )
        let outcome = CodexPoller.apply(.success(snapshot), baseline: prior, now: testNow)
        expect(outcome.snapshot != nil, "response is still displayed")
        expectEqual(outcome.baseline, prior, "baseline remains unchanged without a 7-day window")
        expect(outcome.alert == nil, "missing 7-day window cannot alert")
        expect(outcome.observedWeekly == nil, "missing 7-day window is not reported as observed")
        expect(outcome.errorMessage != nil, "missing 7-day window is surfaced")
    }

    private static func testFullTransitionSequence() {
        let deadline = testNow.addingTimeInterval(86_400)
        let first = CodexPoller.apply(
            .success(snapshot(weeklyUsed: 63, resetsAt: deadline, allowed: true)),
            baseline: nil,
            now: testNow.addingTimeInterval(-600)
        )
        expect(first.alert == nil, "first poll establishes baseline only")
        expect(first.observedWeekly != nil, "successful poll reports the observed weekly window")
        guard let firstBaseline = first.baseline else {
            expect(false, "first poll should persist a baseline")
            return
        }

        let restored = CodexPoller.apply(
            .success(snapshot(weeklyUsed: 6, resetsAt: deadline, allowed: true)),
            baseline: firstBaseline,
            now: deadline.addingTimeInterval(-3_600)
        )
        expect(restored.alert != nil, "second poll detects early restoration even at 6%")
        expectEqual(restored.alert?.previousPercent, 63, "alert reflects persisted baseline")
        guard let restoredBaseline = restored.baseline else {
            expect(false, "restoration poll should return a baseline")
            return
        }
        expect(restoredBaseline.alertedResetsAt == nil, "poll result is not pre-marked")

        let committed = restoredBaseline.markingAlerted(resetsAt: deadline)
        let repeated = CodexPoller.apply(
            .success(snapshot(weeklyUsed: 6, resetsAt: deadline, allowed: true)),
            baseline: committed,
            now: deadline.addingTimeInterval(-3_300)
        )
        expect(repeated.alert == nil, "third poll does not repeat the alert")
    }

    private static func testAlertMarkerPersistsAcrossRestart() {
        let suite = "CodexResetTrayAlertMarkerTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "could not create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BaselineStore(defaults: defaults)

        let deadline = testNow.addingTimeInterval(86_400)
        let evaluation = RestorationDetector.evaluate(
            previous: baseline(82, deadline: deadline),
            current: window(0, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(-600)
        )
        guard evaluation.alert != nil else {
            expect(false, "setup alert should fire")
            return
        }
        store.save(evaluation.baseline.markingAlerted(resetsAt: deadline))
        guard let reloaded = store.load() else {
            expect(false, "alerted baseline should persist")
            return
        }

        let afterRestart = RestorationDetector.evaluate(
            previous: reloaded,
            current: window(0, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: deadline.addingTimeInterval(-300)
        )
        expect(afterRestart.alert == nil, "persisted alert marker prevents duplicate after restart")
    }

    private static func testBaselinePersistence() {
        let suite = "CodexResetTrayTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "could not create test defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BaselineStore(defaults: defaults)
        expect(store.load() == nil, "empty defaults have no baseline")

        let baseline = WeeklyUsageBaseline(
            usedPercent: 82,
            resetsAt: Date(timeIntervalSince1970: 1_793_382_304),
            capturedAt: testNow,
            alertedResetsAt: nil
        )
        store.save(baseline)
        expectEqual(store.load(), baseline, "baseline round-trips through UserDefaults")

        store.save(nil)
        expect(store.load() == nil, "baseline can be cleared")

        defaults.set(Data("not json".utf8), forKey: BaselineStore.key)
        expect(store.load() == nil, "corrupt baseline is treated as absent")
    }

    private static func window(_ usedPercent: Double, resetsAt: Date?) -> CodexRateLimitWindow {
        CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: 10_080,
            resetsAt: resetsAt
        )
    }

    private static func baseline(_ usedPercent: Double, deadline: Date?) -> WeeklyUsageBaseline {
        WeeklyUsageBaseline(
            usedPercent: usedPercent,
            resetsAt: deadline,
            capturedAt: testNow.addingTimeInterval(-600),
            alertedResetsAt: nil
        )
    }

    private static func snapshot(weeklyUsed: Double, resetsAt: Date?, allowed: Bool?) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            ordinaryUsageAllowed: allowed,
            primary: CodexRateLimitWindow(
                usedPercent: weeklyUsed,
                windowDurationMins: 10_080,
                resetsAt: resetsAt
            ),
            secondary: nil,
            observedAt: testNow
        )
    }

    private static func snapshot(
        primaryUsed: Double?,
        secondaryUsed: Double?,
        resetsAt: Date?
    ) -> CodexRateLimitSnapshot {
        CodexRateLimitSnapshot(
            ordinaryUsageAllowed: true,
            primary: primaryUsed.map {
                CodexRateLimitWindow(usedPercent: $0, windowDurationMins: 10_080, resetsAt: resetsAt)
            },
            secondary: secondaryUsed.map {
                CodexRateLimitWindow(usedPercent: $0, windowDurationMins: 10_080, resetsAt: resetsAt)
            },
            observedAt: testNow
        )
    }
}
