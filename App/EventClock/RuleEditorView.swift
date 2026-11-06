import Foundation
import SwiftUI
import EventClockCore

enum RuleEditorMode: Identifiable {
    case create
    case edit(AutomationRule)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let rule):
            return "edit-\(rule.id)"
        }
    }
}

private enum ConditionJoiner: String, CaseIterable, Identifiable {
    case all
    case any

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All (AND)"
        case .any: return "Any (OR)"
        }
    }
}

private enum PredicateKind: String, CaseIterable, Identifiable {
    case stateFlag
    case payload
    case timeWindow
    case timerRunning

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stateFlag: return "State flag"
        case .payload: return "Event payload"
        case .timeWindow: return "Time of day"
        case .timerRunning: return "Timer running"
        }
    }
}

private enum PayloadValueKind: String, CaseIterable, Identifiable {
    case string
    case number
    case boolean

    var id: String { rawValue }

    var label: String {
        switch self {
        case .string: return "Text"
        case .number: return "Number"
        case .boolean: return "Boolean"
        }
    }
}

private enum RuleActionKind: String, CaseIterable, Identifiable {
    case savedPreset
    case configuredTimer
    case notification
    case stateFlag

    var id: String { rawValue }

    var label: String {
        switch self {
        case .savedPreset: return "Start saved preset"
        case .configuredTimer: return "Start timer"
        case .notification: return "Send notification"
        case .stateFlag: return "Set state flag"
        }
    }
}

private struct PredicateDraft: Identifiable {
    let id = UUID()
    var kind: PredicateKind
    var flagName = ""
    var flagExpected = true
    var payloadKey = ""
    var comparison: ComparisonOperator = .equals
    var valueKind: PayloadValueKind = .string
    var stringValue = ""
    var numberValue = ""
    var booleanValue = true
    var startMinute = 8 * 60
    var endMinute = 17 * 60
    var timerExpected = true

    init(kind: PredicateKind) {
        self.kind = kind
    }
}

private struct ParsedCondition {
    let drafts: [PredicateDraft]
    let joiner: ConditionJoiner
    let negated: Bool
    let supported: Bool
}

private struct RuleEditorValidationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RuleEditorView: View {
    let model: AppModel
    let mode: RuleEditorMode

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var eventType: String
    @State private var isEnabled: Bool
    @State private var cooldownEnabled: Bool
    @State private var cooldownSeconds: Int

    @State private var predicateDrafts: [PredicateDraft]
    @State private var joiner: ConditionJoiner
    @State private var negateGroup: Bool
    @State private var conditionWasComplex: Bool
    @State private var originalCondition: ConditionExpression

    @State private var actionKind: RuleActionKind
    @State private var selectedDefinitionID: String
    @State private var timerActionName: String
    @State private var timerActionHours: Int
    @State private var timerActionMinutes: Int
    @State private var timerActionSeconds: Int
    @State private var notifyTitle: String
    @State private var notifyBody: String
    @State private var flagActionName: String
    @State private var flagActionValue: Bool

    @State private var errorText: String?
    @State private var isSaving = false

    init(model: AppModel, mode: RuleEditorMode) {
        self.model = model
        self.mode = mode

        let rule: AutomationRule?
        if case .edit(let existing) = mode {
            rule = existing
        } else {
            rule = nil
        }

        let parsed = rule.map { Self.parseCondition($0.condition) }
        _conditionWasComplex = State(
            initialValue: parsed.map { !$0.supported } ?? false
        )
        _predicateDrafts = State(initialValue: parsed?.drafts ?? [])
        _joiner = State(initialValue: parsed?.joiner ?? .all)
        _negateGroup = State(initialValue: parsed?.negated ?? false)
        _originalCondition = State(initialValue: rule?.condition ?? .always)

        _name = State(initialValue: rule?.name ?? "")
        _eventType = State(initialValue: rule?.trigger.eventType ?? "sensor.water.boiling")
        _isEnabled = State(initialValue: rule?.isEnabled ?? true)
        _cooldownEnabled = State(initialValue: rule?.cooldown != nil)
        _cooldownSeconds = State(initialValue: Int(rule?.cooldown ?? 300))

        var kind: RuleActionKind = .configuredTimer
        var definitionID = model.definitions.first?.id ?? ""
        var timerName = "Automation timer"
        var hours = 0
        var minutes = 10
        var seconds = 0
        var notifyTitleValue = ""
        var notifyBodyValue = ""
        var flagName = ""
        var flagValue = true

        if let action = rule?.action {
            switch action {
            case .startTimerFromDefinition(let id):
                kind = .savedPreset
                definitionID = id
            case .startTimer(let name, let duration):
                kind = .configuredTimer
                timerName = name
                let total = Int(duration)
                hours = total / 3_600
                minutes = (total % 3_600) / 60
                seconds = total % 60
            case .notify(let title, let body):
                kind = .notification
                notifyTitleValue = title
                notifyBodyValue = body
            case .setStateFlag(let name, let value):
                kind = .stateFlag
                flagName = name
                flagValue = value
            }
        }

        _actionKind = State(initialValue: kind)
        _selectedDefinitionID = State(initialValue: definitionID)
        _timerActionName = State(initialValue: timerName)
        _timerActionHours = State(initialValue: hours)
        _timerActionMinutes = State(initialValue: minutes)
        _timerActionSeconds = State(initialValue: seconds)
        _notifyTitle = State(initialValue: notifyTitleValue)
        _notifyBody = State(initialValue: notifyBodyValue)
        _flagActionName = State(initialValue: flagName)
        _flagActionValue = State(initialValue: flagValue)
    }

    var body: some View {
        NavigationStack {
            Form {
                ruleSection
                conditionSection
                actionSection
                cooldownSection

                Section {
                    Text("Rules run only when EventClock processes an event. Recurring reminders are scheduled by iOS separately and do not run rule actions in the background.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existingRule == nil ? "New rule" : "Edit rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private var existingRule: AutomationRule? {
        if case .edit(let existing) = mode { return existing }
        return nil
    }

    // MARK: - Sections

    private var ruleSection: some View {
        Section("Rule") {
            TextField("Name", text: $name)

            TextField("Event type", text: $eventType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            Menu("Common event types") {
                ForEach(
                    [
                        "sensor.water.boiling",
                        "manual.water.boiling",
                        "cooking.water.boiling",
                        "sensor.motion.detected",
                    ],
                    id: \.self
                ) { type in
                    Button(type) { eventType = type }
                }
            }
            .font(.footnote)

            Toggle("Enabled", isOn: $isEnabled)
        }
    }

    private var conditionSection: some View {
        Section("Condition") {
            if conditionWasComplex {
                Label(
                    "This rule has a nested condition. It is preserved while the list below is empty; adding conditions replaces it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.orange)

                Button("Replace with always") {
                    conditionWasComplex = false
                    originalCondition = .always
                    predicateDrafts = []
                }
                .font(.footnote)
            }

            if predicateDrafts.isEmpty {
                Text(
                    conditionWasComplex
                        ? "Using the existing nested condition."
                        : "Always matches when the event type matches."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                if predicateDrafts.count > 1 {
                    Picker("Combine", selection: $joiner) {
                        ForEach(ConditionJoiner.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle("Negate group (NOT)", isOn: $negateGroup)

                ForEach($predicateDrafts) { $draft in
                    predicateEditor($draft)
                }
            }

            Menu("Add condition") {
                ForEach(PredicateKind.allCases) { kind in
                    Button(kind.label) {
                        predicateDrafts.append(PredicateDraft(kind: kind))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func predicateEditor(_ draft: Binding<PredicateDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Type", selection: draft.kind) {
                    ForEach(PredicateKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .labelsHidden()

                Spacer()

                Button(role: .destructive) {
                    let id = draft.wrappedValue.id
                    predicateDrafts.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            switch draft.wrappedValue.kind {
            case .stateFlag:
                TextField("State flag name", text: draft.flagName)
                Toggle("Flag is true", isOn: draft.flagExpected)

            case .payload:
                TextField("Payload key", text: draft.payloadKey)
                Picker("Value type", selection: draft.valueKind) {
                    ForEach(PayloadValueKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                Picker("Comparison", selection: draft.comparison) {
                    ForEach(ComparisonOperator.allCases, id: \.self) { op in
                        Text(operatorLabel(op)).tag(op)
                    }
                }

                switch draft.wrappedValue.valueKind {
                case .string:
                    TextField("Value", text: draft.stringValue)
                case .number:
                    TextField("Value", text: draft.numberValue)
                        .keyboardType(.decimalPad)
                case .boolean:
                    Toggle("Value is true", isOn: draft.booleanValue)
                }

            case .timeWindow:
                DatePicker(
                    "Start",
                    selection: minuteBinding(draft.startMinute),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "End",
                    selection: minuteBinding(draft.endMinute),
                    displayedComponents: .hourAndMinute
                )

            case .timerRunning:
                Toggle("Any timer is running", isOn: draft.timerExpected)
            }
        }
        .padding(.vertical, 4)
    }

    private var actionSection: some View {
        Section("Action") {
            Picker("Action", selection: $actionKind) {
                ForEach(RuleActionKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }

            switch actionKind {
            case .savedPreset:
                if model.definitions.isEmpty {
                    Text("Create a saved timer preset first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Preset", selection: $selectedDefinitionID) {
                        ForEach(model.definitions) { definition in
                            Text(definition.name).tag(definition.id)
                        }
                    }
                }

            case .configuredTimer:
                TextField("Timer name", text: $timerActionName)
                DurationWheels(
                    hours: $timerActionHours,
                    minutes: $timerActionMinutes,
                    seconds: $timerActionSeconds
                )
                .frame(height: 150)

            case .notification:
                TextField("Notification title", text: $notifyTitle)
                TextField("Notification body", text: $notifyBody, axis: .vertical)

            case .stateFlag:
                TextField("State flag name", text: $flagActionName)
                Toggle("Set to true", isOn: $flagActionValue)
            }
        }
    }

    private var cooldownSection: some View {
        Section("Cooldown") {
            Toggle("Use a cooldown", isOn: $cooldownEnabled)
            if cooldownEnabled {
                Stepper(
                    "\(cooldownSeconds) seconds",
                    value: $cooldownSeconds,
                    in: 0...Int(AutomationRule.maximumCooldown),
                    step: 30
                )
                Text("A rule cannot run again until this many seconds have passed since its last successful action.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Binding helpers

    private func minuteBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { date(forMinute: minute.wrappedValue) },
            set: { minute.wrappedValue = minutes(from: $0) }
        )
    }

    private func date(forMinute minute: Int) -> Date {
        var components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: Date()
        )
        components.hour = minute / 60
        components.minute = minute % 60
        return Calendar.current.date(from: components) ?? Date()
    }

    private func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents(
            [.hour, .minute],
            from: date
        )
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    private func operatorLabel(_ op: ComparisonOperator) -> String {
        switch op {
        case .equals: return "equals"
        case .notEquals: return "does not equal"
        case .lessThan: return "less than"
        case .lessThanOrEqual: return "less than or equal"
        case .greaterThan: return "greater than"
        case .greaterThanOrEqual: return "greater than or equal"
        }
    }

    // MARK: - Build and save

    private func save() async {
        do {
            let rule = try buildRule()
            isSaving = true
            errorText = nil
            try await model.saveAutomationRule(rule)
            isSaving = false
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isSaving = false
        }
    }

    private func buildRule() throws -> AutomationRule {
        let rule = AutomationRule(
            id: existingRule?.id ?? UUID().uuidString,
            name: name,
            trigger: AutomationTrigger(eventType: eventType),
            condition: try buildCondition(),
            action: try buildAction(),
            isEnabled: isEnabled,
            cooldown: cooldownEnabled ? TimeInterval(cooldownSeconds) : nil
        )
        return try rule.validated()
    }

    private func buildCondition() throws -> ConditionExpression {
        if predicateDrafts.isEmpty {
            return conditionWasComplex ? originalCondition : .always
        }

        let predicates = try predicateDrafts.map(buildPredicate)
        let expressions = predicates.map { ConditionExpression.predicate($0) }
        let group: ConditionExpression
        if expressions.count == 1 {
            group = expressions[0]
        } else if joiner == .all {
            group = .and(expressions)
        } else {
            group = .or(expressions)
        }
        return negateGroup ? .not(group) : group
    }

    private func buildPredicate(_ draft: PredicateDraft) throws -> ConditionPredicate {
        switch draft.kind {
        case .stateFlag:
            return .stateFlag(name: draft.flagName, equals: draft.flagExpected)

        case .payload:
            let value: EventValue
            switch draft.valueKind {
            case .string:
                value = .string(draft.stringValue)
            case .number:
                guard let number = Double(draft.numberValue), number.isFinite else {
                    throw RuleEditorValidationError(
                        message: "Enter a finite number for the payload comparison."
                    )
                }
                value = .number(number)
            case .boolean:
                value = .boolean(draft.booleanValue)
            }
            return .payloadValue(
                key: draft.payloadKey,
                comparison: draft.comparison,
                value: value
            )

        case .timeWindow:
            return .timeOfDay(
                startMinute: draft.startMinute,
                endMinute: draft.endMinute
            )

        case .timerRunning:
            return .timerRunning(query: .any, isRunning: draft.timerExpected)
        }
    }

    private func buildAction() throws -> AutomationAction {
        switch actionKind {
        case .savedPreset:
            guard !selectedDefinitionID.isEmpty,
                  model.definitions.contains(where: { $0.id == selectedDefinitionID }) else {
                throw RuleEditorValidationError(
                    message: "Choose a saved timer preset for this action."
                )
            }
            return .startTimerFromDefinition(definitionID: selectedDefinitionID)

        case .configuredTimer:
            return .startTimer(
                name: timerActionName,
                duration: TimeInterval(
                    timerActionHours * 3_600
                        + timerActionMinutes * 60
                        + timerActionSeconds
                )
            )

        case .notification:
            return .notify(title: notifyTitle, body: notifyBody)

        case .stateFlag:
            return .setStateFlag(name: flagActionName, value: flagActionValue)
        }
    }

    // MARK: - Existing condition parsing

    private static func parseCondition(_ condition: ConditionExpression) -> ParsedCondition {
        switch condition {
        case .always:
            return ParsedCondition(drafts: [], joiner: .all, negated: false, supported: true)

        case .predicate(let predicate):
            guard let draft = draft(from: predicate) else {
                return ParsedCondition(drafts: [], joiner: .all, negated: false, supported: false)
            }
            return ParsedCondition(drafts: [draft], joiner: .all, negated: false, supported: true)

        case .and(let children):
            guard let drafts = flatDrafts(from: children) else {
                return ParsedCondition(drafts: [], joiner: .all, negated: false, supported: false)
            }
            return ParsedCondition(drafts: drafts, joiner: .all, negated: false, supported: true)

        case .or(let children):
            guard let drafts = flatDrafts(from: children) else {
                return ParsedCondition(drafts: [], joiner: .any, negated: false, supported: false)
            }
            return ParsedCondition(drafts: drafts, joiner: .any, negated: false, supported: true)

        case .not(let inner):
            switch inner {
            case .predicate(let predicate):
                guard let draft = draft(from: predicate) else {
                    return ParsedCondition(drafts: [], joiner: .all, negated: true, supported: false)
                }
                return ParsedCondition(drafts: [draft], joiner: .all, negated: true, supported: true)
            case .and(let children):
                guard let drafts = flatDrafts(from: children) else {
                    return ParsedCondition(drafts: [], joiner: .all, negated: true, supported: false)
                }
                return ParsedCondition(drafts: drafts, joiner: .all, negated: true, supported: true)
            case .or(let children):
                guard let drafts = flatDrafts(from: children) else {
                    return ParsedCondition(drafts: [], joiner: .any, negated: true, supported: false)
                }
                return ParsedCondition(drafts: drafts, joiner: .any, negated: true, supported: true)
            default:
                return ParsedCondition(drafts: [], joiner: .all, negated: true, supported: false)
            }
        }
    }

    private static func flatDrafts(
        from children: [ConditionExpression]
    ) -> [PredicateDraft]? {
        var drafts: [PredicateDraft] = []
        for child in children {
            guard case .predicate(let predicate) = child,
                  let draft = draft(from: predicate) else {
                return nil
            }
            drafts.append(draft)
        }
        return drafts
    }

    private static func draft(from predicate: ConditionPredicate) -> PredicateDraft? {
        switch predicate {
        case .stateFlag(let name, let expected):
            var draft = PredicateDraft(kind: .stateFlag)
            draft.flagName = name
            draft.flagExpected = expected
            return draft

        case .payloadValue(let key, let comparison, let value):
            var draft = PredicateDraft(kind: .payload)
            draft.payloadKey = key
            draft.comparison = comparison
            switch value {
            case .string(let string):
                draft.valueKind = .string
                draft.stringValue = string
            case .number(let number):
                draft.valueKind = .number
                draft.numberValue = String(number)
            case .boolean(let boolean):
                draft.valueKind = .boolean
                draft.booleanValue = boolean
            }
            return draft

        case .timeOfDay(let startMinute, let endMinute):
            var draft = PredicateDraft(kind: .timeWindow)
            draft.startMinute = startMinute
            draft.endMinute = endMinute
            return draft

        case .timerRunning(.any, let expected):
            var draft = PredicateDraft(kind: .timerRunning)
            draft.timerExpected = expected
            return draft

        case .timerRunning(.sourceID, _):
            return nil
        }
    }
}
