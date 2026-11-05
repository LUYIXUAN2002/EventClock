import Foundation
import EventClockCore

/// Manages system-scheduled daily/weekly reminders.
///
/// These are repeating `UNCalendarNotificationTrigger` requests, not rule
/// engine execution. iOS may deliver them while the app is suspended, but the
/// rule engine does not run in the background.
public actor RecurringNotificationCoordinator {
    public static let identifierPrefix = "eventclock.reminder."

    private let center: any RecurringNotificationCenter

    public init(center: any RecurringNotificationCenter) {
        self.center = center
    }

    public nonisolated func identifier(for reminderID: String) -> String {
        Self.identifierPrefix + reminderID
    }

    /// Replaces all managed recurring requests with the currently enabled
    /// reminders. Re-adding is intentional so edited times take effect.
    public func reconcile(reminders: [RecurringReminder]) async throws {
        let pending = await center.pendingRequests()
        let managedIdentifiers = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.identifierPrefix) }

        if !managedIdentifiers.isEmpty {
            await center.removePendingRequests(
                withIdentifiers: managedIdentifiers
            )
        }

        for reminder in reminders where reminder.isEnabled {
            try await center.addRecurring(request(for: reminder))
        }
    }

    public func cancel(reminderID: String) async {
        await center.removePendingRequests(
            withIdentifiers: [identifier(for: reminderID)]
        )
    }

    private nonisolated func request(
        for reminder: RecurringReminder
    ) -> RecurringLocalNotificationRequest {
        RecurringLocalNotificationRequest(
            identifier: identifier(for: reminder.id),
            title: reminder.title,
            body: reminder.body,
            schedule: reminder.schedule
        )
    }
}
