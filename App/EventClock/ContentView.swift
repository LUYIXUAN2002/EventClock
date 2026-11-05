import SwiftUI
import UIKit
import EventClockCore
import EventClockPlatform

struct ContentView: View {
    let model: AppModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var editorMode: PresetEditorMode?
    @State private var presetToDelete: TimerDefinition?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    activeTimersSection
                    recoverySection
                    presetsSection
                    automationsSection
                    controls
                    recentSection
                    permissionNotice
                    errorMessages
                    footer
                }
                .padding(24)
            }
            .navigationTitle(AppInfo.displayVersion)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $editorMode) { mode in
            PresetEditorView(model: model, mode: mode)
        }
        .alert(
            "Delete preset?",
            isPresented: deletePresetBinding,
            presenting: presetToDelete
        ) { definition in
            Button("Delete", role: .destructive) {
                Task { await model.deletePreset(id: definition.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { definition in
            Text("Timers already running from “\(definition.name)” will continue.")
        }
        .task {
            await model.start()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                await model.tick()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await model.handleForeground() }
        }
    }

    // MARK: - Active timers

    private var activeTimersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Active timers")
                    .font(.headline)
                Spacer()
                Text("\(model.activeTimers.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if model.activeTimers.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "timer")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No active timers")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Start a timer below")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 10) {
                        ForEach(model.activeTimers) { timer in
                            activeTimerRow(timer, at: context.date)
                        }
                    }
                }
            }
        }
    }

    private func activeTimerRow(_ timer: TimerInstance, at date: Date) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timer.label)
                    .font(.headline)
                    .lineLimit(1)
                Text("Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(Self.format(remaining(for: timer, at: date)))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            Button {
                Task { await model.cancelTimer(id: timer.id) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Cancel \(timer.label)")
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Recovery

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recovery")
                .font(.headline)

            NavigationLink {
                RecoveryView(model: model)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("External reset times")
                            .font(.subheadline.weight(.semibold))
                        Text(recoverySummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    private var recoverySummary: String {
        let running = model.recoveryTimers.filter { $0.state == .running }.count
        if running == 0 {
            return "No active recovery timers"
        }
        return "\(running) active recovery timer\(running == 1 ? "" : "s")"
    }

    // MARK: - Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Timer presets")
                    .font(.headline)
                Spacer()
                Button {
                    editorMode = .create
                } label: {
                    Label("New", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(!model.isReady)
            }

            if model.definitions.isEmpty {
                Text("No presets yet. Create one for timers you use often.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 8) {
                    ForEach(model.definitions) { definition in
                        presetRow(definition)
                    }
                }
            }

            Button {
                editorMode = .oneOff
            } label: {
                Label("Start custom one-off timer", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!model.isReady)
        }
    }

    private func presetRow(_ definition: TimerDefinition) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(definition.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(Self.durationLabel(definition.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Start") {
                Task { await model.startPreset(id: definition.id) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.isReady)

            Menu {
                Button("Edit") {
                    editorMode = .edit(definition)
                }
                Button("Delete", role: .destructive) {
                    presetToDelete = definition
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var deletePresetBinding: Binding<Bool> {
        Binding(
            get: { presetToDelete != nil },
            set: { presented in
                if !presented { presetToDelete = nil }
            }
        )
    }

    // MARK: - Automations

    private var automationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Automations")
                .font(.headline)

            NavigationLink {
                AutomationsView(model: model)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rules, state flags & reminders")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            "\(model.automationRules.count) rule\(model.automationRules.count == 1 ? "" : "s") · "
                                + "\(model.recurringReminders.count) reminder\(model.recurringReminders.count == 1 ? "" : "s")"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 12) {
            Button {
                Task { await model.startWaterBoiling() }
            } label: {
                Label("Water is boiling", systemImage: "flame.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.isReady)

            Divider()
                .padding(.vertical, 4)

            Text("Development")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                Task { await model.startThirtySecondTest() }
            } label: {
                Label("30-second custom test", systemImage: "timer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!model.isReady)

            Button {
                Task { await model.startTenSecondTest() }
            } label: {
                Label("10-second test", systemImage: "timer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!model.isReady)
        }
    }

    // MARK: - Recent

    @ViewBuilder
    private var recentSection: some View {
        if !model.recentTimers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent")
                    .font(.headline)

                ForEach(model.recentTimers) { timer in
                    HStack {
                        Text(timer.label)
                            .font(.subheadline)
                        Spacer()
                        Text(timer.state == .fired ? "Finished" : "Cancelled")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(timer.state == .fired ? .green : .secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Permission and notes

    @ViewBuilder
    private var permissionNotice: some View {
        if let warning = model.notificationWarning {
            VStack(alignment: .leading, spacing: 8) {
                Label("Notifications are off", systemImage: "bell.slash.fill")
                    .font(.headline)
                Text(warning)
                    .font(.footnote)
                if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                    Button("Open Settings") {
                        openURL(settingsURL)
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.yellow.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    @ViewBuilder
    private var errorMessages: some View {
        if let error = model.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        if let notificationError = model.notificationErrorMessage {
            Text(notificationError)
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Text("Each timer schedules its own completion notification when it starts. iOS delivery is not guaranteed.")
            Text("Timers resume from their saved deadlines after the app restarts.")
            Text("Build \(AppInfo.buildNumber)")
                .foregroundStyle(.tertiary)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    // MARK: - Formatting

    private func remaining(for timer: TimerInstance, at date: Date) -> TimeInterval {
        guard timer.state == .running else { return 0 }
        return max(0, timer.deadline.timeIntervalSince(date))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60

        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) hr") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if seconds > 0 || parts.isEmpty { parts.append("\(seconds) sec") }
        return parts.joined(separator: " ")
    }
}
