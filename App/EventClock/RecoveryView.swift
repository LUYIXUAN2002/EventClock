import Foundation
import SwiftUI
import EventClockCore

private enum RecoverySheet: Identifiable {
    case addReset
    case editReset(TimerInstance)
    case relativeEvent

    var id: String {
        switch self {
        case .addReset:
            return "addReset"
        case .editReset(let timer):
            return "edit-\(timer.id)"
        case .relativeEvent:
            return "relativeEvent"
        }
    }
}

struct RecoveryView: View {
    let model: AppModel

    @State private var sheet: RecoverySheet?
    @State private var cancelTarget: TimerInstance?

    var body: some View {
        Form {
            Section {
                Text("Enter expected reset times manually. Unless a service explicitly guarantees an exact reset, treat these as estimates. EventClock does not access service accounts or private usage APIs.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            recoveryTimersSection

            Section("Add") {
                Button {
                    sheet = .addReset
                } label: {
                    Label("Add expected reset time", systemImage: "plus.circle")
                }

                Button {
                    Task { await model.startFifteenSecondRecoveryTest() }
                } label: {
                    Label("Start 15-second test", systemImage: "bolt")
                }

                Button {
                    sheet = .relativeEvent
                } label: {
                    Label("Record event & start countdown", systemImage: "flag")
                }
            }

            if let error = model.errorMessage {
                Section {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Recovery")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    sheet = .addReset
                } label: {
                    Label("Add reset", systemImage: "plus")
                }
                .disabled(!model.isReady)
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .addReset:
                RecoveryResetEditorView(model: model, existing: nil)
            case .editReset(let timer):
                RecoveryResetEditorView(model: model, existing: timer)
            case .relativeEvent:
                RelativeEventEditorView(model: model)
            }
        }
        .alert(
            "Cancel recovery timer?",
            isPresented: cancelBinding,
            presenting: cancelTarget
        ) { timer in
            Button("Cancel timer", role: .destructive) {
                Task { await model.cancelTimer(id: timer.id) }
            }
            Button("Keep", role: .cancel) {}
        } message: { timer in
            Text("“\(timer.label)” will be cancelled and its pending notification removed.")
        }
    }

    // MARK: - List

    private var recoveryTimersSection: some View {
        Section("Recovery timers") {
            if model.recoveryTimers.isEmpty {
                Text("No recovery timers. Add an expected reset time or record an event countdown.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    ForEach(sortedTimers) { timer in
                        recoveryRow(timer, at: context.date)
                    }
                }
            }
        }
    }

    private var sortedTimers: [TimerInstance] {
        model.recoveryTimers.sorted { lhs, rhs in
            if lhs.state == .running, rhs.state != .running { return true }
            if lhs.state != .running, rhs.state == .running { return false }
            if lhs.state == .running {
                return lhs.deadline < rhs.deadline
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    @ViewBuilder
    private func recoveryRow(_ timer: TimerInstance, at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(timer.label)
                    .font(.headline)
                Spacer()
                Text(statusText(timer))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(timer))
            }

            Text(kindText(timer))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Expected reset: \(timer.deadline.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if timer.state == .running {
                Text(remainingText(until: timer.deadline, at: now))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                HStack {
                    if timer.kind == .recovery {
                        Button("Edit") {
                            sheet = .editReset(timer)
                        }
                        .buttonStyle(.borderless)
                    }

                    Button("Cancel", role: .destructive) {
                        cancelTarget = timer
                    }
                    .buttonStyle(.borderless)
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 6)
    }

    private var cancelBinding: Binding<Bool> {
        Binding(
            get: { cancelTarget != nil },
            set: { if !$0 { cancelTarget = nil } }
        )
    }

    private func statusText(_ timer: TimerInstance) -> String {
        switch timer.state {
        case .running:
            return "Running"
        case .fired:
            return "Reached"
        case .cancelled:
            return "Cancelled"
        }
    }

    private func statusColor(_ timer: TimerInstance) -> Color {
        switch timer.state {
        case .running:
            return .blue
        case .fired:
            return .green
        case .cancelled:
            return .secondary
        }
    }

    private func kindText(_ timer: TimerInstance) -> String {
        switch timer.kind {
        case .recovery:
            return "User-supplied estimate"
        case .relativeEvent:
            return "Relative to recorded event"
        case nil:
            return "Timer"
        }
    }

    private func remainingText(until deadline: Date, at now: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60

        if days > 0 {
            return "\(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

// MARK: - Reset editor

private struct RecoveryResetEditorView: View {
    let model: AppModel
    let existing: TimerInstance?

    @Environment(\.dismiss) private var dismiss
    @State private var serviceName: String
    @State private var deadline: Date
    @State private var errorText: String?
    @State private var isSaving = false

    init(model: AppModel, existing: TimerInstance?) {
        self.model = model
        self.existing = existing
        _serviceName = State(initialValue: existing?.label ?? "")
        _deadline = State(
            initialValue: existing?.deadline ?? Date().addingTimeInterval(3_600)
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Service") {
                    TextField("Service name", text: $serviceName)
                        .textInputAutocapitalization(.words)
                }

                Section("Expected reset") {
                    DatePicker(
                        "Date and time",
                        selection: $deadline,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    Text("This time is supplied by you. Unless the service guarantees it, treat it as an estimate.")
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
            .navigationTitle(existing == nil ? "Add reset" : "Edit reset")
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

    private func save() async {
        isSaving = true
        errorText = nil
        do {
            if let existing {
                try await model.rescheduleRecoveryTimer(
                    id: existing.id,
                    serviceName: serviceName,
                    deadline: deadline
                )
            } else {
                try await model.createRecoveryTimer(
                    serviceName: serviceName,
                    deadline: deadline
                )
            }
            isSaving = false
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isSaving = false
        }
    }
}

// MARK: - Relative event editor

private struct RelativeEventEditorView: View {
    let model: AppModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hours = 1
    @State private var minutes = 0
    @State private var seconds = 0
    @State private var errorText: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Event") {
                    TextField("Countdown name", text: $name)
                    Text("The countdown is recorded from the moment you tap the button below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Duration") {
                    DurationWheels(
                        hours: $hours,
                        minutes: $minutes,
                        seconds: $seconds
                    )
                    .frame(height: 120)
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Record event timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Record & start") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func save() async {
        isSaving = true
        errorText = nil
        do {
            try await model.startRelativeEventTimer(
                name: name,
                duration: TimeInterval(hours * 3_600 + minutes * 60 + seconds)
            )
            isSaving = false
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isSaving = false
        }
    }
}
