import Foundation

/// An occurrence reported by an input source.
///
/// `id` is the deduplication identity. Sources should reuse the same id when
/// re-delivering the same logical occurrence.
public struct Event: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let occurredAt: Date
    public let payload: [String: EventValue]

    public init(
        id: String,
        type: String,
        occurredAt: Date,
        payload: [String: EventValue] = [:]
    ) {
        self.id = id
        self.type = type
        self.occurredAt = occurredAt
        self.payload = payload
    }
}

/// Event type constants shared by core and platform adapters.
public enum EventType {
    public static let waterBoiling = "cooking.water.boiling"
}

/// A side effect the engine asks a host process to perform.
///
/// Requesting an action is a logical engine decision. It does not guarantee
/// that the operating system delivered any external notification.
public enum Action: Codable, Sendable, Equatable {
    case notify(title: String, body: String)
}

/// Maps an event type to a timer and the actions requested when it expires.
public struct Rule: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let eventType: String
    public let duration: TimeInterval
    public let actions: [Action]

    public init(
        id: String,
        label: String,
        eventType: String,
        duration: TimeInterval,
        actions: [Action]
    ) {
        self.id = id
        self.label = label
        self.eventType = eventType
        self.duration = duration
        self.actions = actions
    }
}

public extension Rule {
    /// M0 preset: a manual "water is boiling" event starts a 10-minute timer.
    static let waterBoiling = Rule(
        id: "cooking.water-boiling",
        label: "Boiling water",
        eventType: EventType.waterBoiling,
        duration: 10 * 60,
        actions: [
            .notify(
                title: "Cooking timer",
                body: "Your 10-minute timer is done."
            ),
        ]
    )
}

/// Optional origin tag for timers. Older snapshots decode as `nil`.
public enum TimerKind: String, Codable, Sendable, Equatable {
    case recovery
    case relativeEvent
}

/// Durable timer state.
///
/// `deadline` is wall-clock time and exists only for recovery after the
/// process ends. While the process is alive, elapsed time is measured with
/// the injected monotonic clock.
public struct TimerInstance: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable, Equatable {
        case running
        case fired
        case cancelled
    }

    public let id: String
    public let ruleID: String
    public internal(set) var label: String
    public internal(set) var duration: TimeInterval
    public let startedAt: Date
    public internal(set) var actions: [Action]
    public internal(set) var state: State
    public internal(set) var deadline: Date
    public internal(set) var firedAt: Date?
    public internal(set) var cancelledAt: Date?
    public let kind: TimerKind?

    public init(
        id: String,
        ruleID: String,
        label: String,
        duration: TimeInterval,
        startedAt: Date,
        deadline: Date,
        actions: [Action],
        state: State = .running,
        firedAt: Date? = nil,
        cancelledAt: Date? = nil,
        kind: TimerKind? = nil
    ) {
        self.id = id
        self.ruleID = ruleID
        self.label = label
        self.duration = duration
        self.startedAt = startedAt
        self.deadline = deadline
        self.actions = actions
        self.state = state
        self.firedAt = firedAt
        self.cancelledAt = cancelledAt
        self.kind = kind
    }
}

/// Describes how a reusable timer definition is activated.
///
/// Only manual activation is implemented in M2B. The struct form leaves room
/// for event/sensor triggers without changing the definition shape.
public struct TriggerDescriptor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case manual
    }

    public var kind: Kind

    public init(kind: Kind = .manual) {
        self.kind = kind
    }

    public static let manual = TriggerDescriptor(kind: .manual)
}

/// A reusable, user-visible timer configuration.
///
/// Timers created from a definition snapshot the name, duration, and actions.
/// Editing or deleting the definition therefore does not change timers that
/// are already running.
public struct TimerDefinition: Codable, Sendable, Equatable, Identifiable {
    public static let minimumDuration: TimeInterval = 1
    public static let maximumDuration: TimeInterval = 24 * 60 * 60
    public static let maximumNameLength = 60

    public let id: String
    public var name: String
    public var duration: TimeInterval
    public var trigger: TriggerDescriptor
    public var isEnabled: Bool
    public var actions: [Action]

    public init(
        id: String,
        name: String,
        duration: TimeInterval,
        trigger: TriggerDescriptor = .manual,
        isEnabled: Bool = true,
        actions: [Action]
    ) {
        self.id = id
        self.name = name
        self.duration = duration
        self.trigger = trigger
        self.isEnabled = isEnabled
        self.actions = actions
    }

    /// Returns a normalized copy or throws if the definition is invalid.
    public func validated() throws -> TimerDefinition {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TimerDefinitionError.emptyIdentifier
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw TimerDefinitionError.emptyName
        }
        guard trimmedName.count <= Self.maximumNameLength else {
            throw TimerDefinitionError.nameTooLong
        }
        guard duration.isFinite,
              duration >= Self.minimumDuration,
              duration <= Self.maximumDuration else {
            throw TimerDefinitionError.invalidDuration
        }

        return TimerDefinition(
            id: id,
            name: trimmedName,
            duration: duration,
            trigger: trigger,
            isEnabled: isEnabled,
            actions: actions
        )
    }
}

public enum TimerDefinitionError: Error, Equatable, LocalizedError {
    case emptyIdentifier
    case emptyName
    case nameTooLong
    case invalidDuration

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier:
            return "A timer preset needs a stable identifier."
        case .emptyName:
            return "Enter a timer name."
        case .nameTooLong:
            return "Timer names can be up to \(TimerDefinition.maximumNameLength) characters."
        case .invalidDuration:
            return "Duration must be between 1 second and 24 hours."
        }
    }
}

/// Everything the engine persists in one atomic snapshot.
///
/// `definitions` is decoded with a default so v1.01A snapshots that only
/// contain timers and processed event IDs remain loadable.
public struct PersistedState: Codable, Sendable, Equatable {
    public var timers: [TimerInstance]
    public var processedEventIDs: [String]
    public var definitions: [TimerDefinition]
    public var automationRules: [AutomationRule]
    public var stateFlags: [String: Bool]
    public var ruleLastTriggeredAt: [String: Date]
    public var recurringReminders: [RecurringReminder]

    public init(
        timers: [TimerInstance] = [],
        processedEventIDs: [String] = [],
        definitions: [TimerDefinition] = [],
        automationRules: [AutomationRule] = [],
        stateFlags: [String: Bool] = [:],
        ruleLastTriggeredAt: [String: Date] = [:],
        recurringReminders: [RecurringReminder] = []
    ) {
        self.timers = timers
        self.processedEventIDs = processedEventIDs
        self.definitions = definitions
        self.automationRules = automationRules
        self.stateFlags = stateFlags
        self.ruleLastTriggeredAt = ruleLastTriggeredAt
        self.recurringReminders = recurringReminders
    }

    public static let empty = PersistedState()

    private enum CodingKeys: String, CodingKey {
        case timers
        case processedEventIDs
        case definitions
        case automationRules
        case stateFlags
        case ruleLastTriggeredAt
        case recurringReminders
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timers = try container.decodeIfPresent([TimerInstance].self, forKey: .timers) ?? []
        processedEventIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .processedEventIDs
        ) ?? []
        definitions = try container.decodeIfPresent(
            [TimerDefinition].self,
            forKey: .definitions
        ) ?? []
        automationRules = try container.decodeIfPresent(
            [AutomationRule].self,
            forKey: .automationRules
        ) ?? []
        stateFlags = try container.decodeIfPresent(
            [String: Bool].self,
            forKey: .stateFlags
        ) ?? [:]
        ruleLastTriggeredAt = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .ruleLastTriggeredAt
        ) ?? [:]
        recurringReminders = try container.decodeIfPresent(
            [RecurringReminder].self,
            forKey: .recurringReminders
        ) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timers, forKey: .timers)
        try container.encode(processedEventIDs, forKey: .processedEventIDs)
        try container.encode(definitions, forKey: .definitions)
        try container.encode(automationRules, forKey: .automationRules)
        try container.encode(stateFlags, forKey: .stateFlags)
        try container.encode(ruleLastTriggeredAt, forKey: .ruleLastTriggeredAt)
        try container.encode(recurringReminders, forKey: .recurringReminders)
    }
}

/// Observable outcomes of an engine call.
public enum EngineEffect: Sendable, Equatable {
    case timerStarted(TimerInstance)
    case timerUpdated(TimerInstance)
    case timerCancelled(TimerInstance)
    case timerExpired(TimerInstance)
    /// A request, not a delivery guarantee. `deduplicationKey` is stable for
    /// a given timer and action so hosts can suppress obvious repeats.
    case actionRequested(timerID: String, action: Action, deduplicationKey: String)
    case duplicateEventIgnored(eventID: String)
    case automationEvaluated(AutomationEvaluation)
    /// Request an immediate local notification. The host owns delivery.
    case automationNotificationRequested(
        ruleID: String,
        notificationID: String,
        title: String,
        body: String
    )
}

public enum TimerEngineError: Error, Equatable, LocalizedError {
    case notStarted
    case unknownDefinition
    case definitionDisabled
    case unknownAutomationRule
    case invalidStateFlag
    case unknownReminder
    case unknownRecoveryTimer
    case recoveryTimerNotRunning

    public var errorDescription: String? {
        switch self {
        case .notStarted:
            return "The timer engine has not started."
        case .unknownDefinition:
            return "That timer preset no longer exists."
        case .definitionDisabled:
            return "That timer preset is disabled."
        case .unknownAutomationRule:
            return "That automation rule no longer exists."
        case .invalidStateFlag:
            return "State flag names must be 1–60 characters."
        case .unknownReminder:
            return "That reminder no longer exists."
        case .unknownRecoveryTimer:
            return "That recovery timer no longer exists."
        case .recoveryTimerNotRunning:
            return "Only running recovery timers can be rescheduled."
        }
    }
}

public enum RecoveryTimerError: Error, Equatable, LocalizedError {
    case emptyServiceName
    case serviceNameTooLong
    case deadlineNotFuture
    case invalidDuration
    case eventDeadlineNotFuture

    public var errorDescription: String? {
        switch self {
        case .emptyServiceName:
            return "Enter a service name."
        case .serviceNameTooLong:
            return "Service names can be up to 80 characters."
        case .deadlineNotFuture:
            return "Choose a reset date and time in the future."
        case .invalidDuration:
            return "Duration must be between 1 second and 24 hours."
        case .eventDeadlineNotFuture:
            return "This event is too old for the requested countdown."
        }
    }
}
