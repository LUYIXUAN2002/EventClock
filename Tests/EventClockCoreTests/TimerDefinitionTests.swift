import XCTest
@testable import EventClockCore

final class TimerDefinitionTests: XCTestCase {
    private func makeDefinition(
        id: String = "preset-1",
        name: String = "Tea",
        duration: TimeInterval = 180,
        isEnabled: Bool = true
    ) -> TimerDefinition {
        TimerDefinition(
            id: id,
            name: name,
            duration: duration,
            trigger: .manual,
            isEnabled: isEnabled,
            actions: [.notify(title: name, body: "Your timer is done.")]
        )
    }

    func testCreateEditAndDeleteDefinition() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let created = try await engine.saveDefinition(makeDefinition())
        XCTAssertEqual(created.name, "Tea")

        var definitions = await engine.currentDefinitions()
        XCTAssertEqual(definitions, [created])

        var edited = created
        edited.name = "  Green tea  "
        edited.duration = 240
        let saved = try await engine.saveDefinition(edited)

        XCTAssertEqual(saved.name, "Green tea")
        XCTAssertEqual(saved.duration, 240)
        definitions = await engine.currentDefinitions()
        XCTAssertEqual(definitions.count, 1)
        XCTAssertEqual(definitions.first?.id, created.id)

        try await engine.deleteDefinition(id: created.id)
        definitions = await engine.currentDefinitions()
        XCTAssertTrue(definitions.isEmpty)

        do {
            try await engine.deleteDefinition(id: created.id)
            XCTFail("Expected unknownDefinition")
        } catch let error as TimerEngineError {
            XCTAssertEqual(error, .unknownDefinition)
        }
    }

    func testDefinitionValidationRejectsInvalidInput() async throws {
        XCTAssertThrowsError(try makeDefinition(name: "   ").validated()) { error in
            XCTAssertEqual(error as? TimerDefinitionError, .emptyName)
        }
        XCTAssertThrowsError(
            try makeDefinition(
                name: String(
                    repeating: "a",
                    count: TimerDefinition.maximumNameLength + 1
                )
            ).validated()
        ) { error in
            XCTAssertEqual(error as? TimerDefinitionError, .nameTooLong)
        }
        XCTAssertThrowsError(try makeDefinition(id: " ").validated()) { error in
            XCTAssertEqual(error as? TimerDefinitionError, .emptyIdentifier)
        }
        let invalidDurations: [TimeInterval] = [
            0, -1, TimerDefinition.maximumDuration + 1, .infinity, .nan,
        ]
        for duration in invalidDurations {
            XCTAssertThrowsError(try makeDefinition(duration: duration).validated()) { error in
                XCTAssertEqual(error as? TimerDefinitionError, .invalidDuration)
            }
        }
        XCTAssertNoThrow(try makeDefinition(duration: 1).validated())
        XCTAssertNoThrow(
            try makeDefinition(duration: TimerDefinition.maximumDuration).validated()
        )

        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        do {
            _ = try await engine.saveDefinition(makeDefinition(duration: 0))
            XCTFail("Expected invalidDuration")
        } catch let error as TimerDefinitionError {
            XCTAssertEqual(error, .invalidDuration)
        }
        let definitions = await engine.currentDefinitions()
        XCTAssertTrue(definitions.isEmpty)
    }

    func testDefinitionsPersistAcrossRestart() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let firstEngine = makeEngine(clock: clock, store: store)
        try await firstEngine.start()

        _ = try await firstEngine.saveDefinition(makeDefinition(id: "one", name: "One"))
        _ = try await firstEngine.saveDefinition(
            makeDefinition(id: "two", name: "Two", duration: 60)
        )

        let firstDefinitions = await firstEngine.currentDefinitions()
        var edited = try XCTUnwrap(firstDefinitions.first { $0.id == "one" })
        edited.duration = 300
        _ = try await firstEngine.saveDefinition(edited)

        let secondEngine = makeEngine(clock: clock, store: store)
        try await secondEngine.start()

        var recovered = await secondEngine.currentDefinitions()
        XCTAssertEqual(Set(recovered.map(\.id)), ["one", "two"])
        XCTAssertEqual(recovered.first { $0.id == "one" }?.duration, 300)
        XCTAssertEqual(recovered.first { $0.id == "two" }?.name, "Two")

        try await secondEngine.deleteDefinition(id: "one")

        let thirdEngine = makeEngine(clock: clock, store: store)
        try await thirdEngine.start()
        recovered = await thirdEngine.currentDefinitions()
        XCTAssertEqual(recovered.map(\.id), ["two"])
    }

    func testMultipleActivationsAndDuplicateEventSuppression() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        _ = try await engine.saveDefinition(makeDefinition())

        let firstEffects = try await engine.activateDefinition(
            id: "preset-1",
            eventID: "activation-1"
        )
        let secondEffects = try await engine.activateDefinition(
            id: "preset-1",
            eventID: "activation-2"
        )

        let first = try XCTUnwrap(startedTimers(in: firstEffects).first)
        let second = try XCTUnwrap(startedTimers(in: secondEffects).first)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.label, "Tea")
        XCTAssertEqual(second.label, "Tea")

        var timers = await engine.currentTimers()
        XCTAssertEqual(timers.filter { $0.state == .running }.count, 2)

        let duplicate = try await engine.activateDefinition(
            id: "preset-1",
            eventID: "activation-1"
        )
        XCTAssertTrue(startedTimers(in: duplicate).isEmpty)
        XCTAssertTrue(duplicate.contains { effect in
            if case .duplicateEventIgnored = effect { return true }
            return false
        })

        timers = await engine.currentTimers()
        XCTAssertEqual(timers.filter { $0.state == .running }.count, 2)

        _ = try await engine.cancel(timerID: first.id)
        timers = await engine.currentTimers()
        XCTAssertEqual(timers.first { $0.id == first.id }?.state, .cancelled)
        XCTAssertEqual(timers.first { $0.id == second.id }?.state, .running)
    }

    func testEditingAndDeletingDefinitionDoesNotChangeRunningTimers() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let original = try await engine.saveDefinition(makeDefinition(duration: 180))
        let activation = try await engine.activateDefinition(
            id: original.id,
            eventID: "activation-1"
        )
        let timer = try XCTUnwrap(startedTimers(in: activation).first)

        var edited = original
        edited.name = "Coffee"
        edited.duration = 240
        edited.actions = [.notify(title: "Coffee", body: "Coffee is done.")]
        _ = try await engine.saveDefinition(edited)
        try await engine.deleteDefinition(id: original.id)

        let definitions = await engine.currentDefinitions()
        XCTAssertTrue(definitions.isEmpty)

        let running = await engine.currentTimers()
        XCTAssertEqual(running.first { $0.id == timer.id }?.label, "Tea")
        XCTAssertEqual(running.first { $0.id == timer.id }?.duration, 180)
        XCTAssertEqual(running.first { $0.id == timer.id }?.state, .running)

        clock.advance(by: 180)
        let expiration = try await engine.advance()
        XCTAssertEqual(firedTimers(in: expiration).map(\.id), [timer.id])

        let actions = actionRequests(in: expiration)
        XCTAssertEqual(actions.count, 1)
        guard case .notify(let title, _)? = actions.first?.action else {
            return XCTFail("Expected the original notification action")
        }
        XCTAssertEqual(title, "Tea")
    }

    func testAdHocTimerDoesNotCreateDefinition() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let engine = makeEngine(clock: clock, store: store)
        try await engine.start()

        let definition = makeDefinition(id: "ad-hoc", name: "Quick timer", duration: 45)
        let effects = try await engine.startAdHocTimer(
            definition,
            eventID: "ad-hoc-1"
        )
        XCTAssertEqual(startedTimers(in: effects).map(\.label), ["Quick timer"])

        let definitions = await engine.currentDefinitions()
        XCTAssertTrue(definitions.isEmpty)

        let duplicate = try await engine.startAdHocTimer(
            definition,
            eventID: "ad-hoc-1"
        )
        XCTAssertTrue(startedTimers(in: duplicate).isEmpty)

        _ = try await engine.startAdHocTimer(definition, eventID: "ad-hoc-2")
        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.filter { $0.state == .running }.count, 2)

        let restarted = makeEngine(clock: clock, store: store)
        try await restarted.start()
        let recoveredDefinitions = await restarted.currentDefinitions()
        XCTAssertTrue(recoveredDefinitions.isEmpty)
        let recoveredTimers = await restarted.currentTimers()
        XCTAssertEqual(recoveredTimers.filter { $0.state == .running }.count, 2)
    }

    func testDisabledDefinitionCannotBeActivated() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        _ = try await engine.saveDefinition(makeDefinition(isEnabled: false))

        do {
            _ = try await engine.activateDefinition(
                id: "preset-1",
                eventID: "activation-1"
            )
            XCTFail("Expected definitionDisabled")
        } catch let error as TimerEngineError {
            XCTAssertEqual(error, .definitionDisabled)
        }

        let timers = await engine.currentTimers()
        XCTAssertTrue(timers.isEmpty)
    }

    func testLegacyV101AStateLoadsAndKeepsProcessedEventIDs() async throws {
        let clock = ManualClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("timers.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyTimer = TimerInstance(
            id: "legacy-timer",
            ruleID: Rule.waterBoiling.id,
            label: "Boiling water",
            duration: 600,
            startedAt: clock.now,
            deadline: clock.now.addingTimeInterval(600),
            actions: [
                .notify(title: "Cooking timer", body: "Your timer is done."),
            ]
        )
        let legacy = LegacyPersistedState(
            timers: [legacyTimer],
            processedEventIDs: ["legacy-event"]
        )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: fileURL, options: .atomic)

        let engine = makeEngine(
            clock: clock,
            store: FileTimerStore(fileURL: fileURL)
        )
        let startEffects = try await engine.start()
        XCTAssertTrue(startEffects.isEmpty)

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.map(\.id), ["legacy-timer"])
        XCTAssertEqual(timers.first?.state, .running)

        let definitions = await engine.currentDefinitions()
        XCTAssertTrue(definitions.isEmpty)

        let duplicate = try await engine.handle(
            Event(
                id: "legacy-event",
                type: EventType.waterBoiling,
                occurredAt: clock.now
            )
        )
        XCTAssertTrue(duplicate.contains { effect in
            if case .duplicateEventIgnored = effect { return true }
            return false
        })
        let timersAfterDuplicate = await engine.currentTimers()
        XCTAssertEqual(timersAfterDuplicate.count, 1)
    }
}

/// Mirrors the v1.01A snapshot shape, which had no `definitions` key.
private struct LegacyPersistedState: Encodable {
    let timers: [TimerInstance]
    let processedEventIDs: [String]
}
