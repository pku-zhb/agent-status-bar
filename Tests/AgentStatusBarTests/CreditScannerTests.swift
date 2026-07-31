import AppKit
import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct CreditScannerTests {
    static func main() throws {
        try claudeCacheReadsSessionWeeklyAndFableWindows()
        try claudeCacheRejectsStaleUsage()
        try claudeLiveUsageUsesTheSameWindowModel()
        try claudeDesktopCredentialsAreParsedWithoutOtherEnvironmentValues()
        try claudeDesktopProcessesAreIdentifiedByExecutablePath()
        try codexWeeklyOnlyPrimaryIsClassifiedAsWeekly()
        try codexLegacyDualWindowsUseDurationMetadata()
        try resetProgressKeepsSubPercentPrecisionAndResetsToZero()
        try featurePreferencesDefaultOnAndRemainIndependent()
        try statusHalosAndUsageChangeLayoutIndependently()
        print("CreditScanner tests passed")
    }

    static func claudeCacheReadsSessionWeeklyAndFableWindows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fiveHourReset = "2027-01-15T10:00:00.000Z"
        let weeklyReset = "2027-01-16T10:00:00.000Z"
        let fableReset = "2027-01-17T10:00:00.000Z"
        let data = try JSONSerialization.data(withJSONObject: [
            "cachedUsageUtilization": [
                "fetchedAtMs": now.timeIntervalSince1970 * 1_000,
                "utilization": [
                    "five_hour": ["utilization": 3, "resets_at": fiveHourReset],
                    "seven_day": ["utilization": 7, "resets_at": weeklyReset],
                    "limits": [
                        ["kind": "session", "group": "session", "percent": 12, "resets_at": fiveHourReset],
                        ["kind": "weekly_all", "group": "weekly", "percent": 34, "resets_at": weeklyReset],
                        [
                            "kind": "weekly_scoped",
                            "group": "weekly",
                            "percent": 56,
                            "resets_at": fableReset,
                            "scope": ["model": ["id": "claude-fable-5", "display_name": "Fable"]]
                        ]
                    ]
                ]
            ]
        ])

        guard let status = CreditScanner.claudeCreditStatus(fromConfigData: data, now: now) else {
            throw TestFailure.failed("Expected Claude cache status")
        }
        try expect(status.source == "claude-cache", "Unexpected Claude source")
        try expect(status.fiveHourRemainingPercent == 88, "Unexpected Claude five-hour remaining percent")
        try expect(status.weeklyRemainingPercent == 66, "Unexpected Claude weekly remaining percent")
        try expect(
            status.windows.map(\.id) == ["five-hour", "weekly-all", "weekly-fable"],
            "Unexpected Claude window order"
        )
        try expect(status.windows.map(\.usedPercent) == [12, 34, 56], "Unexpected Claude usage values")
    }

    static func claudeCacheRejectsStaleUsage() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = try JSONSerialization.data(withJSONObject: [
            "cachedUsageUtilization": [
                "fetchedAtMs": now.addingTimeInterval(-16 * 60).timeIntervalSince1970 * 1_000,
                "utilization": ["limits": [["kind": "session", "percent": 10]]]
            ]
        ])

        try expect(
            CreditScanner.claudeCreditStatus(fromConfigData: data, now: now) == nil,
            "Expected stale Claude cache to be rejected"
        )
    }

    static func claudeLiveUsageUsesTheSameWindowModel() throws {
        let status = CreditScanner.claudeCreditStatus(
            fromUtilization: [
                "limits": [
                    ["kind": "session", "percent": 4, "resets_at": "2027-01-15T10:00:00.000Z"],
                    ["kind": "weekly_all", "percent": 21, "resets_at": "2027-01-16T10:00:00.000Z"],
                    [
                        "kind": "weekly_scoped",
                        "percent": 39,
                        "resets_at": "2027-01-16T10:00:00.000Z",
                        "scope": ["model": ["display_name": "Fable"]]
                    ]
                ]
            ],
            source: "claude-api"
        )

        guard let status else {
            throw TestFailure.failed("Expected live Claude status")
        }
        try expect(status.source == "claude-api", "Unexpected live Claude source")
        try expect(status.windows.map(\.usedPercent) == [4, 21, 39], "Unexpected live Claude usage values")
    }

    static func claudeDesktopCredentialsAreParsedWithoutOtherEnvironmentValues() throws {
        let fields = CreditScanner.claudeProcessOAuthFields(from: """
        CLAUDE_CODE_SUBSCRIPTION_TYPE=max
        CLAUDE_CODE_OAUTH_TOKEN=test-oauth-token
        UNRELATED_SECRET=must-not-be-read
        """)

        try expect(fields?.accessToken == "test-oauth-token", "Claude process OAuth token was not parsed")
        try expect(fields?.subscriptionType == "max", "Claude subscription type was not parsed")
    }

    static func claudeDesktopProcessesAreIdentifiedByExecutablePath() throws {
        let processList = """
          120 /usr/local/bin/claude
          240 /Applications/Claude.app/Contents/MacOS/Claude
          360 /Users/test/Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS/claude
          480 /Users/test/other/claude.app/Contents/MacOS/claude
        """

        try expect(
            CreditScanner.claudeDesktopProcessIDs(from: processList) == [480, 360],
            "Claude Desktop process paths were not identified"
        )
    }

    static func codexWeeklyOnlyPrimaryIsClassifiedAsWeekly() throws {
        let primary: [String: Any] = [
            "usedPercent": 7,
            "windowDurationMins": 10_080,
            "resetsAt": 1_800_100_000
        ]

        let status = CreditScanner.codexStatus(from: ["primary": primary, "secondary": NSNull()])
        try expect(status.fiveHourRemainingPercent == nil, "Weekly-only Codex response was mislabeled as five-hour")
        try expect(status.weeklyRemainingPercent == 93, "Unexpected Codex weekly remaining percent")
        try expect(status.windows.map(\.id) == ["weekly"], "Unexpected Codex display windows")
        try expect(status.windows.first?.usedPercent == 7, "Unexpected Codex weekly usage")
    }

    static func codexLegacyDualWindowsUseDurationMetadata() throws {
        let primary: [String: Any] = ["usedPercent": 20, "windowDurationMins": 300]
        let secondary: [String: Any] = ["usedPercent": 40, "windowDurationMins": 10_080]
        let classified = CreditScanner.classifyCodexRateLimitWindows([
            "primary": primary,
            "secondary": secondary
        ])

        try expect(classified.fiveHour?["usedPercent"] as? Int == 20, "Codex five-hour window was not classified")
        try expect(classified.weekly?["usedPercent"] as? Int == 40, "Codex weekly window was not classified")
    }

    static func resetProgressKeepsSubPercentPrecisionAndResetsToZero() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let windowSeconds: TimeInterval = 5 * 60 * 60
        let window = AgentCreditWindow(
            id: "five-hour",
            label: "5h",
            usedPercent: 1,
            resetAt: now.addingTimeInterval(windowSeconds - 60),
            windowSeconds: windowSeconds
        )
        try expect(window.resetElapsedPercent(now: now) == 0.333, "Reset progress lost sub-percent precision")

        let expired = AgentCreditWindow(
            id: "five-hour",
            label: "5h",
            usedPercent: 1,
            resetAt: now,
            windowSeconds: windowSeconds
        )
        try expect(expired.resetElapsedPercent(now: now) == 0, "Expired reset window did not return to zero")
    }

    static func featurePreferencesDefaultOnAndRemainIndependent() throws {
        let suiteName = "AgentStatusBarTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw TestFailure.failed("Could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = MenuBarFeaturePreferences(defaults: defaults)
        try expect(preferences.showsStatusHalos, "Status halos should default on")
        try expect(preferences.showsUsage, "Usage should default on")

        preferences.showsStatusHalos = false
        let reloaded = MenuBarFeaturePreferences(defaults: defaults)
        try expect(!reloaded.showsStatusHalos, "Status halo setting was not persisted")
        try expect(reloaded.showsUsage, "Status halo setting changed usage setting")

        reloaded.showsUsage = false
        try expect(!preferences.showsStatusHalos, "Usage setting changed status halo setting")
        try expect(!preferences.showsUsage, "Usage setting was not persisted")
    }

    static func statusHalosAndUsageChangeLayoutIndependently() throws {
        let client = AgentClient(
            id: "claude-1",
            kind: .claude,
            pid: 1,
            parentPid: 0,
            workspaceId: nil,
            surfaceId: nil,
            tty: nil,
            state: .running,
            cwd: nil,
            title: nil,
            detail: nil,
            lastSeenAt: nil,
            waitingSince: nil
        )
        let snapshot = AgentSnapshot(
            generatedAt: Date(),
            agentPids: [1],
            clients: [client],
            summary: AgentSummary(
                total: 1,
                codex: 0,
                claude: 1,
                running: 1,
                waitingApproval: 0,
                idle: 0,
                stale: 0,
                unknown: 0
            )
        )
        let credit = AgentCreditStatus(
            fiveHourRemainingPercent: 80,
            weeklyRemainingPercent: nil,
            fiveHourResetAt: nil,
            weeklyResetAt: nil,
            unlimited: false,
            source: "test",
            windows: [
                AgentCreditWindow(
                    id: "five-hour",
                    label: "5h",
                    usedPercent: 20,
                    resetAt: nil,
                    windowSeconds: 5 * 60 * 60
                )
            ]
        )
        let credits = AgentCreditSnapshot(generatedAt: Date(), codex: credit, claude: credit)

        let all = StatusBarIconRenderer.render(
            snapshot: snapshot,
            credits: credits,
            showsStatusHalos: true,
            showsUsage: true
        ).size.width
        let halosOnly = StatusBarIconRenderer.render(
            snapshot: snapshot,
            credits: credits,
            showsStatusHalos: true,
            showsUsage: false
        ).size.width
        let usageOnly = StatusBarIconRenderer.render(
            snapshot: snapshot,
            credits: credits,
            showsStatusHalos: false,
            showsUsage: true
        ).size.width
        let iconsOnly = StatusBarIconRenderer.render(
            snapshot: snapshot,
            credits: credits,
            showsStatusHalos: false,
            showsUsage: false
        ).size.width

        try expect(all > halosOnly, "Usage toggle did not change menu bar layout")
        try expect(all > usageOnly, "Status halo toggle did not change menu bar layout")
        try expect(halosOnly > iconsOnly, "Status halos were not independently visible")
        try expect(usageOnly > iconsOnly, "Usage meters were not independently visible")
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw TestFailure.failed(message)
        }
    }
}
