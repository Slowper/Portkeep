import SwiftUI

/// Who started a listening process, derived from its ancestor chain.
///
/// The most specific agent wins: a `next dev` started by Claude Code inside a
/// Cursor terminal is attributed to Claude Code, not Cursor.
enum ProcessOrigin: Hashable, Sendable {
    case claudeCode
    case codex
    case cursorAgent
    case cursor
    case geminiCLI
    case aider
    case openCode
    case vscode
    case windsurf
    case zed
    case terminal(String)
    case tmux
    case ssh
    /// Reparented to launchd: whoever started it has exited.
    case orphaned
    /// Started by launchd on purpose (Homebrew services, app helpers).
    case service
    case unknown

    var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursorAgent: "Cursor Agent"
        case .cursor: "Cursor"
        case .geminiCLI: "Gemini CLI"
        case .aider: "Aider"
        case .openCode: "OpenCode"
        case .vscode: "VS Code"
        case .windsurf: "Windsurf"
        case .zed: "Zed"
        case .terminal(let name): name
        case .tmux: "tmux"
        case .ssh: "SSH"
        case .orphaned: "Left behind"
        case .service: "Service"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode, .codex, .cursorAgent, .geminiCLI, .aider, .openCode: "sparkles"
        case .cursor, .vscode, .windsurf, .zed: "chevron.left.forwardslash.chevron.right"
        case .terminal, .tmux, .ssh: "terminal"
        case .orphaned: "person.slash"
        case .service: "gearshape.2"
        case .unknown: "questionmark"
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.24)
        case .codex, .openCode: Color(red: 0.20, green: 0.66, blue: 0.53)
        case .cursorAgent: Color(red: 0.55, green: 0.42, blue: 0.95)
        case .geminiCLI: Color(red: 0.26, green: 0.52, blue: 0.96)
        case .aider: Color(red: 0.16, green: 0.62, blue: 0.56)
        case .cursor, .vscode, .windsurf, .zed: .secondary
        case .terminal, .tmux, .ssh: .secondary
        case .orphaned: .orange
        case .service: .secondary
        case .unknown: .secondary
        }
    }

    /// An AI coding agent started this.
    var isAgent: Bool {
        switch self {
        case .claudeCode, .codex, .cursorAgent, .geminiCLI, .aider, .openCode: true
        default: false
        }
    }

    /// Worth showing as a chip in the card header.
    var isNotable: Bool {
        switch self {
        case .unknown, .service: false
        default: true
        }
    }
}

/// Everything we know about where a listener sits in the process tree.
struct ProcessLineage: Hashable, Sendable {
    var origin: ProcessOrigin
    /// The pid whose parent is a host (terminal, editor, agent) or launchd:
    /// the `npm run dev` wrapper rather than the `next-server` it spawned.
    var treeRoot: Int32
    /// Human-readable command of the tree root, e.g. "npm run dev".
    var rootCommand: String
    /// The root plus every descendant, in no particular order.
    var treePIDs: [Int32]
    /// Resident memory of the whole tree, in bytes.
    var treeMemory: UInt64
    /// CPU % summed over the tree (ps `pcpu`).
    var treeCPU: Double
    /// The working directory the process was started from no longer exists.
    var directoryMissing: Bool

    var isOrphaned: Bool { origin == .orphaned }

    /// Something a developer should probably clean up: parent gone, or the
    /// project folder was deleted from under it (agent worktree removed).
    var isLeftBehind: Bool { isOrphaned || directoryMissing }

    var treeMemoryLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(treeMemory), countStyle: .memory)
    }
}
