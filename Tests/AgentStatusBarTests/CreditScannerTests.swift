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
        try codexWeeklyOnlyPrimaryIsClassifiedAsWeekly()
        try codexLegacyDualWindowsUseDurationMetadata()
        try resetProgressKeepsSubPercentPrecisionAndResetsToZero()
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
                "fetchedAtMs": now.addingTimeInterval(-25 * 60 * 60).timeIntervalSince1970 * 1_000,
                "utilization": ["limits": [["kind": "session", "percent": 10]]]
            ]
        ])

        try expect(
            CreditScanner.claudeCreditStatus(fromConfigData: data, now: now) == nil,
            "Expected stale Claude cache to be rejected"
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

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw TestFailure.failed(message)
        }
    }
}
