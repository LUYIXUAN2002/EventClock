import Foundation

/// Deterministic, UI-independent event/timer engine.
///
/// All mutations are serialized by the actor. Time comes only from `Clock`,
/// and persistence only through `TimerStore`, so the engine can be tested
/// without sleeping or touching system frameworks.
public actor TimerEngine {
    /// Wall-clock drift beyond this threshold is treated as a clock change.
    private static let clockChangeTolerance: TimeInterval = 1.0

    private let store: any TimerStore
    private let clock: any Clock
    private let scheduler: any WakeScheduler
    private let rules: [Rule]
    private let idGenerator: @Sendable () -> String
    private let processedEventLimit: Int
    private let calendar: Calendar

    private var timers: [String: TimerInstance] = [:]
    private var definitions: [TimerDefinition] = []
    private var automationRules: [AutomationRule] = []
    private var stateFlags: [String: Bool] = [:]
    private var ruleLastTriggeredAt: [String: Date] = [:]
    private var recurringReminders: [RecurringReminder] = []
    /// Absolute monotonic deadlines. Never persisted: monotonic time has no
    /// meaning across process or device restarts.
    private var monotonicDeadlines: [String: TimeInterval] = [:]
    private var processedEventIDs: [String] = []
    private var processedEventSet: Set<String> = []
    private var isStarted = false
    private var lastWallClock = Date.distantPast
    private var lastMonotonic: TimeInterval = 0

    public init(
        store: any TimerStore,
        clock: any Clock,
        rules: [Rule],
        scheduler: any WakeScheduler = NoopWakeScheduler(),
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString },
        processedEventLimit: Int = 256,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.store = store
        self.clock = clock
        self.rules = rules
        self.scheduler = scheduler
        self.idGenerator = idGenerator
        self.processedEventLimit = max(1, processedEventLimit)
        self.calendar = calendar
    }

    // MARK: - Lifecycle

    /// Loads persisted state and recovers timers. Idempotent.
    ///
    /// Recovery uses the persisted wall-clock deadline, because monotonic
    /// anchors do not survive a process restart or reboot. A timer whose
    /// deadline passed while the engine was not running is fired once here.
    @discardableResult
    public func start() throws -> [EngineEffect] {
        guard !isStarted else { return [] }

        let state = try store.load()
        for timer in state.timers {
            timers[timer.id] = timer
        }
        definitions = state.definitions
        automationRules = state.automationRules
        stateFlags = state.stateFlags
        ruleLastTriggeredAt = state.ruleLastTriggeredAt
        recurringReminders = state.recurringReminders
        for id in state.processedEventIDs where processedEventSet.insert(id).inserted {
            processedEventIDs.append(id)
        }
        trimProcessedEventIDs()

        let now = clock.now
        let monotonic = clock.monotonicTime
        lastWallClock = now
        lastMonotonic = monotonic
        isStarted = true

        var effects: [EngineEffect] = []
        var changed = false
        var scheduleRequests: [(id: String, deadline: Date)] = []

        for id in timers.keys.sorted() {
            guard var timer = timers[id], timer.state == .running else { continue }

            let remaining = timer.deadline.timeIntervalSince(now)
            if remaining <= 0 {
                timer.state = .fired
                timer.firedAt = now
                timers[id] = timer
                effects.append(.timerExpired(timer))
                effects.append(contentsOf: actionEffects(for: timer))
                changed = true
            } else {
                monotonicDeadlines[id] = monotonic + remaining
                scheduleRequests.append((id, timer.deadline))
            }
        }

        if changed {
            try persist()
        }
        for request in scheduleRequests {
            scheduler.schedule(timerID: request.id, at: request.deadline)
        }
        return effects
    }

    // MARK: - Input

    /// Processes one event. Events with an already-seen `id` are ignored
    /// without being persisted again or starting another timer.
    ///
    /// Automation conditions are evaluated against one snapshot taken before
    /// any action runs, so actions from one rule cannot change how another
    /// rule sees the same event.
    public func handle(_ event: Event) throws -> [EngineEffect] {
        try requireStarted()
        var effects = try reconcile()

        guard !processedEventSet.contains(event.id) else {
            effects.append(.duplicateEventIgnored(eventID: event.id))
            return effects
        }

        remember(event.id)

        let now = clock.now
        let monotonic = clock.monotonicTime
        let snapshotFlags = stateFlags
        let snapshotTimers = timers.values.filter { $0.state == .running }

        var matchedRules: [AutomationRule] = []
        for rule in automationRules where rule.trigger.eventType == event.type {
            if !rule.isEnabled {
                effects.append(
                    .automationEvaluated(
                        evaluation(for: rule, event: event, outcome: .disabled)
                    )
                )
                continue
            }

            if let cooldown = rule.cooldown, cooldown > 0,
               let lastTriggered = ruleLastTriggeredAt[rule.id] {
                let elapsed = now.timeIntervalSince(lastTriggered)
                if elapsed < cooldown {
                    effects.append(
                        .automationEvaluated(
                            evaluation(
                                for: rule,
                                event: event,
                                outcome: .cooldown(remaining: max(0, cooldown - elapsed))
                            )
                        )
                    )
                    continue
                }
            }

            let conditionMet = RuleConditionEvaluator.matches(
                rule.condition,
                event: event,
                stateFlags: snapshotFlags,
                runningTimers: snapshotTimers,
                now: now,
                calendar: calendar
            )
            if !conditionMet {
                effects.append(
                    .automationEvaluated(
                        evaluation(for: rule, event: event, outcome: .conditionNotMet)
                    )
                )
                continue
            }

            matchedRules.append(rule)
        }

        var scheduleRequests: [(id: String, deadline: Date)] = []

        for rule in rules where rule.eventType == event.type {
            let timer = createTimer(
                label: rule.label,
                duration: rule.duration,
                actions: rule.actions,
                sourceID: rule.id,
                now: now,
                monotonic: monotonic
            )
            effects.append(.timerStarted(timer))
            scheduleRequests.append((timer.id, timer.deadline))
        }

        for rule in matchedRules {
            let result = perform(
                action: rule.action,
                rule: rule,
                event: event,
                now: now,
                monotonic: monotonic,
                scheduleRequests: &scheduleRequests,
                effects: &effects
            )

            switch result {
            case .success:
                ruleLastTriggeredAt[rule.id] = now
                effects.append(
                    .automationEvaluated(
                        evaluation(
                            for: rule,
                            event: event,
                            outcome: .matched(action: rule.action)
                        )
                    )
                )
            case .failure(let reason):
                effects.append(
                    .automationEvaluated(
                        evaluation(
                            for: rule,
                            event: event,
                            outcome: .actionFailed(reason: reason)
                        )
                    )
                )
            }
        }

        // Persist even when no rule matched: the event has been seen and must
        // stay deduplicated across a restart.
        try persist()
        for request in scheduleRequests {
            scheduler.schedule(timerID: request.id, at: request.deadline)
        }
        return effects
    }

    // MARK: - Reusable definitions

    public func currentDefinitions() -> [TimerDefinition] {
        definitions
    }

    /// Creates or updates a reusable definition. Existing timers are untouched
    /// because they hold snapshots of the definition at activation time.
    @discardableResult
    public func saveDefinition(_ definition: TimerDefinition) throws -> TimerDefinition {
        try requireStarted()
        let validated = try definition.validated()

        if let index = definitions.firstIndex(where: { $0.id == validated.id }) {
            definitions[index] = validated
        } else {
            definitions.append(validated)
        }
        try persist()
        return validated
    }

    public func deleteDefinition(id: String) throws {
        try requireStarted()
        guard let index = definitions.firstIndex(where: { $0.id == id }) else {
            throw TimerEngineError.unknownDefinition
        }
        definitions.remove(at: index)
        try persist()
    }

    /// Manual activation of a persisted definition.
    ///
    /// Each call with a new `eventID` creates a new timer instance. A repeated
    /// `eventID` is ignored by the same ledger used for external events.
    @discardableResult
    public func activateDefinition(
        id: String,
        eventID: String
    ) throws -> [EngineEffect] {
        try requireStarted()
        var effects = try reconcile()

        guard !processedEventSet.contains(eventID) else {
            effects.append(.duplicateEventIgnored(eventID: eventID))
            return effects
        }
        guard let definition = definitions.first(where: { $0.id == id }) else {
            throw TimerEngineError.unknownDefinition
        }

        try activate(definition: definition, eventID: eventID, effects: &effects)
        return effects
    }

    /// Starts a timer from a definition that is not saved as a preset.
    @discardableResult
    public func startAdHocTimer(
        _ definition: TimerDefinition,
        eventID: String
    ) throws -> [EngineEffect] {
        try requireStarted()
        var effects = try reconcile()

        guard !processedEventSet.contains(eventID) else {
            effects.append(.duplicateEventIgnored(eventID: eventID))
            return effects
        }

        try activate(definition: definition, eventID: eventID, effects: &effects)
        return effects
    }

    private func activate(
        definition: TimerDefinition,
        eventID: String,
        effects: inout [EngineEffect]
    ) throws {
        let validated = try definition.validated()
        guard validated.isEnabled else {
            throw TimerEngineError.definitionDisabled
        }

        remember(eventID)

        let now = clock.now
        let monotonic = clock.monotonicTime
        let timer = createTimer(
            label: validated.name,
            duration: validated.duration,
            actions: validated.actions,
            sourceID: validated.id,
            now: now,
            monotonic: monotonic
        )
        effects.append(.timerStarted(timer))

        try persist()
        scheduler.schedule(timerID: timer.id, at: timer.deadline)
    }

    // MARK: - Automation rules and state flags

    public func currentAutomationRules() -> [AutomationRule] {
        automationRules
    }

    @discardableResult
    public func saveAutomationRule(_ rule: AutomationRule) throws -> AutomationRule {
        try requireStarted()
        let validated = try rule.validated()

        if let index = automationRules.firstIndex(where: { $0.id == validated.id }) {
            automationRules[index] = validated
        } else {
            automationRules.append(validated)
        }
        try persist()
        return validated
    }

    public func deleteAutomationRule(id: String) throws {
        try requireStarted()
        guard let index = automationRules.firstIndex(where: { $0.id == id }) else {
            throw TimerEngineError.unknownAutomationRule
        }
        automationRules.remove(at: index)
        ruleLastTriggeredAt[id] = nil
        try persist()
    }

    public func currentStateFlags() -> [String: Bool] {
        stateFlags
    }

    public func setStateFlag(name: String, value: Bool) throws {
        try requireStarted()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else {
            throw TimerEngineError.invalidStateFlag
        }
        stateFlags[trimmed] = value
        try persist()
    }

    // MARK: - Recurring reminders

    public func currentRecurringReminders() -> [RecurringReminder] {
        recurringReminders
    }

    @discardableResult
    public func saveRecurringReminder(
        _ reminder: RecurringReminder
    ) throws -> RecurringReminder {
        try requireStarted()
        let validated = try reminder.validated()

        if let index = recurringReminders.firstIndex(where: { $0.id == validated.id }) {
            recurringReminders[index] = validated
        } else {
            recurringReminders.append(validated)
        }
        try persist()
        return validated
    }

    public func deleteRecurringReminder(id: String) throws {
        try requireStarted()
        guard let index = recurringReminders.firstIndex(where: { $0.id == id }) else {
            throw TimerEngineError.unknownReminder
        }
        recurringReminders.remove(at: index)
        try persist()
    }

    // MARK: - Recovery timers

    /// Creates a user-supplied absolute reset timer.
    @discardableResult
    public func startRecoveryTimer(
        serviceName: String,
        deadline: Date,
        eventID: String
    ) throws -> [EngineEffect] {
        try requireStarted()
        var effects = try reconcile()

        guard !processedEventSet.contains(eventID) else {
            effects.append(.duplicateEventIgnored(eventID: eventID))
            return effects
        }

        let name = try validatedServiceName(serviceName)
        let now = clock.now
        guard deadline > now else {
            throw RecoveryTimerError.deadlineNotFuture
        }

        remember(eventID)
        let timer = createTimer(
            label: name,
            duration: deadline.timeIntervalSince(now),
            actions: [.notify(title: name, body: "Expected reset time reached.")],
            sourceID: "recovery.absolute",
            now: now,
            monotonic: clock.monotonicTime,
            kind: .recovery,
            explicitDeadline: deadline
        )
        effects.append(.timerStarted(timer))

        try persist()
        scheduler.schedule(timerID: timer.id, at: timer.deadline)
        return effects
    }

    /// Updates a running recovery timer's name and absolute deadline.
    @discardableResult
    public func rescheduleRecoveryTimer(
        id: String,
        serviceName: String,
        deadline: Date
    ) throws -> [EngineEffect] {
        try requireStarted()
        var effects = try reconcile()

        let name = try validatedServiceName(serviceName)
        let now = clock.now
        guard deadline > now else {
            throw RecoveryTimerError.deadlineNotFuture
        }
        guard var timer = timers[id], timer.kind == .recovery else {
            throw TimerEngineError.unknownRecoveryTimer
        }
        guard timer.state == .running else {
            throw TimerEngineError.recoveryTimerNotRunning
        }

        timer.label = name
        timer.deadline = deadline
        timer.duration = deadline.timeIntervalSince(timer.startedAt)
        timer.actions = [.notify(title: name, body: "Expected reset time reached.")]
        timers[id] = timer
        monotonicDeadlines[id] = clock.monotonicTime + deadline.timeIntervalSince(now)

        try persist()
        scheduler.schedule(timerID: id, at: deadline)
        effects.append(.timerUpdated(timer))
        return effects
    }

    /// Records an event and starts a timer measured from its timestamp.
    @discardableResult
    public func recordEventAndStartTimer(
        name: String,
        duration: TimeInterval,
        event: Event
    ) throws -> [EngineEffect] {
        try requireStarted()
        var effects = try reconcile()

        guard !processedEventSet.contains(event.id) else {
            effects.append(.duplicateEventIgnored(eventID: event.id))
            return effects
        }

        let trimmedName = try validatedServiceName(name)
        guard duration.isFinite,
              duration >= TimerDefinition.minimumDuration,
              duration <= TimerDefinition.maximumDuration else {
            throw RecoveryTimerError.invalidDuration
        }

        let now = clock.now
        let deadline = event.occurredAt.addingTimeInterval(duration)
        guard deadline > now else {
            throw RecoveryTimerError.eventDeadlineNotFuture
        }

        remember(event.id)
        let timer = createTimer(
            label: trimmedName,
            duration: duration,
            actions: [.notify(title: trimmedName, body: "Your timer is done.")],
            sourceID: "recovery.relative",
            now: now,
            monotonic: clock.monotonicTime,
            kind: .relativeEvent,
            startedAt: event.occurredAt,
            explicitDeadline: deadline
        )
        effects.append(.timerStarted(timer))

        try persist()
        scheduler.schedule(timerID: timer.id, at: timer.deadline)
        return effects
    }

    private func validatedServiceName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RecoveryTimerError.emptyServiceName
        }
        guard trimmed.count <= 80 else {
            throw RecoveryTimerError.serviceNameTooLong
        }
        return trimmed
    }

    /// Settles elapsed time and wall-clock changes. Hosts should call this on
    /// foreground, wake-up, and before reading state.
    @discardableResult
    public func advance() throws -> [EngineEffect] {
        try requireStarted()
        return try reconcile()
    }

    /// Cancels a running timer. Terminal timers are left untouched.
    @discardableResult
    public func cancel(timerID: String) throws -> [EngineEffect] {
        try requireStarted()
        var effects = try reconcile()

        guard var timer = timers[timerID], timer.state == .running else {
            return effects
        }

        timer.state = .cancelled
        timer.cancelledAt = clock.now
        timers[timerID] = timer
        monotonicDeadlines[timerID] = nil
        try persist()
        scheduler.cancel(timerID: timerID)
        effects.append(.timerCancelled(timer))
        return effects
    }

    // MARK: - Observation

    public func currentTimers() -> [TimerInstance] {
        timers.values.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.id < $1.id
            }
            return $0.startedAt < $1.startedAt
        }
    }

    // MARK: - Reconciliation

    private func reconcile() throws -> [EngineEffect] {
        let now = clock.now
        let monotonic = clock.monotonicTime
        let wallDelta = now.timeIntervalSince(lastWallClock)
        let monotonicDelta = monotonic - lastMonotonic
        let wallClockChanged = abs(wallDelta - monotonicDelta) > Self.clockChangeTolerance

        lastWallClock = now
        lastMonotonic = monotonic

        var effects: [EngineEffect] = []
        var changed = false
        var scheduleRequests: [(id: String, deadline: Date)] = []
        var cancelRequests: [String] = []

        for id in timers.keys.sorted() {
            guard var timer = timers[id], timer.state == .running else { continue }

            if monotonicDeadlines[id] == nil {
                // Defensive: a running timer should always have an anchor.
                monotonicDeadlines[id] = monotonic + timer.deadline.timeIntervalSince(now)
            }

            if wallClockChanged {
                // Re-anchor the persisted wall deadline to the new wall clock
                // while preserving the monotonic remaining duration.
                let remaining = max(0, (monotonicDeadlines[id] ?? monotonic) - monotonic)
                timer.deadline = now.addingTimeInterval(remaining)
                monotonicDeadlines[id] = monotonic + remaining
                timers[id] = timer
                changed = true
                scheduleRequests.append((id, timer.deadline))
            }

            if let deadline = monotonicDeadlines[id], deadline <= monotonic {
                timer.state = .fired
                timer.firedAt = now
                timers[id] = timer
                monotonicDeadlines[id] = nil
                effects.append(.timerExpired(timer))
                effects.append(contentsOf: actionEffects(for: timer))
                cancelRequests.append(id)
                changed = true
            }
        }

        if changed {
            try persist()
        }
        for request in scheduleRequests {
            scheduler.schedule(timerID: request.id, at: request.deadline)
        }
        for id in cancelRequests {
            scheduler.cancel(timerID: id)
        }
        return effects
    }

    // MARK: - Helpers

    private enum AutomationActionResult {
        case success
        case failure(String)
    }

    private func createTimer(
        label: String,
        duration: TimeInterval,
        actions: [Action],
        sourceID: String,
        now: Date,
        monotonic: TimeInterval,
        kind: TimerKind? = nil,
        startedAt: Date? = nil,
        explicitDeadline: Date? = nil
    ) -> TimerInstance {
        let timerID = idGenerator()
        let start = startedAt ?? now
        let deadline = explicitDeadline ?? start.addingTimeInterval(duration)
        let timer = TimerInstance(
            id: timerID,
            ruleID: sourceID,
            label: label,
            duration: duration,
            startedAt: start,
            deadline: deadline,
            actions: actions,
            kind: kind
        )
        timers[timerID] = timer
        monotonicDeadlines[timerID] = monotonic + deadline.timeIntervalSince(now)
        return timer
    }

    private func evaluation(
        for rule: AutomationRule,
        event: Event,
        outcome: AutomationOutcome
    ) -> AutomationEvaluation {
        AutomationEvaluation(
            ruleID: rule.id,
            ruleName: rule.name,
            eventID: event.id,
            outcome: outcome
        )
    }

    private func perform(
        action: AutomationAction,
        rule: AutomationRule,
        event: Event,
        now: Date,
        monotonic: TimeInterval,
        scheduleRequests: inout [(id: String, deadline: Date)],
        effects: inout [EngineEffect]
    ) -> AutomationActionResult {
        switch action {
        case .startTimerFromDefinition(let definitionID):
            guard let definition = definitions.first(where: { $0.id == definitionID }) else {
                return .failure("Timer preset was not found.")
            }
            guard definition.isEnabled else {
                return .failure("Timer preset is disabled.")
            }
            let timer = createTimer(
                label: definition.name,
                duration: definition.duration,
                actions: definition.actions,
                sourceID: definition.id,
                now: now,
                monotonic: monotonic
            )
            effects.append(.timerStarted(timer))
            scheduleRequests.append((timer.id, timer.deadline))
            return .success

        case .startTimer(let name, let duration):
            let timer = createTimer(
                label: name,
                duration: duration,
                actions: [.notify(title: name, body: "Your timer is done.")],
                sourceID: rule.id,
                now: now,
                monotonic: monotonic
            )
            effects.append(.timerStarted(timer))
            scheduleRequests.append((timer.id, timer.deadline))
            return .success

        case .notify(let title, let body):
            effects.append(
                .automationNotificationRequested(
                    ruleID: rule.id,
                    notificationID: "eventclock.automation.\(rule.id).\(event.id)",
                    title: title,
                    body: body
                )
            )
            return .success

        case .setStateFlag(let name, let value):
            stateFlags[name] = value
            return .success
        }
    }

    private func actionEffects(for timer: TimerInstance) -> [EngineEffect] {
        timer.actions.enumerated().map { index, action in
            .actionRequested(
                timerID: timer.id,
                action: action,
                deduplicationKey: "\(timer.id):\(index)"
            )
        }
    }

    private func remember(_ eventID: String) {
        processedEventIDs.append(eventID)
        processedEventSet.insert(eventID)
        trimProcessedEventIDs()
    }

    private func trimProcessedEventIDs() {
        while processedEventIDs.count > processedEventLimit {
            let removed = processedEventIDs.removeFirst()
            processedEventSet.remove(removed)
        }
    }

    private func persist() throws {
        let state = PersistedState(
            timers: currentTimers(),
            processedEventIDs: processedEventIDs,
            definitions: definitions,
            automationRules: automationRules,
            stateFlags: stateFlags,
            ruleLastTriggeredAt: ruleLastTriggeredAt,
            recurringReminders: recurringReminders
        )
        try store.save(state)
    }

    private func requireStarted() throws {
        guard isStarted else { throw TimerEngineError.notStarted }
    }
}
