import Foundation

final class CreditScanner {
    private static let fiveHours: TimeInterval = 5 * 60 * 60
    private static let sevenDays: TimeInterval = 7 * 24 * 60 * 60
    private static let claudeCacheMaxAge: TimeInterval = 15 * 60

    private let home: String
    private let fileManager = FileManager.default

    init(home: String = NSHomeDirectory()) {
        self.home = home
    }

    func scan() -> AgentCreditSnapshot {
        AgentCreditSnapshot(
            generatedAt: Date(),
            codex: codexCreditStatus(),
            claude: claudeCreditStatus()
        )
    }

    private func claudeCreditStatus() -> AgentCreditStatus? {
        if let liveUtilization = refreshClaudeUsage(),
           let liveStatus = Self.claudeCreditStatus(
               fromUtilization: liveUtilization,
               source: "claude-api"
           ) {
            return liveStatus
        }

        guard let data = fileManager.contents(atPath: claudeConfigJSONPath()) else {
            return nil
        }
        return Self.claudeCreditStatus(fromConfigData: data)
    }

    private func refreshClaudeUsage() -> [String: Any]? {
        guard let credentials = claudeCredentials(),
              let accessToken = credentials.accessToken,
              isClaudeSubscription(credentials.subscriptionType),
              let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ClaudeUsageResultBox()
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            resultBox.utilization = object
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 16) == .timedOut {
            task.cancel()
            return nil
        }
        return resultBox.utilization
    }

    private func claudeConfigJSONPath() -> String {
        guard let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !configDir.isEmpty else {
            return "\(home)/.claude.json"
        }

        let expanded: String
        if configDir == "~" {
            expanded = home
        } else if configDir.hasPrefix("~/") {
            expanded = "\(home)/\(configDir.dropFirst(2))"
        } else {
            expanded = configDir
        }
        return "\(expanded).json"
    }

    static func claudeCreditStatus(fromConfigData data: Data, now: Date = Date()) -> AgentCreditStatus? {
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cachedUsage = config["cachedUsageUtilization"] as? [String: Any] else {
            return nil
        }

        if let fetchedAtMilliseconds = double(cachedUsage["fetchedAtMs"]),
           now.timeIntervalSince1970 - fetchedAtMilliseconds / 1_000 > claudeCacheMaxAge {
            return nil
        }

        guard let utilization = cachedUsage["utilization"] as? [String: Any] else {
            return nil
        }

        return claudeCreditStatus(fromUtilization: utilization, source: "claude-cache")
    }

    static func claudeCreditStatus(
        fromUtilization utilization: [String: Any],
        source: String
    ) -> AgentCreditStatus? {
        let windows = claudeCreditWindows(utilization)
        guard !windows.isEmpty else {
            return nil
        }

        let fiveHour = windows.first { $0.id == "five-hour" }
        let weekly = windows.first { $0.id == "weekly-all" }
        return AgentCreditStatus(
            fiveHourRemainingPercent: fiveHour?.remainingPercent,
            weeklyRemainingPercent: weekly?.remainingPercent,
            fiveHourResetAt: fiveHour?.resetAt,
            weeklyResetAt: weekly?.resetAt,
            unlimited: false,
            source: source,
            windows: windows
        )
    }

    private static func claudeCreditWindows(_ utilization: [String: Any]) -> [AgentCreditWindow] {
        let limits = (utilization["limits"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        let sessionLimit = limits.first { string($0["kind"]) == "session" }
            ?? limits.first { string($0["group"]) == "session" }
        let weeklyAllLimit = limits.first { string($0["kind"]) == "weekly_all" }
            ?? limits.first {
                string($0["group"]) == "weekly" && !($0["scope"] is [String: Any])
            }
        let scopedWeeklyLimit = limits.first(where: isFableWeeklyLimit)
            ?? limits.first { string($0["kind"]) == "weekly_scoped" }

        return [
            limitWindow(id: "five-hour", label: "5h", limit: sessionLimit, windowSeconds: fiveHours)
                ?? utilizationWindow(
                    id: "five-hour",
                    label: "5h",
                    value: utilization["five_hour"] as? [String: Any],
                    windowSeconds: fiveHours
                ),
            limitWindow(id: "weekly-all", label: "W", limit: weeklyAllLimit, windowSeconds: sevenDays)
                ?? utilizationWindow(
                    id: "weekly-all",
                    label: "W",
                    value: utilization["seven_day"] as? [String: Any],
                    windowSeconds: sevenDays
                ),
            limitWindow(id: "weekly-fable", label: "F", limit: scopedWeeklyLimit, windowSeconds: sevenDays)
        ].compactMap { $0 }
    }

    private static func limitWindow(
        id: String,
        label: String,
        limit: [String: Any]?,
        windowSeconds: TimeInterval
    ) -> AgentCreditWindow? {
        guard let limit else {
            return nil
        }
        let usedPercent = percent(limit["percent"])
        let resetAt = isoDate(limit["resets_at"])
        guard usedPercent != nil || resetAt != nil else {
            return nil
        }
        return AgentCreditWindow(
            id: id,
            label: label,
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowSeconds: windowSeconds
        )
    }

    private static func utilizationWindow(
        id: String,
        label: String,
        value: [String: Any]?,
        windowSeconds: TimeInterval
    ) -> AgentCreditWindow? {
        guard let value else {
            return nil
        }
        let usedPercent = percent(value["utilization"])
        let resetAt = isoDate(value["resets_at"])
        guard usedPercent != nil || resetAt != nil else {
            return nil
        }
        return AgentCreditWindow(
            id: id,
            label: label,
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowSeconds: windowSeconds
        )
    }

    private static func isFableWeeklyLimit(_ limit: [String: Any]) -> Bool {
        guard string(limit["kind"]) == "weekly_scoped",
              let scope = limit["scope"] as? [String: Any],
              let model = scope["model"] as? [String: Any] else {
            return false
        }
        let modelID = string(model["id"])?.lowercased() ?? ""
        let displayName = string(model["display_name"])?.lowercased() ?? ""
        return modelID.contains("fable") || displayName.contains("fable")
    }

    private func codexCreditStatus() -> AgentCreditStatus? {
        guard let codex = codexExecutablePath() else {
            return nil
        }

        let request = """
        {"id":1,"method":"initialize","params":{"clientInfo":{"name":"agent-status-bar","title":null,"version":"dev"},"capabilities":null}}
        {"id":2,"method":"account/rateLimits/read"}

        """
        guard let result = ProcessRunner.run(
            codex,
            ["app-server", "--stdio", "--disable", "apps"],
            timeout: 12,
            stdin: request,
            closeStdinAfter: 4,
            environment: codexProcessEnvironment(executablePath: codex)
        ), result.exitCode == 0 else {
            return nil
        }

        return parseCodexRateLimits(stdout: result.stdout)
    }

    private func parseCodexRateLimits(stdout: String) -> AgentCreditStatus? {
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Self.double(object["id"]) == 2,
                  let result = object["result"] as? [String: Any],
                  let rateLimits = result["rateLimits"] as? [String: Any] else {
                continue
            }
            return Self.codexStatus(from: rateLimits)
        }
        return nil
    }

    static func codexStatus(from rateLimits: [String: Any]) -> AgentCreditStatus {
        let classified = classifyCodexRateLimitWindows(rateLimits)
        let fiveHour = classified.fiveHour
        let weekly = classified.weekly
        let credits = rateLimits["credits"] as? [String: Any]
        let weeklyUsedPercent = percent(weekly?["usedPercent"])
        let weeklyResetAt = unixDate(weekly?["resetsAt"])

        return AgentCreditStatus(
            fiveHourRemainingPercent: remainingPercent(fiveHour?["usedPercent"]),
            weeklyRemainingPercent: remainingPercent(weeklyUsedPercent),
            fiveHourResetAt: unixDate(fiveHour?["resetsAt"]),
            weeklyResetAt: weeklyResetAt,
            unlimited: bool(credits?["unlimited"]) ?? false,
            source: "codex-app-server",
            windows: [AgentCreditWindow(
                id: "weekly",
                label: "W",
                usedPercent: weeklyUsedPercent,
                resetAt: weeklyResetAt,
                windowSeconds: sevenDays
            )]
        )
    }

    static func classifyCodexRateLimitWindows(
        _ rateLimits: [String: Any]
    ) -> (fiveHour: [String: Any]?, weekly: [String: Any]?) {
        let primary = rateLimits["primary"] as? [String: Any]
        let secondary = rateLimits["secondary"] as? [String: Any]
        let windows = [primary, secondary].compactMap { $0 }
        let hasDurationMetadata = windows.contains { double($0["windowDurationMins"]) != nil }

        guard hasDurationMetadata else {
            return (primary, secondary)
        }

        return (
            windows.first {
                guard let duration = double($0["windowDurationMins"]) else { return false }
                return duration <= 24 * 60
            },
            windows.first {
                guard let duration = double($0["windowDurationMins"]) else { return false }
                return duration > 24 * 60
            }
        )
    }

    private func codexExecutablePath() -> String? {
        codexExecutableCandidates().first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func codexExecutableCandidates() -> [String] {
        var candidates: [String] = []
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { "\($0)/codex" })
        }

        candidates.append(contentsOf: [
            "\(home)/.local/bin/codex",
            "\(home)/.local/share/fnm/current/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ])
        candidates.append(contentsOf: fnmNodeVersionCandidates())
        candidates.append(contentsOf: fnmMultishellCandidates())

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func codexProcessEnvironment(executablePath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let executableDir = URL(fileURLWithPath: executablePath).deletingLastPathComponent().path
        let currentPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(executableDir):\(currentPath)"
        environment["HOME"] = home
        return environment
    }

    private func fnmNodeVersionCandidates() -> [String] {
        let root = "\(home)/.local/share/fnm/node-versions"
        guard let versions = try? fileManager.contentsOfDirectory(atPath: root) else {
            return []
        }
        return versions.sorted().reversed().map { "\(root)/\($0)/installation/bin/codex" }
    }

    private func fnmMultishellCandidates() -> [String] {
        let root = "\(home)/.local/state/fnm_multishells"
        guard let shells = try? fileManager.contentsOfDirectory(atPath: root) else {
            return []
        }
        return shells.sorted().reversed().map { "\(root)/\($0)/bin/codex" }
    }

    private func claudeCredentials() -> ClaudeOAuthCredentials? {
        if let processCredentials = readRunningClaudeCredentials() {
            return processCredentials
        }

        if let keychainCredentials = readClaudeKeychainCredentials() {
            if isClaudeSubscription(keychainCredentials.subscriptionType) {
                return keychainCredentials
            }
            if let subscriptionType = readClaudeFileSubscriptionType() {
                return ClaudeOAuthCredentials(
                    accessToken: keychainCredentials.accessToken,
                    subscriptionType: subscriptionType,
                    expiresAt: keychainCredentials.expiresAt
                )
            }
            return keychainCredentials
        }

        return readClaudeFileCredentials()
    }

    private func readRunningClaudeCredentials() -> ClaudeOAuthCredentials? {
        guard let processList = ProcessRunner.run(
            "/bin/ps",
            ["-axo", "pid=,comm="],
            timeout: 3
        ), processList.exitCode == 0 else {
            return nil
        }

        for pid in Self.claudeDesktopProcessIDs(from: processList.stdout) {
            let script = #"""
            /bin/ps eww -p "$1" -o command= \
              | /usr/bin/tr ' ' '\n' \
              | /usr/bin/awk -F= '
                  $1 == "CLAUDE_CODE_OAUTH_TOKEN" ||
                  $1 == "CLAUDE_CODE_SUBSCRIPTION_TYPE" {
                      print
                  }
                '
            """#
            guard let result = ProcessRunner.run(
                "/bin/zsh",
                ["-c", script, "agent-status-bar", String(pid)],
                timeout: 3
            ), result.exitCode == 0,
               let fields = Self.claudeProcessOAuthFields(from: result.stdout) else {
                continue
            }

            return ClaudeOAuthCredentials(
                accessToken: fields.accessToken,
                subscriptionType: fields.subscriptionType ?? "subscription",
                expiresAt: nil
            )
        }
        return nil
    }

    static func claudeDesktopProcessIDs(from processList: String) -> [Int] {
        processList
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> Int? in
                let fields = line.split(
                    maxSplits: 1,
                    omittingEmptySubsequences: true,
                    whereSeparator: { $0.isWhitespace }
                )
                guard fields.count == 2,
                      fields[1].hasSuffix("/claude.app/Contents/MacOS/claude") else {
                    return nil
                }
                return Int(fields[0])
            }
            .sorted(by: >)
    }

    static func claudeProcessOAuthFields(
        from output: String
    ) -> (accessToken: String, subscriptionType: String?)? {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  pair[0] == "CLAUDE_CODE_OAUTH_TOKEN"
                    || pair[0] == "CLAUDE_CODE_SUBSCRIPTION_TYPE" else {
                continue
            }
            values[String(pair[0])] = String(pair[1])
        }

        guard let accessToken = values["CLAUDE_CODE_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            return nil
        }
        let subscriptionType = values["CLAUDE_CODE_SUBSCRIPTION_TYPE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            accessToken,
            subscriptionType?.isEmpty == false ? subscriptionType : nil
        )
    }

    private func readClaudeKeychainCredentials() -> ClaudeOAuthCredentials? {
        let serviceName = "Claude Code-credentials"
        let accountName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)

        if !accountName.isEmpty,
           let credentials = loadClaudeKeychainCredentials(serviceName: serviceName, accountName: accountName) {
            return credentials
        }
        return loadClaudeKeychainCredentials(serviceName: serviceName, accountName: nil)
    }

    private func loadClaudeKeychainCredentials(
        serviceName: String,
        accountName: String?
    ) -> ClaudeOAuthCredentials? {
        var arguments = ["find-generic-password", "-s", serviceName]
        if let accountName {
            arguments.append(contentsOf: ["-a", accountName])
        }
        arguments.append("-w")

        guard let result = ProcessRunner.run("/usr/bin/security", arguments, timeout: 3),
              result.exitCode == 0,
              let data = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data) else {
            return nil
        }
        return validClaudeCredentials(file.claudeAiOauth)
    }

    private func readClaudeFileCredentials() -> ClaudeOAuthCredentials? {
        let path = "\(home)/.claude/.credentials.json"
        guard let data = fileManager.contents(atPath: path),
              let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data) else {
            return nil
        }
        return validClaudeCredentials(file.claudeAiOauth)
    }

    private func readClaudeFileSubscriptionType() -> String? {
        let path = "\(home)/.claude/.credentials.json"
        guard let data = fileManager.contents(atPath: path),
              let file = try? JSONDecoder().decode(ClaudeCredentialsFile.self, from: data),
              let subscriptionType = file.claudeAiOauth?.subscriptionType?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !subscriptionType.isEmpty else {
            return nil
        }
        return subscriptionType
    }

    private func validClaudeCredentials(_ credentials: ClaudeOAuthCredentials?) -> ClaudeOAuthCredentials? {
        guard let credentials,
              let accessToken = credentials.accessToken,
              !accessToken.isEmpty else {
            return nil
        }
        if let expiresAt = credentials.expiresAt,
           expiresAt <= Date().timeIntervalSince1970 * 1_000 {
            return nil
        }
        return credentials
    }

    private func isClaudeSubscription(_ subscriptionType: String?) -> Bool {
        guard let subscriptionType = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !subscriptionType.isEmpty else {
            return false
        }
        return !subscriptionType.lowercased().contains("api")
    }

    private static func remainingPercent(_ value: Any?) -> Int? {
        guard let used = percent(value) else {
            return nil
        }
        return min(100, max(0, 100 - used))
    }

    private static func percent(_ value: Any?) -> Int? {
        guard let value = double(value) else {
            return nil
        }
        return min(100, max(0, Int(value.rounded())))
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue.isFinite ? value.doubleValue : nil
        }
        if let value = value as? String, let parsed = Double(value), parsed.isFinite {
            return parsed
        }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            return value.lowercased() == "true"
        }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unixDate(_ value: Any?) -> Date? {
        guard let seconds = double(value), seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let value = string(value) else {
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
}

private final class ClaudeUsageResultBox: @unchecked Sendable {
    var utilization: [String: Any]?
}

private struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: ClaudeOAuthCredentials?
}

private struct ClaudeOAuthCredentials: Decodable {
    let accessToken: String?
    let subscriptionType: String?
    let expiresAt: Double?
}
