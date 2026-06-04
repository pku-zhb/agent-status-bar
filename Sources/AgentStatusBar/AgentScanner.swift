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

struct CmuxPanelSnapshot {
    let id: String
    let workspaceTitle: String?
    let workspaceCwd: String?
    let title: String?
    let customTitle: String?
    let cwd: String?
    let tty: String?
    let terminalAgentKind: AgentKind?
    let terminalAgentSessionId: String?
    let resumeKind: AgentKind?
    let resumeSessionId: String?
    let notifications: [CmuxNotificationSnapshot]

    var displayTitle: String? {
        customTitle ?? title ?? workspaceTitle
    }

    var effectiveCwd: String? {
        cwd ?? workspaceCwd
    }
}

struct CmuxNotificationSnapshot {
    let title: String?
    let subtitle: String?
    let body: String?
    let createdAt: Date?
    let isRead: Bool?
}

struct CmuxHookSession {
    let kind: AgentKind
    let sessionId: String
    let pid: Int?
    let workspaceId: String?
    let surfaceId: String?
    let cwd: String?
    let title: String?
    let lifecycle: String?
    let lastSubtitle: String?
    let lastBody: String?
    let updatedAt: Date?
    let startedAt: Date?
    let isRestorable: Bool?
}

struct CmuxWorkstreamItem {
    let kind: AgentKind
    let workstreamId: String
    let sessionId: String?
    let eventKind: String
    let pid: Int?
    let cwd: String?
    let title: String?
    let text: String?
    let toolName: String?
    let createdAt: Date?
    let updatedAt: Date?

    var lastSeenAt: Date? {
        updatedAt ?? createdAt
    }
}

struct CmuxHookIndex {
    var byKindSession: [AgentKind: [String: CmuxHookSession]] = [:]
    var byKindSurface: [AgentKind: [String: CmuxHookSession]] = [:]
    var byKindWorkspace: [AgentKind: [String: CmuxHookSession]] = [:]

    mutating func add(_ session: CmuxHookSession) {
        byKindSession[session.kind, default: [:]][session.sessionId] = session
        if let surfaceId = session.surfaceId {
            byKindSurface[session.kind, default: [:]][surfaceId] = session
        }
        if let workspaceId = session.workspaceId {
            byKindWorkspace[session.kind, default: [:]][workspaceId] = session
        }
    }

    func session(kind: AgentKind, panel: CmuxPanelSnapshot?) -> CmuxHookSession? {
        if let sessionId = panel?.terminalAgentSessionId,
           let session = byKindSession[kind]?[sessionId] {
            return session
        }
        if let sessionId = panel?.resumeSessionId,
           let session = byKindSession[kind]?[sessionId] {
            return session
        }
        if let surfaceId = panel?.id,
           let session = byKindSurface[kind]?[surfaceId] {
            return session
        }
        return nil
    }
}

struct CmuxWorkstreamIndex {
    var byKindSession: [AgentKind: [String: CmuxWorkstreamItem]] = [:]
    var byKindPid: [AgentKind: [Int: CmuxWorkstreamItem]] = [:]

    mutating func add(_ item: CmuxWorkstreamItem) {
        if let sessionId = item.sessionId {
            Self.update(&byKindSession[item.kind, default: [:]], key: sessionId, item: item)
        }
        if let pid = item.pid {
            Self.update(&byKindPid[item.kind, default: [:]], key: pid, item: item)
        }
    }

    func latest(kind: AgentKind, sessionId: String?, pid: Int?) -> CmuxWorkstreamItem? {
        let bySession = sessionId.flatMap { byKindSession[kind]?[$0] }
        let byPid = pid.flatMap { byKindPid[kind]?[$0] }
        return newestWorkstreamItem(bySession, byPid)
    }

    private static func update<Key: Hashable>(
        _ dictionary: inout [Key: CmuxWorkstreamItem],
        key: Key,
        item: CmuxWorkstreamItem
    ) {
        if let existing = dictionary[key],
           compareOptionalDates(item.lastSeenAt, existing.lastSeenAt) != .orderedDescending {
            return
        }
        dictionary[key] = item
    }
}

private func compareOptionalDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
    switch (lhs, rhs) {
    case (.none, .none):
        return .orderedSame
    case (.some, .none):
        return .orderedDescending
    case (.none, .some):
        return .orderedAscending
    case (.some(let lhs), .some(let rhs)):
        return lhs.compare(rhs)
    }
}

private func newestWorkstreamItem(_ lhs: CmuxWorkstreamItem?, _ rhs: CmuxWorkstreamItem?) -> CmuxWorkstreamItem? {
    switch (lhs, rhs) {
    case (.none, .none):
        return nil
    case (.some(let item), .none), (.none, .some(let item)):
        return item
    case (.some(let lhs), .some(let rhs)):
        return compareOptionalDates(lhs.lastSeenAt, rhs.lastSeenAt) == .orderedAscending ? rhs : lhs
    }
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
        let cmuxPids = processes
            .filter { isCmux($0) }
            .map(\.pid)
            .sorted()

        let panels = loadCmuxPanels()
        let cmuxTtys = Set(panels.compactMap(\.tty))
        let hookIndex = loadCmuxHookIndex()
        let workstreamIndex = loadCmuxWorkstreamIndex()
        let codexByTTY = bestProcessesByTTY(
            codexProcesses(processes, processByPid: processByPid, allowedTtys: cmuxTtys)
        )
        let claudeByTTY = bestProcessesByTTY(
            processes.filter { isClaude($0) && cmuxTtys.contains($0.tty) }
        )

        var usedProcessPids = Set<Int>()
        var clients: [AgentClient] = []

        for panel in panels {
            let kinds = agentKinds(
                for: panel,
                codexProcess: panel.tty.flatMap { codexByTTY[$0] },
                claudeProcess: panel.tty.flatMap { claudeByTTY[$0] },
                hooks: hookIndex
            )

            for kind in kinds {
                let process = panel.tty.flatMap { tty in
                    kind == .codex ? codexByTTY[tty] : claudeByTTY[tty]
                }
                if let process {
                    usedProcessPids.insert(process.pid)
                }
                let hook = hookIndex.session(kind: kind, panel: panel)
                let workstream = workstreamIndex.latest(
                    kind: kind,
                    sessionId: hook?.sessionId ?? panel.terminalAgentSessionId ?? panel.resumeSessionId,
                    pid: process?.pid ?? hook?.pid
                )

                switch kind {
                case .codex:
                    clients.append(makeCodexClient(
                        panel: panel,
                        process: process,
                        hook: hook,
                        workstream: workstream,
                        processes: processes,
                        processByPid: processByPid
                    ))
                case .claude:
                    clients.append(makeClaudeClient(
                        panel: panel,
                        process: process,
                        hook: hook,
                        workstream: workstream,
                        processes: processes,
                        processByPid: processByPid
                    ))
                }
            }
        }

        for process in codexProcesses(processes, processByPid: processByPid, allowedTtys: cmuxTtys)
            where !usedProcessPids.contains(process.pid) {
            usedProcessPids.insert(process.pid)
            let workstream = workstreamIndex.latest(kind: .codex, sessionId: nil, pid: process.pid)
            clients.append(makeCodexClient(
                panel: nil,
                process: process,
                hook: nil,
                workstream: workstream,
                processes: processes,
                processByPid: processByPid
            ))
        }

        for process in processes.filter({ isClaude($0) && cmuxTtys.contains($0.tty) })
            where !usedProcessPids.contains(process.pid) {
            let workstream = workstreamIndex.latest(kind: .claude, sessionId: nil, pid: process.pid)
            clients.append(makeClaudeClient(
                panel: nil,
                process: process,
                hook: nil,
                workstream: workstream,
                processes: processes,
                processByPid: processByPid
            ))
        }

        let sortedClients = dedupe(clients)
            .sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                if ($0.workspaceId ?? "") != ($1.workspaceId ?? "") {
                    return ($0.workspaceId ?? "") < ($1.workspaceId ?? "")
                }
                return $0.pid < $1.pid
            }

        return AgentSnapshot(
            generatedAt: Date(),
            cmuxPids: cmuxPids,
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

    private func isCmux(_ process: ProcInfo) -> Bool {
        process.args.contains("/Applications/cmux.app/Contents/MacOS/cmux")
            || process.args.contains("/Applications/cmux.app/Contents/Resources/bin/cmux")
            || process.comm == "cmux"
    }

    private func isClaude(_ process: ProcInfo) -> Bool {
        process.comm == "claude"
            || process.args == "claude"
            || process.args.hasPrefix("claude ")
            || process.args.hasSuffix("/claude")
            || process.args.contains("/bin/claude ")
            || process.args.contains("/bin/claude\t")
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
        allowedTtys: Set<String>
    ) -> [ProcInfo] {
        let native = processes.filter {
            isCodexNative($0) && allowedTtys.contains($0.tty)
        }
        let nativeAncestorPids = Set(native.flatMap { ancestors(of: $0.pid, processByPid: processByPid) })
        let wrappers = processes.filter {
            isCodexWrapper($0)
                && allowedTtys.contains($0.tty)
                && !nativeAncestorPids.contains($0.pid)
        }
        return native + wrappers
    }

    private func bestProcessesByTTY(_ processes: [ProcInfo]) -> [String: ProcInfo] {
        processes.reduce(into: [:]) { result, process in
            guard process.tty != "??" else {
                return
            }
            if let current = result[process.tty],
               processRank(process) >= processRank(current) {
                return
            }
            result[process.tty] = process
        }
    }

    private func processRank(_ process: ProcInfo) -> Int {
        if isCodexNative(process) {
            return 0
        }
        if isClaude(process) {
            return 0
        }
        return 1
    }

    private func agentKinds(
        for panel: CmuxPanelSnapshot,
        codexProcess: ProcInfo?,
        claudeProcess: ProcInfo?,
        hooks: CmuxHookIndex
    ) -> [AgentKind] {
        var result = Set<AgentKind>()
        if let terminalAgentKind = panel.terminalAgentKind {
            result.insert(terminalAgentKind)
        }
        if let resumeKind = panel.resumeKind {
            result.insert(resumeKind)
        }
        if codexProcess != nil {
            result.insert(.codex)
        }
        if claudeProcess != nil {
            result.insert(.claude)
        }
        if let sessionId = panel.terminalAgentSessionId {
            for kind in [AgentKind.codex, .claude] where hooks.byKindSession[kind]?[sessionId] != nil {
                result.insert(kind)
            }
        }
        if let sessionId = panel.resumeSessionId {
            for kind in [AgentKind.codex, .claude] where hooks.byKindSession[kind]?[sessionId] != nil {
                result.insert(kind)
            }
        }
        for kind in [AgentKind.codex, .claude] where hooks.byKindSurface[kind]?[panel.id] != nil {
            result.insert(kind)
        }
        return result.sorted { $0.rawValue < $1.rawValue }
    }

    private func dedupe(_ clients: [AgentClient]) -> [AgentClient] {
        var result: [AgentClient] = []
        var seen = Set<String>()
        for client in clients {
            let key = "\(client.kind.rawValue):\(client.surfaceId ?? "pid-\(client.pid)")"
            if seen.insert(key).inserted {
                result.append(client)
            }
        }
        return result
    }

    private func makeCodexClient(
        panel: CmuxPanelSnapshot?,
        process: ProcInfo?,
        hook: CmuxHookSession?,
        workstream: CmuxWorkstreamItem?,
        processes: [ProcInfo],
        processByPid: [Int: ProcInfo]
    ) -> AgentClient {
        let runtime = process.map {
            codexRuntimeInfo(
                pid: $0.pid,
                hasActiveToolChild: hasActiveChildProcess(rootPid: $0.pid, processes: processes, processByPid: processByPid)
            )
        }
        let thread = runtime?.threadId.flatMap { codexThreadInfo(threadId: $0) }
        let cmuxState = cmuxState(
            kind: .codex,
            panel: panel,
            hook: hook,
            workstream: workstream,
            hasLiveProcess: process != nil,
            hasActiveToolChild: process.map {
                hasActiveChildProcess(rootPid: $0.pid, processes: processes, processByPid: processByPid)
            } ?? false
        )
        let state = resolvedCodexState(runtime?.state, cmuxState: cmuxState)

        return AgentClient(
            id: stableClientId(kind: .codex, panel: panel, hook: hook, process: process),
            kind: .codex,
            pid: process?.pid ?? hook?.pid ?? 0,
            parentPid: process?.ppid ?? 0,
            workspaceId: hook?.workspaceId,
            surfaceId: panel?.id ?? hook?.surfaceId,
            tty: panel?.tty ?? process?.tty,
            state: state,
            cwd: thread?.cwd ?? panel?.effectiveCwd ?? hook?.cwd ?? workstream?.cwd,
            title: thread?.title ?? panel?.displayTitle ?? hook?.title ?? workstream?.title,
            detail: runtime?.detail ?? detailText(source: "cmux", state: state),
            lastSeenAt: newestDate(runtime?.lastSeenAt, thread?.updatedAt, workstream?.lastSeenAt, hook?.updatedAt),
            waitingSince: state == .waitingApproval ? runtime?.waitingSince ?? workstream?.lastSeenAt ?? hook?.updatedAt : nil
        )
    }

    private func makeClaudeClient(
        panel: CmuxPanelSnapshot?,
        process: ProcInfo?,
        hook: CmuxHookSession?,
        workstream: CmuxWorkstreamItem?,
        processes: [ProcInfo],
        processByPid: [Int: ProcInfo]
    ) -> AgentClient {
        let hasActiveChild = process.map {
            hasActiveChildProcess(rootPid: $0.pid, processes: processes, processByPid: processByPid)
        } ?? false
        let state = cmuxState(
            kind: .claude,
            panel: panel,
            hook: hook,
            workstream: workstream,
            hasLiveProcess: process != nil,
            hasActiveToolChild: hasActiveChild
        )
        let sessionTitle: String?
        if let sessionId = hook?.sessionId {
            sessionTitle = "session \(sessionId.prefix(8))"
        } else {
            sessionTitle = nil
        }
        let title = panel?.displayTitle ?? hook?.title ?? workstream?.title ?? sessionTitle

        return AgentClient(
            id: stableClientId(kind: .claude, panel: panel, hook: hook, process: process),
            kind: .claude,
            pid: process?.pid ?? hook?.pid ?? 0,
            parentPid: process?.ppid ?? 0,
            workspaceId: hook?.workspaceId,
            surfaceId: panel?.id ?? hook?.surfaceId,
            tty: panel?.tty ?? process?.tty,
            state: state,
            cwd: panel?.effectiveCwd ?? hook?.cwd ?? workstream?.cwd,
            title: title,
            detail: detailText(source: "cmux", state: state),
            lastSeenAt: newestDate(workstream?.lastSeenAt, hook?.updatedAt, hook?.startedAt, latestNotification(panel)?.createdAt),
            waitingSince: state == .waitingApproval ? newestDate(workstream?.lastSeenAt, hook?.updatedAt, latestNotification(panel)?.createdAt) : nil
        )
    }

    private func stableClientId(
        kind: AgentKind,
        panel: CmuxPanelSnapshot?,
        hook: CmuxHookSession?,
        process: ProcInfo?
    ) -> String {
        if let surfaceId = panel?.id ?? hook?.surfaceId {
            return "\(kind.rawValue)-surface-\(surfaceId)"
        }
        if let sessionId = hook?.sessionId ?? panel?.terminalAgentSessionId ?? panel?.resumeSessionId {
            return "\(kind.rawValue)-session-\(sessionId)"
        }
        return "\(kind.rawValue)-\(process?.pid ?? 0)"
    }

    private func resolvedCodexState(_ runtimeState: AgentState?, cmuxState: AgentState) -> AgentState {
        if cmuxState == .waitingApproval {
            return cmuxState
        }
        guard let runtimeState else {
            return cmuxState
        }
        if runtimeState == .unknown && cmuxState != .unknown {
            return cmuxState
        }
        return runtimeState
    }

    private func cmuxState(
        kind: AgentKind,
        panel: CmuxPanelSnapshot?,
        hook: CmuxHookSession?,
        workstream: CmuxWorkstreamItem?,
        hasLiveProcess: Bool,
        hasActiveToolChild: Bool
    ) -> AgentState {
        if isWaiting(hook?.lifecycle)
            || isWaiting(hook?.lastSubtitle)
            || isWaiting(hook?.lastBody)
            || panel?.notifications.contains(where: { isWaiting($0.title) || isWaiting($0.subtitle) || isWaiting($0.body) }) == true
            || isWaiting(workstream?.eventKind)
            || isWaiting(workstream?.title)
            || isWaiting(workstream?.text) {
            return .waitingApproval
        }

        if hasActiveToolChild {
            return .running
        }

        if let lifecycle = hook?.lifecycle?.lowercased() {
            if lifecycle.contains("running") || lifecycle.contains("busy") {
                return .running
            }
            if lifecycle.contains("idle") {
                return .idle
            }
            if lifecycle.contains("unknown") {
                return hasLiveProcess ? .idle : .unknown
            }
        }

        if let workstream {
            let eventKind = workstream.eventKind.lowercased()
            if eventKind == "userprompt" || eventKind == "tooluse" {
                return .running
            }
            if eventKind == "sessionstart" {
                if let lastSeenAt = workstream.lastSeenAt,
                   Date().timeIntervalSince(lastSeenAt) <= 30 {
                    return .running
                }
                return hasLiveProcess ? .idle : .stale
            }
            if eventKind == "sessionend" {
                return hasLiveProcess ? .idle : .stale
            }
            if eventKind == "stop" || eventKind == "subagentstop" || eventKind == "toolresult" || eventKind == "notification" {
                return hasLiveProcess ? .idle : .stale
            }
        }

        if hasLiveProcess {
            return .idle
        }
        if hook?.isRestorable == true {
            return .stale
        }
        return kind == .claude || kind == .codex ? .unknown : .unknown
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

    private func latestNotification(_ panel: CmuxPanelSnapshot?) -> CmuxNotificationSnapshot? {
        panel?.notifications.max {
            compareDates($0.createdAt, $1.createdAt) == .orderedAscending
        }
    }

    private func isWaiting(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else {
            return false
        }
        let lower = value.lowercased()
        let compact = lower.filter { $0.isLetter || $0.isNumber }

        if lower == "waiting"
            || lower.contains("waiting for your input")
            || lower.contains("claude is waiting")
            || lower.contains("completed") {
            return false
        }

        return compact.contains("needsinput")
            || lower.contains("permission")
            || lower.contains("approval")
            || lower.contains("approve")
            || lower.contains("confirm")
            || lower.contains("question")
            || lower.contains("批准")
            || lower.contains("确认")
            || lower.contains("问题")
            || lower.contains("回答")
            || lower.contains("权限")
            || lower.contains("需处理")
    }

    private func hasActiveChildProcess(rootPid: Int, processes: [ProcInfo], processByPid: [Int: ProcInfo]) -> Bool {
        processes.contains {
            $0.pid != rootPid && isDescendant($0.pid, of: Set([rootPid]), processByPid: processByPid)
        }
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

    private func loadCmuxPanels() -> [CmuxPanelSnapshot] {
        let path = "\(home)/Library/Application Support/cmux/session-com.cmuxterm.app.json"
        guard let data = fileManager.contents(atPath: path),
              let session = try? JSONDecoder().decode(CmuxAppSession.self, from: data) else {
            return []
        }

        return session.windows.flatMap { window in
            window.tabManager?.workspaces.flatMap { workspace in
                workspace.panels.map { panel in
                    CmuxPanelSnapshot(
                        id: panel.id,
                        workspaceTitle: workspace.customTitle ?? workspace.processTitle,
                        workspaceCwd: workspace.currentDirectory,
                        title: panel.title,
                        customTitle: panel.customTitle,
                        cwd: panel.terminal?.workingDirectory ?? panel.directory,
                        tty: panel.ttyName,
                        terminalAgentKind: agentKind(panel.terminal?.agent?.kind),
                        terminalAgentSessionId: panel.terminal?.agent?.sessionId,
                        resumeKind: agentKind(panel.terminal?.resumeBinding?.kind),
                        resumeSessionId: panel.terminal?.resumeBinding?.checkpointId,
                        notifications: panel.notifications?.map {
                            CmuxNotificationSnapshot(
                                title: $0.title,
                                subtitle: $0.subtitle,
                                body: $0.body,
                                createdAt: dateFromSeconds($0.createdAt),
                                isRead: $0.isRead
                            )
                        } ?? []
                    )
                }
            } ?? []
        }
    }

    private func loadCmuxHookIndex() -> CmuxHookIndex {
        var index = CmuxHookIndex()
        for kind in [AgentKind.codex, .claude] {
            let path = "\(home)/.cmuxterm/\(kind.rawValue)-hook-sessions.json"
            guard let data = fileManager.contents(atPath: path),
                  let hookFile = try? JSONDecoder().decode(CmuxHookSessionFile.self, from: data) else {
                continue
            }
            for (sessionId, session) in hookFile.sessions {
                index.add(CmuxHookSession(
                    kind: kind,
                    sessionId: session.sessionId ?? sessionId,
                    pid: session.pid,
                    workspaceId: session.workspaceId,
                    surfaceId: session.surfaceId,
                    cwd: session.cwd,
                    title: titleFromHookSession(session),
                    lifecycle: session.lifecycle ?? session.status,
                    lastSubtitle: session.lastSubtitle,
                    lastBody: session.lastBody,
                    updatedAt: dateFromSeconds(session.updatedAt),
                    startedAt: dateFromSeconds(session.startedAt),
                    isRestorable: session.isRestorable
                ))
            }
        }
        return index
    }

    private func titleFromHookSession(_ session: CmuxHookSessionFile.Session) -> String? {
        if let lastSubtitle = session.lastSubtitle,
           !isWaiting(lastSubtitle),
           !lastSubtitle.lowercased().contains("completed") {
            return lastSubtitle
        }
        return session.sessionId.map { "session \($0.prefix(8))" }
    }

    private func loadCmuxWorkstreamIndex() -> CmuxWorkstreamIndex {
        var index = CmuxWorkstreamIndex()
        let path = "\(home)/.cmuxterm/workstream.jsonl"
        guard let data = fileManager.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return index
        }

        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let raw = try? decoder.decode(CmuxWorkstreamRawItem.self, from: lineData),
                  let kind = agentKind(raw.source),
                  let workstreamId = raw.workstreamId,
                  let eventKind = raw.kind else {
                continue
            }
            let item = CmuxWorkstreamItem(
                kind: kind,
                workstreamId: workstreamId,
                sessionId: normalizedSessionId(workstreamId: workstreamId, source: raw.source),
                eventKind: eventKind,
                pid: raw.ppid,
                cwd: raw.cwd,
                title: raw.title,
                text: raw.payload?.userPrompt?.text,
                toolName: raw.payload?.toolUse?.toolName ?? raw.payload?.toolResult?.toolName,
                createdAt: parseISODate(raw.createdAt),
                updatedAt: parseISODate(raw.updatedAt)
            )
            index.add(item)
        }
        return index
    }

    private func normalizedSessionId(workstreamId: String, source: String?) -> String? {
        guard !workstreamId.isEmpty else {
            return nil
        }
        if let source, workstreamId.hasPrefix("\(source)-") {
            return String(workstreamId.dropFirst(source.count + 1))
        }
        return workstreamId
    }

    private func agentKind(_ raw: String?) -> AgentKind? {
        switch raw?.lowercased() {
        case "codex":
            return .codex
        case "claude", "claude-code", "claude code":
            return .claude
        default:
            return nil
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

    private func dateFromSeconds(_ value: Double?) -> Date? {
        guard let value, value > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: value)
    }

    private func parseISODate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
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

    private func compareDates(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult {
        compareOptionalDates(lhs, rhs)
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

private struct CmuxAppSession: Decodable {
    let windows: [Window]

    struct Window: Decodable {
        let tabManager: TabManager?
    }

    struct TabManager: Decodable {
        let workspaces: [Workspace]
    }

    struct Workspace: Decodable {
        let currentDirectory: String?
        let customTitle: String?
        let processTitle: String?
        let panels: [Panel]
    }

    struct Panel: Decodable {
        let id: String
        let type: String?
        let directory: String?
        let title: String?
        let customTitle: String?
        let ttyName: String?
        let terminal: Terminal?
        let notifications: [Notification]?
    }

    struct Terminal: Decodable {
        let workingDirectory: String?
        let agent: Agent?
        let resumeBinding: ResumeBinding?
    }

    struct Agent: Decodable {
        let kind: String?
        let sessionId: String?
    }

    struct ResumeBinding: Decodable {
        let kind: String?
        let checkpointId: String?
    }

    struct Notification: Decodable {
        let title: String?
        let subtitle: String?
        let body: String?
        let createdAt: Double?
        let isRead: Bool?
    }
}

private struct CmuxHookSessionFile: Decodable {
    let sessions: [String: Session]

    struct Session: Decodable {
        let cwd: String?
        let lifecycle: String?
        let status: String?
        let lastBody: String?
        let lastSubtitle: String?
        let pid: Int?
        let sessionId: String?
        let startedAt: Double?
        let surfaceId: String?
        let updatedAt: Double?
        let workspaceId: String?
        let isRestorable: Bool?
    }
}

private struct CmuxWorkstreamRawItem: Decodable {
    let workstreamId: String?
    let source: String?
    let kind: String?
    let ppid: Int?
    let cwd: String?
    let title: String?
    let createdAt: String?
    let updatedAt: String?
    let payload: Payload?

    struct Payload: Decodable {
        let userPrompt: UserPrompt?
        let toolUse: ToolUse?
        let toolResult: ToolResult?
    }

    struct UserPrompt: Decodable {
        let text: String?
    }

    struct ToolUse: Decodable {
        let toolName: String?
    }

    struct ToolResult: Decodable {
        let toolName: String?
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
