import Foundation
@preconcurrency import UserNotifications

/// iOS local-notification implementation.
///
/// This type is deliberately outside EventClockCore. It schedules relative
/// time-interval triggers derived from the timer's persisted deadline.
public final class UserNotificationCenterAdapter:
    LocalNotificationCenter,
    RecurringNotificationCenter,
    @unchecked Sendable
{
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public func authorizationStatus() async -> NotificationPermission {
        let settings = await center.notificationSettings()
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
            return .unknown
        }
    }

    public func pendingRequests() async -> [PendingLocalNotification] {
        let requests = await center.pendingNotificationRequests()
        return requests.map { request in
            let fireDate = (request.trigger as? UNTimeIntervalNotificationTrigger)?
                .nextTriggerDate()
            return PendingLocalNotification(
                identifier: request.identifier,
                fireDate: fireDate
            )
        }
    }

    public func add(_ request: LocalNotificationRequest) async throws {
        let interval = request.fireDate.timeIntervalSinceNow
        guard interval > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, interval),
            repeats: false
        )
        let notificationRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )
        try await center.add(notificationRequest)
    }

    public func addRecurring(_ request: RecurringLocalNotificationRequest) async throws {
        var components = DateComponents()
        switch request.schedule {
        case .daily(let hour, let minute):
            components.hour = hour
            components.minute = minute
        case .weekly(let weekday, let hour, let minute):
            components.weekday = weekday.rawValue
            components.hour = hour
            components.minute = minute
        }

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components,
            repeats: true
        )
        let notificationRequest = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )
        try await center.add(notificationRequest)
    }

    public func removePendingRequests(withIdentifiers identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
