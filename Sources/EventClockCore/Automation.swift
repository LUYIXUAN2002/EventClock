import Foundation

// MARK: - Typed event values

/// A small, provider-independent payload value.
public enum EventValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)

    public var typeName: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        }
    }
}

extension EventValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    private enum ValueType: String, Codable {
        case string
        case number
        case boolean
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ValueType.self, forKey: .type) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .value))
        case .number:
            self = .number(try container.decode(Double.self, forKey: .value))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(ValueType.string, forKey: .type)
            try container.encode(value, forKey: .value)
        case .number(let value):
            try container.encode(ValueType.number, forKey: .type)
            try container.encode(value, forKey: .value)
        case .boolean(let value):
            try container.encode(ValueType.boolean, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: - Conditions

public enum ComparisonOperator: String, Codable, Sendable, Equatable, CaseIterable {
    case equals
    case notEquals
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = ComparisonOperator(rawValue: raw) else {
            throw AutomationRuleError.unsupportedOperator(raw)
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TimerStateQuery: Codable, Sendable, Equatable {
    case any
    case sourceID(String)
}

public enum ConditionPredicate: Codable, Sendable, Equatable {
    /// An absent flag is treated as `false`.
    case stateFlag(name: String, equals: Bool)
    case payloadValue(
        key: String,
        comparison: ComparisonOperator,
        value: EventValue
    )
    /// Local-time window in minutes since midnight, inclusive of start and
    /// exclusive of end. A start greater than end wraps over midnight.
    case timeOfDay(startMinute: Int, endMinute: Int)
    case timerRunning(query: TimerStateQuery, isRunning: Bool)
}

public indirect enum ConditionExpression: Codable, Sendable, Equatable {
    case always
    case predicate(ConditionPredicate)
    case and([ConditionExpression])
    case or([ConditionExpression])
    case not(ConditionExpression)
}

// MARK: - Rule model

public struct AutomationTrigger: Codable, Sendable, Equatable {
    public let eventType: String

    public init(eventType: String) {
        self.eventType = eventType
    }
}

public enum AutomationAction: Codable, Sendable, Equatable {
    case startTimerFromDefinition(definitionID: String)
    case startTimer(name: String, duration: TimeInterval)
    case notify(title: String, body: String)
    case setStateFlag(name: String, value: Bool)
}

public struct AutomationRule: Codable, Sendable, Equatable, Identifiable {
    public static let maximumNameLength = 80
    public static let maximumConditionDepth = 8
    public static let maximumCooldown: TimeInterval = 7 * 24 * 60 * 60

    public let id: String
    public var name: String
    public var trigger: AutomationTrigger
    public var condition: ConditionExpression
    public var action: AutomationAction
    public var isEnabled: Bool
    public var cooldown: TimeInterval?

    public init(
        id: String,
        name: String,
        trigger: AutomationTrigger,
        condition: ConditionExpression,
        action: AutomationAction,
        isEnabled: Bool = true,
        cooldown: TimeInterval? = nil
    ) {
        self.id = id
        self.name = name
        self.trigger = trigger
        self.condition = condition
        self.action = action
        self.isEnabled = isEnabled
        self.cooldown = cooldown
    }

    public func validated() throws -> AutomationRule {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AutomationRuleError.emptyIdentifier
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw AutomationRuleError.emptyName
        }
        guard trimmedName.count <= Self.maximumNameLength else {
            throw AutomationRuleError.nameTooLong
        }

        let eventType = trigger.eventType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventType.isEmpty else {
            throw AutomationRuleError.emptyEventType
        }

        if let cooldown {
            guard cooldown.isFinite,
                  cooldown >= 0,
                  cooldown <= Self.maximumCooldown else {
                throw AutomationRuleError.invalidCooldown
            }
        }

        try Self.validate(condition: condition, depth: 0)
        let validatedAction = try Self.validate(action: action)

        return AutomationRule(
            id: id,
            name: trimmedName,
            trigger: AutomationTrigger(eventType: eventType),
            condition: condition,
            action: validatedAction,
            isEnabled: isEnabled,
            cooldown: cooldown
        )
    }

    private static func validate(
        condition: ConditionExpression,
        depth: Int
    ) throws {
        guard depth <= maximumConditionDepth else {
            throw AutomationRuleError.conditionTooDeep
        }

        switch condition {
        case .always:
            return
        case .predicate(let predicate):
            try validate(predicate: predicate)
        case .and(let children), .or(let children):
            guard !children.isEmpty else {
                throw AutomationRuleError.emptyConditionGroup
            }
            for child in children {
                try validate(condition: child, depth: depth + 1)
            }
        case .not(let child):
            try validate(condition: child, depth: depth + 1)
        }
    }

    private static func validate(predicate: ConditionPredicate) throws {
        switch predicate {
        case .stateFlag(let name, _):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 60 else {
                throw AutomationRuleError.invalidPredicate(
                    "State flag names must be 1–60 characters."
                )
            }

        case .payloadValue(let key, let comparison, let value):
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationRuleError.invalidPredicate(
                    "Payload keys must not be empty."
                )
            }
            if case .number(let number) = value, !number.isFinite {
                throw AutomationRuleError.invalidPredicate(
                    "Payload numbers must be finite."
                )
            }
            switch value {
            case .string, .boolean:
                guard comparison == .equals || comparison == .notEquals else {
                    throw AutomationRuleError.unsupportedComparison(
                        "\(comparison.rawValue) is not supported for \(value.typeName) payload values."
                    )
                }
            case .number:
                break
            }

        case .timeOfDay(let startMinute, let endMinute):
            guard (0..<1_440).contains(startMinute),
                  (0..<1_440).contains(endMinute),
                  startMinute != endMinute else {
                throw AutomationRuleError.invalidPredicate(
                    "Time-of-day windows need valid, non-equal minutes within one day."
                )
            }

        case .timerRunning(let query, _):
            if case .sourceID(let sourceID) = query {
                guard !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AutomationRuleError.invalidPredicate(
                        "A timer-state predicate needs a rule or definition identifier."
                    )
                }
            }
        }
    }

    private static func validate(action: AutomationAction) throws -> AutomationAction {
        switch action {
        case .startTimerFromDefinition(let definitionID):
            guard !definitionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AutomationRuleError.invalidAction(
                    "Choose a saved timer preset for this action."
                )
            }
            return action

        case .startTimer(let name, let duration):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 80 else {
                throw AutomationRuleError.invalidAction(
                    "Timer action names must be 1–80 characters."
                )
            }
            guard duration.isFinite,
                  duration >= TimerDefinition.minimumDuration,
                  duration <= TimerDefinition.maximumDuration else {
                throw AutomationRuleError.invalidAction(
                    "Timer action duration must be between 1 second and 24 hours."
                )
            }
            return .startTimer(name: trimmed, duration: duration)

        case .notify(let title, let body):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 100 else {
                throw AutomationRuleError.invalidAction(
                    "Notification titles must be 1–100 characters."
                )
            }
            return .notify(title: trimmed, body: body)

        case .setStateFlag(let name, let value):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 60 else {
                throw AutomationRuleError.invalidAction(
                    "State flag names must be 1–60 characters."
                )
            }
            return .setStateFlag(name: trimmed, value: value)
        }
    }
}

public enum AutomationRuleError: Error, Equatable, LocalizedError {
    case emptyIdentifier
    case emptyName
    case nameTooLong
    case emptyEventType
    case emptyConditionGroup
    case conditionTooDeep
    case invalidPredicate(String)
    case unsupportedOperator(String)
    case unsupportedComparison(String)
    case invalidCooldown
    case invalidAction(String)

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier:
            return "An automation rule needs a stable identifier."
        case .emptyName:
            return "Enter a rule name."
        case .nameTooLong:
            return "Rule names can be up to \(AutomationRule.maximumNameLength) characters."
        case .emptyEventType:
            return "Enter the event type that triggers this rule."
        case .emptyConditionGroup:
            return "AND/OR groups need at least one condition."
        case .conditionTooDeep:
            return "This condition is nested too deeply (maximum \(AutomationRule.maximumConditionDepth))."
        case .invalidPredicate(let message):
            return message
        case .unsupportedOperator(let raw):
            return "Unsupported comparison operator: \(raw)."
        case .unsupportedComparison(let message):
            return message
        case .invalidCooldown:
            return "Cooldown must be between 0 seconds and 7 days."
        case .invalidAction(let message):
            return message
        }
    }
}

// MARK: - Evaluation

public enum AutomationOutcome: Sendable, Equatable {
    case matched(action: AutomationAction)
    case disabled
    case cooldown(remaining: TimeInterval)
    case conditionNotMet
    case actionFailed(reason: String)
}

public struct AutomationEvaluation: Sendable, Equatable {
    public let ruleID: String
    public let ruleName: String
    public let eventID: String
    public let outcome: AutomationOutcome

    public init(
        ruleID: String,
        ruleName: String,
        eventID: String,
        outcome: AutomationOutcome
    ) {
        self.ruleID = ruleID
        self.ruleName = ruleName
        self.eventID = eventID
        self.outcome = outcome
    }
}

enum RuleConditionEvaluator {
    static func matches(
        _ condition: ConditionExpression,
        event: Event,
        stateFlags: [String: Bool],
        runningTimers: [TimerInstance],
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch condition {
        case .always:
            return true
        case .predicate(let predicate):
            return matches(
                predicate,
                event: event,
                stateFlags: stateFlags,
                runningTimers: runningTimers,
                now: now,
                calendar: calendar
            )
        case .and(let children):
            return children.allSatisfy {
                matches(
                    $0,
                    event: event,
                    stateFlags: stateFlags,
                    runningTimers: runningTimers,
                    now: now,
                    calendar: calendar
                )
            }
        case .or(let children):
            return children.contains {
                matches(
                    $0,
                    event: event,
                    stateFlags: stateFlags,
                    runningTimers: runningTimers,
                    now: now,
                    calendar: calendar
                )
            }
        case .not(let child):
            return !matches(
                child,
                event: event,
                stateFlags: stateFlags,
                runningTimers: runningTimers,
                now: now,
                calendar: calendar
            )
        }
    }

    private static func matches(
        _ predicate: ConditionPredicate,
        event: Event,
        stateFlags: [String: Bool],
        runningTimers: [TimerInstance],
        now: Date,
        calendar: Calendar
    ) -> Bool {
        switch predicate {
        case .stateFlag(let name, let expected):
            return (stateFlags[name] ?? false) == expected

        case .payloadValue(let key, let comparison, let expected):
            guard let actual = event.payload[key] else { return false }
            return compare(actual, comparison, expected)

        case .timeOfDay(let startMinute, let endMinute):
            let components = calendar.dateComponents([.hour, .minute], from: now)
            guard let hour = components.hour, let minute = components.minute else {
                return false
            }
            let current = hour * 60 + minute
            if startMinute < endMinute {
                return current >= startMinute && current < endMinute
            }
            return current >= startMinute || current < endMinute

        case .timerRunning(let query, let expected):
            let running = runningTimers.contains { timer in
                switch query {
                case .any:
                    return true
                case .sourceID(let sourceID):
                    return timer.ruleID == sourceID
                }
            }
            return running == expected
        }
    }

    private static func compare(
        _ actual: EventValue,
        _ comparison: ComparisonOperator,
        _ expected: EventValue
    ) -> Bool {
        switch (actual, expected) {
        case (.string(let lhs), .string(let rhs)):
            switch comparison {
            case .equals: return lhs == rhs
            case .notEquals: return lhs != rhs
            default: return false
            }
        case (.boolean(let lhs), .boolean(let rhs)):
            switch comparison {
            case .equals: return lhs == rhs
            case .notEquals: return lhs != rhs
            default: return false
            }
        case (.number(let lhs), .number(let rhs)):
            switch comparison {
            case .equals: return lhs == rhs
            case .notEquals: return lhs != rhs
            case .lessThan: return lhs < rhs
            case .lessThanOrEqual: return lhs <= rhs
            case .greaterThan: return lhs > rhs
            case .greaterThanOrEqual: return lhs >= rhs
            }
        default:
            return false
        }
    }
}

// MARK: - Recurring reminders

public enum Weekday: Int, Codable, Sendable, Equatable, CaseIterable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7
}

public enum RecurrenceSchedule: Codable, Sendable, Equatable {
    case daily(hour: Int, minute: Int)
    case weekly(weekday: Weekday, hour: Int, minute: Int)
}

public struct RecurringReminder: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var title: String
    public var body: String
    public var schedule: RecurrenceSchedule
    public var isEnabled: Bool

    public init(
        id: String,
        title: String,
        body: String,
        schedule: RecurrenceSchedule,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.schedule = schedule
        self.isEnabled = isEnabled
    }

    public func validated() throws -> RecurringReminder {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RecurringReminderError.emptyIdentifier
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, trimmedTitle.count <= 80 else {
            throw RecurringReminderError.invalidTitle
        }

        switch schedule {
        case .daily(let hour, let minute):
            guard Self.validTime(hour: hour, minute: minute) else {
                throw RecurringReminderError.invalidTime
            }
        case .weekly(_, let hour, let minute):
            guard Self.validTime(hour: hour, minute: minute) else {
                throw RecurringReminderError.invalidTime
            }
        }

        return RecurringReminder(
            id: id,
            title: trimmedTitle,
            body: body,
            schedule: schedule,
            isEnabled: isEnabled
        )
    }

    private static func validTime(hour: Int, minute: Int) -> Bool {
        (0..<24).contains(hour) && (0..<60).contains(minute)
    }
}

public enum RecurringReminderError: Error, Equatable, LocalizedError {
    case emptyIdentifier
    case invalidTitle
    case invalidTime

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier:
            return "A reminder needs a stable identifier."
        case .invalidTitle:
            return "Reminder titles must be 1–80 characters."
        case .invalidTime:
            return "Choose a valid reminder time."
        }
    }
}

public enum RecurrenceCalculator {
    /// Computes the next wall-clock occurrence in `calendar`'s time zone.
    ///
    /// Daily and weekly components are matched with `.nextTime`, so DST gaps
    /// resolve to the next existing local time rather than being skipped.
    public static func nextOccurrence(
        for reminder: RecurringReminder,
        after date: Date,
        calendar: Calendar
    ) -> Date? {
        var components = DateComponents()
        components.second = 0

        switch reminder.schedule {
        case .daily(let hour, let minute):
            components.hour = hour
            components.minute = minute
        case .weekly(let weekday, let hour, let minute):
            components.weekday = weekday.rawValue
            components.hour = hour
            components.minute = minute
        }

        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }
}
