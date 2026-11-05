import Foundation
import EventClockCore

/// Value-type notification request used by the coordinator. Keeping this
/// independent of UserNotifications makes the scheduling policy testable.
public struct LocalNotificationRequest: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let fireDate: Date

    public init(identifier: String, title: String, body: String, fireDate: Date) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.fireDate = fireDate
    }
}

public struct RecurringLocalNotificationRequest: Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let schedule: RecurrenceSchedule

    public init(
        identifier: String,
        title: String,
        body: String,
        schedule: RecurrenceSchedule
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.schedule = schedule
    }
}

public struct PendingLocalNotification: Sendable, Equatable {
    public let identifier: String
    public let fireDate: Date?

    public init(identifier: String, fireDate: Date?) {
        self.identifier = identifier
        self.fireDate = fireDate
    }
}

/// Scheduling seam for the platform notification center.
public protocol LocalNotificationCenter: Sendable {
    func pendingRequests() async -> [PendingLocalNotification]
    func add(_ request: LocalNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String]) async
}

/// Platform seam for repeating calendar notifications.
public protocol RecurringNotificationCenter: Sendable {
    func pendingRequests() async -> [PendingLocalNotification]
    func addRecurring(_ request: RecurringLocalNotificationRequest) async throws
    func removePendingRequests(withIdentifiers identifiers: [String]) async
}

public enum NotificationPermission: String, Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown
}
