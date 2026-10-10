#if PHONE_LINK && !APPSTORE
import AppKit
import CloudKit

// MARK: - Instructions from the iPhone
//
// The iPhone writes an `Instruction` record (text encrypted) for a session.
// When the user turned it on (Settings → General → iPhone, off by default),
// this Mac takes each instruction once (the record is deleted on read): on
// iCloud's silent push, else within 15 s. It continues that same Claude Code
// conversation in the background, `claude -p <text> --resume <session id>`,
// in the session's own folder, here or on its SSH host. The folder and the
// session come from what this Mac saw in the hooks, never from the iPhone.
// Hooks keep working, so the notch, the iPhone and the permission requests
// (approved by hand, with Face ID on the phone) follow the run like any
// other turn.
//
// The iPhone can also start a session in a project this Mac lists
// (`Projects`, picked by id), stop a run it started, and pick a model or
// plan mode. Each session pill gets a `RunStatus` back: queued, running,
// finished, failed or ignored, with the reason, so nothing is dropped
// silently. A message sent while a run goes on waits for it.
// GitHub build only: the App Store build is sandboxed and can't start `claude`.

@MainActor
final class InstructionRunner {
    static let shared = InstructionRunner()

    nonisolated static let enabledKey = "iPhoneInstructionsEnabled"
    nonisolated static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    private var database: CKDatabase { CKContainer(identifier: CloudProbe.containerID).privateCloudDatabase }
    private var pollTask: Task<Void, Never>?
    private var changeToken: CKServerChangeToken?
    private var checking = false

    /// One message to run, checked.
    private struct Job {
        let instructionId: String
        let pillId: String
        let sessionId: String
        let cwd: String
        let text: String
        let options: RunOptions
        /// Starts the session (`--session-id`) instead of resuming it.
        let isNew: Bool
        /// The SSH host it runs on, nil on this Mac.
        let alias: String?

        var place: String {
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            return alias.map { "\(folder) on \($0)" } ?? folder
        }
    }

    private var running: [String: (process: Process, job: Job)] = [:]   // by session id
    private var waiting: [String: [Job]] = [:]                            // by session id
    private var stopping: Set<String> = []
    /// When each run ended, by session id: its SessionEnd hook can land just after.
    private var finishedAt: [String: Date] = [:]
    private var publishedProjectIds: [String]?
    private var statusWrite: Task<Void, Never>?

    /// Instructions older than this are dropped instead of run.
    private let maxAge: TimeInterval = 10 * 60
    private let maxWaiting = 5

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on && CloudProbe.isEnabled { start() } else { stop() }
    }

    func startIfEnabled() {
        if Self.isEnabled { start() }
    }

    func start() {
        guard pollTask == nil else { return }
        log("on: checking for instructions on iCloud pushes and every 15 s")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    func stop() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        // The iPhone stops offering new sessions.
        publishedProjectIds = nil
        let id = CKRecord.ID(recordName: RunProjectList.recordName, zoneID: SessionSnapshot.zoneID)
        Task { _ = try? await database.modifyRecords(saving: [], deleting: [id]) }
        log("off")
    }

    /// A CloudKit push came in: an instruction may be waiting.
    func checkNow() async {
        guard pollTask != nil else { return }
        await check()
    }

    /// Whether a session's hook events come from a run started here. Its
    /// SessionEnd only ends the `claude -p` run, not the session in the
    /// terminal or editor: the pill (and the iPhone's chat) must stay.
    func isOwnRun(sessionId: String) -> Bool {
        if running[sessionId] != nil || !(waiting[sessionId] ?? []).isEmpty { return true }
        guard let ended = finishedAt[sessionId] else { return false }
        return Date().timeIntervalSince(ended) < 30
    }

    // MARK: Reading

    private func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        await publishProjects()
        var found: [CKRecord] = []
        do {
            var more = true
            while more {
                let changes = try await database.recordZoneChanges(inZoneWith: SessionSnapshot.zoneID, since: changeToken)
                for (_, result) in changes.modificationResultsByID {
                    if case .success(let mod) = result, mod.record.recordType == "Instruction" { found.append(mod.record) }
                }
                changeToken = changes.changeToken
                more = changes.moreComing
            }
        } catch let error as CKError where error.code == .changeTokenExpired {
            changeToken = nil
            return
        } catch {
            return
        }
        guard !found.isEmpty else { return }
        // Single use: gone from iCloud before anything runs.
        _ = try? await database.modifyRecords(saving: [], deleting: found.map(\.recordID))
        for record in found.sorted(by: { ($0["createdAt"] as? Date ?? .distantPast) < ($1["createdAt"] as? Date ?? .distantPast) }) {
            handle(record)
        }
    }

    private func handle(_ record: CKRecord) {
        let instructionId = record.recordID.recordName
        let kind = record["kind"] as? String ?? "run"
        let pillId = record["pillId"] as? String ?? ""
        let createdAt = record["createdAt"] as? Date ?? .distantPast
        let text = (record.encryptedValues["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let model = record["model"] as? String ?? ""
        let options = RunOptions(model: RunOptions.models.contains(model) ? model : "",
                                 planFirst: record["planFirst"] as? Bool ?? false)
        let accepted = PillCatalog.takesInstructions(pillId)
        // Only for a pill that can take instructions: a status is a record named after it.
        let ignore: (String) -> Void = { [weak self] reason in
            self?.log("ignored: \(reason)")
            if accepted { self?.report(pillId, .ignored, reason, instructionId) }
        }
        guard Self.isEnabled else { ignore("instructions are off on the Mac"); return }
        guard Date().timeIntervalSince(createdAt) < maxAge else { ignore("older than 10 min"); return }
        guard accepted || kind == "list" else { log("ignored: \(pillId) can't take instructions"); return }

        if kind == "stop" {
            stopRun(pillId: pillId, instructionId: instructionId)
            return
        }
        if kind == "list" {
            let place = record["place"] as? String ?? ""
            let path = record.encryptedValues["path"] as? String ?? "~"
            Task { await listFolders(place: place, path: path, requestId: instructionId) }
            return
        }
        guard !text.isEmpty, text.count <= 8000 else { ignore("empty or too long"); return }

        if kind == "new" {
            let projectId = record["projectId"] as? String ?? ""
            guard let sessionId = record["sessionId"] as? String, UUID(uuidString: sessionId) != nil,
                  sessionId == sessionId.lowercased() else { ignore("unexpected session id"); return }
            guard running[sessionId] == nil else {
                ignore("this session already exists")
                return
            }
            if projectId.isEmpty {
                // A folder picked in the folder browser, on a place connected now.
                let place = record["place"] as? String ?? ""
                let cwd = record.encryptedValues["cwd"] as? String ?? ""
                guard let host = currentHosts().first(where: { $0.place == place }) else {
                    ignore("\(place) isn't connected")
                    return
                }
                guard cwd.hasPrefix("/"), FolderListing.isSafePath(cwd) else { ignore("unexpected folder"); return }
                // The pill comes from the place, never from the iPhone.
                guard host.pillId(sessionId: sessionId) == pillId else { ignore("unexpected session"); return }
                enqueue(Job(instructionId: instructionId, pillId: pillId, sessionId: sessionId, cwd: cwd,
                            text: text, options: options, isNew: true, alias: host.isRemote ? host.place : nil))
                return
            }
            guard let project = currentProjects().first(where: { $0.id == projectId }) else {
                ignore("this project isn't on the Mac's list anymore")
                return
            }
            // The pill comes from the project, never from the iPhone.
            guard project.pillId(sessionId: sessionId) == pillId else { ignore("unexpected session"); return }
            enqueue(Job(instructionId: instructionId, pillId: pillId, sessionId: sessionId, cwd: project.cwd,
                        text: text, options: options, isNew: true, alias: project.isRemote ? project.place : nil))
            return
        }

        guard let session = TurnRecorder.shared.lastSession(for: pillId) else {
            ignore("no Claude Code session seen for this Mochi yet")
            return
        }
        guard session.sessionId.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
            ignore("unexpected session id")
            return
        }
        var alias: String?
        if PillCatalog.isSSH(pillId) {
            // Runs on the session's own host, through ssh (key only).
            guard let name = TurnRecorder.shared.lastRemoteHost(for: pillId),
                  let found = SSHTunnels.shared.alias(forRemoteHost: name) else {
                ignore("no SSH tunnel up for this session's host")
                return
            }
            alias = found
        }
        enqueue(Job(instructionId: instructionId, pillId: pillId, sessionId: session.sessionId, cwd: session.cwd,
                    text: text, options: options, isNew: false, alias: alias))
    }

    // MARK: Running

    private func enqueue(_ job: Job) {
        guard running[job.sessionId] != nil else { launch(job); return }
        var queue = waiting[job.sessionId] ?? []
        guard queue.count < maxWaiting else {
            log("ignored: \(maxWaiting) messages already wait for this session")
            report(job.pillId, .ignored, "\(maxWaiting) messages already wait for this session", job.instructionId)
            return
        }
        queue.append(job)
        waiting[job.sessionId] = queue
        log("queued behind the current run (\(job.sessionId.prefix(8))), \(queue.count) waiting")
        report(job.pillId, .queued, "after the current run", job.instructionId, queued: queue.count)
    }

    private func launch(_ job: Job) {
        let process: Process
        let flags = [job.isNew ? "--session-id" : "--resume", job.sessionId] + job.options.arguments
        if let alias = job.alias {
            // Its pid is kept on the host, so Stop can reach it there. claude
            // from the native installer, else the login shell's PATH.
            // Stops there when the folder is gone, never runs claude elsewhere.
            let remote = "mkdir -p \"$HOME/.coucou\" && cd -- \(SSHTunnels.shellQuote(job.cwd)) && "
                + "echo $$ > \(Self.remotePidFile(job.sessionId)) || exit 3; "
                + "c=\"$HOME/.local/bin/claude\"; [ -x \"$c\" ] || c=$(bash -lc 'command -v claude'); "
                + "exec \"$c\" -p \(SSHTunnels.shellQuote(job.text)) "
                + flags.map(SSHTunnels.shellQuote).joined(separator: " ")
            process = SSHTunnels.process(host: alias, command: remote)
        } else {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: job.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                log("ignored: the session's folder is gone")
                report(job.pillId, .ignored, "the session's folder is gone", job.instructionId)
                return
            }
            guard let claude = Self.claudeExecutable() else {
                log("can't find the claude command (looked in ~/.claude/local, Homebrew, /usr/local/bin, ~/.npm-global/bin)")
                report(job.pillId, .failed, "the claude command wasn't found on the Mac", job.instructionId)
                return
            }
            process = Process()
            process.executableURL = URL(fileURLWithPath: claude)
            process.arguments = ["-p", job.text] + flags
            process.currentDirectoryURL = URL(fileURLWithPath: job.cwd)
            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            env["PATH"] = [URL(fileURLWithPath: claude).deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin",
                           "/usr/bin", "/bin", "/usr/sbin", "/sbin", "\(home)/.local/bin", env["PATH"] ?? ""].joined(separator: ":")
            // The hooks route events by editor: keep them on the same pill.
            if job.pillId == "agent_cursor" {
                env["__CFBundleIdentifier"] = "com.todesktop.230313mzl4w4u92"
            } else if PillCatalog.isTerminal(job.pillId) {
                // The session's own terminal; the pill comes from the session id.
                env["__CFBundleIdentifier"] = AppState.shared.tasks.first { $0.id == job.pillId }?.hostApp
                    ?? "com.apple.Terminal"
            } else {
                env["TERM_PROGRAM"] = "vscode"
            }
            process.environment = env
        }
        start(process, job: job)
    }

    /// Starts a claude run (local, or on an SSH host) and reports how it ends.
    private func start(_ process: Process, job: Job) {
        process.standardInput = FileHandle.nullDevice
        // Output goes to a file (a pipe could fill up and stall claude); its
        // end is logged if the run fails.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchBuddy/instruction-last.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let output = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        let sessionId = job.sessionId
        process.terminationHandler = { [weak self] finished in
            try? output?.close()
            let data = (try? Data(contentsOf: logURL)) ?? Data()
            let tail = String(decoding: data.suffix(400), as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let status = finished.terminationStatus
            Task { @MainActor in self?.ended(sessionId: sessionId, status: status, tail: tail) }
        }
        do {
            try process.run()
            running[sessionId] = (process, job)
            log("running in \(job.place) (\(sessionId.prefix(8)))\(job.isNew ? ", new session" : ""): \(job.text.count) chars"
                + (job.options.isDefault ? "" : ", \(job.options.label)"))
            report(job.pillId, .running, job.place, job.instructionId, queued: waiting[sessionId]?.count ?? 0)
        } catch {
            log("couldn't start claude: \(error.localizedDescription)")
            report(job.pillId, .failed, "couldn't start claude: \(error.localizedDescription)", job.instructionId)
        }
    }

    private func ended(sessionId: String, status: Int32, tail: String) {
        guard let job = running.removeValue(forKey: sessionId)?.job else { return }
        finishedAt[sessionId] = Date()
        let next = waiting[sessionId]?.first
        if stopping.remove(sessionId) != nil {
            log("stopped (\(sessionId.prefix(8)))")
            report(job.pillId, .stopped, "", job.instructionId)
        } else if status == 0 {
            log("finished (\(sessionId.prefix(8)))")
            // The next message's status follows at once.
            if next == nil { report(job.pillId, .finished, "", job.instructionId) }
        } else if status == 3 && job.alias != nil && tail.isEmpty {
            log("the folder is gone on \(job.alias ?? "")")
            report(job.pillId, .failed, "the session's folder is gone on \(job.alias ?? "the host")", job.instructionId)
        } else {
            log("ended with \(status): \(tail)")
            report(job.pillId, .failed, tail.isEmpty ? "claude ended with code \(status)" : String(tail.suffix(200)),
                   job.instructionId)
        }
        guard let next else { return }
        waiting[sessionId]?.removeFirst()
        if waiting[sessionId]?.isEmpty == true { waiting[sessionId] = nil }
        // A resumed session from now on, even when the first run started it.
        launch(Job(instructionId: next.instructionId, pillId: next.pillId, sessionId: next.sessionId, cwd: next.cwd,
                   text: next.text, options: next.options, isNew: false, alias: next.alias))
    }

    // MARK: Stopping

    private func stopRun(pillId: String, instructionId: String) {
        guard let (sessionId, entry) = running.first(where: { $0.value.job.pillId == pillId }) else {
            log("stop: nothing runs for \(pillId)")
            report(pillId, .ignored, "nothing was running", instructionId)
            return
        }
        // What waited behind it goes too.
        waiting[sessionId] = nil
        stopping.insert(sessionId)
        log("stopping (\(sessionId.prefix(8)))")
        let process = entry.process
        if let alias = entry.job.alias {
            signalRemote(alias: alias, sessionId: sessionId, signal: "INT")
        } else {
            process.interrupt()
        }
        // Still there after 5 s: ended for good.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, process.isRunning else { return }
            if let alias = entry.job.alias { self.signalRemote(alias: alias, sessionId: sessionId, signal: "TERM") }
            process.terminate()
        }
    }

    /// Sends a signal to a run on an SSH host, through the pid it wrote there.
    private func signalRemote(alias: String, sessionId: String, signal: String) {
        let command = "p=$(cat \(Self.remotePidFile(sessionId)) 2>/dev/null) && [ -n \"$p\" ] && kill -\(signal) \"$p\""
        let process = SSHTunnels.process(host: alias, command: command)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// The session id is checked (letters, digits, hyphens) before it gets here.
    private static func remotePidFile(_ sessionId: String) -> String {
        "\"$HOME/.coucou/run-\(sessionId).pid\""
    }

    // MARK: Status and projects, for the iPhone

    private func report(_ pillId: String, _ state: RunStatus.State, _ detail: String, _ instructionId: String,
                        queued: Int = 0) {
        let status = RunStatus(pillId: pillId, state: state, detail: detail, instructionId: instructionId,
                               queued: queued, updatedAt: Date())
        guard let json = try? JSONEncoder().encode(status), let payload = String(data: json, encoding: .utf8) else { return }
        let record = CKRecord(recordType: RunStatus.recordType,
                              recordID: CKRecord.ID(recordName: RunStatus.recordName(for: pillId), zoneID: SessionSnapshot.zoneID))
        record["pillId"] = pillId
        record["updatedAt"] = status.updatedAt
        record.encryptedValues["payload"] = payload
        // One after the other: "running" never lands after "finished".
        let previous = statusWrite
        let database = database
        statusWrite = Task {
            await previous?.value
            do {
                _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            } catch {
                CloudProbe.shared.log("[instruction] status not saved: \(error.localizedDescription)")
            }
        }
    }

    /// The folders a session can start in: the ones sessions used, on this
    /// Mac and on SSH hosts connected now. Newest first, 30 at most.
    private func currentProjects() -> [RunProject] {
        var byId: [String: RunProject] = [:]
        for session in TurnRecorder.shared.knownSessions() {
            let place: String
            let hostName: String
            if let host = session.host {
                guard PillCatalog.isSSH(session.pillId),
                      let alias = SSHTunnels.shared.alias(forRemoteHost: host) else { continue }
                place = alias
                hostName = host
            } else {
                guard session.pillId == "integration_claude" || session.pillId == "agent_cursor"
                        || PillCatalog.isTerminal(session.pillId) else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: session.cwd, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                place = "Mac"
                hostName = ""
            }
            let id = RunProject.id(place: place, cwd: session.cwd)
            if let known = byId[id], known.lastUsed >= session.lastUsed { continue }
            byId[id] = RunProject(id: id, place: place, hostName: hostName, cwd: session.cwd, lastUsed: session.lastUsed)
        }
        return Array(byId.values.sorted { $0.lastUsed > $1.lastUsed }.prefix(30))
    }

    /// This Mac, and the SSH hosts whose tunnel is up.
    private func currentHosts() -> [RunHost] {
        var hosts = [RunHost(place: "Mac", hostName: "")]
        for alias in SSHTunnels.shared.enabledHosts where SSHTunnels.shared.status[alias] == .connected {
            if let name = SSHTunnels.shared.hostName(forAlias: alias) { hosts.append(RunHost(place: alias, hostName: name)) }
        }
        return hosts
    }

    /// Written when the list (or its order) changes, not at every use.
    private func publishProjects() async {
        let projects = currentProjects()
        let hosts = currentHosts()
        let ids = projects.map(\.id) + hosts.map { "host:\($0.place)" }
        guard ids != publishedProjectIds else { return }
        guard let json = try? JSONEncoder().encode(RunProjectList(projects: projects, hosts: hosts)),
              let payload = String(data: json, encoding: .utf8) else { return }
        let record = CKRecord(recordType: RunProjectList.recordType,
                              recordID: CKRecord.ID(recordName: RunProjectList.recordName, zoneID: SessionSnapshot.zoneID))
        record["updatedAt"] = Date()
        record.encryptedValues["payload"] = payload
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            publishedProjectIds = ids
            log("\(projects.count) project(s) offered to the iPhone")
        } catch {
            log("projects not saved: \(error.localizedDescription)")
        }
    }

    // MARK: Folder browser

    /// Lists the folders in one folder of a place, for the iPhone's folder browser.
    private func listFolders(place: String, path: String, requestId: String) async {
        var listing = FolderListing(requestId: requestId, place: place, path: path, folders: [])
        if !FolderListing.isSafePath(path) {
            listing.error = "unexpected folder"
        } else if let host = currentHosts().first(where: { $0.place == place }) {
            if host.isRemote {
                // Not hidden ones, 300 at most; the first line is where it is.
                let go = path == "~" ? "cd" : "cd -- \(SSHTunnels.shellQuote(path))"
                let command = "\(go) 2>/dev/null || exit 3; pwd; "
                    + "for d in */; do [ -d \"$d\" ] && printf '%s\\n' \"${d%/}\"; done | head -300"
                let result = await SSHTunnels.run(host: place, command: command)
                let lines = result.out.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                if result.status == 0, let first = lines.first {
                    listing.path = first
                    listing.folders = Array(lines.dropFirst())
                } else {
                    listing.error = result.status == 3 ? "this folder isn't there" : "couldn't reach \(place)"
                }
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                let full = path == "~" ? home : path
                if let names = try? FileManager.default.contentsOfDirectory(atPath: full) {
                    listing.path = full
                    listing.folders = names.filter { name in
                        var isDirectory: ObjCBool = false
                        return !name.hasPrefix(".")
                            && FileManager.default.fileExists(atPath: (full as NSString).appendingPathComponent(name),
                                                              isDirectory: &isDirectory)
                            && isDirectory.boolValue
                    }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.prefix(300).map { $0 }
                } else {
                    listing.error = "this folder isn't there"
                }
            }
        } else {
            listing.error = "\(place) isn't connected"
        }
        guard let json = try? JSONEncoder().encode(listing), let payload = String(data: json, encoding: .utf8) else { return }
        let record = CKRecord(recordType: FolderListing.recordType,
                              recordID: CKRecord.ID(recordName: FolderListing.recordName, zoneID: SessionSnapshot.zoneID))
        record["updatedAt"] = Date()
        record.encryptedValues["payload"] = payload
        do {
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
            log("listed \(listing.folders.count) folder(s) on \(place)\(listing.error.isEmpty ? "" : ": \(listing.error)")")
        } catch {
            log("folder list not saved: \(error.localizedDescription)")
        }
    }

    /// Where `claude` usually lives; the app doesn't get the shell's PATH.
    static func claudeExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.npm-global/bin/claude",
            "\(home)/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func log(_ message: String) {
        CloudProbe.shared.log("[instruction] \(message)")
    }
}
#endif
