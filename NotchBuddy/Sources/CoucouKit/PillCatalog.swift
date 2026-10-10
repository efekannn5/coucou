import Foundation

// MARK: - Pill category

enum PillCategory: String, CaseIterable {
    case workspace
    case agent
    case ai
    case service

    var title: String {
        switch self {
        case .workspace: return "Where you code"
        case .agent:     return "Agents"
        case .ai:        return "AI for the chat"
        case .service:   return "Services"
        }
    }
}

// MARK: - Pill definition

struct PillDefinition {
    let id:         String
    let name:       String
    /// The catalog's colour for this pill, whatever the user picked.
    let defaultColor: String
    let category:   PillCategory
    /// Label shown next to the task name in the idle card header.
    let subtitle:   String
    let source:     AgentSource
    var comingSoon: Bool = false
    var githubOnly: Bool = false

    /// The colour the pill is painted with: the user's own if they picked one
    /// (Settings → Active pills), else the catalog's.
    var color: String {
        PillColors.color(for: id, catalogColor: defaultColor, in: PillColors.stored)
    }

    init(id: String, name: String, color: String, category: PillCategory, subtitle: String,
         source: AgentSource, comingSoon: Bool = false, githubOnly: Bool = false) {
        self.id = id
        self.name = name
        self.defaultColor = color
        self.category = category
        self.subtitle = subtitle
        self.source = source
        self.comingSoon = comingSoon
        self.githubOnly = githubOnly
    }

    /// Label shown in the active-session card header (workspace/agent pills only).
    var sessionSubtitle: String {
        switch id {
        case "integration_claude": return "Claude Code"
        case "agent_cursor":       return "Cursor"
        case "agent_codex":        return "Codex"
        case "agent_hermes":       return "Hermes"
        case "agent_claude-desktop": return "Claude Desktop"
        case "agent_ssh":          return "Claude Code"
        case "agent_term":         return "Claude Code"
        default:                   return "Agent"
        }
    }
}

// MARK: - Catalog

enum PillCatalog {
    // All declared pills in display order.
    static let all: [PillDefinition] = [
        // ── Where you code ───────────────────────────────────────────────────
        .init(id: "integration_claude",  name: "VS Code",     color: "#F5F6F8",
              category: .workspace, subtitle: "Integration",  source: .claudeCode),
        .init(id: "agent_cursor",        name: "Cursor",      color: "#C0C4CC",
              category: .workspace, subtitle: "Integration",  source: .agent),
        .init(id: "agent_antigravity",   name: "Antigravity", color: "#E879F9",
              category: .workspace, subtitle: "Integration",  source: .agent,  githubOnly: true),
        .init(id: "agent_codex",         name: "Codex",       color: "#2DD4BF",
              category: .workspace, subtitle: "Integration",  source: .agent,  githubOnly: true),
        // ── Agents ───────────────────────────────────────────────────────────
        .init(id: "agent_gemini",        name: "Gemini CLI",  color: "#8AB4F8",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_copilot",       name: "Copilot CLI", color: "#818CF8",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_muse",          name: "Muse Code",   color: "#38BDF8",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_opencode",      name: "OpenCode",    color: "#4ADE80",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_amp",           name: "Amp",         color: "#F59E0B",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        .init(id: "agent_hermes",        name: "Hermes",      color: "#C084FC",
              category: .agent,     subtitle: "Agent",        source: .agent,  githubOnly: true),
        // Claude Code sessions run from the Claude desktop app: the relay tags them
        // `coucou_agent: claude-desktop` from CLAUDE_CODE_ENTRYPOINT, so nothing to install.
        .init(id: "agent_claude-desktop", name: "Claude Desktop", color: "#D97757",
              category: .agent,     subtitle: "Agent",        source: .agent),
        // Claude Code on remote machines, through Coucou's SSH tunnels (SSHTunnels.swift).
        .init(id: "agent_ssh",           name: "SSH",         color: "#A3E635",
              category: .agent,     subtitle: "Remote",       source: .agent,  githubOnly: true),
        // Claude Code in a terminal on this Mac (Terminal, iTerm, Warp…), one pill per session.
        .init(id: "agent_term",          name: "Terminal",    color: "#F59E0B",
              category: .agent,     subtitle: "Terminal",     source: .agent,  githubOnly: true),
        // ── AI for the chat ──────────────────────────────────────────────────
        .init(id: "ai_anthropic",        name: "Anthropic",   color: ChatProvider.anthropic.accentHex,
              category: .ai,        subtitle: "Chat",         source: .n8n),
        .init(id: "ai_google",           name: "Google AI",   color: ChatProvider.google.accentHex,
              category: .ai,        subtitle: "Chat",         source: .n8n),
        .init(id: "ai_openai",           name: "OpenAI",      color: ChatProvider.openai.accentHex,
              category: .ai,        subtitle: "Chat",         source: .n8n),
        .init(id: "ai_ollama",           name: "Ollama",      color: ChatProvider.ollama.accentHex,
              category: .ai,        subtitle: "Chat",         source: .n8n),
        .init(id: "ai_lmstudio",         name: "LM Studio",   color: ChatProvider.lmstudio.accentHex,
              category: .ai,        subtitle: "Chat",         source: .n8n),
        // ── Services ─────────────────────────────────────────────────────────
        .init(id: "integration_resend",  name: "Resend",      color: "#22C55E",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_n8n",     name: "n8n",         color: "#F29B38",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_vercel",  name: "Vercel",      color: "#7C5CFF",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_github",  name: "GitHub",      color: "#F4505E",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_notion",  name: "Notion",      color: "#8C8C8C",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_calcom",  name: "Cal.com",     color: "#C9956A",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_stripe",  name: "Stripe",      color: "#0570DE",
              category: .service,   subtitle: "Integration",  source: .n8n),
        .init(id: "integration_music",   name: "Apple Music", color: "#FA2D48",
              category: .service,   subtitle: "Integration",  source: .n8n, githubOnly: true),
        .init(id: "integration_spotify", name: "Spotify",     color: "#1DB954",
              category: .service,   subtitle: "Integration",  source: .n8n, githubOnly: true),
    ]

    /// Pills available in the current build target.
    static var available: [PillDefinition] {
        #if APPSTORE
        all.filter { !$0.githubOnly }
        #else
        all
        #endif
    }

    /// Default ID for the always-on main workspace pill.
    static let defaultMainPillId = "integration_claude"

    /// Looks up a definition by task ID (nil if not in catalog). Each SSH
    /// session's pill ("agent_ssh-…") uses the SSH pill's definition, each
    /// terminal session's ("agent_term-…") the Terminal pill's.
    static func definition(for id: String) -> PillDefinition? {
        if let found = all.first(where: { $0.id == id }) { return found }
        if isSSH(id) { return all.first { $0.id == "agent_ssh" } }
        if isTerminal(id) { return all.first { $0.id == "agent_term" } }
        return nil
    }

    /// The Terminal pill, or one local terminal session's own pill.
    static func isTerminal(_ id: String) -> Bool {
        id == "agent_term" || id.hasPrefix("agent_term-")
    }

    /// One pill per Claude Code session in a terminal on this Mac, so two
    /// terminals stay apart: "agent_term-" + 12 hex of a hash of the session.
    static func terminalPillId(sessionId: String) -> String {
        "agent_term-" + fnv12("local\u{1F}\(sessionId)")
    }

    /// A session pill that takes instructions from the iPhone (Claude Code).
    static func takesInstructions(_ id: String) -> Bool {
        id == "integration_claude" || id == "agent_cursor" || isSSH(id) || isTerminal(id)
    }

    /// The SSH pill, or one SSH session's own pill.
    static func isSSH(_ id: String) -> Bool {
        id == "agent_ssh" || id.hasPrefix("agent_ssh-")
    }

    /// One pill per remote Claude Code session, so two sessions on the same
    /// host stay apart: "agent_ssh-" + 12 hex of a hash of host and session.
    static func sshPillId(host: String, sessionId: String) -> String {
        "agent_ssh-" + fnv12("\(host)\u{1F}\(sessionId)")
    }

    /// FNV-1a 64, last 12 hex: stable across launches (Swift's Hasher is seeded per run).
    private static func fnv12(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(String(hash, radix: 16).suffix(12))
    }
}
