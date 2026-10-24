import Foundation

@main
struct ParserSmokeTest {
    static func main() throws {
        let path = CommandLine.arguments.dropFirst().first
            ?? "Tests/Fixtures/codexreset-page.html"
        let html = try String(contentsOfFile: path, encoding: .utf8)
        let snapshot = try ResetSnapshot.parse(html)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let expectedReset = formatter.date(from: "2026-10-23T18:11:21.036Z") else {
            fatalError("Could not build the expected reset date.")
        }
        precondition(abs(snapshot.resetAt.timeIntervalSince(expectedReset)) < 0.001, "Unexpected reset time")
        precondition(snapshot.resetStatus == "Quota restored", "Unexpected reset status")
        precondition(snapshot.restorationStatus == "Monitored account: 75% → 100%. Global confirmation pending.", "Unexpected restoration status")
        precondition(snapshot.probability24h == 28, "Unexpected 24h probability")
        precondition(snapshot.probability48h == 49, "Unexpected 48h probability")
        precondition(
            snapshot.forecastSummary == "28% within 24 hours & 49% within 48 hours, based on recent resets.",
            "Unexpected forecast summary"
        )

        do {
            _ = try ResetSnapshot.parse("<html><body>Unrecognized page</body></html>")
            fatalError("An unrecognized page should not parse.")
        } catch is ResetSnapshot.ParseError {
            // Expected: malformed or changed markup is reported as a parse error.
        }

        print("Parser fixture smoke test passed")
        print("Last reset: \(snapshot.resetAt.formatted(.iso8601))")
        print("Forecast: \(snapshot.probability24h)% / 24h, \(snapshot.probability48h)% / 48h")
    }
}
