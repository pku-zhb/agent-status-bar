import Foundation
import OSLog
import UserNotifications

@MainActor
final class AgentNotificationController: NSObject {
    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "com.zhuhuibin.agentstatusbar", category: "notifications")
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

        let previousById = Dictionary(uniqueKeysWithValues: previous.clients.map { ($0.id, $0) })

        for client in current.clients {
            var notificationState = clientStates[client.id] ?? ClientNotificationState()
            let previousState = previousById[client.id]?.state ?? notificationState.lastObservedState

            if shouldNotifyIdle(client: client, previousState: previousState) {
                sendNotification(kind: "became-idle", client: client, action: "完成本轮任务")
            }
            if shouldNotifyAttention(client: client, previousState: previousState) {
                sendNotification(kind: "needs-attention", client: client, action: "需要处理")
            }

            notificationState.lastObservedState = client.state
            clientStates[client.id] = notificationState
        }

        let currentIds = Set(current.clients.map(\.id))
        clientStates = clientStates.filter { currentIds.contains($0.key) }
    }

    private func seedClientStates(from snapshot: AgentSnapshot) {
        clientStates = Dictionary(uniqueKeysWithValues: snapshot.clients.map {
            ($0.id, ClientNotificationState(lastObservedState: $0.state))
        })
    }

    private func shouldNotifyIdle(client: AgentClient, previousState: AgentState?) -> Bool {
        let isIdle = client.state == .idle || client.state == .stale
        return previousState == .running && isIdle
    }

    private func shouldNotifyAttention(client: AgentClient, previousState: AgentState?) -> Bool {
        client.state == .waitingApproval && previousState != .waitingApproval
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(kind: String, client: AgentClient, action: String) {
        let title = "\(client.kind.displayName) \(action)"
        let content = UNMutableNotificationContent()
        content.title = title
        content.sound = .default
        content.threadIdentifier = "agent-status-bar.\(kind).\(client.id)"

        let request = UNNotificationRequest(
            identifier: "agent-status-bar.\(kind).\(client.id).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        logger.info("Sending notification kind=\(kind, privacy: .public) client=\(client.id, privacy: .public) title=\(title, privacy: .public)")
        center.add(request) { [logger] error in
            if let error {
                logger.error("Notification failed kind=\(kind, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Notification accepted kind=\(kind, privacy: .public)")
            }
        }
    }
}

private struct ClientNotificationState {
    var lastObservedState: AgentState?
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
