import Foundation
import EventClockCore

/// Owns the mapping between engine timers and pending platform notifications.
///
/// Notifications are scheduled at timer-start time, not when the expiry
/// handler eventually runs. Reconciliation compares persisted running timers
/// with pending requests on launch/foreground and repairs drift.
public actor TimerNotificationCoordinator {
    public static let identifierPrefix = "eventclock.timer."
    /// Allowed difference between a pending trigger date and a timer deadline.
    public static let deadlineTolerance: TimeInterval = 2

    private let center: any LocalNotificationCenter

    public init(center: any LocalNotificationCenter) {
        self.center = center
    }

    /// Stable for the lifetime of a timer instance, so scheduling twice
    /// replaces rather than stacks alerts.
    public nonisolated func identifier(for timerID: String) -> String {
        Self.identifierPrefix + timerID
    }

    /// Call immediately after a `.timerStarted` effect.
    public func schedule(_ timer: TimerInstance) async throws {
        guard timer.state == .running else {
            await center.removePendingRequests(
                withIdentifiers: [identifier(for: timer.id)]
            )
            return
        }

        let pending = await center.pendingRequests()
        if let existing = pending.first(where: {
            $0.identifier == identifier(for: timer.id)
        }), let fireDate = existing.fireDate,
           abs(fireDate.timeIntervalSince(timer.deadline)) <= Self.deadlineTolerance {
            return
        }

        try await center.add(request(for: timer))
    }

    public func cancel(timerID: String) async {
        await center.removePendingRequests(
            withIdentifiers: [identifier(for: timerID)]
        )
    }

    /// Schedules an immediate notification for an automation rule action.
    /// The identifier is stable per rule/event, so re-delivery does not stack.
    public func notifyImmediately(
        identifier: String,
        title: String,
        body: String
    ) async throws {
        let pending = await center.pendingRequests()
        guard !pending.contains(where: { $0.identifier == identifier }) else {
            return
        }

        try await center.add(
            LocalNotificationRequest(
                identifier: identifier,
                title: title,
                body: body,
                fireDate: Date().addingTimeInterval(1)
            )
        )
    }

    /// Reconciles persisted running timers against pending notifications.
    ///
    /// - Removes requests for timers that are no longer running or have
    ///   already reached their deadline.
    /// - Removes requests whose trigger date no longer matches the timer's
    ///   persisted deadline.
    /// - Schedules requests for running timers that lack a matching one.
    public func reconcile(
        activeTimers: [TimerInstance],
        now: Date = Date()
    ) async throws {
        let active = activeTimers.filter {
            $0.state == .running && $0.deadline > now
        }
        let expected = Dictionary(
            active.map { (identifier(for: $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let pending = await center.pendingRequests()
        let managed = pending.filter {
            $0.identifier.hasPrefix(Self.identifierPrefix)
        }

        var toRemove: [String] = []
        for request in managed {
            guard let timer = expected[request.identifier] else {
                toRemove.append(request.identifier)
                continue
            }
            if let fireDate = request.fireDate,
               abs(fireDate.timeIntervalSince(timer.deadline)) <= Self.deadlineTolerance {
                continue
            }
            toRemove.append(request.identifier)
        }

        if !toRemove.isEmpty {
            await center.removePendingRequests(withIdentifiers: toRemove)
        }

        let removed = Set(toRemove)
        let present = Set(managed.map(\.identifier)).subtracting(removed)
        for timer in active where !present.contains(identifier(for: timer.id)) {
            try await center.add(request(for: timer))
        }
    }

    private nonisolated func request(for timer: TimerInstance) -> LocalNotificationRequest {
        let content = timer.actions.compactMap { action -> (title: String, body: String)? in
            if case .notify(let title, let body) = action {
                return (title, body)
            }
            return nil
        }.first

        return LocalNotificationRequest(
            identifier: identifier(for: timer.id),
            title: content?.title ?? timer.label,
            body: content?.body ?? "Timer finished.",
            fireDate: timer.deadline
        )
    }
}
