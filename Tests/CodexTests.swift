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
        testScheduledResetDoesNotAlert()
        testBackendPermissionIsRequired()
        testNoAlertWithoutMaterialDrop()
        testNoAlertWithoutPriorDeadline()
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
        expectEqual(evaluation.baseline.alertedResetsAt, deadline, "alert gets persisted")

        let repeated = RestorationDetector.evaluate(
            previous: evaluation.baseline,
            current: window(0, resetsAt: deadline),
            ordinaryUsageAllowed: true,
            now: now.addingTimeInterval(300)
        )
        expect(repeated.alert == nil, "same window must not alert twice")
    }

    private static func testScheduledResetDoesNotAlert() {
        let deadline = testNow.addingTimeInterval(86_400)
        let previous = baseline(80, deadline: deadline)
        let nextDeadline = deadline.addingTimeInterval(7 * 86_400)
        for now in [deadline, deadline.addingTimeInterval(1)] {
            let evaluation = RestorationDetector.evaluate(
                previous: previous,
                current: window(0, resetsAt: nextDeadline),
                ordinaryUsageAllowed: true,
                now: now
            )
            expect(evaluation.alert == nil, "scheduled reset alone must not alert")
        }
    }

    private static func testBackendPermissionIsRequired() {
        let deadline = testNow.addingTimeInterval(86_400)
        let previous = baseline(80, deadline: deadline)
        let permissions: [Bool?] = [nil, false]
        for allowed in permissions {
            let evaluation = RestorationDetector.evaluate(
                previous: previous,
                current: window(0, resetsAt: deadline),
                ordinaryUsageAllowed: allowed,
                now: deadline.addingTimeInterval(-60)
            )
            expect(evaluation.alert == nil, "missing or false ordinaryUsageAllowed must suppress alert")
        }
    }

    private static func testNoAlertWithoutMaterialDrop() {
        let deadline = testNow.addingTimeInterval(86_400)
        let now = deadline.addingTimeInterval(-60)
        let cases: [(Double, Double)] = [(80, 2), (4, 0), (1, 0), (80, 80), (80, 90)]
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
        guard let firstBaseline = first.baseline else {
            expect(false, "first poll should persist a baseline")
            return
        }

        let restored = CodexPoller.apply(
            .success(snapshot(weeklyUsed: 0, resetsAt: deadline, allowed: true)),
            baseline: firstBaseline,
            now: deadline.addingTimeInterval(-3_600)
        )
        expect(restored.alert != nil, "second poll detects early restoration")
        expectEqual(restored.alert?.previousPercent, 63, "alert reflects persisted baseline")

        let repeated = CodexPoller.apply(
            .success(snapshot(weeklyUsed: 0, resetsAt: deadline, allowed: true)),
            baseline: restored.baseline,
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
        store.save(evaluation.baseline)
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
}
