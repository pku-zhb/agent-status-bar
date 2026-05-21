import Foundation

enum AgentKind: String, Codable {
    case codex
    case claude

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        }
    }
}

enum AgentState: String, Codable {
    case running
    case waitingApproval
    case idle
    case stale
    case unknown

    var displayName: String {
        switch self {
        case .running:
            return "运行中"
        case .waitingApproval:
            return "需处理"
        case .idle:
            return "空闲"
        case .stale:
            return "未更新"
        case .unknown:
            return "未知"
        }
    }

    var sortRank: Int {
        switch self {
        case .waitingApproval:
            return 0
        case .running:
            return 1
        case .unknown:
            return 2
        case .stale:
            return 3
        case .idle:
            return 4
        }
    }
}

struct AgentClient: Codable, Identifiable {
    let id: String
    let kind: AgentKind
    let pid: Int
    let parentPid: Int
    let state: AgentState
    let cwd: String?
    let title: String?
    let detail: String?
    let lastSeenAt: Date?
    let waitingSince: Date?
}

struct AgentSummary: Codable {
    let total: Int
    let codex: Int
    let claude: Int
    let running: Int
    let waitingApproval: Int
    let idle: Int
    let stale: Int
    let unknown: Int
}

struct AgentSnapshot: Codable {
    let generatedAt: Date
    let ghosttyPids: [Int]
    let clients: [AgentClient]
    let summary: AgentSummary
}

extension AgentSnapshot {
    static let empty = AgentSnapshot(
        generatedAt: Date(),
        ghosttyPids: [],
        clients: [],
        summary: AgentSummary(
            total: 0,
            codex: 0,
            claude: 0,
            running: 0,
            waitingApproval: 0,
            idle: 0,
            stale: 0,
            unknown: 0
        )
    )
}
