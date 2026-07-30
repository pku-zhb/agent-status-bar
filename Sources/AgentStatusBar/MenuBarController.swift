import AppKit
import Foundation

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let notificationController = AgentNotificationController()
    private let scanQueue = DispatchQueue(label: "AgentStatusBar.AgentScan", qos: .utility)
    private let creditRefreshQueue = DispatchQueue(label: "AgentStatusBar.CreditRefresh", qos: .utility)
    private let featurePreferences = MenuBarFeaturePreferences()
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
        let image = StatusBarIconRenderer.render(
            snapshot: lastSnapshot,
            credits: lastCredits,
            showsStatusHalos: featurePreferences.showsStatusHalos,
            showsUsage: featurePreferences.showsUsage
        )
        statusItem.length = image.size.width + 10
        button.image = image
        button.toolTip = tooltipText()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let haloItem = NSMenuItem(
            title: "显示状态光环",
            action: #selector(toggleStatusHalos),
            keyEquivalent: ""
        )
        haloItem.target = self
        haloItem.state = featurePreferences.showsStatusHalos ? .on : .off
        menu.addItem(haloItem)

        let usageItem = NSMenuItem(
            title: "显示用量",
            action: #selector(toggleUsage),
            keyEquivalent: ""
        )
        usageItem.target = self
        usageItem.state = featurePreferences.showsUsage ? .on : .off
        menu.addItem(usageItem)

        menu.addItem(.separator())
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

    private func tooltipText() -> String {
        guard featurePreferences.showsStatusHalos || featurePreferences.showsUsage else {
            return "Agent Status Bar"
        }

        let summary = lastSnapshot.summary
        var parts: [String] = []
        if featurePreferences.showsStatusHalos {
            parts.append("Claude \(summary.claude) · Codex \(summary.codex)")
            parts.append("运行 \(summary.running) · 需处理 \(summary.waitingApproval)")
        }
        if featurePreferences.showsUsage {
            parts.append("Claude\(tooltipCreditSuffix(for: .claude))")
            parts.append("Codex\(tooltipCreditSuffix(for: .codex))")
        }
        return parts.joined(separator: " · ")
    }

    private func refreshCreditsIfNeeded(force: Bool = false) {
        guard featurePreferences.showsUsage else {
            return
        }
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
        if credits.claude?.hasDisplayableUsage == true && credits.codex?.hasDisplayableUsage == true {
            return creditRefreshInterval
        }
        return creditRetryInterval
    }

    private func tooltipCreditSuffix(for kind: AgentKind) -> String {
        guard let credit = lastCredits.status(for: kind) else {
            return ""
        }
        return " (\(credit.menuText))"
    }

    @objc private func toggleStatusHalos() {
        featurePreferences.showsStatusHalos.toggle()
        updateStatusIcon()
        rebuildMenu()
    }

    @objc private func toggleUsage() {
        featurePreferences.showsUsage.toggle()
        if featurePreferences.showsUsage {
            nextCreditRefreshAt = .distantPast
            refreshCreditsIfNeeded(force: true)
        }
        updateStatusIcon()
        rebuildMenu()
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
