import Foundation

struct ResetSnapshot: Equatable, Sendable {
    let resetAt: Date
    let resetStatus: String
    let restorationStatus: String
    let probability24h: Int
    let probability48h: Int
    let forecastSummary: String

    static func parse(_ html: String) throws -> ResetSnapshot {
        let resetTime = element(with: "data-testid", value: "reset-exact-time", in: html)
        let resetHeading = ["Time since the last blessing", "Quota restored"].first { html.localizedCaseInsensitiveContains($0) }
        let semanticReset = resetHeading.flatMap { section(after: $0, in: html) }
        let timestamp = resetTime.flatMap { attribute("datetime", in: $0.openingTag) }
            ?? semanticReset.flatMap { firstTimeAttribute("datetime", in: $0) }
        if let timestamp, parseISO8601(timestamp) == nil {
            throw ParseError.invalid("reset time")
        }
        let resetAt = timestamp.flatMap(parseISO8601)
            ?? semanticReset.flatMap { visibleResetDate(in: clean($0)) }
        guard let resetAt else {
            throw ParseError.invalid("reset time")
        }
        let title = element(with: "id", value: "reset-elapsed-title", in: html).map { clean($0.content) }
            ?? resetHeading
        guard let title, !title.isEmpty else {
            throw ParseError.missing("reset status")
        }
        let restoration = try restorationStatus(in: html)
        let probability24h = try probability(hours: 24, in: html)
        let probability48h = try probability(hours: 48, in: html)
        let summary = element(with: "data-testid", value: "forecast-summary", in: html).map { clean($0.content) }
            ?? section(after: "Why this estimate", in: html).flatMap { firstParagraph(in: $0) }
        guard let summary, !summary.isEmpty else {
            throw ParseError.missing("forecast summary")
        }

        return ResetSnapshot(
            resetAt: resetAt,
            resetStatus: title,
            restorationStatus: restoration,
            probability24h: probability24h,
            probability48h: probability48h,
            forecastSummary: summary
        )
    }

    enum ParseError: LocalizedError {
        case missing(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missing(let field): "Could not find the \(field) on codexreset.org; its page format may have changed."
            case .invalid(let field): "Could not read the \(field) on codexreset.org; its page format may have changed."
            }
        }
    }

    private struct Element {
        let openingTag: String
        let content: String
    }

    private static func probability(hours: Int, in html: String) throws -> Int {
        let ring = element(with: "data-testid", value: "probability-ring-\(hours)h", in: html)
        let attributed = ring.flatMap { attribute("data-target-value", in: $0.openingTag) }
        let visible = ring.flatMap { firstCapture(#"^\s*(\d{1,3})\s*%\s*$"#, in: clean($0.content)) }
        let pageText = clean(html)
        let semanticPair = firstCaptures("\\b\(hours)\\s*hours\\s*(\\d{1,3})\\s*%\\s*Final forecast:\\s*(\\d{1,3})\\s*%", in: pageText)
        if let semanticPair, semanticPair[0] != semanticPair[1] {
            throw ParseError.invalid("\(hours)-hour forecast")
        }
        let semantic = semanticPair?.first
        let raw = attributed ?? visible ?? semantic
        guard let raw else { throw ParseError.missing("\(hours)-hour forecast") }
        guard let value = Int(raw), (0...100).contains(value),
              (attributed == nil || visible == nil || attributed == visible),
              (attributed == nil || semantic == nil || attributed == semantic) else {
            throw ParseError.invalid("\(hours)-hour forecast")
        }
        return value
    }

    private static func restorationStatus(in html: String) throws -> String {
        if let restorationElement = element(with: "data-testid", value: "quota-restoration-status", in: html) {
            let status = clean(restorationElement.content)
            guard !status.isEmpty else {
                throw ParseError.invalid("restoration status")
            }
            return status
        }

        // The current page no longer exposes an account-level restoration element.
        // Its timeline only confirms a global reset, so never present that as proof
        // that the monitored account's quota was restored.
        if hasGlobalTimelineConfirmation(in: html) {
            return "Global timeline: Confirmed reset (account-level restoration not stated)."
        }
        throw ParseError.missing("restoration status")
    }

    private static func hasGlobalTimelineConfirmation(in html: String) -> Bool {
        guard let timeline = timelineRegion(in: html) else { return false }
        let text = clean(timeline)
        // clean() removes adjacent tags without inserting whitespace, so word-boundary
        // regexes can miss labels such as "</button><span>Confirmed reset".
        return text.localizedCaseInsensitiveContains("Latest confirmed")
            && text.localizedCaseInsensitiveContains("Confirmed reset")
    }

    /// Scope semantic timeline checks to the actual timeline. The live page also
    /// contains JSON-LD and FAQ prose such as "after the latest confirmed reset";
    /// scanning the whole document would treat that prose as timeline evidence.
    private static func timelineRegion(in html: String) -> String? {
        let openingPatterns = [
            #"<section\b[^>]*\bid\s*=\s*["']timeline["'][^>]*>"#,
            #"<h2\b[^>]*\bid\s*=\s*["']timeline-title["'][^>]*>"#,
        ]
        for pattern in openingPatterns {
            if let tag = firstCapture("(" + pattern + ")", in: html),
               let range = html.range(of: tag) {
                return String(html[range.upperBound...].prefix(20_000))
            }
        }

        // Support the id-less variant by anchoring to the visible heading element.
        // Matching the bare phrase would also find document metadata such as the
        // <title> or JSON-LD that appears before the visible timeline.
        let headingPattern = #"<h2\b[^>]*>\s*Codex reset timeline\s*</h2\s*>"#
        if let heading = firstCapture("(" + headingPattern + ")", in: html),
           let range = html.range(of: heading) {
            return String(html[range.upperBound...].prefix(20_000))
        }
        return nil
    }

    private static func section(after marker: String, in html: String) -> String? {
        guard let range = html.range(of: marker, options: .caseInsensitive) else { return nil }
        return String(html[range.upperBound...].prefix(800))
    }

    private static func firstTimeAttribute(_ name: String, in html: String) -> String? {
        let pattern = #"<time\b[^>]*\s"# + NSRegularExpression.escapedPattern(for: name) + #"\s*=\s*(?:"[^"]*"|'[^']*')[^>]*>"#
        guard let tag = firstCapture("(" + pattern + ")", in: html) else { return nil }
        return attribute(name, in: tag)
    }

    private static func visibleResetDate(in text: String) -> Date? {
        guard let value = firstCapture(#"\b([A-Z][a-z]{2} \d{1,2}, \d{4} · \d{2}:\d{2} UTC)\b"#, in: text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy · HH:mm 'UTC'"
        return formatter.date(from: value)
    }

    private static func firstParagraph(in html: String) -> String? {
        firstCapture(#"<p\b[^>]*>(.*?)</p\s*>"#, in: html, options: [.caseInsensitive, .dotMatchesLineSeparators]).map(clean)
    }

    private static func firstCapture(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> String? {
        firstCaptures(pattern, in: text, options: options)?.first
    }

    private static func firstCaptures(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let captures = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
        return captures.count == match.numberOfRanges - 1 ? captures : nil
    }

    private static func element(with attributeName: String, value: String, in html: String) -> Element? {
        let name = NSRegularExpression.escapedPattern(for: attributeName)
        let escapedValue = NSRegularExpression.escapedPattern(for: value)
        let pattern = #"<([a-zA-Z][a-zA-Z0-9:-]*)\b[^>]*\s"# + name + #"\s*=\s*["']"# + escapedValue + #"["'][^>]*>(.*?)</\1\s*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let contentRange = Range(match.range(at: 2), in: html) else { return nil }

        let source = html as NSString
        let fullMatch = source.substring(with: match.range(at: 0))
        guard let tagEnd = fullMatch.firstIndex(of: ">") else { return nil }
        return Element(openingTag: String(fullMatch[...tagEnd]), content: String(html[contentRange]))
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"\s"# + escapedName + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }

        let source = tag as NSString
        return (1...2).lazy
            .map { match.range(at: $0) }
            .first { $0.location != NSNotFound }
            .map { source.substring(with: $0) }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func clean(_ html: String) -> String {
        let withoutComments = html.replacingOccurrences(of: "<!--.*?-->", with: "", options: .regularExpression)
        let withoutTags = withoutComments.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        let decoded = decodeNamedEntities(decodeNumericEntities(withoutTags))
        return decoded
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeNamedEntities(_ text: String) -> String {
        let entities = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
            ("&amp;", "&"),
        ]
        return entities.reduce(text) { result, entity in
            result.replacingOccurrences(of: entity.0, with: entity.1)
        }
    }

    private static func decodeNumericEntities(_ text: String) -> String {
        let pattern = #"&#(x[0-9a-f]+|[0-9]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = 0
        for match in matches {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let token = source.substring(with: match.range(at: 1))
            let scalar: UnicodeScalar?
            if token.lowercased().hasPrefix("x") {
                scalar = UInt32(token.dropFirst(), radix: 16).flatMap(UnicodeScalar.init)
            } else {
                scalar = UInt32(token).flatMap(UnicodeScalar.init)
            }
            output += scalar.map { String($0) } ?? source.substring(with: match.range)
            cursor = NSMaxRange(match.range)
        }
        output += source.substring(from: cursor)
        return output
    }
}

enum ResetPage {
    static let url = URL(string: "https://codexreset.org/")!

    static func fetch() async throws -> ResetSnapshot {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("CodexResetTray/\(AppBuildInfo.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw FetchError.invalidResponse }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw FetchError.httpStatus(httpResponse.statusCode)
        }
        guard let html = String(data: data, encoding: .utf8) else { throw FetchError.invalidEncoding }
        return try ResetSnapshot.parse(html)
    }

    enum FetchError: LocalizedError {
        case invalidResponse
        case httpStatus(Int)
        case invalidEncoding

        var errorDescription: String? {
            switch self {
            case .invalidResponse: "codexreset.org returned an invalid response."
            case .httpStatus(let status): "codexreset.org returned HTTP \(status)."
            case .invalidEncoding: "codexreset.org returned a page that could not be decoded."
            }
        }
    }
}
