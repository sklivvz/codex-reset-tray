import Foundation
import UserNotifications

enum NotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case error(String)

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
    case delivered
    case notAuthorized(NotificationAuthorization)
    case failed(String)
}

/// Injectable boundary around UserNotifications. Production uses
/// `SystemNotificationScheduler`; tests use a deterministic fake so they never
/// prompt, schedule, or display a real notification.
protocol NotificationScheduling: AnyObject {
    func authorizationStatus() async -> NotificationAuthorization
    func requestAuthorization() async -> NotificationAuthorization
    func schedule(_ alert: RestorationAlert) async -> NotificationDeliveryResult
}

final class SystemNotificationScheduler: NotificationScheduling {
    func authorizationStatus() async -> NotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .error("Unrecognized notification authorization status.")
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            return await authorizationStatus()
        } catch {
            return .error(safeSystemErrorDescription(error))
        }
    }

    func schedule(_ alert: RestorationAlert) async -> NotificationDeliveryResult {
        var authorization = await authorizationStatus()
        if authorization == .notDetermined {
            authorization = await requestAuthorization()
        }
        guard authorization.allowsDelivery else {
            return .notAuthorized(authorization)
        }

        let content = UNMutableNotificationContent()
        content.title = "Codex quota restored early"
        content.body = body(for: alert)
        content.sound = .default

        let identifier = "codex-early-restoration-\(Int(alert.resetsAt.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return .delivered
        } catch {
            return .failed(safeSystemErrorDescription(error))
        }
    }

    /// Do not surface a raw system error in the menu or copied status summary:
    /// notification errors can include local bundle paths. The numeric code is
    /// enough to make the failure visible without leaking account or file data.
    private func safeSystemErrorDescription(_ error: Error) -> String {
        "the system notification service returned error \((error as NSError).code)."
    }

    private func body(for alert: RestorationAlert) -> String {
        let permission: String
        switch alert.ordinaryUsageAllowed {
        case .some(true):
            permission = "Codex reports ordinary usage allowed."
        case .some(false):
            permission = "Codex reports ordinary usage is not currently allowed."
        case .none:
            permission = "Codex did not report ordinary-usage permission."
        }
        return "7-day Codex usage fell from \(percent(alert.previousPercent)) to "
            + "\(percent(alert.currentPercent)) before the window reset at "
            + "\(alert.resetsAt.formatted(date: .abbreviated, time: .shortened)). "
            + permission
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
