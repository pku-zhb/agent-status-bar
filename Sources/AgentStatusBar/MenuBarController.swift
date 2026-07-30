import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notificationController = AgentNotificationController()
    private let scanQueue = DispatchQueue(label: "AgentStatusBar.AgentScan", qos: .utility)
    private let creditRefreshQueue = DispatchQueue(label: "AgentStatusBar.CreditRefresh", qos: .utility)
    private let home = NSHomeDirectory()
    private let scanInterval: TimeInterval = 5
    private let creditRefreshInterval: TimeInterval = 5 * 60
    private let creditRetryInterval: TimeInterval = 60
    private var scanTimer: Timer?
    private var lastSnapshot = AgentSnapshot.empty
    private var lastCredits = AgentCreditSnapshot.empty
    private var scanInFlight = false
    private var forceCreditRefreshAfterScan = false
    private var creditRefreshInFlight = false
    private var nextCreditRefreshAt = Date.distantPast
    private var hasScannedAgents = false

    override init() {
        super.init()
        configureStatusItem()
        refresh()
        scanTimer = Timer.scheduledTimer(withTimeInterval: scanInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        scanTimer?.tolerance = 1
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = "Codex / Claude Code 状态"
        }
        statusItem.menu = NSMenu()
    }

    @objc private func refresh() {
        refresh(forceCredits: false)
    }

    @objc private func refreshNow() {
        refresh(forceCredits: true)
    }

    private func refresh(forceCredits: Bool) {
        if forceCredits {
            forceCreditRefreshAfterScan = true
        }
        guard !scanInFlight else {
            return
        }

        scanInFlight = true
        let home = home
        scanQueue.async { [weak self, home] in
            let snapshot = AgentScanner(home: home).scan()
            DispatchQueue.main.async { [weak self] in
                self?.applySnapshot(snapshot)
            }
        }
    }

    private func applySnapshot(_ snapshot: AgentSnapshot) {
        let forceCreditRefresh = forceCreditRefreshAfterScan
        forceCreditRefreshAfterScan = false
        let previousSnapshot = lastSnapshot
        notificationController.handleTransition(
            from: previousSnapshot,
            to: snapshot,
            isInitialSnapshot: !hasScannedAgents
        )
        hasScannedAgents = true
        lastSnapshot = snapshot
        scanInFlight = false
        refreshCreditsIfNeeded(force: forceCreditRefresh)
        updateStatusIcon()
        rebuildMenu()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else {
            return
        }
        let image = StatusBarIconRenderer.render(snapshot: lastSnapshot, credits: lastCredits)
        statusItem.length = image.size.width + 10
        button.image = image
        button.toolTip = tooltipText()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        let summary = lastSnapshot.summary
        let claudeClients = sessionSortedClients(lastSnapshot.clients.filter { $0.kind == .claude })
        let codexClients = sessionSortedClients(lastSnapshot.clients.filter { $0.kind == .codex })

        menu.addItem(disabled("Agent 状态"))
        menu.addItem(viewItem(AgentGroupRowView(
            kind: .claude,
            clients: claudeClients,
            credit: credit(for: .claude)
        )))
        menu.addItem(viewItem(AgentGroupRowView(
            kind: .codex,
            clients: codexClients,
            credit: credit(for: .codex)
        )))
        menu.addItem(disabled("白环 空闲 · 绿环 运行中 · 红光 需处理"))
        menu.addItem(disabled("总数 \(summary.total) · 运行 \(summary.running) · 需处理 \(summary.waitingApproval)"))
        if summary.unknown > 0 {
            menu.addItem(disabled("未知 \(summary.unknown)"))
        }
        menu.addItem(NSMenuItem.separator())

        if lastSnapshot.clients.isEmpty {
            menu.addItem(disabled("没有检测到 Codex / Claude Code 进程"))
        } else {
            addSection(title: "需要处理", clients: clients(in: .waitingApproval), emptyText: "无", to: menu)
            addSection(title: "运行中", clients: clients(in: .running), emptyText: "无", to: menu)
            addSection(title: "空闲", clients: idleClients(), emptyText: "无", to: menu)
            addSection(title: "未知", clients: unknownClients(), emptyText: "无", to: menu)
        }

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "刷新", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let copyItem = NSMenuItem(title: "复制 JSON 快照", action: #selector(copySnapshot), keyEquivalent: "c")
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addSection(title: String, clients: [AgentClient], emptyText: String, to menu: NSMenu) {
        menu.addItem(disabled(title))
        if clients.isEmpty {
            menu.addItem(disabled("  \(emptyText)"))
            return
        }
        for client in clients {
            menu.addItem(viewItem(AgentClientRowView(
                client: client,
                title: displayTitle(for: client),
                subtitle: subtitle(for: client)
            )))
        }
    }

    private func clients(in state: AgentState) -> [AgentClient] {
        sortedClients(lastSnapshot.clients.filter { $0.state == state })
    }

    private func idleClients() -> [AgentClient] {
        sortedClients(lastSnapshot.clients.filter { $0.state == .idle || $0.state == .stale })
    }

    private func unknownClients() -> [AgentClient] {
        sortedClients(lastSnapshot.clients.filter { $0.state == .unknown })
    }

    private func sessionSortedClients(_ clients: [AgentClient]) -> [AgentClient] {
        clients.sorted {
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.pid < $1.pid
        }
    }

    private func sortedClients(_ clients: [AgentClient]) -> [AgentClient] {
        clients.sorted {
            if $0.state.sortRank != $1.state.sortRank {
                return $0.state.sortRank < $1.state.sortRank
            }
            if $0.kind.rawValue != $1.kind.rawValue {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.pid < $1.pid
        }
    }

    private func displayTitle(for client: AgentClient) -> String {
        if let title = client.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let cwd = client.cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return "\(client.kind.displayName) 会话"
    }

    private func subtitle(for client: AgentClient) -> String {
        var parts = [displayStateName(for: client.state)]

        if let waitingSince = client.waitingSince, client.state == .waitingApproval {
            parts.append("已等 \(durationText(since: waitingSince))")
        } else if let lastSeenAt = client.lastSeenAt {
            parts.append("\(durationText(since: lastSeenAt))前")
        }

        if let cwd = client.cwd, !cwd.isEmpty {
            let folder = URL(fileURLWithPath: cwd).lastPathComponent
            if folder != displayTitle(for: client) {
                parts.append(folder)
            }
        }

        return parts.joined(separator: " · ")
    }

    private func displayStateName(for state: AgentState) -> String {
        state == .stale ? AgentState.idle.displayName : state.displayName
    }

    private func tooltipText() -> String {
        let summary = lastSnapshot.summary
        return "Claude \(summary.claude)\(tooltipCreditSuffix(for: .claude)) · Codex \(summary.codex)\(tooltipCreditSuffix(for: .codex)) · 运行 \(summary.running) · 需处理 \(summary.waitingApproval)"
    }

    private func refreshCreditsIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now >= nextCreditRefreshAt else {
            return
        }
        guard !creditRefreshInFlight else {
            return
        }

        creditRefreshInFlight = true
        let home = home
        creditRefreshQueue.async { [weak self, home] in
            let credits = CreditScanner(home: home).scan()
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    return
                }
                self.lastCredits = credits.replacingMissingValues(with: self.lastCredits)
                self.creditRefreshInFlight = false
                self.nextCreditRefreshAt = Date().addingTimeInterval(self.nextCreditRefreshInterval(for: credits))
                self.updateStatusIcon()
                self.rebuildMenu()
            }
        }
    }

    private func nextCreditRefreshInterval(for credits: AgentCreditSnapshot) -> TimeInterval {
        if credits.claude?.hasDisplayableUsage == true || credits.codex?.hasDisplayableUsage == true {
            return creditRefreshInterval
        }
        return creditRetryInterval
    }

    private func credit(for kind: AgentKind) -> AgentCreditStatus? {
        lastCredits.status(for: kind)
    }

    private func tooltipCreditSuffix(for kind: AgentKind) -> String {
        guard let credit = lastCredits.status(for: kind) else {
            return ""
        }
        return " (\(credit.menuText))"
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func viewItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.view = view
        return item
    }

    private func durationText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        return "\(minutes / 60)h"
    }

    @objc private func copySnapshot() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = DebugSnapshot(agents: lastSnapshot, credits: lastCredits)
        guard let data = try? encoder.encode(snapshot),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private struct DebugSnapshot: Codable {
    let agents: AgentSnapshot
    let credits: AgentCreditSnapshot
}
