import XCTest
@testable import EventClockCore

final class RecoveryTimerTests: XCTestCase {
    private func updatedTimers(in effects: [EngineEffect]) -> [TimerInstance] {
        effects.compactMap {
            if case .timerUpdated(let timer) = $0 { return timer }
            return nil
        }
    }

    private func calendar(timeZone identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        in calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    // MARK: - Absolute reset timers

    func testExactResetTimestampsAndMultipleTimers() async throws {
        let clock = ManualClock()
        let scheduler = RecordingScheduler()
        let engine = makeEngine(clock: clock, scheduler: scheduler)
        try await engine.start()

        let firstDeadline = clock.now.addingTimeInterval(3_600)
        let secondDeadline = clock.now.addingTimeInterval(7_200)

        let firstEffects = try await engine.startRecoveryTimer(
            serviceName: "ChatGPT allowance",
            deadline: firstDeadline,
            eventID: "reset-1"
        )
        let secondEffects = try await engine.startRecoveryTimer(
            serviceName: "Claude allowance",
            deadline: secondDeadline,
            eventID: "reset-2"
        )

        let first = try XCTUnwrap(startedTimers(in: firstEffects).first)
        let second = try XCTUnwrap(startedTimers(in: secondEffects).first)
        XCTAssertEqual(first.deadline, firstDeadline)
        XCTAssertEqual(second.deadline, secondDeadline)
        XCTAssertEqual(first.kind, .recovery)
        XCTAssertEqual(second.kind, .recovery)
        XCTAssertEqual(first.label, "ChatGPT allowance")

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.filter { $0.state == .running }.count, 2)
        XCTAssertEqual(scheduler.scheduled.count, 2)
        XCTAssertEqual(
            Set(scheduler.scheduled.map(\.timerID)),
            [first.id, second.id]
        )
    }

    func testRelativeEventTimerUsesEventTimestampAndDuration() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let eventDate = clock.now
        let event = Event(
            id: "recorded-1",
            type: "manual.event.recorded",
            occurredAt: eventDate,
            payload: ["source": .string("manual")]
        )
        let effects = try await engine.recordEventAndStartTimer(
            name: "Five-hour task",
            duration: 5 * 3_600,
            event: event
        )
        let timer = try XCTUnwrap(startedTimers(in: effects).first)

        XCTAssertEqual(timer.startedAt, eventDate)
        XCTAssertEqual(timer.deadline, eventDate.addingTimeInterval(5 * 3_600))
        XCTAssertEqual(timer.duration, 5 * 3_600)
        XCTAssertEqual(timer.kind, .relativeEvent)
        XCTAssertEqual(timer.label, "Five-hour task")

        clock.advance(by: 3 * 3_600)
        let midway = try await engine.advance()
        XCTAssertTrue(firedTimers(in: midway).isEmpty)

        clock.advance(by: 2 * 3_600)
        let fired = firedTimers(in: try await engine.advance())
        XCTAssertEqual(fired.map(\.id), [timer.id])
    }

    func testRescheduleAndCancelAreIndependent() async throws {
        let clock = ManualClock()
        let scheduler = RecordingScheduler()
        let engine = makeEngine(clock: clock, scheduler: scheduler)
        try await engine.start()

        let firstDeadline = clock.now.addingTimeInterval(600)
        let firstEffects = try await engine.startRecoveryTimer(
            serviceName: "Service A",
            deadline: firstDeadline,
            eventID: "a-1"
        )
        let secondEffects = try await engine.startRecoveryTimer(
            serviceName: "Service B",
            deadline: clock.now.addingTimeInterval(1_200),
            eventID: "b-1"
        )
        let first = try XCTUnwrap(startedTimers(in: firstEffects).first)
        let second = try XCTUnwrap(startedTimers(in: secondEffects).first)

        let newDeadline = clock.now.addingTimeInterval(900)
        let editEffects = try await engine.rescheduleRecoveryTimer(
            id: first.id,
            serviceName: "Service A renamed",
            deadline: newDeadline
        )
        let updated = try XCTUnwrap(updatedTimers(in: editEffects).first)
        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.label, "Service A renamed")
        XCTAssertEqual(updated.deadline, newDeadline)
        XCTAssertEqual(scheduler.scheduled.last?.timerID, first.id)
        XCTAssertEqual(scheduler.scheduled.last?.deadline, newDeadline)

        _ = try await engine.cancel(timerID: second.id)

        let timersAfterCancel = await engine.currentTimers()
        XCTAssertEqual(timersAfterCancel.first { $0.id == first.id }?.state, .running)
        XCTAssertEqual(timersAfterCancel.first { $0.id == second.id }?.state, .cancelled)

        clock.advance(by: 900)
        let fired = firedTimers(in: try await engine.advance())
        XCTAssertEqual(fired.map(\.id), [first.id])
        XCTAssertFalse(fired.map(\.id).contains(second.id))
    }

    // MARK: - Validation and duplicates

    func testInvalidResetTimesAndNamesAreRejected() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        do {
            _ = try await engine.startRecoveryTimer(
                serviceName: "Past",
                deadline: clock.now,
                eventID: "past-1"
            )
            XCTFail("Expected deadlineNotFuture")
        } catch let error as RecoveryTimerError {
            XCTAssertEqual(error, .deadlineNotFuture)
        }

        do {
            _ = try await engine.startRecoveryTimer(
                serviceName: " ",
                deadline: clock.now.addingTimeInterval(60),
                eventID: "blank-name"
            )
            XCTFail("Expected emptyServiceName")
        } catch let error as RecoveryTimerError {
            XCTAssertEqual(error, .emptyServiceName)
        }

        do {
            _ = try await engine.startRecoveryTimer(
                serviceName: String(repeating: "a", count: 81),
                deadline: clock.now.addingTimeInterval(60),
                eventID: "long-name"
            )
            XCTFail("Expected serviceNameTooLong")
        } catch let error as RecoveryTimerError {
            XCTAssertEqual(error, .serviceNameTooLong)
        }

        let timers = await engine.currentTimers()
        XCTAssertTrue(timers.isEmpty)
    }

    func testInvalidRelativeTimersAreRejected() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        for duration in [0, -1, TimerDefinition.maximumDuration + 1] {
            let event = Event(
                id: "invalid-\(duration)",
                type: "manual.event.recorded",
                occurredAt: clock.now
            )
            do {
                _ = try await engine.recordEventAndStartTimer(
                    name: "Invalid",
                    duration: duration,
                    event: event
                )
                XCTFail("Expected invalidDuration")
            } catch let error as RecoveryTimerError {
                XCTAssertEqual(error, .invalidDuration)
            }
        }

        let oldEvent = Event(
            id: "too-old",
            type: "manual.event.recorded",
            occurredAt: clock.now.addingTimeInterval(-7_200)
        )
        do {
            _ = try await engine.recordEventAndStartTimer(
                name: "Old event",
                duration: 3_600,
                event: oldEvent
            )
            XCTFail("Expected eventDeadlineNotFuture")
        } catch let error as RecoveryTimerError {
            XCTAssertEqual(error, .eventDeadlineNotFuture)
        }
    }

    func testDuplicateCreationEventIDsAreSuppressed() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let deadline = clock.now.addingTimeInterval(300)
        _ = try await engine.startRecoveryTimer(
            serviceName: "One",
            deadline: deadline,
            eventID: "duplicate-reset"
        )
        let duplicate = try await engine.startRecoveryTimer(
            serviceName: "Two",
            deadline: deadline,
            eventID: "duplicate-reset"
        )
        XCTAssertTrue(startedTimers(in: duplicate).isEmpty)
        XCTAssertTrue(duplicate.contains { effect in
            if case .duplicateEventIgnored = effect { return true }
            return false
        })

        let event = Event(
            id: "duplicate-relative",
            type: "manual.event.recorded",
            occurredAt: clock.now
        )
        _ = try await engine.recordEventAndStartTimer(
            name: "Relative",
            duration: 300,
            event: event
        )
        let relativeDuplicate = try await engine.recordEventAndStartTimer(
            name: "Relative",
            duration: 300,
            event: event
        )
        XCTAssertTrue(startedTimers(in: relativeDuplicate).isEmpty)

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.count, 2)
    }

    // MARK: - Persistence and clock behavior

    func testRecoveryTimersPersistAndRecover() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let firstEngine = makeEngine(clock: clock, store: store)
        try await firstEngine.start()

        let recoveryDeadline = clock.now.addingTimeInterval(600)
        let recoveryEffects = try await firstEngine.startRecoveryTimer(
            serviceName: "Persisted reset",
            deadline: recoveryDeadline,
            eventID: "persist-reset"
        )
        let recoveryTimer = try XCTUnwrap(startedTimers(in: recoveryEffects).first)

        let event = Event(
            id: "persist-relative",
            type: "manual.event.recorded",
            occurredAt: clock.now
        )
        let relativeEffects = try await firstEngine.recordEventAndStartTimer(
            name: "Persisted relative",
            duration: 300,
            event: event
        )
        let relativeTimer = try XCTUnwrap(startedTimers(in: relativeEffects).first)

        let secondEngine = makeEngine(clock: clock, store: store)
        let startEffects = try await secondEngine.start()
        XCTAssertTrue(firedTimers(in: startEffects).isEmpty)

        let recovered = await secondEngine.currentTimers()
        XCTAssertEqual(recovered.first { $0.id == recoveryTimer.id }?.deadline, recoveryDeadline)
        XCTAssertEqual(recovered.first { $0.id == recoveryTimer.id }?.kind, .recovery)
        XCTAssertEqual(recovered.first { $0.id == relativeTimer.id }?.kind, .relativeEvent)

        clock.advance(by: 300)
        let firstFire = firedTimers(in: try await secondEngine.advance())
        XCTAssertEqual(firstFire.map(\.id), [relativeTimer.id])

        clock.advance(by: 300)
        let secondFire = firedTimers(in: try await secondEngine.advance())
        XCTAssertEqual(secondFire.map(\.id), [recoveryTimer.id])

        let thirdEngine = makeEngine(clock: clock, store: store)
        let thirdStart = try await thirdEngine.start()
        XCTAssertTrue(firedTimers(in: thirdStart).isEmpty)
    }

    func testRecoveryTimerAcrossDSTBoundaryUsesAbsoluteInstant() async throws {
        let newYork = calendar(timeZone: "America/New_York")
        let start = date(2026, 3, 8, 1, 30, in: newYork) // EST
        let deadline = date(2026, 3, 8, 3, 30, in: newYork) // EDT, after DST jump
        let clock = ManualClock(wall: start)
        let engine = makeEngine(clock: clock, calendar: newYork)
        try await engine.start()

        let effects = try await engine.startRecoveryTimer(
            serviceName: "DST reset",
            deadline: deadline,
            eventID: "dst-reset"
        )
        let timer = try XCTUnwrap(startedTimers(in: effects).first)
        XCTAssertEqual(timer.deadline, deadline)
        XCTAssertEqual(deadline.timeIntervalSince(start), 3_600, accuracy: 0.001)

        clock.advance(by: 3_600)
        let fired = firedTimers(in: try await engine.advance())
        XCTAssertEqual(fired.map(\.id), [timer.id])

        let components = newYork.dateComponents(
            [.hour, .minute],
            from: deadline
        )
        XCTAssertEqual(components.hour, 3)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(newYork.timeZone.secondsFromGMT(for: deadline), -4 * 3_600)
    }

    func testRecoveryTimerClockJumpPreservesRemainingDuration() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let effects = try await engine.startRecoveryTimer(
            serviceName: "Clock jump",
            deadline: clock.now.addingTimeInterval(600),
            eventID: "clock-jump"
        )
        let timer = try XCTUnwrap(startedTimers(in: effects).first)

        clock.advance(by: 60)
        clock.shiftWall(by: 3_600)

        let afterJump = try await engine.advance()
        XCTAssertTrue(firedTimers(in: afterJump).isEmpty)

        let timers = await engine.currentTimers()
        XCTAssertEqual(
            timers.first { $0.id == timer.id }?.deadline.timeIntervalSince(clock.now) ?? -1,
            540,
            accuracy: 0.001
        )

        clock.advance(by: 540)
        let fired = firedTimers(in: try await engine.advance())
        XCTAssertEqual(fired.map(\.id), [timer.id])
    }

    func testRescheduleRejectsMissingOrNonRunningRecoveryTimer() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        do {
            _ = try await engine.rescheduleRecoveryTimer(
                id: "missing",
                serviceName: "Missing",
                deadline: clock.now.addingTimeInterval(60)
            )
            XCTFail("Expected unknownRecoveryTimer")
        } catch let error as TimerEngineError {
            XCTAssertEqual(error, .unknownRecoveryTimer)
        }

        let futureEffects = try await engine.startRecoveryTimer(
            serviceName: "Past reschedule",
            deadline: clock.now.addingTimeInterval(300),
            eventID: "past-reschedule"
        )
        let futureTimer = try XCTUnwrap(startedTimers(in: futureEffects).first)
        do {
            _ = try await engine.rescheduleRecoveryTimer(
                id: futureTimer.id,
                serviceName: "Past reschedule",
                deadline: clock.now
            )
            XCTFail("Expected deadlineNotFuture")
        } catch let error as RecoveryTimerError {
            XCTAssertEqual(error, .deadlineNotFuture)
        }

        let effects = try await engine.startRecoveryTimer(
            serviceName: "Cancel then edit",
            deadline: clock.now.addingTimeInterval(60),
            eventID: "cancel-edit"
        )
        let timer = try XCTUnwrap(startedTimers(in: effects).first)
        _ = try await engine.cancel(timerID: timer.id)

        do {
            _ = try await engine.rescheduleRecoveryTimer(
                id: timer.id,
                serviceName: "Edited",
                deadline: clock.now.addingTimeInterval(120)
            )
            XCTFail("Expected recoveryTimerNotRunning")
        } catch let error as TimerEngineError {
            XCTAssertEqual(error, .recoveryTimerNotRunning)
        }
    }
}
