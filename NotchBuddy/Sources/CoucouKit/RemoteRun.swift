import Foundation

// Runs of Claude Code started from the iPhone, shared by the Mac and the
// iPhone. The iPhone writes an `Instruction` record (continue a session, start
// one in a known project, or stop a run); the Mac answers with a `RunStatus`
// per session pill, and lists the projects a session can start in
// (`Projects`). Folders come only from what the Mac saw in the hooks: the
// iPhone picks a project by its id, it never sends a path.

/// Options of one run, each from a fixed list (the Mac checks them again).
struct RunOptions: Codable, Hashable, Sendable {
    /// "" (the session's own), "opus", "sonnet" or "haiku": `claude --model`.
    var model: String = ""
    /// Plans only, changes nothing: `--permission-mode plan`.
    var planFirst: Bool = false

    static let models = ["opus", "sonnet", "haiku"]

    var isDefault: Bool { model.isEmpty && !planFirst }

    /// The flags for `claude`, never anything outside the lists above.
    var arguments: [String] {
        var args: [String] = []
        if Self.models.contains(model) { args += ["--model", model] }
        if planFirst { args += ["--permission-mode", "plan"] }
        return args
    }

    var label: String {
        var parts: [String] = []
        if !model.isEmpty { parts.append(model.capitalized) }
        if planFirst { parts.append("Plan") }
        return parts.joined(separator: " · ")
    }
}

/// Where a run from the iPhone stands, one per session pill.
struct RunStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case queued, running, finished, failed, stopped, ignored
    }

    var pillId: String
    var state: State
    /// Why it was ignored or failed, or where it runs ("api on build-server").
    var detail: String
    /// The Instruction record it answers, so the iPhone knows it's about its message.
    var instructionId: String
    /// Messages waiting behind this one.
    var queued: Int = 0
    var updatedAt: Date

    static let recordType = "RunStatus"
    static func recordName(for pillId: String) -> String { "runstatus-\(pillId)" }

    var isActive: Bool { state == .queued || state == .running }
}

/// A folder a session can start in, on this Mac or on an SSH host.
struct RunProject: Codable, Hashable, Identifiable, Sendable {
    /// Stable for a place and folder.
    var id: String
    /// "Mac", or the SSH host as written in ~/.ssh/config.
    var place: String
    /// The host's own name (what the hook reports), "" on the Mac.
    var hostName: String
    var cwd: String
    var lastUsed: Date

    var name: String { URL(fileURLWithPath: cwd).lastPathComponent }
    var isRemote: Bool { !hostName.isEmpty }

    static func id(place: String, cwd: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in "\(place)\n\(cwd)".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }

    /// The pill a new session started here shows on.
    func pillId(sessionId: String) -> String {
        isRemote ? PillCatalog.sshPillId(host: hostName, sessionId: sessionId) : "integration_claude"
    }
}

/// A place a session can start in: this Mac, or an SSH host connected now.
struct RunHost: Codable, Hashable, Sendable {
    /// "Mac", or the ssh alias.
    var place: String
    /// The host's own name (what the hook reports), "" on the Mac.
    var hostName: String

    var isRemote: Bool { !hostName.isEmpty }

    /// The pill a new session started there shows on.
    func pillId(sessionId: String) -> String {
        isRemote ? PillCatalog.sshPillId(host: hostName, sessionId: sessionId) : "integration_claude"
    }
}

struct RunProjectList: Codable, Equatable, Sendable {
    var projects: [RunProject]
    /// Every place, also those with no project yet (optional: older Macs).
    var hosts: [RunHost]? = nil
    static let recordType = "Projects"
    static let recordName = "projects"
}

/// The folders in one folder of a place, listed by the Mac for the iPhone's
/// folder browser (New session → Choose a folder).
struct FolderListing: Codable, Equatable, Sendable {
    /// The Instruction record that asked for it.
    var requestId: String
    var place: String
    /// Absolute, as the host resolved it ("~" becomes the home folder).
    var path: String
    var folders: [String]
    var error: String = ""

    static let recordType = "FolderListing"
    static let recordName = "folders"

    /// A folder the iPhone may ask for: "~", or absolute, no "..", no control
    /// characters. The host still checks it exists (cd fails otherwise).
    static func isSafePath(_ path: String) -> Bool {
        guard path == "~" || path.hasPrefix("/"), path.count <= 1024 else { return false }
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        return !path.split(separator: "/").contains("..")
    }

    /// The folder above, nil at the top.
    static func parent(of path: String) -> String? {
        guard path != "/", path != "~" else { return nil }
        let up = (path as NSString).deletingLastPathComponent
        return up.isEmpty ? "/" : up
    }
}
