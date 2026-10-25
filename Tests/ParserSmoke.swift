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

        let fixtures = URL(fileURLWithPath: path).deletingLastPathComponent()
        let fallbackPath = fixtures.appendingPathComponent("codexreset-page-current-variant.html").path
        let fallbackHTML = try String(contentsOfFile: fallbackPath, encoding: .utf8)
        let fallback = try ResetSnapshot.parse(fallbackHTML)
        precondition(fallback.probability24h == 29 && fallback.probability48h == 50, "Current visible wording should parse")
        precondition(fallback.resetStatus == "Time since the last blessing", "Current reset heading should parse")
        precondition(
            fallback.restorationStatus == "Global timeline: Confirmed reset (account-level restoration not stated).",
            "A text-only timeline must not be reported as account-level restoration"
        )

        // Sanitized excerpt captured from the live 2026-10-25 page. Its JSON-LD
        // contains "latest confirmed reset" before the visible timeline, which is
        // the prose that defeated the previous section(prefix:) fallback.
        let livePath = fixtures.appendingPathComponent("codexreset-page-live-2026-10-25.html").path
        let liveHTML = try String(contentsOfFile: livePath, encoding: .utf8)
        precondition(
            liveHTML.localizedCaseInsensitiveContains("after the latest confirmed reset"),
            "Fixture must retain the JSON-LD prose decoy"
        )
        precondition(
            !liveHTML.contains("data-testid=\"quota-restoration-status\""),
            "Fixture must model the current page without quota-restoration-status"
        )
        precondition(
            !liveHTML.localizedCaseInsensitiveContains("Quota restored"),
            "Fixture must not invent an account-level restoration claim"
        )

        let live = try ResetSnapshot.parse(liveHTML)
        guard let expectedLiveReset = formatter.date(from: "2026-10-25T06:06:16.000Z") else {
            fatalError("Could not build the expected live reset date.")
        }
        precondition(abs(live.resetAt.timeIntervalSince(expectedLiveReset)) < 0.001, "Unexpected live reset time")
        precondition(live.resetStatus == "Time since the last blessing", "Current reset heading should parse")
        precondition(
            live.restorationStatus == "Global timeline: Confirmed reset (account-level restoration not stated).",
            "The global timeline must not be presented as account-level quota restoration"
        )
        precondition(
            !live.restorationStatus.localizedCaseInsensitiveContains("Monitored account"),
            "The current page has no monitored-account restoration evidence"
        )
        precondition(live.probability24h == 29, "Unexpected live 24h probability")
        precondition(live.probability48h == 50, "Unexpected live 48h probability")
        precondition(
            live.forecastSummary == "No predictive X signal with an active time window remains. The estimate therefore stays at the observed reset-cadence baseline: 29% within 24 hours and 50% within 48 hours.",
            "Unexpected live forecast summary"
        )

        let withoutTimeline = liveHTML.replacingOccurrences(
            of: #"(?s)<section id="timeline".*?</section>"#,
            with: "",
            options: .regularExpression
        )
        precondition(
            withoutTimeline.localizedCaseInsensitiveContains("latest confirmed reset"),
            "The decoy-only variant must still contain the JSON-LD prose"
        )
        do {
            _ = try ResetSnapshot.parse(withoutTimeline)
            fatalError("JSON-LD prose alone must not count as a timeline confirmation")
        } catch is ResetSnapshot.ParseError {
            // Expected: no visible timeline evidence remains.
        }

        let metadataOnly = withoutTimeline.replacingOccurrences(
            of: "<title>Codex Reset Monitor – Live Status &amp; Reset Timeline</title>",
            with: "<title>Codex reset timeline — Latest confirmed reset</title>"
        )
        precondition(
            metadataOnly.localizedCaseInsensitiveContains("Codex reset timeline")
                && metadataOnly.localizedCaseInsensitiveContains("Latest confirmed")
                && metadataOnly.localizedCaseInsensitiveContains("Confirmed reset"),
            "The metadata-only variant must contain the timeline phrase and confirmation terms"
        )
        precondition(
            metadataOnly.range(
                of: #"<h2\b[^>]*>\s*Codex reset timeline\s*</h2\s*>"#,
                options: [.regularExpression, .caseInsensitive]
            ) == nil,
            "The metadata-only variant must not contain a visible timeline heading"
        )
        do {
            _ = try ResetSnapshot.parse(metadataOnly)
            fatalError("Metadata-only timeline prose must not count as visible timeline evidence")
        } catch ResetSnapshot.ParseError.missing(let field) {
            precondition(field == "restoration status", "Unexpected missing field: \(field)")
        }

        let malformed = [
            html.replacingOccurrences(of: "data-target-value=\"28\"", with: "data-target-value=\"128\""),
            html.replacingOccurrences(of: "data-target-value=\"28\"", with: "data-target-value=\"29\""),
            html.replacingOccurrences(of: "2026-10-23T18:11:21.036Z", with: "not-a-date"),
            fallbackHTML.replacingOccurrences(of: "Final forecast: 29%", with: "Final forecast: 92%"),
            fallbackHTML.replacingOccurrences(of: "2026-10-25T06:06:00Z", with: "not-a-date"),
            fallbackHTML.replacingOccurrences(of: "Final forecast: 50%", with: "Final forecast: 150%"),
            liveHTML.replacingOccurrences(of: "dateTime=\"2026-10-25T06:06:16.000Z\"", with: "dateTime=\"not-a-date\""),
            liveHTML.replacingOccurrences(of: "data-target-value=\"29\"", with: "data-target-value=\"30\""),
            liveHTML.replacingOccurrences(of: "data-target-value=\"29\"", with: "data-target-value=\"128\""),
            liveHTML.replacingOccurrences(of: "Final forecast: 29%", with: "Final forecast: 92%"),
            liveHTML.replacingOccurrences(of: "Final forecast: 50%", with: "Final forecast: 150%"),
        ]
        for (index, bad) in malformed.enumerated() {
            do {
                _ = try ResetSnapshot.parse(bad)
                fatalError("Malformed forecast data should not parse (case \(index))")
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
