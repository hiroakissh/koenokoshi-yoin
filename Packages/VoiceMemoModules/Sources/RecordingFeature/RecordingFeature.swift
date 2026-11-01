import SwiftUI
import Observation
import VoiceMemoDomain
import VoiceMemoInterfaces
import DesignSystem

@MainActor @Observable public final class RecordingViewModel {
    private let recorder: any RecorderService
    private let afterCapture: @Sendable (CapturedRecording) async throws -> Void
    private let reminders: any RecordingReminderService
    private let loadSettings: @Sendable () async -> RecordingSettings
    private let saveSettings: @Sendable (RecordingSettings) async -> Void
    private var currentID: UUID?
    private var currentPromptID: UUID?
    private var startedAt: Date?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    private var settingsLoaded = false
    private var reminderAuthorizationRequested = false
    public var isRecording = false
    public var elapsed = 0
    public var limit: RecordingLimit = .fourHours
    public var reminder: ReminderInterval = .thirtyMinutes
    public var message: String?
    public init(recorder: any RecorderService, reminders: any RecordingReminderService = NoopReminderService(), loadSettings: @escaping @Sendable () async -> RecordingSettings = { RecordingSettings() }, saveSettings: @escaping @Sendable (RecordingSettings) async -> Void = { _ in }, afterCapture: @escaping @Sendable (CapturedRecording) async throws -> Void = { _ in }) {
        self.recorder = recorder
        self.reminders = reminders
        self.loadSettings = loadSettings
        self.saveSettings = saveSettings
        self.afterCapture = afterCapture
    }

    public func loadPersistedSettings() async {
        guard !settingsLoaded else { return }
        let settings = await loadSettings()
        guard !isRecording else { return }
        limit = settings.limit
        reminder = settings.reminder
        settingsLoaded = true
    }

    public func persistSettings() async {
        guard settingsLoaded, !isRecording else { return }
        if reminder != .off, !reminderAuthorizationRequested {
            _ = await reminders.requestAuthorization()
            reminderAuthorizationRequested = true
        }
        await saveSettings(.init(limit: limit, reminder: reminder))
    }

    public func toggleRecording() async {
        do {
            if isRecording {
                let capture = try await recorder.stop()
                stopTimer()
                if let currentID { await reminders.cancel(memoID: currentID) }
                self.currentID = nil
                self.currentPromptID = nil
                isRecording = false
                try await afterCapture(capture)
                message = "Watchに保存済み"
                elapsed = 0
            }
            else {
                await persistSettings()
                let id = UUID()
                try await recorder.start(id: id, selectedLimitSeconds: limit.rawValue)
                currentID = id
                await scheduleReminder(for: id, from: Date())
                isRecording = true
                message = "録音中"
                startedAt = Date()
                startTimer()
            }
        } catch {
            stopTimer()
            message = error.localizedDescription
        }
    }

    public func handleReminderAction(memoID: UUID, promptID: UUID, action: String) async {
        guard isRecording, currentID == memoID, currentPromptID == promptID else { return }
        if action == "stop" {
            await toggleRecording()
        } else if action == "continue" {
            await scheduleReminder(for: memoID, from: Date())
        }
    }

    private func scheduleReminder(for memoID: UUID, from date: Date) async {
        guard reminder != .off else { return }
        let fireDate = date.addingTimeInterval(TimeInterval(reminder.rawValue))
        guard fireDate < date.addingTimeInterval(TimeInterval(limit.rawValue - elapsed)) else { return }
        let promptID = UUID()
        currentPromptID = promptID
        try? await reminders.schedule(.init(memoID: memoID, promptID: promptID, fireDate: fireDate))
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let startedAt = self.startedAt {
                    self.elapsed = max(0, Int(Date().timeIntervalSince(startedAt)))
                    if self.isRecording, self.elapsed >= self.limit.rawValue {
                        await self.toggleRecording()
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func stopTimer() {
        timerTask?.cancel()
        timerTask = nil
        startedAt = nil
    }
}

public struct NoopReminderService: RecordingReminderService { public init() {}; public func schedule(_ request: RecordingReminderRequest) async throws {}; public func cancel(memoID: UUID) async {} }

public struct RecordingView: View {
    @Environment(\.colorScheme) private var scheme
    @Bindable private var model: RecordingViewModel
    public init(model: RecordingViewModel) { self.model = model }
    public var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text(model.isRecording ? "録音中" : "録音待機")
                    .font(.headline)
                    .foregroundStyle(YoinTheme.secondary(scheme))
                    .accessibilityAddTraits(.isHeader)
                Text(Self.format(model.elapsed))
                    .font(.system(size: 34, weight: .regular, design: .monospaced))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .frame(maxWidth: .infinity)
                Button { Task { await model.toggleRecording() } } label: {
                    Text(model.isRecording ? "停止して保存" : "録音開始")
                        .foregroundStyle(YoinTheme.onAction(scheme))
                        .frame(maxWidth: .infinity)
                }
                    .buttonStyle(.borderedProminent)
                    .tint(YoinTheme.action(scheme))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .accessibilityHint("録音の開始または保存")
                if !model.isRecording {
                    HStack {
                        Text("録音上限")
                        Spacer(minLength: 4)
                        Button(model.limit.label) { model.limit = next(model.limit, in: RecordingLimit.allCases) }
                            .buttonStyle(.plain)
                            .frame(minWidth: 96, minHeight: 36)
                            .background(Capsule().fill(YoinTheme.raised(scheme)))
                            .accessibilityLabel("録音上限: \(model.limit.label)")
                            .accessibilityHint("タップすると次の上限に切り替えます")
                    }
                    HStack {
                        Text("継続確認")
                        Spacer(minLength: 4)
                        Button(model.reminder.label) { model.reminder = next(model.reminder, in: ReminderInterval.allCases) }
                            .buttonStyle(.plain)
                            .frame(minWidth: 96, minHeight: 36)
                            .background(Capsule().fill(YoinTheme.raised(scheme)))
                            .accessibilityLabel("継続確認: \(model.reminder.label)")
                            .accessibilityHint("タップすると次の間隔に切り替えます")
                    }
                } else {
                    Text("適用中の上限: \(model.limit.label)")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                if let message = model.message {
                    Text(message)
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel(message)
                }

            }
            .foregroundStyle(YoinTheme.text(scheme))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(YoinTheme.background(scheme).ignoresSafeArea())
        .task { await model.loadPersistedSettings() }
        .onChange(of: model.limit) { _, _ in Task { await model.persistSettings() } }
        .onChange(of: model.reminder) { _, _ in Task { await model.persistSettings() } }
    }
    private static func format(_ seconds: Int) -> String { String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    private func next<Value: CaseIterable & Equatable>(_ value: Value, in values: Value.AllCases) -> Value {
        let array = Array(values)
        guard let index = array.firstIndex(of: value), !array.isEmpty else { return value }
        return array[(index + 1) % array.count]
    }
}
