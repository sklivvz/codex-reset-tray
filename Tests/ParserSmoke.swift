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

        let reordered = html
            .replacingOccurrences(of: "data-testid=\"probability-ring-24h\" data-target-value=\"28\"", with: "data-target-value='28' class='ring' data-testid='probability-ring-24h'")
            .replacingOccurrences(of: "data-testid=\"reset-exact-time\" datetime=\"2026-10-23T18:11:21.036Z\"", with: "datetime='2026-10-23T18:11:21.036Z' class='date' data-testid='reset-exact-time'")
        let reorderedSnapshot = try ResetSnapshot.parse(reordered)
        precondition(reorderedSnapshot == snapshot, "Reordered attributes should parse")

        let variantPath = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent("codexreset-page-current-variant.html").path
        let currentVariant = try String(contentsOfFile: variantPath, encoding: .utf8)
        let current = try ResetSnapshot.parse(currentVariant)
        precondition(current.probability24h == 29 && current.probability48h == 50, "Current visible wording should parse")
        precondition(current.resetStatus == "Time since the last blessing", "Current reset heading should parse")
        precondition(current.restorationStatus == "Confirmed reset", "Current confirmation should parse")

        let malformed = [
            html.replacingOccurrences(of: "data-target-value=\"28\"", with: "data-target-value=\"128\""),
            html.replacingOccurrences(of: "data-target-value=\"28\"", with: "data-target-value=\"29\""),
            html.replacingOccurrences(of: "2026-10-23T18:11:21.036Z", with: "not-a-date"),
            currentVariant.replacingOccurrences(of: "Final forecast: 29%", with: "Final forecast: 92%"),
            currentVariant.replacingOccurrences(of: "2026-10-25T06:06:00Z", with: "not-a-date"),
            currentVariant.replacingOccurrences(of: "Final forecast: 50%", with: "Final forecast: 150%"),
        ]
        for bad in malformed {
            do {
                _ = try ResetSnapshot.parse(bad)
                fatalError("Malformed forecast data should not parse")
            } catch is ResetSnapshot.ParseError {
                // Expected.
            }
        }

        do {
            _ = try ResetSnapshot.parse("<html><body>Unrecognized page</body></html>")
            fatalError("An unrecognized page should not parse.")
        } catch is ResetSnapshot.ParseError {
            // Expected: malformed or changed markup is reported as a parse error.
        }

        print("Parser fixture and malformed-data tests passed")
        print("Last reset: \(snapshot.resetAt.formatted(.iso8601))")
        print("Forecast: \(snapshot.probability24h)% / 24h, \(snapshot.probability48h)% / 48h")
    }
}
