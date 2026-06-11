import Foundation

struct ProcInfo {
    let pid: Int
    let ppid: Int
    let tty: String
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

struct ClaudeSessionInfo: Decodable {
    let pid: Int
    let sessionId: String?
    let cwd: String?
    let startedAt: Double?
    let status: String?
    let updatedAt: Double?
    let name: String?
    let kind: String?
    let entrypoint: String?
}

final class AgentScanner {
    private let home: String
    private let fileManager = FileManager.default
    private let sqlitePath = "/usr/bin/sqlite3"
    private let claudeBusyFreshness: TimeInterval = 5 * 60
    private let codexTurnActivityFreshness: TimeInterval = 90

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    func scan() -> AgentSnapshot {
        let processes = loadProcesses()
        let processByPid = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let claudeSessions = loadClaudeSessions()

        let codexClients = codexProcesses(processes, processByPid: processByPid).map {
            makeCodexClient(process: $0, processes: processes, processByPid: processByPid)
        }
        let claudeClients = processes
            .filter { isTerminalProcess($0) && isClaude($0) }
            .map {
                makeClaudeClient(
                    process: $0,
                    session: claudeSessions[$0.pid],
                    processes: processes,
                    processByPid: processByPid
                )
            }

        let sortedClients = dedupe(codexClients + claudeClients)
            .sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.pid < $1.pid
            }

        return AgentSnapshot(
            generatedAt: Date(),
            agentPids: sortedClients.map(\.pid).sorted(),
            clients: sortedClients,
            summary: makeSummary(sortedClients)
        )
    }

    private func loadProcesses() -> [ProcInfo] {
        guard let result = ProcessRunner.run("/bin/ps", ["-axo", "pid,ppid,tty,comm,args"], timeout: 3),
              result.exitCode == 0 else {
            return []
        }

        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst()
            .compactMap(parseProcessLine)
    }

    private func parseProcessLine(_ line: Substring) -> ProcInfo? {
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 5,
              let pid = Int(parts[0]),
              let ppid = Int(parts[1]) else {
            return nil
        }

        return ProcInfo(
            pid: pid,
            ppid: ppid,
            tty: String(parts[2]),
            comm: String(parts[3]),
            args: String(parts[4])
        )
    }

    private func isTerminalProcess(_ process: ProcInfo) -> Bool {
        process.tty != "??"
    }

    private func executableName(_ process: ProcInfo) -> String {
        URL(fileURLWithPath: process.comm).lastPathComponent
    }

    private func isClaude(_ process: ProcInfo) -> Bool {
        let executable = executableName(process)
        return executable == "claude"
            || executable == "claude-code"
            || process.args == "claude"
            || process.args.hasPrefix("claude ")
            || process.args.hasSuffix("/claude")
            || process.args.contains("/bin/claude ")
            || process.args.contains("/bin/claude\t")
    }

    private func isCodexNative(_ process: ProcInfo) -> Bool {
        if executableName(process) == "codex" {
            return true
        }
        return process.args.contains("@openai/codex")
            && process.args.contains("/vendor/")
            && (process.args.contains("/codex/codex")
                || process.args.hasSuffix("/bin/codex")
                || process.args.contains("/bin/codex "))
    }

    private func isCodexWrapper(_ process: ProcInfo) -> Bool {
        executableName(process) == "node"
            && process.args.contains("/bin/codex")
            && !process.args.contains("/node_modules/")
    }

    private func codexProcesses(_ processes: [ProcInfo], processByPid: [Int: ProcInfo]) -> [ProcInfo] {
        let native = processes.filter {
            isTerminalProcess($0) && isCodexNative($0)
        }
        let nativeAncestorPids = Set(native.flatMap { ancestors(of: $0.pid, processByPid: processByPid) })
        let wrappers = processes.filter {
            isTerminalProcess($0)
                && isCodexWrapper($0)
                && !nativeAncestorPids.contains($0.pid)
        }
        return native + wrappers
    }

    private func dedupe(_ clients: [AgentClient]) -> [AgentClient] {
        var result: [AgentClient] = []
        var seen = Set<String>()
        for client in clients {
            let key = "\(client.kind.rawValue):\(client.pid)"
            if seen.insert(key).inserted {
                result.append(client)
            }
        }
        return result
    }

    private func makeCodexClient(
        process: ProcInfo,
        processes: [ProcInfo],
        processByPid: [Int: ProcInfo]
    ) -> AgentClient {
        let hasActiveChild = hasActiveChildProcess(rootPid: process.pid, processes: processes, processByPid: processByPid)
        let fallbackState = processState(hasActiveChild: hasActiveChild)
        let runtime = codexRuntimeInfo(pid: process.pid, hasActiveToolChild: hasActiveChild)
        let thread = runtime.threadId.flatMap { codexThreadInfo(threadId: $0) }
        let state = resolvedState(runtime.state, fallback: fallbackState)

        return AgentClient(
            id: "codex-\(process.pid)",
            kind: .codex,
            pid: process.pid,
            parentPid: process.ppid,
            workspaceId: nil,
            surfaceId: nil,
            tty: process.tty,
            state: state,
            cwd: thread?.cwd,
            title: thread?.title ?? processTitle(kind: .codex, process: process),
            detail: runtime.detail ?? detailText(source: "process", state: state),
            lastSeenAt: newestDate(runtime.lastSeenAt, thread?.updatedAt),
            waitingSince: state == .waitingApproval ? runtime.waitingSince : nil
        )
    }

    private func makeClaudeClient(
        process: ProcInfo,
        session: ClaudeSessionInfo?,
        processes: [ProcInfo],
        processByPid: [Int: ProcInfo]
    ) -> AgentClient {
        let hasActiveChild = hasActiveChildProcess(rootPid: process.pid, processes: processes, processByPid: processByPid)
        let sessionUpdatedAt = dateFromMilliseconds(session?.updatedAt)
        let state = claudeState(session: session, hasActiveChild: hasActiveChild)

        return AgentClient(
            id: "claude-\(process.pid)",
            kind: .claude,
            pid: process.pid,
            parentPid: process.ppid,
            workspaceId: nil,
            surfaceId: nil,
            tty: process.tty,
            state: state,
            cwd: session?.cwd,
            title: claudeTitle(session: session, process: process),
            detail: claudeDetail(session: session, state: state),
            lastSeenAt: sessionUpdatedAt,
            waitingSince: state == .waitingApproval ? sessionUpdatedAt : nil
        )
    }

    private func processTitle(kind: AgentKind, process: ProcInfo) -> String {
        if let tty = process.tty.nilIfEmpty {
            return "\(kind.displayName) \(tty)"
        }
        return kind.displayName
    }

    private func processState(hasActiveChild: Bool) -> AgentState {
        hasActiveChild ? .running : .idle
    }

    private func claudeState(session: ClaudeSessionInfo?, hasActiveChild: Bool) -> AgentState {
        guard let status = session?.status?.trimmingCharacters(in: .whitespacesAndNewlines),
              !status.isEmpty else {
            return processState(hasActiveChild: hasActiveChild)
        }

        let compact = status.lowercased().filter { $0.isLetter || $0.isNumber }
        if compact == "busy" || compact == "running" || compact == "thinking" || compact == "working" {
            if hasActiveChild || isRecent(dateFromMilliseconds(session?.updatedAt), within: claudeBusyFreshness) {
                return .running
            }
            return .idle
        }
        if compact == "waiting"
            || compact == "needsinput"
            || compact == "needsapproval"
            || compact == "waitingapproval"
            || compact == "blocked"
            || compact == "paused" {
            return .waitingApproval
        }
        if compact == "idle" || compact == "ready" {
            return .idle
        }
        if compact == "ended" || compact == "exited" || compact == "closed" {
            return .stale
        }
        return processState(hasActiveChild: hasActiveChild)
    }

    private func claudeTitle(session: ClaudeSessionInfo?, process: ProcInfo) -> String {
        if let name = session?.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            return name
        }
        return processTitle(kind: .claude, process: process)
    }

    private func claudeDetail(session: ClaudeSessionInfo?, state: AgentState) -> String {
        if let status = session?.status?.nilIfEmpty {
            let compact = status.lowercased().filter { $0.isLetter || $0.isNumber }
            if state == .idle,
               (compact == "busy" || compact == "running" || compact == "thinking" || compact == "working") {
                return "claude session: stale \(status)"
            }
            return "claude session: \(status)"
        }
        return detailText(source: "process", state: state)
    }

    private func resolvedState(_ runtimeState: AgentState, fallback: AgentState) -> AgentState {
        runtimeState == .unknown ? fallback : runtimeState
    }

    private func loadClaudeSessions() -> [Int: ClaudeSessionInfo] {
        let directory = "\(home)/.claude/sessions"
        guard let files = try? fileManager.contentsOfDirectory(atPath: directory) else {
            return [:]
        }

        let decoder = JSONDecoder()
        var sessions: [Int: ClaudeSessionInfo] = [:]
        for file in files where file.hasSuffix(".json") {
            let path = "\(directory)/\(file)"
            guard let data = fileManager.contents(atPath: path),
                  let session = try? decoder.decode(ClaudeSessionInfo.self, from: data) else {
                continue
            }
            sessions[session.pid] = session
        }
        return sessions
    }

    private func detailText(source: String, state: AgentState) -> String {
        switch state {
        case .waitingApproval:
            return "\(source): needs input"
        case .running:
            return "\(source): running"
        case .idle:
            return "\(source): idle"
        case .stale:
            return "\(source): stale"
        case .unknown:
            return "\(source): unknown"
        }
    }

    private func hasActiveChildProcess(rootPid: Int, processes: [ProcInfo], processByPid: [Int: ProcInfo]) -> Bool {
        let roots = Set([rootPid])
        return processes.contains {
            $0.pid != rootPid
                && !isIgnorableAgentChild($0)
                && isDescendant($0.pid, of: roots, processByPid: processByPid)
        }
    }

    private func isIgnorableAgentChild(_ process: ProcInfo) -> Bool {
        let executable = executableName(process)
        return executable == "caffeinate"
            || process.args == "caffeinate"
            || process.args.hasPrefix("caffeinate ")
            || process.args == "/usr/bin/caffeinate"
            || process.args.hasPrefix("/usr/bin/caffeinate ")
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

    private func codexRuntimeInfo(pid: Int, hasActiveToolChild: Bool) -> CodexRuntimeInfo {
        let db = "\(home)/.codex/logs_2.sqlite"
        guard fileManager.fileExists(atPath: db) else {
            return CodexRuntimeInfo(state: .unknown, threadId: nil, detail: nil, lastSeenAt: nil, waitingSince: nil)
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
          COALESCE(MAX(CASE WHEN (target = 'codex_otel.trace_safe' AND (feedback_log_body LIKE '%otel.name="session_task.turn"%' OR feedback_log_body LIKE '%codex.op="user_input_with_turn_context"%' OR feedback_log_body LIKE '%run_sampling_request%' OR feedback_log_body LIKE '%event.name="codex.tool_result"%')) OR (target = 'codex_core::stream_events_utils' AND feedback_log_body LIKE '%:handle_output_item_done: ToolCall:%') THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_core::stream_events_utils' AND feedback_log_body LIKE '%:handle_output_item_done: ToolCall:%' THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_otel.trace_safe' AND feedback_log_body LIKE '%event.name="codex.tool_result"%' THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_core::session::turn' AND feedback_log_body LIKE '%:run_turn: post sampling token usage%' AND feedback_log_body LIKE '% needs_follow_up=true%' THEN ts * 1000000000 + ts_nanos END), 0),
          COALESCE(MAX(CASE WHEN target = 'codex_core::session::turn' AND feedback_log_body LIKE '%:run_turn: post sampling token usage%' AND feedback_log_body LIKE '% needs_follow_up=false%' THEN ts * 1000000000 + ts_nanos END), 0)
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
        let turnActivityNs = int64(metrics[safe: 9]) ?? 0
        let turnActivity = dateFromNanoseconds(metrics[safe: 9])
        let toolCall = int64(metrics[safe: 10]) ?? 0
        let anyToolResult = int64(metrics[safe: 11]) ?? 0
        let turnNeedsFollowUp = int64(metrics[safe: 12]) ?? 0
        let turnFinished = int64(metrics[safe: 13]) ?? 0

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
        let hasRecentTurnActivity = turnActivity.map { Date().timeIntervalSince($0) <= codexTurnActivityFreshness } ?? false
        let toolCallWaitingSince = dateFromNanoseconds(String(toolCall))
        let toolCallIsRecent = toolCallWaitingSince.map { Date().timeIntervalSince($0) <= 30 * 60 } ?? false
        let toolCallPending = toolCall > anyToolResult && toolCallIsRecent
        let strictTurnResolved = max(turnFinished, interrupt)
        let hasStrictTurnSignal = max(turnNeedsFollowUp, turnFinished) > 0
        let strictTurnRunning = turnNeedsFollowUp > strictTurnResolved
        let strictTurnFinished = hasStrictTurnSignal
            && strictTurnResolved > turnNeedsFollowUp
            && turnActivityNs <= strictTurnResolved

        if approvalPending || questionPending {
            state = .waitingApproval
        } else if hasActiveToolChild {
            state = .running
        } else if toolCallPending {
            state = .running
        } else if strictTurnRunning {
            state = .running
        } else if strictTurnFinished {
            state = .idle
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
            detail = toolCallPending ? "tool call pending" : (strictTurnRunning ? "turn follow-up pending" : "turn active")
        case .idle:
            detail = "idle"
        case .stale:
            detail = "idle"
        case .unknown:
            detail = nil
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

    private func dateFromMilliseconds(_ value: Double?) -> Date? {
        guard let value, value > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: value / 1000)
    }

    private func int64(_ value: String?) -> Int64? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return Int64(value)
    }

    private func newestDate(_ dates: Date?...) -> Date? {
        dates.compactMap { $0 }.max()
    }

    private func isRecent(_ date: Date?, within seconds: TimeInterval) -> Bool {
        guard let date else {
            return false
        }
        return Date().timeIntervalSince(date) <= seconds
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
