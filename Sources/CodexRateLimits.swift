import Foundation

struct CodexRateLimitWindow: Equatable, Sendable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Date?

    var durationLabel: String {
        guard let minutes = windowDurationMins else { return "Codex window" }
        if minutes == 10_080 { return "7-day" }
        if minutes % 10_080 == 0 { return "\(minutes / 10_080)-week" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

struct CodexRateLimitSnapshot: Equatable, Sendable {
    let ordinaryUsageAllowed: Bool?
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let observedAt: Date

    /// The 7-day Codex quota window. The backend has exposed this as either
    /// `primary` or `secondary`, so identify it by its duration instead of its slot.
    var weeklyWindow: CodexRateLimitWindow? {
        if let secondary, secondary.windowDurationMins == 10_080 {
            return secondary
        }
        if let primary, primary.windowDurationMins == 10_080 {
            return primary
        }
        return nil
    }
}

enum CodexRateLimitsError: LocalizedError, Equatable {
    case invalidJSON
    case missingResult
    case missingRateLimits
    case malformedWindow(String)
    case serverError(code: Int?)

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Codex app-server returned JSON that could not be decoded."
        case .missingResult:
            return "Codex app-server returned an unexpected response envelope."
        case .missingRateLimits:
            return "Codex app-server returned no rate-limit snapshot."
        case .malformedWindow(let name):
            return "Codex app-server returned an unreadable \(name) usage window."
        case .serverError(let code):
            if let code {
                return "Codex app-server rejected the usage request (code \(code))."
            }
            return "Codex app-server rejected the usage request."
        }
    }
}

enum CodexRateLimitsParser {
    static func parse(jsonLine: String, observedAt: Date = Date()) throws -> CodexRateLimitSnapshot {
        guard let data = jsonLine.data(using: .utf8) else {
            throw CodexRateLimitsError.invalidJSON
        }
        return try parse(data: data, observedAt: observedAt)
    }

    static func parse(data: Data, observedAt: Date = Date()) throws -> CodexRateLimitSnapshot {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CodexRateLimitsError.invalidJSON
        }
        guard let root = object as? [String: Any] else {
            throw CodexRateLimitsError.invalidJSON
        }
        return try parse(root: root, observedAt: observedAt)
    }

    static func parse(root: [String: Any], observedAt: Date = Date()) throws -> CodexRateLimitSnapshot {
        if let error = root["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue
            throw CodexRateLimitsError.serverError(code: code)
        }

        let result: [String: Any]
        if let envelopeResult = root["result"] as? [String: Any] {
            result = envelopeResult
        } else if root["rateLimits"] != nil {
            result = root
        } else if root["error"] != nil {
            throw CodexRateLimitsError.serverError(code: nil)
        } else {
            throw CodexRateLimitsError.missingResult
        }

        guard let rateLimits = result["rateLimits"] as? [String: Any] else {
            throw CodexRateLimitsError.missingRateLimits
        }

        let ordinaryUsageAllowed: Bool?
        if let value = result["ordinaryUsageAllowed"] {
            ordinaryUsageAllowed = value is NSNull ? nil : value as? Bool
        } else {
            ordinaryUsageAllowed = nil
        }

        return CodexRateLimitSnapshot(
            ordinaryUsageAllowed: ordinaryUsageAllowed,
            primary: try parseWindow(rateLimits["primary"], name: "primary"),
            secondary: try parseWindow(rateLimits["secondary"], name: "secondary"),
            observedAt: observedAt
        )
    }

    private static func parseWindow(_ value: Any?, name: String) throws -> CodexRateLimitWindow? {
        guard let value, !(value is NSNull) else { return nil }
        guard let dictionary = value as? [String: Any] else {
            throw CodexRateLimitsError.malformedWindow(name)
        }
        guard let usedPercent = number(dictionary["usedPercent"]),
              usedPercent.isFinite,
              usedPercent >= 0 else {
            throw CodexRateLimitsError.malformedWindow(name)
        }

        var duration: Int?
        if let rawDuration = dictionary["windowDurationMins"], !(rawDuration is NSNull) {
            guard let minutes = number(rawDuration),
                  minutes.isFinite,
                  minutes >= 0,
                  minutes.rounded() == minutes,
                  minutes <= Double(Int.max) else {
                throw CodexRateLimitsError.malformedWindow(name)
            }
            duration = Int(minutes)
        }

        var resetsAt: Date?
        if let rawReset = dictionary["resetsAt"], !(rawReset is NSNull) {
            guard let seconds = number(rawReset), seconds.isFinite, seconds > 0 else {
                throw CodexRateLimitsError.malformedWindow(name)
            }
            resetsAt = Date(timeIntervalSince1970: seconds)
        }

        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            windowDurationMins: duration,
            resetsAt: resetsAt
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        return nil
    }
}
