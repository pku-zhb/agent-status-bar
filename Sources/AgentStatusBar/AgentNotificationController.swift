import Foundation
import UserNotifications

@MainActor
final class AgentNotificationController: NSObject {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        requestAuthorization()
    }

    func handleTransition(from previous: AgentSnapshot, to current: AgentSnapshot, isInitialSnapshot: Bool) {
        guard !isInitialSnapshot else {
            return
        }

        let previousById = Dictionary(uniqueKeysWithValues: previous.clients.map { ($0.id, $0) })
        let needsAttention = current.clients.filter { client in
            client.state == .waitingApproval && previousById[client.id]?.state != .waitingApproval
        }
        let becameIdle = current.clients.filter { client in
            previousById[client.id]?.state == .running && (client.state == .idle || client.state == .stale)
        }

        if !needsAttention.isEmpty {
            sendNotification(
                kind: "needs-attention",
                title: title(for: needsAttention, action: "需要处理"),
                body: body(for: needsAttention, fallback: "出现红色状态，需要处理。")
            )
        }

        if !becameIdle.isEmpty {
            sendNotification(
                kind: "became-idle",
                title: title(for: becameIdle, action: "已空闲"),
                body: body(for: becameIdle, fallback: "运行已结束，状态从绿色变为空闲。")
            )
        }
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(kind: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "agent-status-bar.\(kind)"

        let request = UNNotificationRequest(
            identifier: "agent-status-bar.\(kind).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func title(for clients: [AgentClient], action: String) -> String {
        guard clients.count == 1, let client = clients.first else {
            return "\(clients.count) 个 Agent \(action)"
        }
        return "\(client.kind.displayName) \(action)"
    }

    private func body(for clients: [AgentClient], fallback: String) -> String {
        let names = clients.prefix(3).map(displayName)
        guard !names.isEmpty else {
            return fallback
        }

        let suffix = clients.count > names.count ? " 等 \(clients.count) 个会话" : ""
        return names.joined(separator: "、") + suffix
    }

    private func displayName(for client: AgentClient) -> String {
        if let title = client.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let cwd = client.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return "\(client.kind.displayName) \(client.pid)"
    }
}

extension AgentNotificationController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
