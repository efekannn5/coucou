import AVFoundation
import Speech
import SwiftUI

/// Write or dictate an instruction for a Claude Code session; Face ID sends
/// it to the Mac, which continues the conversation in the background.
struct InstructionComposer: View {
    let link: PhoneLink
    let session: SessionItem

    @State private var text = ""
    @State private var sending = false
    @State private var sentAt: Date?
    /// The last message sent from this screen: its RunStatus is shown below.
    @State private var sentId: String?
    @State private var options = RunOptions()
    @State private var stopping = false
    @State private var error: String?
    @State private var dictation = Dictation()
    @State private var quickReplies = QuickReplies.load()
    @FocusState private var focused: Bool

    /// A bar at the bottom of the session screen, like a chat.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.acceptsInstructions {
                shortcuts
                composer
                status
            } else {
                Label("To write to Claude from here, turn on \"Let my iPhone send instructions to Claude Code\" in Coucou's Settings on your Mac (GitHub version).",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        // Floating, like Messages on iOS 26: no bar behind it, the screen
        // fades out underneath.
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .onChange(of: dictation.transcript) { _, words in
            if dictation.isRecording { text = dictation.prefix + words }
        }
    }

    /// Instructions you send often: a tap puts one in the field (it isn't sent
    /// yet); + keeps what is typed; a long press removes one.
    private var shortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                optionsMenu
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        text = reply
                        focused = true
                        Haptics.impact()
                    } label: {
                        Text(reply)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassPill(Capsule(), interactive: true)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .contextMenu {
                        Button(role: .destructive) {
                            quickReplies.removeAll { $0 == reply }
                            QuickReplies.save(quickReplies)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty && !quickReplies.contains(typed) {
                    Button {
                        quickReplies.append(typed)
                        QuickReplies.save(quickReplies)
                        Haptics.success()
                    } label: {
                        Label("Keep", systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .glassPill(Capsule(), interactive: true, tint: .accentColor)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    /// One glass capsule with the field, the language and the mic inside,
    /// and the send button next to it, like Messages.
    private var composer: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 2) {
                TextField("Tell Claude what to do next…", text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)
                Menu {
                    Picker("Dictation language", selection: $dictation.localeID) {
                        ForEach(Dictation.languages, id: \.self) { id in
                            Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                        }
                    }
                } label: {
                    Text(Dictation.shortName(dictation.localeID))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 42)
                }
                Button {
                    Task { await dictation.toggle(startingFrom: text) }
                } label: {
                    Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                        .font(.body)
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                        .frame(width: 38, height: 42)
                }
                .padding(.trailing, 4)
            }
            .glassPill(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(empty ? Color.secondary : Color.black)
                    .frame(width: 44, height: 44)
                    .background(empty ? Color.white.opacity(0.12) : Color.white, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(empty || sending)
            .animation(.spring(duration: 0.3), value: empty)
        }
    }

    /// The model and plan mode for the next message (the session's own by default).
    private var optionsMenu: some View {
        Menu {
            Picker("Model", selection: $options.model) {
                Text("Session's model").tag("")
                ForEach(RunOptions.models, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Toggle(isOn: $options.planFirst) {
                Label("Plan first, change nothing", systemImage: "list.bullet.clipboard")
            }
        } label: {
            Label(options.isDefault ? "Options" : options.label, systemImage: "slider.horizontal.3")
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .glassPill(Capsule(), interactive: true, tint: options.isDefault ? nil : .accentColor)
        }
        .buttonStyle(PressableButtonStyle())
    }

    /// What the Mac said about the last message: sent from here, or still going.
    private var run: RunStatus? {
        guard let run = link.runStatus[session.id] else { return nil }
        if run.instructionId == sentId { return run }
        // A run still going (sent before this screen opened), not a stale one.
        if run.isActive && Date().timeIntervalSince(run.updatedAt) < 2 * 3600 { return run }
        if let sentAt, run.updatedAt >= sentAt { return run }
        return nil
    }

    @ViewBuilder private var status: some View {
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if let run {
            HStack(spacing: 8) {
                runLabel(run)
                Spacer(minLength: 0)
                if run.isActive {
                    Button {
                        Task { await stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .glassPill(Capsule(), interactive: true, tint: .red)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(stopping)
                }
            }
            .animation(.spring(duration: 0.3), value: run.state)
        } else if sentAt != nil {
            Label("Sent to your Mac…", systemImage: "paperplane.fill")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func runLabel(_ run: RunStatus) -> some View {
        switch run.state {
        case .queued:
            Label(run.queued > 1 ? "Waiting for the current run · \(run.queued) in line" : "Waiting for the current run",
                  systemImage: "hourglass")
                .font(.caption).foregroundStyle(.secondary)
        case .running:
            Label {
                Text(run.detail.isEmpty ? "Running on your Mac" : "Running in \(run.detail)")
                    + Text(run.queued > 0 ? " · \(run.queued) waiting" : "")
            } icon: {
                Image(systemName: "gearshape.2.fill").symbolEffect(.rotate, isActive: true)
            }
            .font(.caption).foregroundStyle(.green)
        case .finished:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .stopped:
            Label("Stopped", systemImage: "stop.circle")
                .font(.caption).foregroundStyle(.secondary)
        case .failed:
            Label("Failed: \(run.detail)", systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.red)
                .lineLimit(3)
        case .ignored:
            Label("Not run: \(run.detail)", systemImage: "exclamationmark.circle")
                .font(.caption).foregroundStyle(.orange)
                .lineLimit(3)
        }
    }

    private func stop() async {
        stopping = true
        defer { stopping = false }
        if await link.stopRun(pillId: session.id) {
            Haptics.impact()
        } else {
            error = link.lastPong ?? "Couldn't reach iCloud."
            Haptics.error()
        }
    }

    private func send() async {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        dictation.stop()
        focused = false
        sending = true
        defer { sending = false }
        error = nil
        guard await OwnerCheck.confirm(reason: "Send this instruction to Claude Code on your Mac") else {
            error = "Face ID didn't confirm. Nothing was sent."
            Haptics.warning()
            return
        }
        if let id = await link.sendInstruction(instruction, pillId: session.id, options: options) {
            sentAt = .now
            sentId = id
            text = ""
            // Plan mode is for one message: the next one acts on the plan.
            options.planFirst = false
            Haptics.success()
        } else {
            error = link.lastPong ?? "Couldn't reach iCloud."
            Haptics.error()
        }
    }
}

/// Speech to text on the iPhone (on-device when available). Not main-actor
/// bound: the audio tap and the recognizer call back on their own threads;
/// the published values are only set on the main actor.
@Observable
final class Dictation: @unchecked Sendable {
    var isRecording = false
    var transcript = ""
    /// The language heard, chosen next to the mic and remembered.
    var localeID: String = UserDefaults.standard.string(forKey: "dictationLocale")
        ?? Locale.preferredLanguages.first ?? "en-US" {
        didSet { UserDefaults.standard.set(localeID, forKey: "dictationLocale") }
    }

    /// The iPhone's languages first, then French and English.
    static var languages: [String] {
        var ids: [String] = []
        for id in Locale.preferredLanguages + ["fr-FR", "en-US"] where !ids.contains(id) {
            if SFSpeechRecognizer(locale: Locale(identifier: id)) != nil { ids.append(id) }
        }
        return ids
    }

    static func shortName(_ id: String) -> String {
        String(Locale(identifier: id).language.languageCode?.identifier.uppercased().prefix(2) ?? "?")
    }
    /// What was typed before dictating, kept in front of the words.
    var prefix = ""

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    @MainActor func toggle(startingFrom text: String) async {
        if isRecording { stop(); return }
        guard await Self.authorized() else { return }
        prefix = text.isEmpty || text.hasSuffix(" ") ? text : text + " "
        transcript = ""
        start()
    }

    /// Not main-actor bound, so the audio and speech callbacks made here don't
    /// inherit the main actor (they run on their own threads).
    nonisolated private func start() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            return
        }
        self.request = request
        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let words { self.transcript = words }
                if done { self.stop() }
            }
        }
    }

    @MainActor func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// The shortcuts above the instruction field, kept on this iPhone.
enum QuickReplies {
    private static let key = "quickReplies"
    static let defaults = ["Continue", "Run the tests", "Fix the errors", "Commit the changes", "Explain what you changed"]

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? defaults
    }

    static func save(_ replies: [String]) {
        UserDefaults.standard.set(replies, forKey: key)
    }
}
