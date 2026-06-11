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
            return "空闲"
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
        case .idle, .stale:
            return 4
        }
    }
}

struct AgentClient: Codable, Identifiable {
    let id: String
    let kind: AgentKind
    let pid: Int
    let parentPid: Int
    let workspaceId: String?
    let surfaceId: String?
    let tty: String?
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
    let agentPids: [Int]
    let clients: [AgentClient]
    let summary: AgentSummary
}

struct AgentCreditSnapshot: Codable {
    let generatedAt: Date
    let codex: AgentCreditStatus?
    let claude: AgentCreditStatus?

    func status(for kind: AgentKind) -> AgentCreditStatus? {
        switch kind {
        case .codex:
            return codex
        case .claude:
            return claude
        }
    }

    func replacingMissingValues(with previous: AgentCreditSnapshot) -> AgentCreditSnapshot {
        AgentCreditSnapshot(
            generatedAt: generatedAt,
            codex: codex?.hasDisplayableUsage == true ? codex : previous.codex,
            claude: claude?.hasDisplayableUsage == true ? claude : previous.claude
        )
    }
}

struct AgentCreditStatus: Codable {
    let fiveHourRemainingPercent: Int?
    let weeklyRemainingPercent: Int?
    let fiveHourResetAt: Date?
    let weeklyResetAt: Date?
    let unlimited: Bool
    let source: String

    var menuText: String {
        "5h \(display(fiveHourRemainingPercent)) left · weekly \(display(weeklyRemainingPercent)) left"
    }

    var menuBarText: String {
        "5h \(display(fiveHourRemainingPercent)) / W \(display(weeklyRemainingPercent))"
    }

    var fiveHourUsedPercent: Int? {
        usedPercent(fromRemaining: fiveHourRemainingPercent)
    }

    var weeklyUsedPercent: Int? {
        usedPercent(fromRemaining: weeklyRemainingPercent)
    }

    var fiveHourResetElapsedPercent: Int? {
        elapsedPercent(until: fiveHourResetAt, windowSeconds: 5 * 60 * 60)
    }

    var weeklyResetElapsedPercent: Int? {
        elapsedPercent(until: weeklyResetAt, windowSeconds: 7 * 24 * 60 * 60)
    }

    var hasDisplayableUsage: Bool {
        unlimited || fiveHourRemainingPercent != nil || weeklyRemainingPercent != nil || fiveHourResetAt != nil || weeklyResetAt != nil
    }

    private func display(_ value: Int?) -> String {
        if unlimited {
            return "unlimited"
        }
        guard let value else {
            return "n/a"
        }
        return "\(value)%"
    }

    private func usedPercent(fromRemaining value: Int?) -> Int? {
        guard !unlimited, let value else {
            return nil
        }
        return min(100, max(0, 100 - value))
    }

    private func elapsedPercent(until resetAt: Date?, windowSeconds: TimeInterval) -> Int? {
        guard !unlimited, let resetAt else {
            return nil
        }

        let remaining = resetAt.timeIntervalSince(Date())
        if remaining <= 0 {
            return 100
        }
        let elapsed = windowSeconds - remaining
        let percent = Int((elapsed / windowSeconds * 100).rounded())
        return min(100, max(0, percent))
    }
}

extension AgentSnapshot {
    static let empty = AgentSnapshot(
        generatedAt: Date(),
        agentPids: [],
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

extension AgentCreditSnapshot {
    static let empty = AgentCreditSnapshot(
        generatedAt: Date(),
        codex: nil,
        claude: nil
    )
}
