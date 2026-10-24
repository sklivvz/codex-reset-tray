import Foundation
import UserNotifications

enum NotificationScheduler {
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func send(_ alert: RestorationAlert) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Codex quota restored early"
        content.body = "7-day Codex usage fell from \(percent(alert.previousPercent)) to "
            + "\(percent(alert.currentPercent)) before the window reset at "
            + "\(alert.resetsAt.formatted(date: .abbreviated, time: .shortened)). "
            + "Codex reports ordinary usage allowed."
        content.sound = .default

        let identifier = "codex-early-restoration-\(Int(alert.resetsAt.timeIntervalSince1970))"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    private static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
