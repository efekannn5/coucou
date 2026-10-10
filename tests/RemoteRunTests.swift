import Foundation

// Runs started from the iPhone (CoucouKit/RemoteRun.swift): the flags the Mac
// passes to `claude` come only from fixed lists, and a new session's pill is
// the one the Mac's hooks will route it to.

// PillCatalog pulls in most of the app: this stand-in records what the
// project asks for, so the test checks which host and session it passes.
enum PillCatalog {
    static func sshPillId(host: String, sessionId: String) -> String { "agent_ssh[\(host)|\(sessionId)]" }
}

@main
enum RemoteRunTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("RunOptions.arguments — only known models and modes")
        check("default → no flags", RunOptions().arguments.isEmpty)
        check("sonnet → --model sonnet", RunOptions(model: "sonnet").arguments == ["--model", "sonnet"])
        check("plan → --permission-mode plan",
              RunOptions(planFirst: true).arguments == ["--permission-mode", "plan"])
        for bad in ["opus; rm -rf ~", "--dangerously-skip-permissions", "OPUS", " sonnet"] {
            check("'\(bad)' → no flags", RunOptions(model: bad).arguments.isEmpty)
        }
        check("label", RunOptions(model: "opus", planFirst: true).label == "Opus · Plan")

        print("RunProject — ids and pills")
        let a = RunProject.id(place: "build-server", cwd: "/home/me/app")
        check("id is stable", a == RunProject.id(place: "build-server", cwd: "/home/me/app"))
        check("id depends on the place", a != RunProject.id(place: "Mac", cwd: "/home/me/app"))
        check("id is 16 hex", a.count == 16 && a.allSatisfy(\.isHexDigit))
        let session = "6f1d2c3b-1111-4222-8333-444455556666"
        let remote = RunProject(id: a, place: "build-server", hostName: "build01", cwd: "/home/me/app", lastUsed: .now)
        // The hook reports the host's own name, not the ssh alias.
        check("remote → SSH pill from the host's own name",
              remote.pillId(sessionId: session) == "agent_ssh[build01|\(session)]")
        let mac = RunProject(id: "x", place: "Mac", hostName: "", cwd: "/Users/me/app", lastUsed: .now)
        check("Mac → integration_claude", mac.pillId(sessionId: session) == "integration_claude")
        check("name is the folder", mac.name == "app")

        print("RunStatus — round trip")
        let status = RunStatus(pillId: "agent_ssh-1", state: .queued, detail: "after", instructionId: "i", queued: 2,
                               updatedAt: Date(timeIntervalSince1970: 1_000))
        let back = try? JSONDecoder().decode(RunStatus.self, from: JSONEncoder().encode(status))
        check("decodes the same", back == status)
        check("queued is active", status.isActive)

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("all passed")
    }
}
