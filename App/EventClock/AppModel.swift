import Foundation
import Observation
import EventClockCore
import EventClockPlatform

@MainActor
@Observable
final class AppModel {
    static let tenSecondEventType = "development.ten-second"
    static let thirtySecondEventType = "development.thirty-second"

    private static let tenSecondRule = Rule(
        id: "development.ten-second",
        label: "10-second test",
        eventType: "development.ten-second",
        duration: 10,
        actions: [
            .notify(
                title: "Test timer",
                body: "Your 10-second test is done."
            ),
        ]
    )

    private static let thirtySecondRule = Rule(
        id: "development.thirty-second",
        label: "30-second test",
        eventType: "development.thirty-second",
        duration: 30,
        actions: [
            .notify(
                title: "Test timer",
                body: "Your 30-second test is done."
            ),
        ]
    )

    private(set) var activeTimers: [TimerInstance] = []
    private(set) var recentTimers: [TimerInstance] = []
    private(set) var recoveryTimers: [TimerInstance] = []
    private(set) var definitions: [TimerDefinition] = []
    private(set) var automationRules: [AutomationRule] = []
    private(set) var stateFlags: [String: Bool] = [:]
    private(set) var recurringReminders: [RecurringReminder] = []
    private(set) var lastAutomationEventType: String?
    private(set) var lastAutomationEventAt: Date?
    private(set) var automationEvaluations: [AutomationEvaluation] = []
    private(set) var permission: NotificationPermission = .unknown
    private(set) var errorMessage: String?
    private(set) var notificationErrorMessage: String?
    private(set) var isReady = false

    private let engine: TimerEngine
    private let notificationAdapter: UserNotificationCenterAdapter
    private let notificationCoordinator: TimerNotificationCoordinator
    private let recurringNotificationCoordinator: RecurringNotificationCoordinator
    private var didStart = false

    init() {
        let directory = URL.applicationSupportDirectory
            .appending(path: "EventClock", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let store = FileTimerStore(
            fileURL: directory.appending(path: "timers.json")
        )

        let adapter = UserNotificationCenterAdapter()
        self.notificationAdapter = adapter
        self.notificationCoordinator = TimerNotificationCoordinator(center: adapter)
        self.recurringNotificationCoordinator = RecurringNotificationCoordinator(center: adapter)
        self.engine = TimerEngine(
            store: store,
            clock: SystemClock(),
            rules: [.waterBoiling, Self.tenSecondRule, Self.thirtySecondRule]
        )
    }

    var notificationWarning: String? {
        guard permission == .denied else { return nil }
        return "Notifications are turned off. Timers still run while EventClock is open, but iOS cannot alert you when they end. Enable notifications in Settings to be alerted in the background."
    }

    var referencedStateFlagNames: [String] {
        var names = Set(stateFlags.keys)
        for rule in automationRules {
            collectStateFlagNames(from: rule.condition, into: &names)
            if case .setStateFlag(let name, _) = rule.action {
                names.insert(name)
            }
        }
        return names.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    // MARK: - Lifecycle

    func start() async {
        guard !didStart else { return }
        didStart = true
        await refreshPermission(requestIfNeeded: true)

        do {
            let effects = try await engine.start()
            await apply(effects)
            await refreshTimers()
            await refreshDefinitions()
            await refreshAutomations()
            await reconcileNotifications()
            await reconcileReminderNotifications()
            isReady = true
        } catch {
            errorMessage = "Could not load saved timers: \(error.localizedDescription)"
        }
    }

    func handleForeground() async {
        guard didStart else {
            await start()
            return
        }
        guard isReady else { return }

        await refreshPermission(requestIfNeeded: false)
        do {
            let effects = try await engine.advance()
            await apply(effects)
            await refreshTimers()
            await refreshAutomations()
            await reconcileNotifications()
            await reconcileReminderNotifications()
        } catch {
            errorMessage = "Could not reconcile timers: \(error.localizedDescription)"
        }
    }

    // MARK: - User actions

    func startWaterBoiling() async {
        await startTimer(eventType: EventType.waterBoiling)
    }

    func startTenSecondTest() async {
        await startTimer(eventType: Self.tenSecondEventType)
    }

    func startThirtySecondTest() async {
        await startTimer(eventType: Self.thirtySecondEventType)
    }

    func cancelTimer(id: String) async {
        do {
            let effects = try await engine.cancel(timerID: id)
            await apply(effects)
            await refreshTimers()
        } catch {
            errorMessage = "Could not cancel timer: \(error.localizedDescription)"
        }
    }

    // MARK: - Presets

    func savePreset(_ definition: TimerDefinition) async throws {
        guard isReady else { throw AppModelError.notReady }
        _ = try await engine.saveDefinition(definition)
        await refreshDefinitions()
    }

    func deletePreset(id: String) async {
        guard isReady else {
            errorMessage = AppModelError.notReady.localizedDescription
            return
        }
        do {
            try await engine.deleteDefinition(id: id)
            await refreshDefinitions()
        } catch {
            errorMessage = "Could not delete preset: \(error.localizedDescription)"
            await refreshDefinitions()
        }
    }

    func startPreset(id: String) async {
        guard isReady else {
            errorMessage = AppModelError.notReady.localizedDescription
            return
        }
        do {
            let effects = try await engine.activateDefinition(
                id: id,
                eventID: UUID().uuidString
            )
            await apply(effects)
            await refreshTimers()
        } catch {
            errorMessage = "Could not start preset: \(error.localizedDescription)"
            await refreshDefinitions()
        }
    }

    /// Starts a timer from a transient definition without saving a preset.
    func startOneOff(_ definition: TimerDefinition) async throws {
        guard isReady else { throw AppModelError.notReady }
        let effects = try await engine.startAdHocTimer(
            definition,
            eventID: UUID().uuidString
        )
        await apply(effects)
        await refreshTimers()
    }

    // MARK: - Recovery timers

    func createRecoveryTimer(
        serviceName: String,
        deadline: Date
    ) async throws {
        guard isReady else { throw AppModelError.notReady }
        let effects = try await engine.startRecoveryTimer(
            serviceName: serviceName,
            deadline: deadline,
            eventID: UUID().uuidString
        )
        await apply(effects)
        await refreshTimers()
    }

    func rescheduleRecoveryTimer(
        id: String,
        serviceName: String,
        deadline: Date
    ) async throws {
        guard isReady else { throw AppModelError.notReady }
        let effects = try await engine.rescheduleRecoveryTimer(
            id: id,
            serviceName: serviceName,
            deadline: deadline
        )
        await apply(effects)
        await refreshTimers()
    }

    func startFifteenSecondRecoveryTest() async {
        do {
            try await createRecoveryTimer(
                serviceName: "15-second reset test",
                deadline: Date().addingTimeInterval(15)
            )
        } catch {
            errorMessage = "Could not start recovery test: \(error.localizedDescription)"
        }
    }

    func startRelativeEventTimer(
        name: String,
        duration: TimeInterval
    ) async throws {
        guard isReady else { throw AppModelError.notReady }
        let event = Event(
            id: UUID().uuidString,
            type: "manual.event.recorded",
            occurredAt: Date()
        )
        let effects = try await engine.recordEventAndStartTimer(
            name: name,
            duration: duration,
            event: event
        )
        await apply(effects)
        await refreshTimers()
    }

    // MARK: - Automations

    func saveAutomationRule(_ rule: AutomationRule) async throws {
        guard isReady else { throw AppModelError.notReady }
        _ = try await engine.saveAutomationRule(rule)
        await refreshAutomations()
    }

    func deleteAutomationRule(id: String) async {
        guard isReady else {
            errorMessage = AppModelError.notReady.localizedDescription
            return
        }
        do {
            try await engine.deleteAutomationRule(id: id)
            await refreshAutomations()
        } catch {
            errorMessage = "Could not delete automation: \(error.localizedDescription)"
            await refreshAutomations()
        }
    }

    func setAutomationEnabled(ruleID: String, isEnabled: Bool) async {
        guard let rule = automationRules.first(where: { $0.id == ruleID }) else {
            return
        }
        var edited = rule
        edited.isEnabled = isEnabled
        do {
            _ = try await engine.saveAutomationRule(edited)
            await refreshAutomations()
        } catch {
            errorMessage = "Could not update automation: \(error.localizedDescription)"
            await refreshAutomations()
        }
    }

    func setStateFlag(name: String, value: Bool) async {
        guard isReady else {
            errorMessage = AppModelError.notReady.localizedDescription
            return
        }
        do {
            try await engine.setStateFlag(name: name, value: value)
            stateFlags = await engine.currentStateFlags()
        } catch {
            errorMessage = "Could not update state flag: \(error.localizedDescription)"
        }
    }

    func sendSyntheticEvent(
        type: String,
        payload: [String: EventValue]
    ) async {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter an event type to send a test event."
            return
        }
        guard isReady else {
            errorMessage = AppModelError.notReady.localizedDescription
            return
        }

        await processEvent(
            Event(
                id: UUID().uuidString,
                type: trimmed,
                occurredAt: Date(),
                payload: payload
            )
        )
    }

    // MARK: - Recurring reminders

    func saveReminder(_ reminder: RecurringReminder) async throws {
        guard isReady else { throw AppModelError.notReady }
        _ = try await engine.saveRecurringReminder(reminder)
        await refreshAutomations()
        await reconcileReminderNotifications()
    }

    func deleteReminder(id: String) async {
        guard isReady else {
            errorMessage = AppModelError.notReady.localizedDescription
            return
        }
        do {
            try await engine.deleteRecurringReminder(id: id)
            await refreshAutomations()
            await reconcileReminderNotifications()
        } catch {
            errorMessage = "Could not delete reminder: \(error.localizedDescription)"
            await refreshAutomations()
        }
    }

    func setReminderEnabled(reminderID: String, isEnabled: Bool) async {
        guard let reminder = recurringReminders.first(where: { $0.id == reminderID }) else {
            return
        }
        var edited = reminder
        edited.isEnabled = isEnabled
        do {
            _ = try await engine.saveRecurringReminder(edited)
            await refreshAutomations()
            await reconcileReminderNotifications()
        } catch {
            errorMessage = "Could not update reminder: \(error.localizedDescription)"
            await refreshAutomations()
        }
    }

    // MARK: - UI cadence

    /// Drives engine reconciliation while the app is visible. Each displayed
    /// countdown is derived from its timer's deadline, not from this tick.
    func tick() async {
        guard isReady else { return }
        do {
            let effects = try await engine.advance()
            await apply(effects)
            await refreshTimers()
        } catch {
            errorMessage = "Timer update failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Effects and notifications

    private func startTimer(eventType: String) async {
        if !didStart {
            await start()
        }
        guard isReady else { return }

        await processEvent(
            Event(
                id: UUID().uuidString,
                type: eventType,
                occurredAt: Date()
            )
        )
    }

    private func processEvent(_ event: Event) async {
        lastAutomationEventType = event.type
        lastAutomationEventAt = event.occurredAt
        automationEvaluations = []

        do {
            let effects = try await engine.handle(event)
            await apply(effects)
            await refreshTimers()
            await refreshAutomations()
        } catch {
            errorMessage = "Could not process event: \(error.localizedDescription)"
        }
    }

    private func apply(_ effects: [EngineEffect]) async {
        for effect in effects {
            switch effect {
            case .timerStarted(let timer), .timerUpdated(let timer):
                // Schedule immediately, using the deadline persisted by the
                // engine, rather than waiting for the expiry handler. Updates
                // replace the pending request with the same stable identifier.
                do {
                    try await notificationCoordinator.schedule(timer)
                } catch {
                    notificationErrorMessage = "Could not schedule notification for \(timer.label): \(error.localizedDescription)"
                }

            case .timerCancelled(let timer), .timerExpired(let timer):
                await notificationCoordinator.cancel(timerID: timer.id)

            case .actionRequested:
                // Each completion notification was scheduled at timer start.
                // Requesting another here would duplicate the visible alert.
                break

            case .duplicateEventIgnored:
                break

            case .automationEvaluated(let evaluation):
                automationEvaluations.append(evaluation)

            case .automationNotificationRequested(
                _,
                let notificationID,
                let title,
                let body
            ):
                do {
                    try await notificationCoordinator.notifyImmediately(
                        identifier: notificationID,
                        title: title,
                        body: body
                    )
                } catch {
                    notificationErrorMessage = "Could not schedule automation notification: \(error.localizedDescription)"
                }
            }
        }
    }

    private func reconcileNotifications() async {
        let timers = await engine.currentTimers()
        do {
            try await notificationCoordinator.reconcile(activeTimers: timers)
            notificationErrorMessage = nil
        } catch {
            notificationErrorMessage = "Could not reconcile notifications: \(error.localizedDescription)"
        }
    }

    private func refreshTimers() async {
        let timers = await engine.currentTimers()

        activeTimers = timers
            .filter { $0.state == .running }
            .sorted {
                if $0.deadline == $1.deadline {
                    return $0.id < $1.id
                }
                return $0.deadline < $1.deadline
            }

        recentTimers = Array(
            timers
                .filter { $0.state != .running }
                .sorted { $0.startedAt > $1.startedAt }
                .prefix(5)
        )

        recoveryTimers = timers.filter {
            $0.kind == .recovery || $0.kind == .relativeEvent
        }
    }

    private func refreshDefinitions() async {
        definitions = await engine.currentDefinitions()
    }

    private func refreshAutomations() async {
        automationRules = await engine.currentAutomationRules()
        stateFlags = await engine.currentStateFlags()
        recurringReminders = await engine.currentRecurringReminders()
    }

    private func reconcileReminderNotifications() async {
        do {
            try await recurringNotificationCoordinator.reconcile(
                reminders: recurringReminders
            )
        } catch {
            notificationErrorMessage = "Could not schedule recurring reminders: \(error.localizedDescription)"
        }
    }

    private func collectStateFlagNames(
        from condition: ConditionExpression,
        into names: inout Set<String>
    ) {
        switch condition {
        case .always:
            break
        case .predicate(let predicate):
            if case .stateFlag(let name, _) = predicate {
                names.insert(name)
            }
        case .and(let children), .or(let children):
            for child in children {
                collectStateFlagNames(from: child, into: &names)
            }
        case .not(let child):
            collectStateFlagNames(from: child, into: &names)
        }
    }

    private func refreshPermission(requestIfNeeded: Bool) async {
        var status = await notificationAdapter.authorizationStatus()
        if requestIfNeeded, status == .notDetermined {
            _ = await notificationAdapter.requestAuthorization()
            status = await notificationAdapter.authorizationStatus()
        }
        permission = status
    }
}

enum AppModelError: LocalizedError {
    case notReady

    var errorDescription: String? {
        "EventClock is still loading. Try again in a moment."
    }
}
