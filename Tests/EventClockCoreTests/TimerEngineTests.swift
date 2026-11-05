import XCTest
@testable import EventClockCore

final class TimerEngineTests: XCTestCase {

    // MARK: - Start and expiry

    func testWaterBoilingStartsTenMinuteTimer() async throws {
        let clock = ManualClock()
        let scheduler = RecordingScheduler()
        let engine = makeEngine(clock: clock, scheduler: scheduler)
        try await engine.start()

        let effects = try await engine.handle(waterBoilingEvent(id: "evt-1", clock: clock))
        let started = startedTimers(in: effects)

        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(started.first?.duration, 600)
        XCTAssertEqual(started.first?.state, .running)
        XCTAssertEqual(started.first?.ruleID, Rule.waterBoiling.id)
        XCTAssertEqual(
            started.first?.deadline.timeIntervalSince(clock.now) ?? -1,
            600,
            accuracy: 0.001
        )

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(scheduler.scheduled.count, 1)
        XCTAssertEqual(scheduler.scheduled.first?.timerID, started.first?.id)
    }

    func testTimerExpiresAtTenMinutesAndRequestsAction() async throws {
        let clock = ManualClock()
        let scheduler = RecordingScheduler()
        let engine = makeEngine(clock: clock, scheduler: scheduler)
        try await engine.start()

        let startEffects = try await engine.handle(waterBoilingEvent(id: "evt-1", clock: clock))
        let timerID = try XCTUnwrap(startedTimers(in: startEffects).first?.id)

        clock.advance(by: 599)
        let beforeDeadline = try await engine.advance()
        XCTAssertTrue(beforeDeadline.isEmpty)

        clock.advance(by: 1)
        let expiryEffects = try await engine.advance()

        let fired = firedTimers(in: expiryEffects)
        XCTAssertEqual(fired.count, 1)
        XCTAssertEqual(fired.first?.id, timerID)
        XCTAssertEqual(fired.first?.state, .fired)
        XCTAssertNotNil(fired.first?.firedAt)

        let actions = actionRequests(in: expiryEffects)
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.timerID, timerID)
        XCTAssertEqual(actions.first?.key, "\(timerID):0")
        guard case .notify(let title, _)? = actions.first?.action else {
            return XCTFail("Expected a notify action")
        }
        XCTAssertEqual(title, "Cooking timer")
        XCTAssertEqual(scheduler.cancelled, [timerID])

        // Firing is recorded once; later advances produce no effects.
        let afterFiring = try await engine.advance()
        XCTAssertTrue(afterFiring.isEmpty)
    }

    // MARK: - Duplicates

    func testDuplicateEventStartsOnlyOneTimer() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        _ = try await engine.handle(waterBoilingEvent(id: "evt-1", clock: clock))
        clock.advance(by: 5)
        let duplicateEffects = try await engine.handle(waterBoilingEvent(id: "evt-1", clock: clock))

        XCTAssertTrue(duplicateEffects.contains { effect in
            if case .duplicateEventIgnored(let id) = effect { return id == "evt-1" }
            return false
        })
        XCTAssertTrue(startedTimers(in: duplicateEffects).isEmpty)
        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.count, 1)
    }

    func testDuplicateEventSuppressedAfterEngineRestart() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let firstEngine = makeEngine(clock: clock, store: store)
        try await firstEngine.start()
        _ = try await firstEngine.handle(waterBoilingEvent(id: "evt-1", clock: clock))

        let secondEngine = makeEngine(clock: clock, store: store)
        try await secondEngine.start()
        let effects = try await secondEngine.handle(waterBoilingEvent(id: "evt-1", clock: clock))

        XCTAssertTrue(startedTimers(in: effects).isEmpty)
        XCTAssertTrue(effects.contains { effect in
            if case .duplicateEventIgnored = effect { return true }
            return false
        })
        let timers = await secondEngine.currentTimers()
        XCTAssertEqual(timers.count, 1)
    }

    // MARK: - Cancellation

    func testCancellationPreventsExpiry() async throws {
        let clock = ManualClock()
        let scheduler = RecordingScheduler()
        let engine = makeEngine(clock: clock, scheduler: scheduler)
        try await engine.start()

        let effects = try await engine.handle(waterBoilingEvent(id: "evt-1", clock: clock))
        let timerID = try XCTUnwrap(startedTimers(in: effects).first?.id)

        let cancelEffects = try await engine.cancel(timerID: timerID)
        let cancelled = cancelEffects.compactMap { effect -> TimerInstance? in
            if case .timerCancelled(let timer) = effect { return timer }
            return nil
        }
        XCTAssertEqual(cancelled.count, 1)
        XCTAssertEqual(cancelled.first?.state, .cancelled)
        XCTAssertEqual(scheduler.cancelled, [timerID])

        clock.advance(by: 601)
        let laterEffects = try await engine.advance()
        XCTAssertTrue(firedTimers(in: laterEffects).isEmpty)
        XCTAssertTrue(actionRequests(in: laterEffects).isEmpty)
    }

    // MARK: - Recovery

    func testRecoveryKeepsRunningTimerOnTrack() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let firstEngine = makeEngine(clock: clock, store: store)
        try await firstEngine.start()
        _ = try await firstEngine.handle(waterBoilingEvent(id: "evt-1", clock: clock))

        clock.advance(by: 120)

        let secondEngine = makeEngine(clock: clock, store: store)
        let recoveryEffects = try await secondEngine.start()
        XCTAssertTrue(firedTimers(in: recoveryEffects).isEmpty)

        let recovered = await secondEngine.currentTimers()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.state, .running)
        XCTAssertEqual(
            recovered.first?.deadline.timeIntervalSince(clock.now) ?? -1,
            480,
            accuracy: 0.001
        )

        clock.advance(by: 479)
        let beforeDeadline = try await secondEngine.advance()
        XCTAssertTrue(beforeDeadline.isEmpty)

        clock.advance(by: 1)
        let fired = firedTimers(in: try await secondEngine.advance())
        XCTAssertEqual(fired.count, 1)
    }

    func testRecoveryFiresOverdueTimerOnceWithActions() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let firstEngine = makeEngine(clock: clock, store: store)
        try await firstEngine.start()
        _ = try await firstEngine.handle(waterBoilingEvent(id: "evt-1", clock: clock))

        clock.advance(by: 601)

        let secondEngine = makeEngine(clock: clock, store: store)
        let recoveryEffects = try await secondEngine.start()
        XCTAssertEqual(firedTimers(in: recoveryEffects).count, 1)
        XCTAssertEqual(actionRequests(in: recoveryEffects).count, 1)

        let thirdEngine = makeEngine(clock: clock, store: store)
        let secondRecovery = try await thirdEngine.start()
        XCTAssertTrue(firedTimers(in: secondRecovery).isEmpty)
        XCTAssertTrue(actionRequests(in: secondRecovery).isEmpty)
    }

    func testFileStorePersistsAcrossEngineRestart() async throws {
        let clock = ManualClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("timers.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstEngine = makeEngine(clock: clock, store: FileTimerStore(fileURL: fileURL))
        try await firstEngine.start()
        _ = try await firstEngine.handle(waterBoilingEvent(id: "evt-file", clock: clock))

        clock.advance(by: 600)

        let secondEngine = makeEngine(clock: clock, store: FileTimerStore(fileURL: fileURL))
        let recoveryEffects = try await secondEngine.start()
        XCTAssertEqual(firedTimers(in: recoveryEffects).count, 1)

        // Deduplication state also survived the file round trip.
        let duplicate = try await secondEngine.handle(waterBoilingEvent(id: "evt-file", clock: clock))
        XCTAssertTrue(startedTimers(in: duplicate).isEmpty)
    }

    // MARK: - Clock changes

    func testForwardWallClockJumpDoesNotExpireTimerAndRebasesDeadline() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        _ = try await engine.handle(waterBoilingEvent(id: "evt-1", clock: clock))

        clock.advance(by: 60)
        clock.shiftWall(by: 6 * 60 * 60)

        let effects = try await engine.advance()
        XCTAssertTrue(firedTimers(in: effects).isEmpty)

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.first?.state, .running)
        XCTAssertEqual(
            timers.first?.deadline.timeIntervalSince(clock.now) ?? -1,
            540,
            accuracy: 0.001
        )

        clock.advance(by: 540)
        let firedAfterChange = try await engine.advance()
        XCTAssertEqual(firedTimers(in: firedAfterChange).count, 1)
    }

    func testBackwardWallClockJumpDoesNotExpireTimerAndRebasesDeadline() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        _ = try await engine.handle(waterBoilingEvent(id: "evt-1", clock: clock))

        clock.advance(by: 60)
        clock.shiftWall(by: -60 * 60)

        let effects = try await engine.advance()
        XCTAssertTrue(firedTimers(in: effects).isEmpty)

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.first?.state, .running)
        XCTAssertEqual(
            timers.first?.deadline.timeIntervalSince(clock.now) ?? -1,
            540,
            accuracy: 0.001
        )

        clock.advance(by: 540)
        let firedAfterChange = try await engine.advance()
        XCTAssertEqual(firedTimers(in: firedAfterChange).count, 1)
    }

    // MARK: - Lifecycle guard

    func testEngineRejectsCallsBeforeStart() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)

        do {
            _ = try await engine.handle(waterBoilingEvent(id: "evt-1", clock: clock))
            XCTFail("Expected notStarted")
        } catch let error as TimerEngineError {
            XCTAssertEqual(error, .notStarted)
        }
    }

    // MARK: - Multiple independent timers

    private var thirtySecondRule: Rule {
        Rule(
            id: "test.thirty-second",
            label: "30-second test",
            eventType: "test.thirty-second",
            duration: 30,
            actions: [.notify(title: "30-second test", body: "Done")],
        )
    }

    func testTwoConcurrentTimersWithDifferentDurations() async throws {
        let clock = ManualClock()
        let rule = thirtySecondRule
        let engine = makeEngine(clock: clock, rules: [.waterBoiling, rule])
        try await engine.start()

        let longEffects = try await engine.handle(
            waterBoilingEvent(id: "long-1", clock: clock)
        )
        clock.advance(by: 5)
        let shortEffects = try await engine.handle(
            Event(id: "short-1", type: rule.eventType, occurredAt: clock.now)
        )

        let long = try XCTUnwrap(startedTimers(in: longEffects).first)
        let short = try XCTUnwrap(startedTimers(in: shortEffects).first)
        XCTAssertNotEqual(long.id, short.id)

        let started = await engine.currentTimers()
        XCTAssertEqual(started.filter { $0.state == .running }.count, 2)

        clock.advance(by: 25) // t=30; short timer is due at t=35
        let beforeShortDeadline = try await engine.advance()
        XCTAssertTrue(firedTimers(in: beforeShortDeadline).isEmpty)

        clock.advance(by: 5) // t=35
        let firstFire = try await engine.advance()
        XCTAssertEqual(firedTimers(in: firstFire).map(\.id), [short.id])

        let afterFirstFire = await engine.currentTimers()
        let longAfterFirstFire = afterFirstFire.first { $0.id == long.id }
        XCTAssertEqual(longAfterFirstFire?.state, .running)
        XCTAssertEqual(
            longAfterFirstFire?.deadline.timeIntervalSince(clock.now) ?? -1,
            565,
            accuracy: 0.001
        )

        clock.advance(by: 565) // t=600
        let secondFire = try await engine.advance()
        XCTAssertEqual(firedTimers(in: secondFire).map(\.id), [long.id])
    }

    func testCancellingOneTimerLeavesOtherRunningAndStatusPersists() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let rule = thirtySecondRule
        let rules: [Rule] = [.waterBoiling, rule]
        let engine = makeEngine(clock: clock, store: store, rules: rules)
        try await engine.start()

        let longEffects = try await engine.handle(
            waterBoilingEvent(id: "long-1", clock: clock)
        )
        let shortEffects = try await engine.handle(
            Event(id: "short-1", type: rule.eventType, occurredAt: clock.now)
        )
        let long = try XCTUnwrap(startedTimers(in: longEffects).first)
        let short = try XCTUnwrap(startedTimers(in: shortEffects).first)

        _ = try await engine.cancel(timerID: short.id)

        clock.advance(by: 600)
        let effects = try await engine.advance()
        XCTAssertEqual(firedTimers(in: effects).map(\.id), [long.id])

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.first { $0.id == long.id }?.state, .fired)
        XCTAssertEqual(timers.first { $0.id == short.id }?.state, .cancelled)

        // Terminal statuses are durable, and the cancelled timer never fires.
        let restarted = makeEngine(clock: clock, store: store, rules: rules)
        let recoveryEffects = try await restarted.start()
        XCTAssertTrue(firedTimers(in: recoveryEffects).isEmpty)

        let recovered = await restarted.currentTimers()
        XCTAssertEqual(recovered.first { $0.id == long.id }?.state, .fired)
        XCTAssertEqual(recovered.first { $0.id == short.id }?.state, .cancelled)
    }

    func testMultipleTimersPersistAndRecoverIndependently() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let rule = thirtySecondRule
        let rules: [Rule] = [.waterBoiling, rule]

        let firstEngine = makeEngine(clock: clock, store: store, rules: rules)
        try await firstEngine.start()
        let longEffects = try await firstEngine.handle(
            waterBoilingEvent(id: "long-1", clock: clock)
        )
        let shortEffects = try await firstEngine.handle(
            Event(id: "short-1", type: rule.eventType, occurredAt: clock.now)
        )
        let long = try XCTUnwrap(startedTimers(in: longEffects).first)
        let short = try XCTUnwrap(startedTimers(in: shortEffects).first)
        XCTAssertNotEqual(long.id, short.id)

        clock.advance(by: 10)

        let secondEngine = makeEngine(clock: clock, store: store, rules: rules)
        let secondStart = try await secondEngine.start()
        XCTAssertTrue(firedTimers(in: secondStart).isEmpty)

        let recovered = await secondEngine.currentTimers()
        XCTAssertEqual(recovered.filter { $0.state == .running }.count, 2)
        XCTAssertEqual(
            recovered.first { $0.id == long.id }?.deadline.timeIntervalSince(clock.now) ?? -1,
            590,
            accuracy: 0.001
        )
        XCTAssertEqual(
            recovered.first { $0.id == short.id }?.deadline.timeIntervalSince(clock.now) ?? -1,
            20,
            accuracy: 0.001
        )

        clock.advance(by: 20) // t=30: only the short timer expires
        let shortFire = try await secondEngine.advance()
        XCTAssertEqual(firedTimers(in: shortFire).map(\.id), [short.id])

        let thirdEngine = makeEngine(clock: clock, store: store, rules: rules)
        let thirdStart = try await thirdEngine.start()
        XCTAssertTrue(firedTimers(in: thirdStart).isEmpty)
        let thirdTimers = await thirdEngine.currentTimers()
        XCTAssertEqual(thirdTimers.first { $0.id == long.id }?.state, .running)
        XCTAssertEqual(thirdTimers.first { $0.id == short.id }?.state, .fired)

        clock.advance(by: 570) // t=600
        let longFire = try await thirdEngine.advance()
        XCTAssertEqual(firedTimers(in: longFire).map(\.id), [long.id])

        let fourthEngine = makeEngine(clock: clock, store: store, rules: rules)
        let fourthStart = try await fourthEngine.start()
        XCTAssertTrue(firedTimers(in: fourthStart).isEmpty)
    }

    func testDuplicateEventVersusLegitimateRepeatedEvent() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        _ = try await engine.handle(waterBoilingEvent(id: "same-id", clock: clock))
        _ = try await engine.handle(waterBoilingEvent(id: "same-id", clock: clock))
        let afterDuplicate = await engine.currentTimers()
        XCTAssertEqual(afterDuplicate.count, 1)

        _ = try await engine.handle(waterBoilingEvent(id: "new-id", clock: clock))
        let afterNewEvent = await engine.currentTimers()
        XCTAssertEqual(runningCount(afterNewEvent), 2)
        XCTAssertEqual(Set(afterNewEvent.map(\.id)).count, 2)
    }

    private func runningCount(_ timers: [TimerInstance]) -> Int {
        timers.filter { $0.state == .running }.count
    }
}
