import AppKit
import Foundation

struct VisualFrame {
    let tick: Int

    var phase: CGFloat {
        CGFloat(tick % 120) / 120
    }

    var breath: CGFloat {
        0.5 + 0.5 * CGFloat(sin(Double(phase * 2 * .pi)))
    }

    var runningStartAngle: CGFloat {
        CGFloat((tick * 15) % 360)
    }
}

enum StatusVisuals {
    static let maxMenuBarLights = 5

    static func brandColor(for kind: AgentKind) -> NSColor {
        switch kind {
        case .claude:
            return NSColor(calibratedRed: 0.94, green: 0.43, blue: 0.16, alpha: 1)
        case .codex:
            return NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.22, alpha: 1)
        }
    }

    static func monogram(for kind: AgentKind) -> String {
        switch kind {
        case .claude:
            return "C"
        case .codex:
            return "X"
        }
    }

    static func drawAgentIcon(kind: AgentKind, in rect: CGRect, muted: Bool = false) {
        let radius = rect.height * 0.28
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let base = brandColor(for: kind)
        let alpha: CGFloat = muted ? 0.36 : 1

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(muted ? 0.05 : 0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -0.6)
        shadow.shadowBlurRadius = 2.4
        shadow.set()

        if let gradient = NSGradient(colors: [
            base.highlight(withLevel: 0.18)?.withAlphaComponent(alpha) ?? base.withAlphaComponent(alpha),
            base.shadow(withLevel: 0.16)?.withAlphaComponent(alpha) ?? base.withAlphaComponent(alpha)
        ]) {
            gradient.draw(in: path, angle: 90)
        } else {
            base.withAlphaComponent(alpha).setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(muted ? 0.10 : 0.22).setFill()
        NSBezierPath(
            roundedRect: rect.insetBy(dx: 1.3, dy: rect.height * 0.56),
            xRadius: radius * 0.65,
            yRadius: radius * 0.65
        ).fill()

        NSColor.black.withAlphaComponent(muted ? 0.10 : 0.20).setStroke()
        path.lineWidth = 0.7
        path.stroke()

        let text = monogram(for: kind) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rect.height * 0.66, weight: .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(muted ? 0.68 : 0.96)
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            in: CGRect(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2 - 0.6,
                width: textSize.width,
                height: textSize.height
            ),
            withAttributes: attributes
        )
    }

    static func drawLight(state: AgentState?, center: CGPoint, radius: CGFloat, frame: VisualFrame) {
        guard let state else {
            drawIdleLight(center: center, radius: radius, frame: frame, empty: true)
            return
        }

        switch state {
        case .waitingApproval:
            drawApprovalLight(center: center, radius: radius, frame: frame)
        case .running:
            drawRunningLight(center: center, radius: radius, frame: frame)
        case .idle:
            drawIdleLight(center: center, radius: radius, frame: frame, empty: false)
        case .stale:
            drawStaleLight(center: center, radius: radius)
        case .unknown:
            drawUnknownLight(center: center, radius: radius, frame: frame)
        }
    }

    private static func drawIdleLight(center: CGPoint, radius: CGFloat, frame: VisualFrame, empty: Bool) {
        drawGlassBase(center: center, radius: radius)
        let ringRadius = radius - 1.4 + frame.breath * 0.45
        let ringAlpha = empty ? 0.32 : 0.56 + frame.breath * 0.28
        drawRingGlow(center: center, radius: ringRadius, color: .white, alpha: ringAlpha, width: 2.4, blur: empty ? 3.8 : 5.6)
        drawRing(center: center, radius: ringRadius, color: .white, alpha: ringAlpha, width: 1.8)
    }

    private static func drawRunningLight(center: CGPoint, radius: CGFloat, frame: VisualFrame) {
        drawGlassBase(center: center, radius: radius)
        drawRing(center: center, radius: radius - 1.4, color: .white, alpha: 0.28, width: 1.5)

        let arcRadius = radius - 1.7
        drawArcGlow(
            center: center,
            radius: arcRadius,
            startAngle: frame.runningStartAngle,
            endAngle: frame.runningStartAngle + 245,
            color: .systemGreen,
            alpha: 0.96,
            width: 2.8,
            blur: 6.8
        )

        let angle = (frame.runningStartAngle + 255) * .pi / 180
        let lead = CGPoint(
            x: center.x + CGFloat(cos(Double(angle))) * arcRadius,
            y: center.y + CGFloat(sin(Double(angle))) * arcRadius
        )
        drawDisc(center: lead, radius: 1.8, color: .systemGreen, alpha: 1)
    }

    private static func drawApprovalLight(center: CGPoint, radius: CGFloat, frame: VisualFrame) {
        drawGlassBase(center: center, radius: radius)
        drawDisc(center: center, radius: radius - 1.1, color: .systemRed, alpha: 0.22)
        drawRingGlow(center: center, radius: radius - 1.15, color: .systemRed, alpha: 0.92, width: 3.1, blur: 8.5)
        drawRing(center: center, radius: radius - 1.15, color: .systemRed, alpha: 0.96, width: 2.4)
        drawRing(center: center, radius: radius - 3.2, color: .white, alpha: 0.22, width: 0.7)
    }

    private static func drawStaleLight(center: CGPoint, radius: CGFloat) {
        drawGlassBase(center: center, radius: radius)
        drawRing(center: center, radius: radius - 1.2, color: .systemGray, alpha: 0.58, width: 2)
    }

    private static func drawUnknownLight(center: CGPoint, radius: CGFloat, frame: VisualFrame) {
        drawGlassBase(center: center, radius: radius)
        drawRingGlow(center: center, radius: radius - 1.2, color: .systemRed, alpha: 0.36, width: 2.4, blur: 5)
        drawRing(center: center, radius: radius - 1.2, color: .systemRed, alpha: 0.72, width: 2.2)
    }

    private static func drawGlassBase(center: CGPoint, radius: CGFloat) {
        drawDisc(center: center, radius: radius, color: .black, alpha: 0.12)
        drawDisc(center: center, radius: radius - 0.8, color: .white, alpha: 0.16)
        drawDisc(center: CGPoint(x: center.x - radius * 0.24, y: center.y + radius * 0.26), radius: radius * 0.34, color: .white, alpha: 0.18)
        drawRing(center: center, radius: radius - 0.4, color: .white, alpha: 0.34, width: 0.8)
        drawRing(center: center, radius: radius - 0.1, color: .black, alpha: 0.18, width: 0.7)
    }

    private static func drawRingGlow(center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat, width: CGFloat, blur: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(alpha)
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = blur
        shadow.set()
        drawRing(center: center, radius: radius, color: color, alpha: alpha * 0.80, width: width)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawArcGlow(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        color: NSColor,
        alpha: CGFloat,
        width: CGFloat,
        blur: CGFloat
    ) {
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: startAngle, endAngle: endAngle)
        arc.lineWidth = width
        arc.lineCapStyle = .round

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color.withAlphaComponent(alpha)
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = blur
        shadow.set()
        color.withAlphaComponent(alpha).setStroke()
        arc.stroke()
        NSGraphicsContext.restoreGraphicsState()

        color.withAlphaComponent(alpha).setStroke()
        arc.stroke()
    }

    private static func drawDisc(center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let disc = NSBezierPath(ovalIn: rect)
        color.withAlphaComponent(alpha).setFill()
        disc.fill()
    }

    private static func drawRing(center: CGPoint, radius: CGFloat, color: NSColor, alpha: CGFloat, width: CGFloat) {
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        let ring = NSBezierPath(ovalIn: rect)
        ring.lineWidth = width
        color.withAlphaComponent(alpha).setStroke()
        ring.stroke()
    }
}

enum StatusBarIconRenderer {
    static func render(snapshot: AgentSnapshot, frame: VisualFrame) -> NSImage {
        let claude = sorted(snapshot.clients.filter { $0.kind == .claude })
        let codex = sorted(snapshot.clients.filter { $0.kind == .codex })
        let claudeOverflow = max(0, claude.count - StatusVisuals.maxMenuBarLights)
        let codexOverflow = max(0, codex.count - StatusVisuals.maxMenuBarLights)

        let claudeWidth = groupWidth(for: claude, overflow: claudeOverflow)
        let codexWidth = groupWidth(for: codex, overflow: codexOverflow)
        let groupGap: CGFloat = 10
        let size = NSSize(width: claudeWidth + groupGap + codexWidth, height: 24)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()

        drawGroup(kind: .claude, clients: claude, overflow: claudeOverflow, atX: 0, frame: frame)
        drawGroup(kind: .codex, clients: codex, overflow: codexOverflow, atX: claudeWidth + groupGap, frame: frame)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func groupWidth(for clients: [AgentClient], overflow: Int) -> CGFloat {
        let visibleCount = min(clients.count, StatusVisuals.maxMenuBarLights)
        let iconWidth: CGFloat = 24
        guard visibleCount > 0 else {
            return iconWidth
        }

        let firstLightX: CGFloat = 38
        let lightStep: CGFloat = 24
        let lastLightRadius: CGFloat = 9.5
        let overflowWidth: CGFloat = overflow > 0 ? 27 : 5
        return firstLightX + CGFloat(visibleCount - 1) * lightStep + lastLightRadius + overflowWidth
    }

    private static func drawGroup(kind: AgentKind, clients: [AgentClient], overflow: Int, atX x: CGFloat, frame: VisualFrame) {
        let iconRect = CGRect(x: x + 3, y: 3, width: 18, height: 18)
        StatusVisuals.drawAgentIcon(kind: kind, in: iconRect, muted: clients.isEmpty)

        let visible = Array(clients.prefix(StatusVisuals.maxMenuBarLights))
        var lightX = x + 38
        for client in visible {
            StatusVisuals.drawLight(
                state: client.state,
                center: CGPoint(x: lightX, y: 12),
                radius: 9.5,
                frame: frame
            )
            lightX += 24
        }

        if overflow > 0 {
            let text = "+\(overflow)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            text.draw(at: CGPoint(x: lightX - 2, y: 3.6), withAttributes: attributes)
        }
    }

    private static func sorted(_ clients: [AgentClient]) -> [AgentClient] {
        clients.sorted {
            return $0.pid < $1.pid
        }
    }
}

final class AgentGroupRowView: NSView {
    private let kind: AgentKind
    private let clients: [AgentClient]
    private let frameState: VisualFrame

    init(kind: AgentKind, clients: [AgentClient], frame: VisualFrame) {
        self.kind = kind
        self.clients = clients
        self.frameState = frame
        super.init(frame: CGRect(x: 0, y: 0, width: 370, height: 38))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let iconRect = CGRect(x: 12, y: 10, width: 18, height: 18)
        StatusVisuals.drawAgentIcon(kind: kind, in: iconRect, muted: clients.isEmpty)

        let title = kind.displayName as NSString
        title.draw(
            in: CGRect(x: 40, y: 14, width: 105, height: 15),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )

        let countText = "\(clients.count) 个会话" as NSString
        countText.draw(
            in: CGRect(x: 145, y: 14, width: 72, height: 15),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )

        let visible = Array(clients.prefix(8))
        var x: CGFloat = 185
        for client in visible {
            StatusVisuals.drawLight(
                state: client.state,
                center: CGPoint(x: x, y: 19),
                radius: 9.5,
                frame: frameState
            )
            x += 22
        }

        if clients.count > visible.count {
            let overflow = "+\(clients.count - visible.count)" as NSString
            overflow.draw(
                at: CGPoint(x: x - 1, y: 12),
                withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }
    }
}

final class AgentClientRowView: NSView {
    private let client: AgentClient
    private let title: String
    private let subtitle: String
    private let frameState: VisualFrame

    init(client: AgentClient, title: String, subtitle: String, frame: VisualFrame) {
        self.client = client
        self.title = title
        self.subtitle = subtitle
        self.frameState = frame
        super.init(frame: CGRect(x: 0, y: 0, width: 370, height: 46))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        StatusVisuals.drawLight(
            state: client.state,
            center: CGPoint(x: 18.5, y: 26),
            radius: 9.5,
            frame: frameState
        )

        (client.kind.displayName as NSString).draw(
            in: CGRect(x: 33, y: 25, width: 76, height: 14),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: StatusVisuals.brandColor(for: client.kind)
            ]
        )

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        (title as NSString).draw(
            in: CGRect(x: 110, y: 24, width: 246, height: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )

        (subtitle as NSString).draw(
            in: CGRect(x: 33, y: 7, width: 323, height: 14),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]
        )
    }
}
