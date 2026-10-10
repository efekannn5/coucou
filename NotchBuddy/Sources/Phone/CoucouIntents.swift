import AppIntents
import Foundation

// Siri and the Shortcuts app, in English and Turkish: ask where your agents
// are and what Claude answered, send a session its next instruction, start a
// task in a project, allow or deny the command waiting for your OK. Sending,
// starting and deciding need the iPhone unlocked by its owner, like Face ID
// in the app; Siri reads the command out before it's allowed.

/// Siri's answers in the iPhone's language (English or Turkish).
enum SiriText {
    static var turkish: Bool { Locale.preferredLanguages.first?.hasPrefix("tr") == true }
    static func say(_ english: String, _ turkish: String) -> String { Self.turkish ? turkish : english }

    /// One session, read out: "my-app, Terminal: working, now Bash."
    static func line(_ session: SessionItem) -> String {
        let status: String
        switch session.urgency {
        case 0:
            let command = session.approvalCommand.isEmpty ? "" : ": \(session.approvalCommand.prefix(80))"
            status = say("waiting for your OK", "onayını bekliyor") + command
        case 1: status = say("has a question for you", "sana bir soru soruyor")
        case 2: status = say("ran into an error", "hata verdi")
        case 3:
            let step = session.currentStep.map { say(", now ", ", şu an ") + String($0.prefix(60)) } ?? ""
            status = say("working", "çalışıyor") + step
        case 4: status = say("is done", "işini bitirdi")
        default: status = say("idle", "boşta")
        }
        return "\(session.title), \(session.pillName): \(status)."
    }
}

/// A Claude Code session on the Mac, for Siri and Shortcuts.
struct SessionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Session"
    static let defaultQuery = SessionQuery()

    let id: String
    let title: String
    let agent: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(agent)")
    }

    init(_ session: SessionItem) {
        id = session.id
        title = session.title
        agent = session.pillName
    }
}

struct SessionQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [SessionEntity] {
        PhoneLink.shared.sessions.filter { identifiers.contains($0.id) }.map(SessionEntity.init)
    }

    /// The sessions that take instructions, latest first.
    @MainActor func suggestedEntities() async throws -> [SessionEntity] {
        await PhoneLink.shared.refresh()
        return PhoneLink.shared.sessions.filter(\.acceptsInstructions)
            .sorted { $0.updatedAt > $1.updatedAt }.map(SessionEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [SessionEntity] {
        try await suggestedEntities().filter {
            $0.title.localizedCaseInsensitiveContains(string) || $0.agent.localizedCaseInsensitiveContains(string)
        }
    }
}

/// A folder the Mac can start a session in, for Siri and Shortcuts.
struct ProjectEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Project"
    static let defaultQuery = ProjectQuery()

    let id: String
    let name: String
    let place: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(place == "Mac" ? SiriText.say("this Mac", "bu Mac") : place)")
    }

    init(_ project: RunProject) {
        id = project.id
        name = project.name
        place = project.place
    }
}

struct ProjectQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ProjectEntity] {
        PhoneLink.shared.projects.filter { identifiers.contains($0.id) }.map(ProjectEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [ProjectEntity] {
        await PhoneLink.shared.refresh()
        return PhoneLink.shared.projects.map(ProjectEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [ProjectEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct AgentsStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Agent status"
    static var description: IntentDescription { IntentDescription("What your agents are doing on your Mac.") }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = PhoneLink.shared
        await link.refresh()
        let sessions = link.sessions.sortedByUrgency()
        guard !sessions.isEmpty else {
            return .result(dialog: "\(SiriText.say("All quiet: no agent session on your Mac.", "Her şey sakin: Mac'te açık oturum yok."))")
        }
        let working = sessions.filter(\.isWorking).count
        let waiting = sessions.filter(\.isWaitingForYou).count
        var parts: [String] = []
        if waiting > 0 { parts.append(SiriText.say("\(waiting) waiting for you", "\(waiting) oturum seni bekliyor")) }
        if working > 0 { parts.append(SiriText.say("\(working) working", "\(working) oturum çalışıyor")) }
        let head = parts.isEmpty
            ? SiriText.say("Nothing is running.", "Şu an çalışan bir şey yok.")
            : parts.joined(separator: SiriText.say(", ", ", ")) + "."
        // The most urgent first, four at most: more is too long to listen to.
        let lines = sessions.prefix(4).map(SiriText.line).joined(separator: " ")
        return .result(dialog: "\(head) \(lines)")
    }
}

struct AskClaudeIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Claude"
    static var description: IntentDescription {
        IntentDescription("Sends the next instruction to a Claude Code session on your Mac or an SSH host.")
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Session")
    var session: SessionEntity?

    @Parameter(title: "Instruction")
    var instruction: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = PhoneLink.shared
        await link.refresh()
        let candidates = link.sessions.filter(\.acceptsInstructions).sorted { $0.updatedAt > $1.updatedAt }
        guard !candidates.isEmpty else {
            return .result(dialog: "\(SiriText.say("No Claude Code session takes instructions. Turn it on in Coucou's Settings on your Mac.", "Talimat alan bir Claude Code oturumu yok. Mac'te Coucou ayarlarından açabilirsin."))")
        }
        // Siri asks which one when there are several.
        let target: SessionEntity
        if let session {
            target = session
        } else if candidates.count == 1 {
            target = SessionEntity(candidates[0])
        } else {
            target = try await $session.requestDisambiguation(
                among: candidates.map(SessionEntity.init),
                dialog: "\(SiriText.say("Which session?", "Hangi oturum?"))")
        }
        var text = (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = try await $instruction.requestValue("\(SiriText.say("What should Claude do in \(target.title)?", "\(target.title) için Claude ne yapsın?"))")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return .result(dialog: "\(SiriText.say("Nothing to send.", "Gönderilecek bir şey yok."))") }
        guard await link.sendInstruction(text, pillId: target.id) != nil else {
            return .result(dialog: "\(SiriText.say("Couldn't reach iCloud. Nothing was sent.", "iCloud'a ulaşamadım, bir şey gönderilmedi."))")
        }
        return .result(dialog: "\(SiriText.say("Sent to Claude in \(target.title).", "\(target.title) oturumuna gönderdim, Claude başlıyor."))")
    }
}

struct StartTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a task"
    static var description: IntentDescription {
        IntentDescription("Starts a new Claude Code session in one of your projects, on your Mac or an SSH host.")
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Project")
    var project: ProjectEntity?

    @Parameter(title: "Task")
    var task: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = PhoneLink.shared
        await link.refresh()
        guard !link.projects.isEmpty else {
            return .result(dialog: "\(SiriText.say("Your Mac lists no project yet. Turn on instructions in Coucou's Settings on your Mac.", "Mac henüz proje listelemiyor. Mac'te Coucou ayarlarından talimatları açabilirsin."))")
        }
        let target: ProjectEntity
        if let project {
            target = project
        } else if link.projects.count == 1 {
            target = ProjectEntity(link.projects[0])
        } else {
            target = try await $project.requestDisambiguation(
                among: link.projects.map(ProjectEntity.init),
                dialog: "\(SiriText.say("In which project?", "Hangi projede?"))")
        }
        guard let chosen = link.projects.first(where: { $0.id == target.id }) else {
            return .result(dialog: "\(SiriText.say("That project isn't on your Mac's list anymore.", "Bu proje artık Mac'in listesinde yok."))")
        }
        var text = (task ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            text = try await $task.requestValue("\(SiriText.say("What should Claude do in \(chosen.name)?", "\(chosen.name) projesinde Claude ne yapsın?"))")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { return .result(dialog: "\(SiriText.say("Nothing to start.", "Başlatılacak bir şey yok."))") }
        guard let pillId = await link.startSession(text, in: chosen, options: RunOptions()) else {
            return .result(dialog: "\(SiriText.say("Couldn't reach iCloud. Nothing was started.", "iCloud'a ulaşamadım, bir şey başlatılmadı."))")
        }
        // Opening Coucou later shows that session.
        link.openPillId = pillId
        let place = chosen.isRemote ? chosen.place : SiriText.say("your Mac", "Mac'inde")
        return .result(dialog: "\(SiriText.say("Started in \(chosen.name) on \(place).", "\(chosen.name) projesinde başlattım, \(chosen.isRemote ? "\(chosen.place) sunucusunda" : place)."))")
    }
}

struct LastAnswerIntent: AppIntent {
    static let title: LocalizedStringResource = "What did Claude say"
    static var description: IntentDescription { IntentDescription("Reads out Claude's last answer in a session.") }

    @Parameter(title: "Session")
    var session: SessionEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = PhoneLink.shared
        await link.refresh()
        // The chosen session, else the one that moved last and has a turn.
        let pillId = session?.id ?? link.sessions
            .filter { link.turns[$0.id] != nil }
            .max { $0.updatedAt < $1.updatedAt }?.id
        guard let pillId, let turn = link.turns[pillId] else {
            return .result(dialog: "\(SiriText.say("No answer from Claude yet.", "Claude'dan henüz bir cevap yok."))")
        }
        let title = link.sessions.first { $0.id == pillId }?.title ?? turn.project
        if turn.endedAt == nil {
            let last = turn.actions.last.map { "\($0.tool) \($0.summary.prefix(60))" } ?? ""
            return .result(dialog: "\(SiriText.say("Claude is still working in \(title).", "Claude \(title) oturumunda hâlâ çalışıyor.")) \(last.isEmpty ? "" : SiriText.say("Last: ", "Son yaptığı: ") + last)")
        }
        let answer = PhoneMarkdownView.plain(turn.finalMessage).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else {
            return .result(dialog: "\(SiriText.say("Claude finished in \(title) without a message.", "Claude \(title) oturumunda mesaj yazmadan bitirdi."))")
        }
        let spoken = answer.count > 600 ? String(answer.prefix(600)) + "…" : answer
        return .result(dialog: "\(title): \(spoken)")
    }
}

/// Allow or deny by voice: Siri reads the command and asks to confirm.
struct DecideApprovalIntent: AppIntent {
    static let title: LocalizedStringResource = "Answer the waiting command"
    static var description: IntentDescription {
        IntentDescription("Allows or denies the command an agent is waiting on, after reading it out.")
    }
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    @Parameter(title: "Allow", default: true)
    var allow: Bool

    init() {}
    init(allow: Bool) { self.allow = allow }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let link = PhoneLink.shared
        await link.refresh()
        guard let session = link.sessions.sortedByUrgency()
            .first(where: { $0.needsApproval && !$0.approvalFingerprint.isEmpty }) else {
            return .result(dialog: "\(SiriText.say("Nothing is waiting for your OK.", "Onayını bekleyen bir şey yok."))")
        }
        let command = session.approvalCommand.isEmpty ? session.title : String(session.approvalCommand.prefix(160))
        let question = allow
            ? SiriText.say("\(session.title) wants to run: \(command). Allow it?", "\(session.title) şunu çalıştırmak istiyor: \(command). Onaylıyor musun?")
            : SiriText.say("Deny \(command) in \(session.title)?", "\(session.title) oturumundaki \(command) reddedilsin mi?")
        try await requestConfirmation(conditions: [], actionName: .go, dialog: "\(question)")
        let summary = String(command.prefix(200))
        let sent = allow
            ? await link.allowFromOutside(fingerprint: session.approvalFingerprint, pillId: session.id, from: "Siri")
            : await link.decide(.deny, fingerprint: session.approvalFingerprint, pillId: session.id, summary: summary)
        guard sent else {
            return .result(dialog: "\(SiriText.say("Couldn't reach iCloud. Nothing was sent.", "iCloud'a ulaşamadım, bir şey gönderilmedi."))")
        }
        return .result(dialog: "\(allow ? SiriText.say("Allowed.", "Onaylandı.") : SiriText.say("Denied.", "Reddedildi."))")
    }
}

struct CoucouShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AgentsStatusIntent(),
                    phrases: ["What are my agents doing in \(.applicationName)",
                              "\(.applicationName) status",
                              "Agent status in \(.applicationName)",
                              "How is \(.applicationName) doing"],
                    shortTitle: "Agent status",
                    systemImageName: "sparkles")
        AppShortcut(intent: AskClaudeIntent(),
                    phrases: ["Ask Claude in \(.applicationName)",
                              "Tell Claude with \(.applicationName)",
                              "Send an instruction with \(.applicationName)",
                              "Give \(.applicationName) a job"],
                    shortTitle: "Ask Claude",
                    systemImageName: "text.bubble")
        AppShortcut(intent: StartTaskIntent(),
                    phrases: ["Start a task in \(.applicationName)",
                              "New task with \(.applicationName)",
                              "Start a new session in \(.applicationName)"],
                    shortTitle: "Start a task",
                    systemImageName: "square.and.pencil")
        AppShortcut(intent: LastAnswerIntent(),
                    phrases: ["What did Claude say in \(.applicationName)",
                              "Read the last answer in \(.applicationName)",
                              "What did \(.applicationName) say"],
                    shortTitle: "Last answer",
                    systemImageName: "text.quote")
        AppShortcut(intent: DecideApprovalIntent(allow: true),
                    phrases: ["Allow the command in \(.applicationName)",
                              "Approve in \(.applicationName)"],
                    shortTitle: "Allow",
                    systemImageName: "checkmark.shield")
        AppShortcut(intent: DecideApprovalIntent(allow: false),
                    phrases: ["Deny the command in \(.applicationName)",
                              "Reject in \(.applicationName)"],
                    shortTitle: "Deny",
                    systemImageName: "xmark.shield")
    }
}

/// A Focus filter: in a Focus (Sleep, Work…), Coucou can keep quiet about
/// finished and failed agents and only notify what waits on you.
struct CoucouFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Coucou"
    static var description: IntentDescription {
        IntentDescription("Choose what Coucou notifies during this Focus.")
    }

    @Parameter(title: "Only approvals and questions", default: false)
    var onlyWaiting: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: onlyWaiting ? "Only approvals and questions" : "Everything")
    }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(onlyWaiting, forKey: PhoneSettings.focusOnlyWaitingKey)
        return .result()
    }
}
