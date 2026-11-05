import XCTest
@testable import EventClockCore

final class AutomationRuleTests: XCTestCase {
    // MARK: - Helpers

    private func makeRule(
        id: String = "rule-1",
        name: String = "Rule",
        eventType: String = "test.event",
        condition: ConditionExpression = .always,
        action: AutomationAction = .startTimer(name: "Rule timer", duration: 30),
        isEnabled: Bool = true,
        cooldown: TimeInterval? = nil
    ) -> AutomationRule {
        AutomationRule(
            id: id,
            name: name,
            trigger: AutomationTrigger(eventType: eventType),
            condition: condition,
            action: action,
            isEnabled: isEnabled,
            cooldown: cooldown
        )
    }

    private func makeEvent(
        id: String,
        type: String = "test.event",
        payload: [String: EventValue] = [:],
        clock: ManualClock
    ) -> Event {
        Event(id: id, type: type, occurredAt: clock.now, payload: payload)
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

    private func outcome(
        ruleID: String,
        in effects: [EngineEffect]
    ) -> AutomationOutcome? {
        automationEvaluations(in: effects)
            .first { $0.ruleID == ruleID }?
            .outcome
    }

    // MARK: - Event matching

    func testManualAndSensorEventMatching() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        try await engine.saveAutomationRule(
            makeRule(
                id: "water-rule",
                eventType: "sensor.water.boiling",
                action: .startTimer(name: "Sensor timer", duration: 30)
            )
        )

        let sensorEvent = makeEvent(
            id: "sensor-1",
            type: "sensor.water.boiling",
            payload: [
                "temperature": .number(100),
                "confirmed": .boolean(true),
            ],
            clock: clock
        )
        let sensorEffects = try await engine.handle(sensorEvent)
        XCTAssertEqual(startedTimers(in: sensorEffects).map(\.label), ["Sensor timer"])
        XCTAssertEqual(
            outcome(ruleID: "water-rule", in: sensorEffects),
            .matched(action: .startTimer(name: "Sensor timer", duration: 30))
        )

        let manualEffects = try await engine.handle(
            makeEvent(id: "manual-1", type: "manual.water.boiling", clock: clock)
        )
        XCTAssertTrue(startedTimers(in: manualEffects).isEmpty)
        XCTAssertTrue(automationEvaluations(in: manualEffects).isEmpty)
    }

    // MARK: - Conditions

    func testNestedANDORNOTConditions() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let condition: ConditionExpression = .and([
            .predicate(.stateFlag(name: "cooking", equals: true)),
            .not(
                .or([
                    .predicate(.stateFlag(name: "paused", equals: true)),
                    .predicate(
                        .payloadValue(
                            key: "boiling",
                            comparison: .equals,
                            value: .boolean(true)
                        )
                    ),
                ])
            ),
        ])
        try await engine.saveAutomationRule(
            makeRule(
                id: "conditional",
                condition: condition,
                action: .setStateFlag(name: "matched", value: true)
            )
        )

        try await engine.setStateFlag(name: "cooking", value: true)
        try await engine.setStateFlag(name: "paused", value: false)

        let matched = try await engine.handle(
            makeEvent(
                id: "e1",
                payload: ["boiling": .boolean(false)],
                clock: clock
            )
        )
        XCTAssertEqual(
            outcome(ruleID: "conditional", in: matched),
            .matched(action: .setStateFlag(name: "matched", value: true))
        )

        try await engine.setStateFlag(name: "cooking", value: false)
        let cookingOff = try await engine.handle(
            makeEvent(
                id: "e2",
                payload: ["boiling": .boolean(false)],
                clock: clock
            )
        )
        XCTAssertEqual(outcome(ruleID: "conditional", in: cookingOff), .conditionNotMet)

        try await engine.setStateFlag(name: "cooking", value: true)
        try await engine.setStateFlag(name: "paused", value: true)
        let paused = try await engine.handle(
            makeEvent(
                id: "e3",
                payload: ["boiling": .boolean(false)],
                clock: clock
            )
        )
        XCTAssertEqual(outcome(ruleID: "conditional", in: paused), .conditionNotMet)

        try await engine.setStateFlag(name: "paused", value: false)
        let boiling = try await engine.handle(
            makeEvent(
                id: "e4",
                payload: ["boiling": .boolean(true)],
                clock: clock
            )
        )
        XCTAssertEqual(outcome(ruleID: "conditional", in: boiling), .conditionNotMet)
    }

    func testTimerStateCondition() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let definition = TimerDefinition(
            id: "preset-1",
            name: "Tea",
            duration: 300,
            actions: [.notify(title: "Tea", body: "Done")]
        )
        _ = try await engine.saveDefinition(definition)
        let activation = try await engine.activateDefinition(
            id: definition.id,
            eventID: "activation-setup"
        )
        let timer = try XCTUnwrap(startedTimers(in: activation).first)

        try await engine.saveAutomationRule(
            makeRule(
                id: "timer-state",
                condition: .predicate(
                    .timerRunning(query: .sourceID(definition.id), isRunning: true)
                ),
                action: .setStateFlag(name: "timerObserved", value: true)
            )
        )

        let runningEffects = try await engine.handle(
            makeEvent(id: "timer-1", clock: clock)
        )
        XCTAssertEqual(
            outcome(ruleID: "timer-state", in: runningEffects),
            .matched(action: .setStateFlag(name: "timerObserved", value: true))
        )

        _ = try await engine.cancel(timerID: timer.id)
        let stoppedEffects = try await engine.handle(
            makeEvent(id: "timer-2", clock: clock)
        )
        XCTAssertEqual(
            outcome(ruleID: "timer-state", in: stoppedEffects),
            .conditionNotMet
        )
    }

    // MARK: - Multiple rules, enabled state, cooldown

    func testMultipleRulesRespondToOneEvent() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        try await engine.saveAutomationRule(
            makeRule(
                id: "flag-rule",
                action: .setStateFlag(name: "alarm", value: true)
            )
        )
        try await engine.saveAutomationRule(
            makeRule(
                id: "timer-rule",
                action: .startTimer(name: "Independent", duration: 45)
            )
        )

        let effects = try await engine.handle(makeEvent(id: "multi-1", clock: clock))
        XCTAssertEqual(automationEvaluations(in: effects).count, 2)
        XCTAssertEqual(startedTimers(in: effects).map(\.label), ["Independent"])
        let flags = await engine.currentStateFlags()
        XCTAssertEqual(flags["alarm"], true)
    }

    func testDisabledRuleDoesNotExecuteAndCanBeReenabled() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let rule = try await engine.saveAutomationRule(
            makeRule(id: "disabled", isEnabled: false)
        )

        let disabledEffects = try await engine.handle(
            makeEvent(id: "disabled-1", clock: clock)
        )
        XCTAssertEqual(outcome(ruleID: rule.id, in: disabledEffects), .disabled)
        XCTAssertTrue(startedTimers(in: disabledEffects).isEmpty)

        var enabled = rule
        enabled.isEnabled = true
        _ = try await engine.saveAutomationRule(enabled)

        let enabledEffects = try await engine.handle(
            makeEvent(id: "disabled-2", clock: clock)
        )
        XCTAssertEqual(
            outcome(ruleID: rule.id, in: enabledEffects),
            .matched(action: .startTimer(name: "Rule timer", duration: 30))
        )
        XCTAssertEqual(startedTimers(in: enabledEffects).count, 1)
    }

    func testCooldownBoundaryAndPersistence() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let rule = makeRule(id: "cooldown", cooldown: 60)
        let firstEngine = makeEngine(clock: clock, store: store)
        try await firstEngine.start()
        _ = try await firstEngine.saveAutomationRule(rule)

        let first = try await firstEngine.handle(makeEvent(id: "c1", clock: clock))
        XCTAssertEqual(
            outcome(ruleID: rule.id, in: first),
            .matched(action: rule.action)
        )

        // Cooldown survives engine restart.
        let secondEngine = makeEngine(clock: clock, store: store)
        try await secondEngine.start()

        let withinCooldown = try await secondEngine.handle(
            makeEvent(id: "c2", clock: clock)
        )
        guard case .cooldown(let remaining)? = outcome(
            ruleID: rule.id,
            in: withinCooldown
        ) else {
            return XCTFail("Expected cooldown")
        }
        XCTAssertEqual(remaining, 60, accuracy: 0.001)
        XCTAssertTrue(startedTimers(in: withinCooldown).isEmpty)

        clock.advance(by: 59)
        let beforeBoundary = try await secondEngine.handle(
            makeEvent(id: "c3", clock: clock)
        )
        guard case .cooldown(let remainingBefore)? = outcome(
            ruleID: rule.id,
            in: beforeBoundary
        ) else {
            return XCTFail("Expected cooldown before boundary")
        }
        XCTAssertEqual(remainingBefore, 1, accuracy: 0.001)

        clock.advance(by: 1)
        let atBoundary = try await secondEngine.handle(
            makeEvent(id: "c4", clock: clock)
        )
        XCTAssertEqual(
            outcome(ruleID: rule.id, in: atBoundary),
            .matched(action: rule.action)
        )
    }

    // MARK: - Deduplication

    func testDuplicateEventsVersusDistinctIdenticalPayloads() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        _ = try await engine.saveAutomationRule(makeRule())

        let payload: [String: EventValue] = [
            "temperature": .number(100),
        ]
        _ = try await engine.handle(
            makeEvent(id: "same", payload: payload, clock: clock)
        )
        let duplicate = try await engine.handle(
            makeEvent(id: "same", payload: payload, clock: clock)
        )
        XCTAssertTrue(startedTimers(in: duplicate).isEmpty)
        XCTAssertTrue(duplicate.contains { effect in
            if case .duplicateEventIgnored = effect { return true }
            return false
        })

        let different = try await engine.handle(
            makeEvent(id: "different", payload: payload, clock: clock)
        )
        XCTAssertEqual(startedTimers(in: different).count, 1)

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.count, 2)
    }

    // MARK: - Actions

    func testRuleActionsExecuteIndependently() async throws {
        let clock = ManualClock()
        let scheduler = RecordingScheduler()
        let engine = makeEngine(clock: clock, scheduler: scheduler)
        try await engine.start()

        let definition = TimerDefinition(
            id: "preset-action",
            name: "Preset timer",
            duration: 45,
            actions: [.notify(title: "Preset timer", body: "Done")]
        )
        _ = try await engine.saveDefinition(definition)

        try await engine.saveAutomationRule(
            makeRule(
                id: "preset-rule",
                action: .startTimerFromDefinition(definitionID: definition.id)
            )
        )
        try await engine.saveAutomationRule(
            makeRule(
                id: "configured-rule",
                action: .startTimer(name: "Configured timer", duration: 25)
            )
        )
        try await engine.saveAutomationRule(
            makeRule(
                id: "notify-rule",
                action: .notify(title: "Automation", body: "Triggered")
            )
        )
        try await engine.saveAutomationRule(
            makeRule(
                id: "flag-rule",
                action: .setStateFlag(name: "automationRan", value: true)
            )
        )

        let effects = try await engine.handle(
            makeEvent(id: "actions-1", clock: clock)
        )

        XCTAssertEqual(automationEvaluations(in: effects).count, 4)
        XCTAssertEqual(
            Set(startedTimers(in: effects).map(\.label)),
            ["Preset timer", "Configured timer"]
        )
        XCTAssertEqual(scheduler.scheduled.count, 2)

        let notifications = effects.compactMap { effect -> (String, String)? in
            if case .automationNotificationRequested(_, let id, let title, _) = effect {
                return (id, title)
            }
            return nil
        }
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(notifications.first?.0, "eventclock.automation.notify-rule.actions-1")
        XCTAssertEqual(notifications.first?.1, "Automation")

        let flags = await engine.currentStateFlags()
        XCTAssertEqual(flags["automationRan"], true)
    }

    func testActionFailureDoesNotSetCooldownOrTimer() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        let rule = try await engine.saveAutomationRule(
            makeRule(
                id: "missing-preset",
                action: .startTimerFromDefinition(definitionID: "missing"),
                cooldown: 60
            )
        )

        let failed = try await engine.handle(
            makeEvent(id: "missing-1", clock: clock)
        )
        guard case .actionFailed? = outcome(ruleID: rule.id, in: failed) else {
            return XCTFail("Expected actionFailed")
        }
        XCTAssertTrue(startedTimers(in: failed).isEmpty)

        // A failed action does not start a cooldown.
        let retry = try await engine.handle(
            makeEvent(id: "missing-2", clock: clock)
        )
        guard case .actionFailed? = outcome(ruleID: rule.id, in: retry) else {
            return XCTFail("Expected actionFailed on retry")
        }
    }

    func testRulesEvaluateAgainstOneConsistentSnapshot() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        try await engine.saveAutomationRule(
            makeRule(
                id: "sets-ready",
                action: .setStateFlag(name: "ready", value: true)
            )
        )
        try await engine.saveAutomationRule(
            makeRule(
                id: "needs-ready",
                condition: .predicate(.stateFlag(name: "ready", equals: true)),
                action: .startTimer(name: "After ready", duration: 30)
            )
        )

        let first = try await engine.handle(makeEvent(id: "snapshot-1", clock: clock))
        XCTAssertEqual(outcome(ruleID: "sets-ready", in: first), .matched(action: .setStateFlag(name: "ready", value: true)))
        XCTAssertEqual(outcome(ruleID: "needs-ready", in: first), .conditionNotMet)
        XCTAssertTrue(startedTimers(in: first).isEmpty)

        // The flag persisted from the previous event, so the next event sees it.
        let second = try await engine.handle(makeEvent(id: "snapshot-2", clock: clock))
        XCTAssertEqual(
            outcome(ruleID: "needs-ready", in: second),
            .matched(action: .startTimer(name: "After ready", duration: 30))
        )
        XCTAssertEqual(startedTimers(in: second).map(\.label), ["After ready"])
    }

    func testDeletingAndEditingRuleDoesNotChangeRunningTimers() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()

        let rule = try await engine.saveAutomationRule(
            makeRule(
                id: "running-rule",
                action: .startTimer(name: "Started by rule", duration: 30)
            )
        )
        let effects = try await engine.handle(
            makeEvent(id: "rule-timer-1", clock: clock)
        )
        let timer = try XCTUnwrap(startedTimers(in: effects).first)

        var edited = rule
        edited.name = "Edited rule"
        edited.action = .startTimer(name: "Different", duration: 90)
        _ = try await engine.saveAutomationRule(edited)
        try await engine.deleteAutomationRule(id: rule.id)

        let timersAfterDelete = await engine.currentTimers()
        XCTAssertEqual(timersAfterDelete.first { $0.id == timer.id }?.label, "Started by rule")
        XCTAssertEqual(timersAfterDelete.first { $0.id == timer.id }?.duration, 30)
        XCTAssertEqual(timersAfterDelete.first { $0.id == timer.id }?.state, .running)

        clock.advance(by: 30)
        let expiration = try await engine.advance()
        XCTAssertEqual(firedTimers(in: expiration).map(\.id), [timer.id])
    }

    // MARK: - Truth tables

    private func assertRule(
        _ ruleID: String,
        matched: Bool,
        in effects: [EngineEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = outcome(ruleID: ruleID, in: effects)
        if matched {
            if case .matched? = result { return }
            XCTFail("Expected matched, got \(String(describing: result))", file: file, line: line)
        } else {
            XCTAssertEqual(result, .conditionNotMet, file: file, line: line)
        }
    }

    func testANDTruthTable() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        let action = AutomationAction.notify(title: "Matched", body: "")
        try await engine.saveAutomationRule(
            makeRule(
                id: "and",
                condition: .and([
                    .predicate(.stateFlag(name: "a", equals: true)),
                    .predicate(.stateFlag(name: "b", equals: true)),
                ]),
                action: action
            )
        )

        let table: [(Bool, Bool, Bool)] = [
            (true, true, true),
            (true, false, false),
            (false, true, false),
            (false, false, false),
        ]
        for (index, row) in table.enumerated() {
            try await engine.setStateFlag(name: "a", value: row.0)
            try await engine.setStateFlag(name: "b", value: row.1)
            let effects = try await engine.handle(
                makeEvent(id: "and-\(index)", clock: clock)
            )
            assertRule("and", matched: row.2, in: effects)
        }
    }

    func testORTruthTable() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        try await engine.saveAutomationRule(
            makeRule(
                id: "or",
                condition: .or([
                    .predicate(.stateFlag(name: "a", equals: true)),
                    .predicate(.stateFlag(name: "b", equals: true)),
                ]),
                action: .notify(title: "Matched", body: "")
            )
        )

        let table: [(Bool, Bool, Bool)] = [
            (true, true, true),
            (true, false, true),
            (false, true, true),
            (false, false, false),
        ]
        for (index, row) in table.enumerated() {
            try await engine.setStateFlag(name: "a", value: row.0)
            try await engine.setStateFlag(name: "b", value: row.1)
            let effects = try await engine.handle(
                makeEvent(id: "or-\(index)", clock: clock)
            )
            assertRule("or", matched: row.2, in: effects)
        }
    }

    func testNOTTruthTable() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        try await engine.saveAutomationRule(
            makeRule(
                id: "not",
                condition: .not(.predicate(.stateFlag(name: "a", equals: true))),
                action: .notify(title: "Matched", body: "")
            )
        )

        for (index, value) in [true, false].enumerated() {
            try await engine.setStateFlag(name: "a", value: value)
            let effects = try await engine.handle(
                makeEvent(id: "not-\(index)", clock: clock)
            )
            assertRule("not", matched: !value, in: effects)
        }
    }

    func testNestedLogicalTruthTable() async throws {
        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        try await engine.saveAutomationRule(
            makeRule(
                id: "nested",
                condition: .or([
                    .and([
                        .predicate(.stateFlag(name: "a", equals: true)),
                        .predicate(.stateFlag(name: "b", equals: true)),
                    ]),
                    .not(.predicate(.stateFlag(name: "c", equals: true))),
                ]),
                action: .notify(title: "Matched", body: "")
            )
        )

        var index = 0
        for a in [true, false] {
            for b in [true, false] {
                for c in [true, false] {
                    try await engine.setStateFlag(name: "a", value: a)
                    try await engine.setStateFlag(name: "b", value: b)
                    try await engine.setStateFlag(name: "c", value: c)
                    let effects = try await engine.handle(
                        makeEvent(id: "nested-\(index)", clock: clock)
                    )
                    let expected = (a && b) || !c
                    assertRule("nested", matched: expected, in: effects)
                    index += 1
                }
            }
        }
    }

    // MARK: - Time windows and time zones

    func testTimeOfDayWindowAndTimeZoneBoundaries() async throws {
        let newYork = calendar(timeZone: "America/New_York")
        let tokyo = calendar(timeZone: "Asia/Tokyo")
        let wall = date(2026, 1, 15, 23, 30, in: newYork) // 04:30 UTC Jan 16
        let condition: ConditionExpression = .predicate(
            .timeOfDay(startMinute: 22 * 60, endMinute: 2 * 60)
        )
        let rule = makeRule(
            id: "night-window",
            condition: condition,
            action: .setStateFlag(name: "windowMatched", value: true)
        )

        let nyClock = ManualClock(wall: wall)
        let nyEngine = makeEngine(clock: nyClock, calendar: newYork)
        try await nyEngine.start()
        _ = try await nyEngine.saveAutomationRule(rule)

        let nyEvent = try await nyEngine.handle(
            makeEvent(id: "ny-1", clock: nyClock)
        )
        XCTAssertEqual(
            outcome(ruleID: rule.id, in: nyEvent),
            .matched(action: .setStateFlag(name: "windowMatched", value: true))
        )

        let tokyoClock = ManualClock(wall: wall)
        let tokyoEngine = makeEngine(clock: tokyoClock, calendar: tokyo)
        try await tokyoEngine.start()
        _ = try await tokyoEngine.saveAutomationRule(rule)

        let tokyoEvent = try await tokyoEngine.handle(
            makeEvent(id: "tokyo-1", clock: tokyoClock)
        )
        XCTAssertEqual(
            outcome(ruleID: rule.id, in: tokyoEvent),
            .conditionNotMet
        )

        let midday = ManualClock(
            wall: date(2026, 1, 15, 12, 0, in: newYork)
        )
        let middayEngine = makeEngine(clock: midday, calendar: newYork)
        try await middayEngine.start()
        _ = try await middayEngine.saveAutomationRule(rule)
        let middayEvent = try await middayEngine.handle(
            makeEvent(id: "midday-1", clock: midday)
        )
        XCTAssertEqual(
            outcome(ruleID: rule.id, in: middayEvent),
            .conditionNotMet
        )
    }

    // MARK: - Validation

    func testInvalidRuleConfigurations() async throws {
        let invalidRules: [AutomationRule] = [
            makeRule(id: " "),
            makeRule(name: "  "),
            makeRule(eventType: "   "),
            makeRule(condition: .and([])),
            makeRule(
                condition: .predicate(
                    .timeOfDay(startMinute: 1_500, endMinute: 10)
                )
            ),
            makeRule(
                condition: .predicate(
                    .timeOfDay(startMinute: 600, endMinute: 600)
                )
            ),
            makeRule(
                condition: .predicate(
                    .payloadValue(
                        key: "name",
                        comparison: .lessThan,
                        value: .string("abc")
                    )
                )
            ),
            makeRule(
                condition: .predicate(
                    .payloadValue(
                        key: "score",
                        comparison: .equals,
                        value: .number(.infinity)
                    )
                )
            ),
            makeRule(cooldown: -1),
            makeRule(cooldown: AutomationRule.maximumCooldown + 1),
            makeRule(action: .startTimer(name: " ", duration: 30)),
            makeRule(action: .startTimer(name: "Bad", duration: 0)),
            makeRule(action: .notify(title: " ", body: "Body")),
            makeRule(action: .setStateFlag(name: " ", value: true)),
        ]

        for rule in invalidRules {
            XCTAssertThrowsError(try rule.validated(), "Should reject \(rule)")
        }

        var deep: ConditionExpression = .always
        for _ in 0..<10 {
            deep = .not(deep)
        }
        XCTAssertThrowsError(try makeRule(condition: deep).validated()) { error in
            XCTAssertEqual(error as? AutomationRuleError, .conditionTooDeep)
        }

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ComparisonOperator.self,
                from: Data("\"contains\"".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? AutomationRuleError,
                .unsupportedOperator("contains")
            )
        }

        let clock = ManualClock()
        let engine = makeEngine(clock: clock)
        try await engine.start()
        do {
            _ = try await engine.saveAutomationRule(makeRule(name: ""))
            XCTFail("Expected validation failure")
        } catch let error as AutomationRuleError {
            XCTAssertEqual(error, .emptyName)
        }
        let rules = await engine.currentAutomationRules()
        XCTAssertTrue(rules.isEmpty)
    }

    // MARK: - Persistence and migration

    func testRulesFlagsAndRemindersPersistAcrossRestart() async throws {
        let clock = ManualClock()
        let store = InMemoryTimerStore()
        let firstEngine = makeEngine(clock: clock, store: store)
        try await firstEngine.start()

        _ = try await firstEngine.saveAutomationRule(makeRule(id: "persisted"))
        try await firstEngine.setStateFlag(name: "cooking", value: true)
        _ = try await firstEngine.saveRecurringReminder(
            RecurringReminder(
                id: "reminder-1",
                title: "Daily check",
                body: "Check timers",
                schedule: .daily(hour: 9, minute: 30)
            )
        )

        let secondEngine = makeEngine(clock: clock, store: store)
        try await secondEngine.start()

        let rules = await secondEngine.currentAutomationRules()
        XCTAssertEqual(rules.map(\.id), ["persisted"])
        let flags = await secondEngine.currentStateFlags()
        XCTAssertEqual(flags["cooking"], true)
        let reminders = await secondEngine.currentRecurringReminders()
        XCTAssertEqual(reminders.map(\.id), ["reminder-1"])
    }

    func testV101BStateLoadsAndTimersStillWork() async throws {
        let clock = ManualClock()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("timers.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let timer = TimerInstance(
            id: "v101b-timer",
            ruleID: Rule.waterBoiling.id,
            label: "Boiling water",
            duration: 600,
            startedAt: clock.now,
            deadline: clock.now.addingTimeInterval(600),
            actions: [.notify(title: "Cooking timer", body: "Done")]
        )
        let definition = TimerDefinition(
            id: "v101b-preset",
            name: "Tea",
            duration: 120,
            actions: [.notify(title: "Tea", body: "Done")]
        )
        let legacy = LegacyV101BState(
            timers: [timer],
            processedEventIDs: ["legacy-event"],
            definitions: [definition]
        )

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(legacy).write(to: fileURL, options: .atomic)

        let engine = makeEngine(
            clock: clock,
            store: FileTimerStore(fileURL: fileURL)
        )
        try await engine.start()

        let timers = await engine.currentTimers()
        XCTAssertEqual(timers.map(\.id), ["v101b-timer"])
        XCTAssertNil(timers.first?.kind)
        let definitions = await engine.currentDefinitions()
        XCTAssertEqual(definitions.map(\.id), ["v101b-preset"])
        let rules = await engine.currentAutomationRules()
        XCTAssertTrue(rules.isEmpty)

        clock.advance(by: 600)
        let expiration = try await engine.advance()
        XCTAssertEqual(firedTimers(in: expiration).map(\.id), ["v101b-timer"])

        _ = try await engine.saveAutomationRule(makeRule(id: "post-migration"))
        let migratedRules = await engine.currentAutomationRules()
        XCTAssertEqual(migratedRules.map(\.id), ["post-migration"])
    }

    // MARK: - Recurrence

    func testDailyAndWeeklyRecurrenceCalculations() throws {
        let newYork = calendar(timeZone: "America/New_York")
        let daily = RecurringReminder(
            id: "daily",
            title: "Daily",
            body: "",
            schedule: .daily(hour: 9, minute: 0)
        )

        let beforeDaily = date(2026, 1, 15, 8, 0, in: newYork)
        let sameDay = try XCTUnwrap(
            RecurrenceCalculator.nextOccurrence(
                for: daily,
                after: beforeDaily,
                calendar: newYork
            )
        )
        XCTAssertEqual(
            newYork.dateComponents([.day, .hour, .minute], from: sameDay).day,
            15
        )
        XCTAssertEqual(
            newYork.dateComponents([.hour, .minute], from: sameDay).hour,
            9
        )

        let afterDaily = date(2026, 1, 15, 9, 30, in: newYork)
        let nextDay = try XCTUnwrap(
            RecurrenceCalculator.nextOccurrence(
                for: daily,
                after: afterDaily,
                calendar: newYork
            )
        )
        XCTAssertEqual(
            newYork.dateComponents([.day], from: nextDay).day,
            16
        )

        let weekly = RecurringReminder(
            id: "weekly",
            title: "Weekly",
            body: "",
            schedule: .weekly(weekday: .monday, hour: 9, minute: 0)
        )
        let wednesday = date(2026, 1, 14, 12, 0, in: newYork)
        let nextMonday = try XCTUnwrap(
            RecurrenceCalculator.nextOccurrence(
                for: weekly,
                after: wednesday,
                calendar: newYork
            )
        )
        let components = newYork.dateComponents(
            [.weekday, .day, .hour, .minute],
            from: nextMonday
        )
        XCTAssertEqual(components.weekday, Weekday.monday.rawValue)
        XCTAssertEqual(components.day, 19)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
    }

    func testRecurrenceAcrossDaylightSavingChange() throws {
        let newYork = calendar(timeZone: "America/New_York")
        let daily = RecurringReminder(
            id: "dst",
            title: "DST",
            body: "",
            schedule: .daily(hour: 9, minute: 0)
        )

        // US DST begins at 02:00 on 2026-03-08.
        let before = date(2026, 3, 7, 10, 0, in: newYork)
        let next = try XCTUnwrap(
            RecurrenceCalculator.nextOccurrence(
                for: daily,
                after: before,
                calendar: newYork
            )
        )
        let components = newYork.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: next
        )
        XCTAssertEqual(components.day, 8)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(newYork.timeZone.secondsFromGMT(for: next), -4 * 3_600)
    }
}

/// Mirrors the v1.01B snapshot shape, which has no automation keys.
private struct LegacyV101BState: Encodable {
    let timers: [TimerInstance]
    let processedEventIDs: [String]
    let definitions: [TimerDefinition]
}
