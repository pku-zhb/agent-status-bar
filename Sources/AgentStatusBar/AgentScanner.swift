import Foundation

struct ProcInfo {
    let pid: Int
    let ppid: Int
    let comm: String
    let args: String
}

struct CodexThreadInfo {
    let id: String
    let title: String?
    let cwd: String?
    let updatedAt: Date?
}

struct CodexRuntimeInfo {
    let state: AgentState
    let threadId: String?
    let detail: String?
    let lastSeenAt: Date?
    let waitingSince: Date?
}

final class AgentScanner {
    private let home: String
    private let fileManager = FileManager.default
    private let sqlitePath = "/usr/bin/sqlite3"

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    func scan() -> AgentSnapshot {
        let processes = loadProcesses()
        let processByPid = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let ghosttyPids = processes
            .filter { isGhostty($0) }
            .map(\.pid)
            .sorted()
        let ghosttySet = Set(ghosttyPids)

        let codexClients = codexProcesses(processes, processByPid: processByPid, ghosttyPids: ghosttySet)
            .map { makeCodexClient(from: $0, processes: processes, processByPid: processByPid) }
        let claudeClients = processes
            .filter { isClaude($0) && isDescendant($0.pid, of: ghosttySet, processByPid: processByPid) }
            .map { makeClaudeClient(from: $0) }

        let clients = (codexClients + claudeClients)
            .sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.pid < $1.pid
            }

        return AgentSnapshot(
            generatedAt: Date(),
            ghosttyPids: ghosttyPids,
            clients: clients,
            summary: makeSummary(clients)
        )
    }

    private func loadProcesses() -> [ProcInfo] {
        guard let result = ProcessRunner.run("/bin/ps", ["-axo", "pid,ppid,comm,args"], timeout: 3),
              result.exitCode == 0 else {
            return []
        }

        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .compactMap(parseProcessLine)
    }

    private func parseProcessLine(_ line: Substring) -> ProcInfo? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 4,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]) else {
            return nil
        }

        return ProcInfo(pid: pid, ppid: ppid, comm: String(parts[2]), args: String(parts[3]))
    }

    private func isGhostty(_ process: ProcInfo) -> Bool {
        process.args.contains("/Applications/Ghostty.app/Contents/MacOS/ghostty")
            || process.comm == "ghostty"
    }

    private func isClaude(_ process: ProcInfo) -> Bool {
        process.comm == "claude" || process.args == "claude" || process.args.hasSuffix("/claude")
    }

    private func isCodexNative(_ process: ProcInfo) -> Bool {
        process.args.contains("@openai/codex")
            && process.args.contains("/vendor/")
            && (process.args.contains("/codex/codex") || process.args.hasSuffix("/bin/codex"))
    }

    private func isCodexWrapper(_ process: ProcInfo) -> Bool {
        process.comm == "node"
            && process.args.contains("/bin/codex")
            && !process.args.contains("/node_modules/")
    }

    private func codexProcesses(
        _ processes: [ProcInfo],
        processByPid: [Int: ProcInfo],
        ghosttyPids: Set<Int>
    ) -> [ProcInfo] {
        let native = processes.filter {
            isCodexNative($0) && isDescendant($0.pid, of: ghosttyPids, processByPid: processByPid)
        }
        let nativeAncestorPids = Set(native.flatMap { ancestors(of: $0.pid, processByPid: processByPid) })
        let wrappers = processes.filter {
            isCodexWrapper($0)
                && isDescendant($0.pid, of: ghosttyPids, processByPid: processByPid)
                && !nativeAncestorPids.contains($0.pid)
        }
        return native + wrappers
    }

    private func isDescendant(_ pid: Int, of roots: Set<Int>, processByPid: [Int: ProcInfo]) -> Bool {
        if roots.contains(pid) {
            return true
        }
        var current = pid
        var seen = Set<Int>()
        while let process = processByPid[current], !seen.contains(current) {
            seen.insert(current)
            if roots.contains(process.ppid) {
                return true
            }
            current = process.ppid
        }
        return false
    }

    private func ancestors(of pid: Int, processByPid: [Int: ProcInfo]) -> [Int] {
        var result: [Int] = []
        var current = pid
        var seen = Set<Int>()
        while let process = processByPid[current], !seen.contains(current) {
            seen.insert(current)
            result.append(process.ppid)
            current = process.ppid
        }
        return result
    }

    private func makeCodexClient(from process: ProcInfo, processes: [ProcInfo], processByPid: [Int: ProcInfo]) -> AgentClient {
        let runtime = codexRuntimeInfo(
            pid: process.pid,
            hasActiveToolChild: hasActiveChildProcess(rootPid: process.pid, processes: processes, processByPid: processByPid)
        )
        let thread = runtime.threadId.flatMap { codexThreadInfo(threadId: $0) }

        return AgentClient(
            id: "codex-\(process.pid)",
            kind: .codex,
            pid: process.pid,
            parentPid: process.ppid,
            state: runtime.state,
            cwd: thread?.cwd,
            title: thread?.title,
            detail: runtime.detail,
            lastSeenAt: runtime.lastSeenAt ?? thread?.updatedAt,
            waitingSince: runtime.waitingSince
        )
    }

    private func makeClaudeClient(from process: ProcInfo) -> AgentClient {
        let session = claudeSession(pid: process.pid)
        let sessionState = mapClaudeState(session.status, updatedAt: session.updatedAt)

        return AgentClient(
            id: "claude-\(process.pid)",
            kind: .claude,
            pid: process.pid,
            parentPid: process.ppid,
            state: sessionState,
            cwd: session.cwd,
            title: session.sessionId.map { "session \($0.prefix(8))" },
            detail: session.status,
            lastSeenAt: session.updatedAt,
            waitingSince: nil
        )
    }

    private func hasActiveChildProcess(rootPid: Int, processes: [ProcInfo], processByPid: [Int: ProcInfo]) -> Bool {
        processes.contains {
            $0.pid != rootPid && isDescendant($0.pid, of: Set([rootPid]), processByPid: processByPid)
        }
    }

    private func codexRuntimeInfo(pid: Int, hasActiveToolChild: Bool) -> CodexRuntimeInfo {
        let db = "\(home)/.codex/logs_2.sqlite"
        guard fileManager.fileExists(atPath: db) else {
            return CodexRuntimeInfo(state: .unknown, threadId: nil, detail: "Codex logs not found", lastSeenAt: nil, waitingSince: nil)
        }

        let like = "pid:\(pid):%"
        let metricsQuery = """
        SELECT
          COALESCE(MAX(ts * 1000000000 + ts_nanos), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_core::tasks' AND feedback_log_body LIKE 'codex_core::tasks: new%' AND feedback_log_body LIKE '%turn{%' THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_core::tasks' AND feedback_log_body LIKE 'codex_core::tasks: close time.busy=%' AND feedback_log_body LIKE '%turn{%' THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_core::stream_events_utils' AND feedback_log_body LIKE '%:handle_output_item_done: ToolCall: exec_command {%' AND (feedback_log_body LIKE '%"sandbox_permissions":"require_escalated"%' OR feedback_log_body LIKE '%"sandbox_permissions": "require_escalated"%') THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target IN ('codex_core::session', 'codex_core::tasks') AND (feedback_log_body LIKE 'session_loop%op.dispatch.exec_approval%' OR feedback_log_body LIKE 'session_loop%op.dispatch.patch_approval%') THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_otel.trace_safe' AND feedback_log_body LIKE '%event.name="codex.tool_result"%' AND feedback_log_body LIKE '%tool_name=exec_command%' THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_core::stream_events_utils' AND (feedback_log_body LIKE '%:handle_output_item_done: ToolCall: request_user_input {%' OR feedback_log_body LIKE '%:handle_output_item_done: ToolCall: ask_question {%' OR feedback_log_body LIKE '%:handle_output_item_done: ToolCall: askquestion {%') THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_otel.trace_safe' AND feedback_log_body LIKE '%event.name="codex.tool_result"%' AND (feedback_log_body LIKE '%tool_name=request_user_input%' OR feedback_log_body LIKE '%tool_name=ask_question%' OR feedback_log_body LIKE '%tool_name=askquestion%') THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_core::session' AND feedback_log_body LIKE 'session_loop%interrupt received: abort current task%' THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_otel.trace_safe' AND (feedback_log_body LIKE '%otel.name="session_task.turn"%' OR feedback_log_body LIKE '%codex.op="user_input_with_turn_context"%' OR feedback_log_body LIKE '%run_sampling_request%') THEN ts * 1000000000 + ts_nanos END), 0)
        FROM logs
        WHERE process_uuid LIKE '\(sqlEscape(like))';
        """

        let metrics = sqliteRows(db: db, query: metricsQuery).first ?? []
        let lastSeen = dateFromNanoseconds(metrics[safe: 0])
        let turnStart = int64(metrics[safe: 1]) ?? 0
        let turnEnd = int64(metrics[safe: 2]) ?? 0
        let escalated = int64(metrics[safe: 3]) ?? 0
        let approval = int64(metrics[safe: 4]) ?? 0
        let toolResult = int64(metrics[safe: 5]) ?? 0
        let question = int64(metrics[safe: 6]) ?? 0
        let questionResult = int64(metrics[safe: 7]) ?? 0
        let interrupt = int64(metrics[safe: 8]) ?? 0
        let turnActivity = dateFromNanoseconds(metrics[safe: 9])

        let threadId = latestCodexThreadId(pid: pid, db: db)
        let state: AgentState
        let approvalResolvedNs = max(max(approval, toolResult), interrupt)
        let questionResolvedNs = max(questionResult, interrupt)
        let approvalWaitingSince = dateFromNanoseconds(String(escalated))
        let questionWaitingSince = dateFromNanoseconds(String(question))
        let approvalIsMature = approvalWaitingSince.map { Date().timeIntervalSince($0) >= 1.2 } ?? false
        let approvalPending = escalated > approvalResolvedNs && approvalIsMature && !hasActiveToolChild
        let questionPending = question > questionResolvedNs
        let waitingNs = questionPending ? question : (approvalPending ? escalated : 0)
        let waitingSince = dateFromNanoseconds(String(waitingNs))
        let isWaitingForQuestion = questionPending && (questionWaitingSince != nil)
        let hasRecentTurnActivity = turnActivity.map { Date().timeIntervalSince($0) <= 12 } ?? false

        if approvalPending || questionPending {
            state = .waitingApproval
        } else if hasActiveToolChild {
            state = .running
        } else if turnStart > turnEnd {
            state = .running
        } else if hasRecentTurnActivity {
            state = .running
        } else if lastSeen != nil {
            state = .idle
        } else {
            state = .unknown
        }

        let detail: String?
        switch state {
        case .waitingApproval:
            detail = isWaitingForQuestion ? "等待用户回答" : "等待命令或补丁批准"
        case .running:
            detail = "turn active"
        case .idle:
            detail = "idle"
        case .stale:
            detail = "idle"
        case .unknown:
            detail = "no Codex log match"
        }

        return CodexRuntimeInfo(
            state: state,
            threadId: threadId,
            detail: detail,
            lastSeenAt: lastSeen,
            waitingSince: state == .waitingApproval ? waitingSince : nil
        )
    }

    private func latestCodexThreadId(pid: Int, db: String) -> String? {
        let like = "pid:\(pid):%"
        let query = """
        SELECT thread_id
        FROM logs
        WHERE process_uuid LIKE '\(sqlEscape(like))'
          AND thread_id IS NOT NULL
          AND thread_id != ''
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1;
        """
        return sqliteRows(db: db, query: query).first?.first?.nilIfEmpty
    }

    private func codexThreadInfo(threadId: String) -> CodexThreadInfo? {
        let db = "\(home)/.codex/state_5.sqlite"
        guard fileManager.fileExists(atPath: db) else {
            return nil
        }
        let query = """
        SELECT title, cwd, updated_at_ms
        FROM threads
        WHERE id = '\(sqlEscape(threadId))'
        LIMIT 1;
        """
        guard let row = sqliteRows(db: db, query: query).first else {
            return nil
        }
        let updatedMs = Double(row[safe: 2] ?? "")
        return CodexThreadInfo(
            id: threadId,
            title: row[safe: 0]?.nilIfEmpty,
            cwd: row[safe: 1]?.nilIfEmpty,
            updatedAt: updatedMs.map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    private struct ClaudeSession: Decodable {
        let pid: Int?
        let sessionId: String?
        let cwd: String?
        let status: String?
        let updatedAt: Int64?
    }

    private func claudeSession(pid: Int) -> (sessionId: String?, cwd: String?, status: String?, updatedAt: Date?) {
        let path = "\(home)/.claude/sessions/\(pid).json"
        guard let data = fileManager.contents(atPath: path),
              let session = try? JSONDecoder().decode(ClaudeSession.self, from: data) else {
            return (nil, nil, "unknown", nil)
        }

        return (
            session.sessionId,
            session.cwd,
            session.status,
            session.updatedAt.map { Date(timeIntervalSince1970: Double($0) / 1000) }
        )
    }

    private func mapClaudeState(_ status: String?, updatedAt: Date?) -> AgentState {
        if let updatedAt, Date().timeIntervalSince(updatedAt) > 1800 {
            return .idle
        }

        let value = (status ?? "").lowercased()
        if value == "waiting"
            || value.contains("approval")
            || value.contains("permission")
            || value.contains("confirm")
            || value.contains("question")
            || value.contains("input")
            || value.contains("prompt") {
            return .waitingApproval
        }
        if value == "idle" || value == "ready" {
            return .idle
        }
        if value.contains("run") || value.contains("busy") || value.contains("thinking") || value.contains("tool") {
            return .running
        }
        return status == nil ? .unknown : .idle
    }

    private func sqliteRows(db: String, query: String) -> [[String]] {
        guard fileManager.fileExists(atPath: db),
              let result = ProcessRunner.run(sqlitePath, ["-batch", "-separator", "\t", db, query], timeout: 3),
              result.exitCode == 0 else {
            return []
        }

        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
            .map { row in
                row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
    }

    private func sqlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    private func dateFromNanoseconds(_ value: String?) -> Date? {
        guard let raw = int64(value), raw > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(raw) / 1_000_000_000)
    }

    private func int64(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return Int64(value)
    }

    private func makeSummary(_ clients: [AgentClient]) -> AgentSummary {
        AgentSummary(
            total: clients.count,
            codex: clients.filter { $0.kind == .codex }.count,
            claude: clients.filter { $0.kind == .claude }.count,
            running: clients.filter { $0.state == .running }.count,
            waitingApproval: clients.filter { $0.state == .waitingApproval }.count,
            idle: clients.filter { $0.state == .idle }.count,
            stale: clients.filter { $0.state == .stale }.count,
            unknown: clients.filter { $0.state == .unknown }.count
        )
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
