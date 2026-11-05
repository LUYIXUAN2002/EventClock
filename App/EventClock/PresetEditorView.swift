import Foundation
import SwiftUI
import EventClockCore

enum PresetEditorMode: Identifiable {
    case create
    case edit(TimerDefinition)
    case oneOff

    var id: String {
        switch self {
        case .create:
            return "create"
        case .oneOff:
            return "oneOff"
        case .edit(let definition):
            return "edit-\(definition.id)"
        }
    }
}

struct PresetEditorView: View {
    let model: AppModel
    let mode: PresetEditorMode

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var hours: Int
    @State private var minutes: Int
    @State private var seconds: Int
    @State private var errorText: String?
    @State private var isWorking = false

    init(model: AppModel, mode: PresetEditorMode) {
        self.model = model
        self.mode = mode

        let existing: TimerDefinition?
        if case .edit(let definition) = mode {
            existing = definition
        } else {
            existing = nil
        }

        let total = Int(existing?.duration ?? 10 * 60)
        _name = State(initialValue: existing?.name ?? "")
        _hours = State(initialValue: total / 3_600)
        _minutes = State(initialValue: (total % 3_600) / 60)
        _seconds = State(initialValue: total % 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Timer name", text: $name)
                        .textInputAutocapitalization(.words)
                }

                Section("Duration") {
                    HStack(spacing: 0) {
                        Picker("Hours", selection: $hours) {
                            ForEach(0...24, id: \.self) { value in
                                Text("\(value) hr").tag(value)
                            }
                        }
                        .labelsHidden()

                        Picker("Minutes", selection: $minutes) {
                            ForEach(0...59, id: \.self) { value in
                                Text("\(value) min").tag(value)
                            }
                        }
                        .labelsHidden()

                        Picker("Seconds", selection: $seconds) {
                            ForEach(0...59, id: \.self) { value in
                                Text("\(value) sec").tag(value)
                            }
                        }
                        .labelsHidden()
                    }
                    .pickerStyle(.wheel)
                    .frame(height: 120)

                    Text("Total: \(formattedDuration)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text(explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(actionLabel) {
                        Task { await submit() }
                    }
                    .disabled(isWorking || validationMessage != nil)
                }
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private var title: String {
        switch mode {
        case .create:
            return "New preset"
        case .edit:
            return "Edit preset"
        case .oneOff:
            return "One-off timer"
        }
    }

    private var actionLabel: String {
        switch mode {
        case .create, .edit:
            return "Save"
        case .oneOff:
            return "Start"
        }
    }

    private var explanation: String {
        switch mode {
        case .oneOff:
            return "This timer starts immediately and is not saved as a preset."
        case .create, .edit:
            return "Presets can be reused. Timers already running keep the name, duration, and notification they started with."
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var totalSeconds: Int {
        hours * 3_600 + minutes * 60 + seconds
    }

    private var formattedDuration: String {
        String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private var validationMessage: String? {
        if trimmedName.isEmpty {
            return "Enter a timer name."
        }
        if trimmedName.count > TimerDefinition.maximumNameLength {
            return "Timer names can be up to \(TimerDefinition.maximumNameLength) characters."
        }
        if totalSeconds < Int(TimerDefinition.minimumDuration) {
            return "Duration must be at least 1 second."
        }
        if totalSeconds > Int(TimerDefinition.maximumDuration) {
            return "Duration cannot exceed 24 hours."
        }
        return nil
    }

    private func definitionForSubmission() -> TimerDefinition? {
        guard validationMessage == nil else { return nil }

        let identifier: String
        let enabled: Bool
        switch mode {
        case .edit(let existing):
            identifier = existing.id
            enabled = existing.isEnabled
        case .create, .oneOff:
            identifier = UUID().uuidString
            enabled = true
        }

        return TimerDefinition(
            id: identifier,
            name: trimmedName,
            duration: TimeInterval(totalSeconds),
            trigger: .manual,
            isEnabled: enabled,
            actions: [
                .notify(title: trimmedName, body: "Your timer is done."),
            ]
        )
    }

    private func submit() async {
        guard let definition = definitionForSubmission() else {
            errorText = validationMessage
            return
        }

        isWorking = true
        errorText = nil
        do {
            switch mode {
            case .create, .edit:
                try await model.savePreset(definition)
            case .oneOff:
                try await model.startOneOff(definition)
            }
            isWorking = false
            dismiss()
        } catch {
            errorText = error.localizedDescription
            isWorking = false
        }
    }
}
