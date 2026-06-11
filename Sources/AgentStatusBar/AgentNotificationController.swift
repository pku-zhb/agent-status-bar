import Foundation
import OSLog
import UserNotifications

@MainActor
final class AgentNotificationController: NSObject {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.zhuhuibin.AgentStatusBar", category: "notifications")
    private let idleSettleInterval: TimeInterval = 20
    private let completionSettleInterval: TimeInterval = 20
    private let attentionSettleInterval: TimeInterval = 2
    private let notificationCooldown: TimeInterval = 5 * 60
    private var clientStates: [String: ClientNotificationState] = [:]

    override init() {
        super.init()
        center.delegate = self
        requestAuthorization()
    }

    func handleTransition(from previous: AgentSnapshot, to current: AgentSnapshot, isInitialSnapshot: Bool) {
        guard !isInitialSnapshot else {
            seedClientStates(from: current)
            return
        }

        let now = Date()
        let previousById = Dictionary(uniqueKeysWithValues: previous.clients.map { ($0.id, $0) })
        var needsAttention: [AgentClient] = []
        var becameIdle: [AgentClient] = []

        for client in current.clients {
            var notificationState = clientStates[client.id] ?? ClientNotificationState()
            let previousState = previousById[client.id]?.state ?? notificationState.lastObservedState

            updateIdleNotificationState(
                &notificationState,
                client: client,
                previousState: previousState,
                now: now,
                readyClients: &becameIdle
            )
            updateCompletionNotificationState(
                &notificationState,
                client: client,
                now: now,
                readyClients: &becameIdle
            )
            updateAttentionNotificationState(
                &notificationState,
                client: client,
                previousState: previousState,
                now: now,
                readyClients: &needsAttention
            )

            notificationState.lastObservedState = client.state
            notificationState.lastObservedCompletionId = client.completedTurnId
            clientStates[client.id] = notificationState
        }

        let currentIds = Set(current.clients.map(\.id))
        clientStates = clientStates.filter { currentIds.contains($0.key) }

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

    private func seedClientStates(from snapshot: AgentSnapshot) {
        clientStates = Dictionary(uniqueKeysWithValues: snapshot.clients.map {
            ($0.id, ClientNotificationState(lastObservedState: $0.state, lastObservedCompletionId: $0.completedTurnId))
        })
    }

    private func updateIdleNotificationState(
        _ notificationState: inout ClientNotificationState,
        client: AgentClient,
        previousState: AgentState?,
        now: Date,
        readyClients: inout [AgentClient]
    ) {
        if client.kind == .codex && client.completedTurnId != nil {
            return
        }

        let isIdle = client.state == .idle || client.state == .stale
        guard isIdle else {
            notificationState.pendingIdleSince = nil
            return
        }

        if previousState == .running && notificationState.pendingIdleSince == nil {
            notificationState.pendingIdleSince = now
        }

        guard let pendingSince = notificationState.pendingIdleSince,
              now.timeIntervalSince(pendingSince) >= idleSettleInterval,
              canSend(lastSentAt: notificationState.lastIdleNotificationAt, now: now) else {
            return
        }

        readyClients.append(client)
        notificationState.pendingIdleSince = nil
        notificationState.lastIdleNotificationAt = now
    }

    private func updateCompletionNotificationState(
        _ notificationState: inout ClientNotificationState,
        client: AgentClient,
        now: Date,
        readyClients: inout [AgentClient]
    ) {
        guard client.kind == .codex,
              let completedTurnId = client.completedTurnId,
              client.completedAt != nil else {
            notificationState.pendingCompletion = nil
            return
        }

        if completedTurnId != notificationState.lastObservedCompletionId,
           notificationState.pendingCompletion?.turnId != completedTurnId {
            notificationState.pendingCompletion = PendingCompletion(
                turnId: completedTurnId,
                since: now,
                client: client
            )
        }

        guard let pending = notificationState.pendingCompletion,
              pending.turnId == completedTurnId,
              now.timeIntervalSince(pending.since) >= completionSettleInterval,
              canSend(lastSentAt: notificationState.lastIdleNotificationAt, now: now) else {
            return
        }

        readyClients.append(pending.client)
        notificationState.pendingCompletion = nil
        notificationState.lastIdleNotificationAt = now
    }

    private func updateAttentionNotificationState(
        _ notificationState: inout ClientNotificationState,
        client: AgentClient,
        previousState: AgentState?,
        now: Date,
        readyClients: inout [AgentClient]
    ) {
        guard client.state == .waitingApproval else {
            notificationState.pendingAttentionSince = nil
            return
        }

        if previousState != .waitingApproval && notificationState.pendingAttentionSince == nil {
            notificationState.pendingAttentionSince = now
        }

        guard let pendingSince = notificationState.pendingAttentionSince,
              now.timeIntervalSince(pendingSince) >= attentionSettleInterval,
              canSend(lastSentAt: notificationState.lastAttentionNotificationAt, now: now) else {
            return
        }

        readyClients.append(client)
        notificationState.pendingAttentionSince = nil
        notificationState.lastAttentionNotificationAt = now
    }

    private func canSend(lastSentAt: Date?, now: Date) -> Bool {
        guard let lastSentAt else {
            return true
        }
        return now.timeIntervalSince(lastSentAt) >= notificationCooldown
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
        logger.info("Sending notification kind=\(kind, privacy: .public) title=\(title, privacy: .public) body=\(body, privacy: .public)")
        center.add(request) { [logger] error in
            if let error {
                logger.error("Notification failed kind=\(kind, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Notification accepted kind=\(kind, privacy: .public)")
            }
        }
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

private struct ClientNotificationState {
    var lastObservedState: AgentState?
    var lastObservedCompletionId: String?
    var pendingIdleSince: Date?
    var pendingCompletion: PendingCompletion?
    var pendingAttentionSince: Date?
    var lastIdleNotificationAt: Date?
    var lastAttentionNotificationAt: Date?
}

private struct PendingCompletion {
    let turnId: String
    let since: Date
    let client: AgentClient
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
