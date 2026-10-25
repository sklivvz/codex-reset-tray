import Foundation
import UserNotifications

enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case error(String)

    init(status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .error("Unrecognized notification authorization status.")
        }
    }

    var allowsDelivery: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .error:
            return false
        }
    }

    var explanation: String {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return "Notifications are allowed."
        case .notDetermined:
            return "notification permission is not determined."
        case .denied:
            return "notifications are denied in System Settings."
        case .error(let message):
            return "notification permission could not be checked: \(message)"
        }
    }
}

enum NotificationDeliveryResult: Equatable, Sendable {
    /// The system accepted a notification request. This does not prove that a
    /// banner was displayed; macOS and Focus settings control visual delivery.
    case scheduled
    case notAuthorized(NotificationAuthorization)
    case failed(String)
}

/// Wraps the tiny part of `UNUserNotificationCenter` used by the app. Production
/// uses the real center; tests use a deterministic fake so they never prompt,
/// schedule, or display a notification.
protocol UserNotificationCenterClient: AnyObject {
    var delegate: (any UNUserNotificationCenterDelegate)? { get set }
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: UserNotificationCenterClient {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

/// Without a delegate, a notification request with a nil trigger can be
/// suppressed while this accessory app is active. Presenting it through
/// `willPresent` keeps the alert visible even when the menu or information
/// popover has focus.
final class NotificationPresentationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresentationDelegate()
    static let foregroundOptions: UNNotificationPresentationOptions = [.banner, .sound, .list]

    let options: UNNotificationPresentationOptions

    init(options: UNNotificationPresentationOptions = NotificationPresentationDelegate.foregroundOptions) {
        self.options = options
        super.init()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(options)
    }
}

/// Injectable boundary around UserNotifications. Production uses
/// `SystemNotificationScheduler`; tests use a deterministic fake so they never
/// prompt, schedule, or display a real notification.
protocol NotificationScheduling: AnyObject {
    func authorizationStatus() async -> NotificationAuthorization
    func requestAuthorization() async -> NotificationAuthorization
    func schedule(_ alert: RestorationAlert) async -> NotificationDeliveryResult
}

extension NotificationScheduling {
    /// Read-only authorization check used before scheduling. It never prompts:
    /// permission requests are reserved for the explicit Enable Notifications
    /// menu action.
    func currentAuthorization() async -> NotificationAuthorization {
        await authorizationStatus()
    }
}

/// Formats a system error for the diagnostic Copy Status Summary without
/// exposing a raw error description, which can contain local bundle paths. The
/// NSError domain and numeric code are preserved because they are the actionable
/// diagnostic values.
enum NotificationErrorDiagnostics {
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(sanitizedDomain(nsError.domain)) code \(nsError.code)"
    }

    static func sanitizedDomain(_ domain: String) -> String {
        let characters = domain.map { character -> Character in
            if character.isLetter || character.isNumber
                || character == "." || character == "-" || character == "_" {
                return character
            }
            return "_"
        }
        let sanitized = String(characters.prefix(64))
        return sanitized.isEmpty ? "unknown" : sanitized
    }
}

final class SystemNotificationScheduler: NotificationScheduling {
    private let lock = NSLock()
    private let injectedCenter: (any UserNotificationCenterClient)?
    private let presentationDelegate: NotificationPresentationDelegate
    private var resolvedCenter: (any UserNotificationCenterClient)?

    /// The real notification center is resolved lazily. Command-line tests
    /// construct `ResetStore` without ever touching UserNotifications, and
    /// `UNUserNotificationCenter.current()` requires a real app bundle.
    init(
        center: (any UserNotificationCenterClient)? = nil,
        presentationDelegate: NotificationPresentationDelegate = .shared
    ) {
        injectedCenter = center
        self.presentationDelegate = presentationDelegate
        if let center {
            resolvedCenter = center
            center.delegate = presentationDelegate
        }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        NotificationAuthorization(status: await notificationCenter().authorizationStatus())
    }

    func requestAuthorization() async -> NotificationAuthorization {
        let existing = await authorizationStatus()
        guard existing == .notDetermined else { return existing }
        do {
            _ = try await notificationCenter().requestAuthorization(options: [.alert, .sound])
            return await authorizationStatus()
        } catch {
            return .error(NotificationErrorDiagnostics.describe(error))
        }
    }

    func schedule(_ alert: RestorationAlert) async -> NotificationDeliveryResult {
        // Scheduling only reads the current authorization. Asking for
        // permission here would unexpectedly prompt on a reset or app launch;
        // the Enable Notifications menu action is the only prompt path.
        let authorization = await currentAuthorization()
        guard authorization.allowsDelivery else {
            return .notAuthorized(authorization)
        }

        let content = UNMutableNotificationContent()
        content.title = title(for: alert)
        content.body = body(for: alert)
        content.sound = .default

        let identifier = "codex-reset-\(Int(alert.resetsAt.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await notificationCenter().add(request)
            return .scheduled
        } catch {
            return .failed(NotificationErrorDiagnostics.describe(error))
        }
    }

    private func notificationCenter() -> any UserNotificationCenterClient {
        lock.lock()
        defer { lock.unlock() }
        if let resolvedCenter { return resolvedCenter }
        let center = injectedCenter ?? UNUserNotificationCenter.current()
        center.delegate = presentationDelegate
        resolvedCenter = center
        return center
    }

    private func title(for alert: RestorationAlert) -> String {
        switch alert.timing {
        case .scheduled:
            return "Codex 7-day quota reset"
        case .early:
            return "Codex 7-day quota restored early"
        }
    }

    private func body(for alert: RestorationAlert) -> String {
        let transition: String
        if alert.currentPercent < alert.previousPercent {
            transition = "7-day Codex usage fell from \(percent(alert.previousPercent)) "
                + "to \(percent(alert.currentPercent))."
        } else {
            transition = "7-day Codex usage was \(percent(alert.previousPercent)) before "
                + "the reset and is now \(percent(alert.currentPercent))."
        }

        let deadline: String
        switch alert.timing {
        case .scheduled:
            deadline = "The previous window was scheduled to reset at "
                + "\(alert.resetsAt.formatted(date: .abbreviated, time: .shortened))."
        case .early:
            deadline = "The previous window was not due to reset until "
                + "\(alert.resetsAt.formatted(date: .abbreviated, time: .shortened))."
        }

        let permission: String
        switch alert.ordinaryUsageAllowed {
        case .some(true):
            permission = "Codex reports ordinary usage allowed."
        case .some(false):
            permission = "Codex reports ordinary usage is not currently allowed."
        case .none:
            permission = "Codex did not report ordinary-usage permission."
        }
        return "\(transition) \(deadline) \(permission)"
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
