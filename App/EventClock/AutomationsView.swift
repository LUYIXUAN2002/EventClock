import Foundation
import SwiftUI
import EventClockCore

enum ReminderEditorMode: Identifiable {
    case create
    case edit(RecurringReminder)

    var id: String {
        switch self {
        case .create:
            return "create"
        case .edit(let reminder):
            return "edit-\(reminder.id)"
        }
    }
}

private enum TestPayloadKind: String, CaseIterable, Identifiable {
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

private enum AutomationSheet: Identifiable {
    case rule(RuleEditorMode)
    case reminder(ReminderEditorMode)

    var id: String {
        switch self {
        case .rule(let mode):
            return "rule-\(mode.id)"
        case .reminder(let mode):
            return "reminder-\(mode.id)"
        }
    }
}

private enum DeleteTarget: Identifiable {
    case rule(AutomationRule)
    case reminder(RecurringReminder)

    var id: String {
        switch self {
        case .rule(let rule):
            return "rule-\(rule.id)"
        case .reminder(let reminder):
            return "reminder-\(reminder.id)"
        }
    }
}

struct AutomationsView: View {
    let model: AppModel

    @State private var sheet: AutomationSheet?
    @State private var deleteTarget: DeleteTarget?

    @State private var testEventType = "sensor.water.boiling"
    @State private var payloadKey = ""
    @State private var payloadKind: TestPayloadKind = .string
    @State private var payloadString = ""
    @State private var payloadNumber = ""
    @State private var payloadBoolean = true
    @State private var testError: String?
    @State private var isSending = false

    var body: some View {
        Form {
            rulesSection
            testEventSection
            stateFlagsSection
            remindersSection

            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Automations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sheet = .rule(.create)
                } label: {
                    Label("Add rule", systemImage: "plus")
                }
                .disabled(!model.isReady)
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .rule(let mode):
                RuleEditorView(model: model, mode: mode)
            case .reminder(let mode):
                ReminderEditorView(model: model, mode: mode)
            }
        }
        .alert(
            "Delete?",
            isPresented: deleteBinding,
            presenting: deleteTarget
        ) { target in
            Button("Delete", role: .destructive) {
                Task {
                    switch target {
                    case .rule(let rule):
                        await model.deleteAutomationRule(id: rule.id)
                    case .reminder(let reminder):
                        await model.deleteReminder(id: reminder.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            switch target {
            case .rule:
                Text("Timers already started by this rule are not affected.")
            case .reminder:
                Text("Its scheduled system notifications will be removed.")
            }
        }
    }

    // MARK: - Rules

    private var rulesSection: some View {
        Section("Rules") {
            if model.automationRules.isEmpty {
                Text("No automation rules yet. Create a rule to respond to events.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.automationRules) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(rule.name)
                                .font(.headline)
                            Spacer()
                            Toggle(
                                "Enabled",
                                isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { value in
                                        Task {
                                            await model.setAutomationEnabled(
                                                ruleID: rule.id,
                                                isEnabled: value
                                            )
                                        }
                                    }
                                )
                            )
                            .labelsHidden()
                        }

                        Text("When \(rule.trigger.eventType)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(actionSummary(rule.action))
                            .font(.caption)

                        HStack {
                            Button("Edit") {
                                sheet = .rule(.edit(rule))
                            }
                            .buttonStyle(.borderless)

                            Button("Delete", role: .destructive) {
                                deleteTarget = .rule(rule)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Test event

    private var testEventSection: some View {
        Section("Send test event") {
            TextField("Event type", text: $testEventType)
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
                    Button(type) { testEventType = type }
                }
            }
            .font(.footnote)

            TextField("Payload key (optional)", text: $payloadKey)

            if !payloadKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Picker("Payload value type", selection: $payloadKind) {
                    ForEach(TestPayloadKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }

                switch payloadKind {
                case .string:
                    TextField("Payload value", text: $payloadString)
                case .number:
                    TextField("Payload value", text: $payloadNumber)
                        .keyboardType(.decimalPad)
                case .boolean:
                    Toggle("Payload value is true", isOn: $payloadBoolean)
                }
            }

            Button {
                Task { await sendTestEvent() }
            } label: {
                Label("Send event", systemImage: "paperplane")
            }
            .disabled(isSending)

            if let testError {
                Text(testError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            resultsView
        }
    }

    @ViewBuilder
    private var resultsView: some View {
        if let eventType = model.lastAutomationEventType {
            Text("Last event: \(eventType)")
                .font(.footnote.weight(.semibold))

            if let at = model.lastAutomationEventAt {
                Text(at.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if model.automationEvaluations.isEmpty {
                Text("No rule is configured for this event type.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.automationEvaluations, id: \.ruleID) { evaluation in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(evaluation.ruleName)
                            .font(.footnote.weight(.semibold))
                        Text(outcomeSummary(evaluation.outcome))
                            .font(.caption)
                            .foregroundStyle(outcomeColor(evaluation.outcome))
                    }
                    .padding(.vertical, 2)
                }
            }
        } else {
            Text("Send an event to see which rules matched.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - State flags

    private var stateFlagsSection: some View {
        Section("State flags") {
            let names = model.referencedStateFlagNames
            if names.isEmpty {
                Text("State flags appear here when a rule references one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(names, id: \.self) { name in
                    Toggle(
                        name,
                        isOn: Binding(
                            get: { model.stateFlags[name] ?? false },
                            set: { value in
                                Task {
                                    await model.setStateFlag(name: name, value: value)
                                }
                            }
                        )
                    )
                }
            }

            Text("A flag that has never been set is treated as false.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recurring reminders

    private var remindersSection: some View {
        Section("Scheduled reminders") {
            if model.recurringReminders.isEmpty {
                Text("No scheduled reminders.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.recurringReminders) { reminder in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(reminder.title)
                                .font(.headline)
                            Spacer()
                            Toggle(
                                "Enabled",
                                isOn: Binding(
                                    get: { reminder.isEnabled },
                                    set: { value in
                                        Task {
                                            await model.setReminderEnabled(
                                                reminderID: reminder.id,
                                                isEnabled: value
                                            )
                                        }
                                    }
                                )
                            )
                            .labelsHidden()
                        }

                        Text(scheduleDescription(reminder.schedule))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Edit") {
                                sheet = .reminder(.edit(reminder))
                            }
                            .buttonStyle(.borderless)

                            Button("Delete", role: .destructive) {
                                deleteTarget = .reminder(reminder)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.footnote)
                    }
                    .padding(.vertical, 4)
                }
            }

            Button {
                sheet = .reminder(.create)
            } label: {
                Label("Add reminder", systemImage: "plus.circle")
            }
            .disabled(!model.isReady)

            Text("Recurring reminders are delivered by iOS as system calendar notifications. The rule engine does not run while the app is suspended.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )
    }

    private func actionSummary(_ action: AutomationAction) -> String {
        switch action {
        case .startTimerFromDefinition:
            return "Action: start a saved timer preset"
        case .startTimer(let name, let duration):
            return "Action: start \(name) for \(durationText(duration))"
        case .notify(let title, _):
            return "Action: notify “\(title)”"
        case .setStateFlag(let name, let value):
            return "Action: set \(name) to \(value ? "true" : "false")"
        }
    }

    private func outcomeSummary(_ outcome: AutomationOutcome) -> String {
        switch outcome {
        case .matched(let action):
            return "Matched — \(actionSummary(action))"
        case .disabled:
            return "Skipped — rule is disabled"
        case .cooldown(let remaining):
            return "Skipped — cooldown, \(Int(remaining.rounded(.up)))s remaining"
        case .conditionNotMet:
            return "Skipped — condition did not match"
        case .actionFailed(let reason):
            return "Action failed — \(reason)"
        }
    }

    private func outcomeColor(_ outcome: AutomationOutcome) -> Color {
        switch outcome {
        case .matched:
            return .green
        case .actionFailed:
            return .red
        case .disabled, .cooldown, .conditionNotMet:
            return .secondary
        }
    }

    private func durationText(_ duration: TimeInterval) -> String {
        let total = Int(duration)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hr") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds) sec") }
        return parts.joined(separator: " ")
    }

    private func scheduleDescription(_ schedule: RecurrenceSchedule) -> String {
        switch schedule {
        case .daily(let hour, let minute):
            return "Daily at \(timeText(hour: hour, minute: minute))"
        case .weekly(let weekday, let hour, let minute):
            return "\(weekdayName(weekday)) at \(timeText(hour: hour, minute: minute))"
        }
    }

    private func timeText(hour: Int, minute: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func weekdayName(_ weekday: Weekday) -> String {
        let index = weekday.rawValue - 1
        let symbols = Calendar.current.shortWeekdaySymbols
        guard symbols.indices.contains(index) else { return "Weekly" }
        return symbols[index]
    }

    private func sendTestEvent() async {
        testError = nil
        isSending = true
        defer { isSending = false }

        var payload: [String: EventValue] = [:]
        let key = payloadKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            switch payloadKind {
            case .string:
                payload[key] = .string(payloadString)
            case .number:
                guard let number = Double(payloadNumber), number.isFinite else {
                    testError = "Enter a finite number for the payload."
                    return
                }
                payload[key] = .number(number)
            case .boolean:
                payload[key] = .boolean(payloadBoolean)
            }
        }

        await model.sendSyntheticEvent(type: testEventType, payload: payload)
    }
}

// MARK: - Reminder editor

private enum ReminderFrequency: String, CaseIterable, Identifiable {
    case daily
    case weekly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }
}

struct ReminderEditorView: View {
    let model: AppModel
    let mode: ReminderEditorMode

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var bodyText: String
    @State private var frequency: ReminderFrequency
    @State private var weekday: Weekday
    @State private var time: Date
    @State private var isEnabled: Bool
    @State private var errorText: String?
    @State private var isSaving = false

    init(model: AppModel, mode: ReminderEditorMode) {
        self.model = model
        self.mode = mode

        let reminder: RecurringReminder?
        if case .edit(let existing) = mode {
            reminder = existing
        } else {
            reminder = nil
        }

        var hour = 9
        var minute = 0
        var weekdayValue = Weekday.monday
        var frequencyValue = ReminderFrequency.daily
        if let schedule = reminder?.schedule {
            switch schedule {
            case .daily(let h, let m):
                hour = h
                minute = m
            case .weekly(let day, let h, let m):
                hour = h
                minute = m
                weekdayValue = day
                frequencyValue = .weekly
            }
        }

        var components = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: Date()
        )
        components.hour = hour
        components.minute = minute

        _title = State(initialValue: reminder?.title ?? "")
        _bodyText = State(initialValue: reminder?.body ?? "")
        _frequency = State(initialValue: frequencyValue)
        _weekday = State(initialValue: weekdayValue)
        _time = State(initialValue: Calendar.current.date(from: components) ?? Date())
        _isEnabled = State(initialValue: reminder?.isEnabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reminder") {
                    TextField("Title", text: $title)
                    TextField("Body (optional)", text: $bodyText, axis: .vertical)
                    Toggle("Enabled", isOn: $isEnabled)
                }

                Section("Schedule") {
                    Picker("Repeats", selection: $frequency) {
                        ForEach(ReminderFrequency.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }

                    if frequency == .weekly {
                        Picker("Day", selection: $weekday) {
                            ForEach(Weekday.allCases, id: \.self) { day in
                                Text(weekdayName(day)).tag(day)
                            }
                        }
                    }

                    DatePicker(
                        "Time",
                        selection: $time,
                        displayedComponents: .hourAndMinute
                    )
                }

                Section {
                    Text("This creates a repeating iOS calendar notification. The automation engine does not execute rules in the background.")
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
            .navigationTitle(existingReminder == nil ? "New reminder" : "Edit reminder")
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

    private var existingReminder: RecurringReminder? {
        if case .edit(let existing) = mode { return existing }
        return nil
    }

    private func weekdayName(_ weekday: Weekday) -> String {
        let index = weekday.rawValue - 1
        let symbols = Calendar.current.shortWeekdaySymbols
        guard symbols.indices.contains(index) else { return "Day" }
        return symbols[index]
    }

    private func save() async {
        let components = Calendar.current.dateComponents(
            [.hour, .minute],
            from: time
        )
        let hour = components.hour ?? 9
        let minute = components.minute ?? 0

        let schedule: RecurrenceSchedule
        switch frequency {
        case .daily:
            schedule = .daily(hour: hour, minute: minute)
        case .weekly:
            schedule = .weekly(weekday: weekday, hour: hour, minute: minute)
        }

        let reminder = RecurringReminder(
            id: existingReminder?.id ?? UUID().uuidString,
            title: title,
            body: bodyText,
            schedule: schedule,
            isEnabled: isEnabled
        )

        isSaving = true
        errorText = nil
        do {
            try await model.saveReminder(reminder)
            isSaving = false
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isSaving = false
        }
    }
}
