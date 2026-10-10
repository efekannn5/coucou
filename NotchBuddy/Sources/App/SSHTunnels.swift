#if !APPSTORE
import AppKit
import Combine

// MARK: - SSH tunnels: Claude Code on remote machines, in the notch
//
// For each host the user turns on (Settings → Agents → SSH), Coucou keeps one
// `ssh -N -R` that forwards its hook socket to <host>:~/.coucou/nb.sock. The
// hook installed there (installHook) finds that socket, tags its events with
// the host name, and HookServer gives them the SSH pill — sessions, approvals
// and questions, on the Mac and the iPhone, like a local session.
//
// The terminal stays whatever the user likes (Termius, Terminal…): the tunnel
// is a separate connection that runs no command. Key authentication only:
// BatchMode=yes never asks for (or sends) a password, and an unknown host key
// is refused, not accepted. Idle cost: a sleeping child process per host.

@MainActor
final class SSHTunnels: ObservableObject {
    static let shared = SSHTunnels()

    enum Status: Equatable {
        case off, connecting, connected
        case failed(String)
    }

    static let hostsKey = "sshTunnelHosts"

    /// Hosts with a tunnel turned on, persisted.
    @Published private(set) var enabledHosts: [String] =
        UserDefaults.standard.stringArray(forKey: SSHTunnels.hostsKey) ?? []
    @Published private(set) var status: [String: Status] = [:]
    /// Whether ~/.coucou/nb-hook.py exists on the host (seen by the last probe).
    @Published private(set) var hookInstalled: [String: Bool] = [:]
    /// The host's own name (what its hook reports) → the ssh alias it was reached by.
    private var aliasByHostname: [String: String] = [:]

    /// The ssh alias of a host connected now, from the name its hook reports.
    func alias(forRemoteHost name: String) -> String? {
        guard let alias = aliasByHostname[name], enabledHosts.contains(alias) else { return nil }
        return alias
    }

    /// The name a connected host's hook reports, from its ssh alias.
    func hostName(forAlias alias: String) -> String? {
        aliasByHostname.first { $0.value == alias }?.key
    }

    private var processes: [String: Process] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var attempts: [String: Int] = [:]

    private var wakeObserver: NSObjectProtocol?

    private init() {}

    // MARK: Hosts

    /// Host aliases from ~/.ssh/config (no wildcards, no negations).
    static func configHosts() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for alias in parts.dropFirst().map(String.init)
            where isValidHost(alias) && !hosts.contains(alias) {
                hosts.append(alias)
            }
        }
        return hosts
    }

    /// Letters, digits and . _ - @ only, never starting with "-" (so it can't
    /// be read as an ssh option), no wildcard.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 128, !host.hasPrefix("-") else { return false }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-@".contains($0)) }
    }

    func setEnabled(_ on: Bool, host: String) {
        guard Self.isValidHost(host) else { return }
        if on {
            if !enabledHosts.contains(host) { enabledHosts.append(host) }
            attempts[host] = 0
            connect(host)
        } else {
            enabledHosts.removeAll { $0 == host }
            disconnect(host)
            status[host] = .off
        }
        UserDefaults.standard.set(enabledHosts, forKey: Self.hostsKey)
    }

    // MARK: Lifecycle

    func start() {
        Self.endOrphanedTunnels()
        for host in enabledHosts where processes[host] == nil { connect(host) }
        // After sleep the network is back before the next retry (up to 2 min):
        // reconnect the hosts that are down right away.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    let tunnels = SSHTunnels.shared
                    for host in tunnels.enabledHosts where tunnels.status[host] != .connected {
                        tunnels.attempts[host] = 0
                        tunnels.connect(host)
                    }
                }
            }
        }
    }

    /// Tunnels left by a previous run that didn't quit cleanly (crash, force
    /// quit) keep holding the remote socket. Only ours: adopted by launchd,
    /// `ssh -N -T`, forwarding to this app's own socket.
    private static func endOrphanedTunnels() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        ps.waitUntilExit()
        let forward = "/.coucou/nb.sock:\(HookServer.socketPath) "
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, fields[1] == "1", let pid = Int32(fields[0]) else { continue }
            let command = String(fields[2])
            guard command.hasPrefix("/usr/bin/ssh "), command.contains(" -N -T "), command.contains(forward) else { continue }
            kill(pid, SIGTERM)
            appendAppLog("nb.log", "[SSH] ended a tunnel left by a previous run (pid \(pid))")
        }
    }

    func stopAll() {
        for host in Array(processes.keys) { disconnect(host) }
    }

    private func disconnect(_ host: String) {
        retryTasks[host]?.cancel()
        retryTasks[host] = nil
        if let process = processes.removeValue(forKey: host), process.isRunning { process.terminate() }
    }

    private func connect(_ host: String) {
        disconnect(host)
        status[host] = .connecting
        retryTasks[host] = Task { [weak self] in
            guard let self else { return }
            let probe = await Self.ssh(host, command: "python3 -I -", input: Data(Self.probeScript.utf8), timeout: 20)
            guard !Task.isCancelled, self.enabledHosts.contains(host) else { return }
            guard probe.status == 0, let home = Self.value("HOME", in: probe.out) else {
                self.fail(host, Self.reason(probe.err, fallback: "can't reach the host"))
                return
            }
            self.hookInstalled[host] = Self.value("HOOK", in: probe.out) == "yes"
            if let name = Self.value("HOSTNAME", in: probe.out) { self.aliasByHostname[name] = host }
            if probe.out.contains("BUSY") {
                // Another tunnel (another Mac, scripts/coucou-ssh) owns the socket.
                self.fail(host, "socket in use by another connection")
                return
            }
            guard home.hasPrefix("/"), !home.contains(":"), !home.contains(where: \.isWhitespace) else {
                self.fail(host, "unsupported home path")
                return
            }
            self.launchTunnel(host, remoteSocket: home + "/.coucou/nb.sock")
        }
    }

    private func launchTunnel(_ host: String, remoteSocket: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.baseOptions + [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
            "-R", "\(remoteSocket):\(HookServer.socketPath)",
            host,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let code = proc.terminationStatus
            Task { @MainActor in self?.tunnelEnded(host, process: proc, code: code, err: err) }
        }
        do {
            try process.run()
        } catch {
            fail(host, error.localizedDescription)
            return
        }
        processes[host] = process
        // ssh -N says nothing once the forward is up: still running after a
        // few seconds means connected.
        retryTasks[host] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, !Task.isCancelled, self.processes[host] === process, process.isRunning else { return }
            self.status[host] = .connected
            self.attempts[host] = 0
            self.log("\(host): tunnel up")
        }
    }

    private func tunnelEnded(_ host: String, process: Process, code: Int32, err: String) {
        guard processes[host] === process else { return }   // replaced or stopped on purpose
        processes[host] = nil
        fail(host, Self.reason(err, fallback: "connection closed (\(code))"))
    }

    /// Marks the host failed and tries again later: 10 s, 20 s, 40 s… up to 2 min.
    private func fail(_ host: String, _ reason: String) {
        status[host] = .failed(reason)
        log("\(host): \(reason)")
        guard enabledHosts.contains(host) else { return }
        let n = attempts[host, default: 0]
        attempts[host] = n + 1
        let delay = min(120, 10 * (1 << min(n, 4)))
        retryTasks[host] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.enabledHosts.contains(host) else { return }
            self.connect(host)
        }
    }

    // MARK: Remote hook install

    /// Copies nb-hook and nb-hook.py to <host>:~/.coucou/, then returns the
    /// diff Coucou's hooks would make to <host>:~/.claude/settings.json
    /// ("" when nothing changes). Nothing is written to settings.json here.
    func prepareInstall(host: String) async throws -> String {
        guard Self.isValidHost(host) else { throw SSHError("invalid host") }
        let dir = URL(fileURLWithPath: HookServer.hookScriptPath).deletingLastPathComponent()
        for name in ["nb-hook", "nb-hook.py"] {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else {
                throw SSHError("missing \(name) in \(dir.path)")
            }
            let copy = await Self.ssh(host, command:
                "umask 077 && mkdir -p ~/.coucou && cat > ~/.coucou/\(name).tmp && chmod 755 ~/.coucou/\(name).tmp && mv ~/.coucou/\(name).tmp ~/.coucou/\(name)",
                input: data, timeout: 30)
            guard copy.status == 0 else { throw SSHError(Self.reason(copy.err, fallback: "copy failed")) }
        }
        hookInstalled[host] = true
        let preview = await Self.ssh(host, command: "python3 -I -", input: Data(Self.mergeScript.utf8), timeout: 30)
        guard preview.status == 0 else { throw SSHError(Self.reason(preview.err, fallback: "preview failed")) }
        return preview.out == "UNCHANGED\n" ? "" : preview.out
    }

    /// Writes the merge shown by prepareInstall, after the user confirmed it.
    /// A dated backup of the previous settings.json stays next to it.
    func confirmInstall(host: String) async throws -> String {
        guard Self.isValidHost(host) else { throw SSHError("invalid host") }
        let write = await Self.ssh(host, command: "python3 -I - --write", input: Data(Self.mergeScript.utf8), timeout: 30)
        guard write.status == 0 else { throw SSHError(Self.reason(write.err, fallback: "write failed")) }
        return write.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct SSHError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    // MARK: Helpers

    /// Key authentication only, never a prompt; an unknown host key fails.
    private nonisolated static let baseOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "ControlMaster=no", "-o", "ControlPath=none",
    ]

    /// An ssh Process (not started) that runs `command` on the host, key only.
    nonisolated static func process(host: String, command: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = baseOptions + [host, command]
        return process
    }

    /// Single-quotes a value for the remote POSIX shell.
    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs one command on a host (key only), off the main thread: its status and output.
    nonisolated static func run(host: String, command: String, timeout: TimeInterval = 15) async -> (status: Int32, out: String) {
        let output = await ssh(host, command: command, input: Data(), timeout: timeout)
        return (output.status, output.out)
    }

    private struct Output: Sendable { let status: Int32; let out: String; let err: String }

    /// Runs one ssh command off the main thread, with stdin and a timeout.
    private nonisolated static func ssh(_ host: String, command: String, input: Data, timeout: TimeInterval) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = baseOptions + [host, command]
                let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
                process.standardInput = inPipe
                process.standardOutput = outPipe
                process.standardError = errPipe
                do { try process.run() } catch {
                    continuation.resume(returning: Output(status: -1, out: "", err: error.localizedDescription))
                    return
                }
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
                // Read both pipes at once so a full one can't stall the other.
                final class Box: @unchecked Sendable { var data = Data() }   // written once, read after wait()
                let errBox = Box()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile() }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                let errData = errBox.data
                process.waitUntilExit()
                timer.cancel()
                continuation.resume(returning: Output(status: process.terminationStatus,
                                                      out: String(data: outData, encoding: .utf8) ?? "",
                                                      err: String(data: errData, encoding: .utf8) ?? ""))
            }
        }
    }

    private static func value(_ key: String, in output: String) -> String? {
        output.split(separator: "\n").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    /// A short, human reason from ssh's stderr.
    private static func reason(_ err: String, fallback: String) -> String {
        if err.contains("Host key verification failed") || err.contains("No ED25519 host key")
            || err.contains("host key for") {
            return "host key not verified: connect once with ssh in Terminal"
        }
        if err.contains("Permission denied") { return "key refused (no password is ever sent)" }
        if err.contains("python3") && err.contains("not found") { return "python3 missing on the host" }
        if err.contains("remote port forwarding failed") { return "forwarding refused by the host" }
        // isNewline, not "\n": ssh ends lines with "\r\n", a single Character in Swift.
        let line = err.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return line.isEmpty ? fallback : String(line.prefix(120))
    }

    private func log(_ message: String) {
        appendAppLog("nb.log", "[SSH] \(message)")
    }

    // MARK: Remote scripts (run with python3 -I, read from stdin)

    /// Makes ~/.coucou (0700), removes a stale socket left by a dropped
    /// connection, and reports the home path and whether the hook is there.
    private static let probeScript = #"""
import os, socket
d = os.path.expanduser("~/.coucou")
os.makedirs(d, mode=0o700, exist_ok=True)
os.chmod(d, 0o700)
p = os.path.join(d, "nb.sock")
if os.path.exists(p):
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(1)
    try:
        s.connect(p)
        s.sendall(b"\n")
        print("BUSY")
    except Exception:
        os.remove(p)
    finally:
        s.close()
print("HOME=" + os.path.expanduser("~"))
print("HOSTNAME=" + socket.gethostname()[:64])
print("HOOK=" + ("yes" if os.path.exists(os.path.join(d, "nb-hook.py")) else "no"))
"""#

    /// Same events and timeouts as HookServer.buildHooksData(). Without
    /// --write: prints the unified diff (or UNCHANGED). With --write: dated
    /// backup, then an atomic replace.
    private static let mergeScript = #"""
import json, os, sys, time, difflib
write = sys.argv[1:] == ["--write"]
path = os.path.expanduser("~/.claude/settings.json")
cmd = '/bin/sh "%s"' % os.path.expanduser("~/.coucou/nb-hook")
before = open(path).read() if os.path.exists(path) else ""
settings = json.loads(before) if before.strip() else {}
hooks = settings.setdefault("hooks", {})
events = [("SessionStart", 10), ("SessionEnd", 10), ("UserPromptSubmit", 10),
          ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
          ("PermissionRequest", 120), ("Notification", 10), ("Stop", 10),
          ("StopFailure", 10), ("SubagentStart", 10), ("SubagentStop", 10)]
def ours(group):
    return any("coucou" in h.get("command", "") or "NotchBuddy" in h.get("command", "")
               for h in group.get("hooks", []))
for event, timeout in events:
    groups = [g for g in hooks.get(event, []) if not ours(g)]
    groups.append({"hooks": [{"type": "command", "command": cmd, "timeout": timeout}]})
    hooks[event] = groups
hooks["PreToolUse"].append({"matcher": "AskUserQuestion",
    "hooks": [{"type": "command", "command": cmd + " --ask", "timeout": 130}]})
after = json.dumps(settings, indent=2, sort_keys=True) + "\n"
if after == before:
    print("UNCHANGED")
    sys.exit(0)
if not write:
    sys.stdout.writelines(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                                               "settings.json", "settings.json (Coucou)"))
    sys.exit(0)
os.makedirs(os.path.dirname(path), exist_ok=True)
if before:
    backup = path + ".coucou-backup-" + time.strftime("%Y%m%d-%H%M%S")
    open(backup, "w").write(before)
    print("Backup: " + backup)
tmp = path + ".coucou-tmp"
open(tmp, "w").write(after)
os.replace(tmp, path)
print("Written: " + path)
"""#
}
#endif
