import Foundation

struct ResetSnapshot: Equatable, Sendable {
    let resetAt: Date
    let resetStatus: String
    let restorationStatus: String
    let probability24h: Int
    let probability48h: Int
    let forecastSummary: String

    static func parse(_ html: String) throws -> ResetSnapshot {
        guard let resetTime = element(with: "data-testid", value: "reset-exact-time", in: html) else {
            throw ParseError.missing("reset time")
        }
        guard let timestamp = attribute("datetime", in: resetTime.openingTag), let resetAt = parseISO8601(timestamp) else {
            throw ParseError.invalid("reset time")
        }
        guard let title = element(with: "id", value: "reset-elapsed-title", in: html) else {
            throw ParseError.missing("reset status")
        }
        guard let restoration = element(with: "data-testid", value: "quota-restoration-status", in: html) else {
            throw ParseError.missing("restoration status")
        }
        guard let probability24h = probability(hours: 24, in: html) else {
            throw ParseError.missing("24-hour forecast")
        }
        guard let probability48h = probability(hours: 48, in: html) else {
            throw ParseError.missing("48-hour forecast")
        }
        guard let summary = element(with: "data-testid", value: "forecast-summary", in: html) else {
            throw ParseError.missing("forecast summary")
        }

        return ResetSnapshot(
            resetAt: resetAt,
            resetStatus: clean(title.content),
            restorationStatus: clean(restoration.content),
            probability24h: probability24h,
            probability48h: probability48h,
            forecastSummary: clean(summary.content)
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

    private static func probability(hours: Int, in html: String) -> Int? {
        guard let ring = element(with: "data-testid", value: "probability-ring-\(hours)h", in: html),
              let value = attribute("data-target-value", in: ring.openingTag) else { return nil }
        return Int(value.trimmingCharacters(in: .whitespaces))
    }

    private static func element(with attributeName: String, value: String, in html: String) -> Element? {
        let name = NSRegularExpression.escapedPattern(for: attributeName)
        let escapedValue = NSRegularExpression.escapedPattern(for: value)
        let pattern = #"<([a-zA-Z][a-zA-Z0-9:-]*)\b[^>]*\b"# + name + #"\s*=\s*["']"# + escapedValue + #"["'][^>]*>(.*?)</\1\s*>"#
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
        let pattern = #"\b"# + escapedName + #"\s*=\s*(?:"([^"]*)"|'([^']*)')"#
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
