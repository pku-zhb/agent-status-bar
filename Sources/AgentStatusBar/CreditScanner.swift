import Foundation

final class CreditScanner {
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
        if let usage = refreshClaudeUsage(), usage.hasUsagePercent {
            return claudeCreditStatus(from: usage, source: "claude-hud-api")
        }

        guard let usage = cachedClaudeUsage() else {
            return nil
        }

        return claudeCreditStatus(from: usage, source: "claude-hud-cache")
    }

    private func claudeCreditStatus(from usage: ClaudeUsageData, source: String) -> AgentCreditStatus {
        AgentCreditStatus(
            fiveHourRemainingPercent: remainingPercent(fromUsedPercent: usage.fiveHour),
            weeklyRemainingPercent: remainingPercent(fromUsedPercent: usage.sevenDay),
            fiveHourResetAt: parseISODate(usage.fiveHourResetAt),
            weeklyResetAt: parseISODate(usage.sevenDayResetAt),
            unlimited: false,
            source: source
        )
    }

    private func cachedClaudeUsage() -> ClaudeUsageData? {
        let path = "\(home)/.claude/plugins/claude-hud/.usage-cache.json"
        guard let data = fileManager.contents(atPath: path),
              let cache = try? JSONDecoder().decode(ClaudeUsageCache.self, from: data) else {
            return nil
        }

        return [cache.data, cache.lastGoodData]
            .compactMap { $0 }
            .first { $0.hasUsagePercent }
    }

    private func refreshClaudeUsage() -> ClaudeUsageData? {
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
                  let decoded = try? JSONDecoder().decode(ClaudeUsageApiResponse.self, from: data) else {
                return
            }
            resultBox.usage = ClaudeUsageData(
                fiveHour: decoded.fiveHour?.utilization,
                sevenDay: decoded.sevenDay?.utilization,
                fiveHourResetAt: decoded.fiveHour?.resetsAt,
                sevenDayResetAt: decoded.sevenDay?.resetsAt
            )
        }
        task.resume()

        if semaphore.wait(timeout: .now() + 16) == .timedOut {
            task.cancel()
            return nil
        }
        return resultBox.usage
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
                  number(object["id"]) == 2,
                  let result = object["result"] as? [String: Any],
                  let rateLimits = result["rateLimits"] as? [String: Any] else {
                continue
            }

            return codexStatus(from: rateLimits)
        }
        return nil
    }

    private func codexStatus(from rateLimits: [String: Any]) -> AgentCreditStatus {
        let primary = rateLimits["primary"] as? [String: Any]
        let secondary = rateLimits["secondary"] as? [String: Any]
        let credits = rateLimits["credits"] as? [String: Any]

        return AgentCreditStatus(
            fiveHourRemainingPercent: remainingPercent(fromUsedPercent: primary?["usedPercent"]),
            weeklyRemainingPercent: remainingPercent(fromUsedPercent: secondary?["usedPercent"]),
            fiveHourResetAt: dateFromUnixSeconds(primary?["resetsAt"]),
            weeklyResetAt: dateFromUnixSeconds(secondary?["resetsAt"]),
            unlimited: bool(credits?["unlimited"]) ?? false,
            source: "codex-app-server"
        )
    }

    private func codexExecutablePath() -> String? {
        for candidate in codexExecutableCandidates() where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func codexExecutableCandidates() -> [String] {
        var candidates: [String] = []
        let env = ProcessInfo.processInfo.environment

        if let path = env["PATH"] {
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

    private func readClaudeKeychainCredentials() -> ClaudeOAuthCredentials? {
        let serviceNames = ["Claude Code-credentials"]
        let accountName = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)

        for serviceName in serviceNames {
            if !accountName.isEmpty,
               let credentials = loadClaudeKeychainCredentials(serviceName: serviceName, accountName: accountName) {
                return credentials
            }
            if let credentials = loadClaudeKeychainCredentials(serviceName: serviceName, accountName: nil) {
                return credentials
            }
        }
        return nil
    }

    private func loadClaudeKeychainCredentials(serviceName: String, accountName: String?) -> ClaudeOAuthCredentials? {
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
              let subscriptionType = file.claudeAiOauth?.subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
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
           expiresAt <= Date().timeIntervalSince1970 * 1000 {
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

    private func remainingPercent(fromUsedPercent value: Any?) -> Int? {
        guard let used = number(value) else {
            return nil
        }
        return clampedPercent(100 - used)
    }

    private func clampedPercent(_ value: Int?) -> Int? {
        guard let value else {
            return nil
        }
        return min(100, max(0, value))
    }

    private func number(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value.rounded())
        }
        if let value = value as? NSNumber {
            return Int(value.doubleValue.rounded())
        }
        if let value = value as? String,
           let double = Double(value) {
            return Int(double.rounded())
        }
        return nil
    }

    private func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            return Bool(value)
        }
        return nil
    }

    private func dateFromUnixSeconds(_ value: Any?) -> Date? {
        guard let seconds = number(value), seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: Double(seconds))
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
}

private struct ClaudeUsageCache: Decodable {
    let data: ClaudeUsageData?
    let lastGoodData: ClaudeUsageData?
}

private struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: ClaudeOAuthCredentials?
}

private final class ClaudeUsageResultBox: @unchecked Sendable {
    var usage: ClaudeUsageData?
}

private struct ClaudeOAuthCredentials: Decodable {
    let accessToken: String?
    let subscriptionType: String?
    let expiresAt: Double?
}

private struct ClaudeUsageApiResponse: Decodable {
    let fiveHour: ClaudeUsageWindow?
    let sevenDay: ClaudeUsageWindow?

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct ClaudeUsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

private struct ClaudeUsageData: Decodable {
    let fiveHour: Double?
    let sevenDay: Double?
    let fiveHourResetAt: String?
    let sevenDayResetAt: String?

    var hasUsagePercent: Bool {
        fiveHour != nil || sevenDay != nil
    }
}
