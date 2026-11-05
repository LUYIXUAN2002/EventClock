import XCTest
import EventClockCore
@testable import EventClockPlatform

private actor FakeNotificationCenter: LocalNotificationCenter, RecurringNotificationCenter {
    private(set) var pending: [PendingLocalNotification] = []
    private(set) var added: [LocalNotificationRequest] = []
    private(set) var recurringAdded: [RecurringLocalNotificationRequest] = []
    private(set) var removedBatches: [[String]] = []

    func pendingRequests() async -> [PendingLocalNotification] {
        pending
    }

    func add(_ request: LocalNotificationRequest) async throws {
        added.append(request)
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(
            PendingLocalNotification(
                identifier: request.identifier,
                fireDate: request.fireDate
            )
        )
    }

    func addRecurring(_ request: RecurringLocalNotificationRequest) async throws {
        recurringAdded.append(request)
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(
            PendingLocalNotification(
                identifier: request.identifier,
                fireDate: nil
            )
        )
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) async {
        removedBatches.append(identifiers)
        pending.removeAll { identifiers.contains($0.identifier) }
    }
}

final class NotificationCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func makeTimer(
        id: String,
        deadline: Date,
        state: TimerInstance.State = .running
    ) -> TimerInstance {
        TimerInstance(
            id: id,
            ruleID: Rule.waterBoiling.id,
            label: "Boiling water",
            duration: deadline.timeIntervalSince(now),
            startedAt: now,
            deadline: deadline,
            actions: [
                .notify(title: "Cooking timer", body: "Your 10-minute timer is done."),
            ],
            state: state
        )
    }

    func testScheduleUsesStableIdentifierAndDoesNotDuplicate() async throws {
        let center = FakeNotificationCenter()
        let coordinator = TimerNotificationCoordinator(center: center)
        let timer = makeTimer(id: "timer-1", deadline: now.addingTimeInterval(600))

        try await coordinator.schedule(timer)
        try await coordinator.schedule(timer)

        let added = await center.added
        let pending = await center.pending
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(
            added.first?.identifier,
            "eventclock.timer.timer-1"
        )
        XCTAssertEqual(added.first?.title, "Cooking timer")
        XCTAssertEqual(added.first?.fireDate, timer.deadline)
    }

    func testSchedulingTerminalTimerRemovesNotification() async throws {
        let center = FakeNotificationCenter()
        let coordinator = TimerNotificationCoordinator(center: center)
        let timer = makeTimer(id: "timer-1", deadline: now.addingTimeInterval(600))

        try await coordinator.schedule(timer)
        let cancelled = makeTimer(
            id: "timer-1",
            deadline: timer.deadline,
            state: .cancelled
        )
        try await coordinator.schedule(cancelled)

        let pending = await center.pending
        let removed = await center.removedBatches
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(removed.last, ["eventclock.timer.timer-1"])
    }

    func testCancelRemovesPendingNotification() async {
        let center = FakeNotificationCenter()
        let coordinator = TimerNotificationCoordinator(center: center)
        let timer = makeTimer(id: "timer-1", deadline: now.addingTimeInterval(600))

        try? await coordinator.schedule(timer)
        await coordinator.cancel(timerID: "timer-1")

        let pending = await center.pending
        let removed = await center.removedBatches
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(removed.last, ["eventclock.timer.timer-1"])
    }

    func testReconcileSchedulesMissingAndRepairsDrift() async throws {
        let center = FakeNotificationCenter()
        let coordinator = TimerNotificationCoordinator(center: center)

        let first = makeTimer(id: "first", deadline: now.addingTimeInterval(600))
        let second = makeTimer(id: "second", deadline: now.addingTimeInterval(900))
        let third = makeTimer(id: "third", deadline: now.addingTimeInterval(1_200))
        let stale = PendingLocalNotification(
            identifier: "eventclock.timer.stale",
            fireDate: now.addingTimeInterval(300)
        )

        try await center.add(
            LocalNotificationRequest(
                identifier: "eventclock.timer.first",
                title: "Cooking timer",
                body: "Done",
                fireDate: first.deadline
            )
        )
        try await center.add(
            LocalNotificationRequest(
                identifier: "eventclock.timer.second",
                title: "Cooking timer",
                body: "Done",
                fireDate: second.deadline.addingTimeInterval(120)
            )
        )
        try await center.add(
            LocalNotificationRequest(
                identifier: stale.identifier,
                title: "Old",
                body: "Old",
                fireDate: stale.fireDate ?? now
            )
        )

        let addedBefore = await center.added.count
        try await coordinator.reconcile(
            activeTimers: [first, second, third],
            now: now
        )

        let pending = await center.pending
        let added = await center.added
        let pendingIDs = Set(pending.map(\.identifier))
        XCTAssertEqual(
            pendingIDs,
            [
                "eventclock.timer.first",
                "eventclock.timer.second",
                "eventclock.timer.third",
            ]
        )
        XCTAssertFalse(pendingIDs.contains("eventclock.timer.stale"))
        XCTAssertEqual(added.count - addedBefore, 2)
        XCTAssertEqual(
            pending.first { $0.identifier == "eventclock.timer.second" }?.fireDate,
            second.deadline
        )
        XCTAssertEqual(
            pending.first { $0.identifier == "eventclock.timer.third" }?.fireDate,
            third.deadline
        )
    }

    func testReconcileLeavesMatchingRequestsAlone() async throws {
        let center = FakeNotificationCenter()
        let coordinator = TimerNotificationCoordinator(center: center)
        let timer = makeTimer(id: "timer-1", deadline: now.addingTimeInterval(600))

        try await coordinator.schedule(timer)
        let addedBefore = await center.added.count

        try await coordinator.reconcile(activeTimers: [timer], now: now)

        let addedAfter = await center.added.count
        let pending = await center.pending
        let removed = await center.removedBatches
        XCTAssertEqual(addedAfter, addedBefore)
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(removed.isEmpty)
    }

    func testReconcileIgnoresExpiredOrTerminalTimers() async throws {
        let center = FakeNotificationCenter()
        let coordinator = TimerNotificationCoordinator(center: center)
        let expired = makeTimer(
            id: "expired",
            deadline: now.addingTimeInterval(-1)
        )
        let fired = makeTimer(
            id: "fired",
            deadline: now.addingTimeInterval(600),
            state: .fired
        )

        try await coordinator.reconcile(activeTimers: [expired, fired], now: now)

        let added = await center.added
        let pending = await center.pending
        XCTAssertTrue(added.isEmpty)
        XCTAssertTrue(pending.isEmpty)
    }

    func testTwoTimersScheduleAndCancelIndependently() async throws {
        let center = FakeNotificationCenter()
        let coordinator = TimerNotificationCoordinator(center: center)
        let first = makeTimer(id: "first", deadline: now.addingTimeInterval(60))
        let second = makeTimer(id: "second", deadline: now.addingTimeInterval(120))

        try await coordinator.schedule(first)
        try await coordinator.schedule(second)

        let afterSchedule = await center.pending
        XCTAssertEqual(
            Set(afterSchedule.map(\.identifier)),
            ["eventclock.timer.first", "eventclock.timer.second"]
        )

        await coordinator.cancel(timerID: first.id)

        let afterCancel = await center.pending
        let removed = await center.removedBatches
        XCTAssertEqual(afterCancel.map(\.identifier), ["eventclock.timer.second"])
        XCTAssertEqual(afterCancel.first?.fireDate, second.deadline)
        XCTAssertEqual(removed.last, ["eventclock.timer.first"])
    }

    func testImmediateAutomationNotificationIsStableAndDeduplicated() async throws {
        let center = FakeNotificationCenter()
        let coordinator = TimerNotificationCoordinator(center: center)
        let identifier = "eventclock.automation.rule-1.event-1"

        try await coordinator.notifyImmediately(
            identifier: identifier,
            title: "Automation",
            body: "Triggered"
        )
        try await coordinator.notifyImmediately(
            identifier: identifier,
            title: "Automation",
            body: "Triggered"
        )

        let pending = await center.pending
        let added = await center.added
        XCTAssertEqual(pending.map(\.identifier), [identifier])
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.title, "Automation")
    }

    func testRecurringRemindersReconcileAndCancelIndependently() async throws {
        let center = FakeNotificationCenter()
        let coordinator = RecurringNotificationCoordinator(center: center)

        let daily = RecurringReminder(
            id: "daily",
            title: "Daily reminder",
            body: "Body",
            schedule: .daily(hour: 8, minute: 30)
        )
        let weekly = RecurringReminder(
            id: "weekly",
            title: "Weekly reminder",
            body: "Body",
            schedule: .weekly(weekday: .monday, hour: 9, minute: 0)
        )
        let disabled = RecurringReminder(
            id: "disabled",
            title: "Disabled",
            body: "",
            schedule: .daily(hour: 7, minute: 0),
            isEnabled: false
        )

        try await coordinator.reconcile(reminders: [daily, weekly, disabled])

        var pending = await center.pending
        var requests = await center.recurringAdded
        XCTAssertEqual(
            Set(pending.map(\.identifier)),
            [
                "eventclock.reminder.daily",
                "eventclock.reminder.weekly",
            ]
        )
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.first { $0.identifier.hasSuffix("daily") }?.schedule,
            .daily(hour: 8, minute: 30)
        )
        XCTAssertEqual(
            requests.first { $0.identifier.hasSuffix("weekly") }?.schedule,
            .weekly(weekday: .monday, hour: 9, minute: 0)
        )

        let editedDaily = RecurringReminder(
            id: "daily",
            title: "Edited",
            body: "Body",
            schedule: .daily(hour: 9, minute: 0)
        )
        try await coordinator.reconcile(reminders: [editedDaily, disabled])

        pending = await center.pending
        requests = await center.recurringAdded
        XCTAssertEqual(pending.map(\.identifier), ["eventclock.reminder.daily"])
        XCTAssertEqual(requests.last?.title, "Edited")
        XCTAssertEqual(requests.last?.schedule, .daily(hour: 9, minute: 0))

        await coordinator.cancel(reminderID: "daily")
        pending = await center.pending
        XCTAssertTrue(pending.isEmpty)
    }
}
