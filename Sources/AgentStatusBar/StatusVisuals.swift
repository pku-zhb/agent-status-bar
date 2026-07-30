import AppKit
import Foundation

enum StatusVisuals {
    static let maxMenuBarLights = 5
    private static let localClaudeIcon = loadIcon(named: "claude")
    private static let localCodexIcon = loadIcon(named: "codex")

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

        if let image = localIcon(for: kind) {
            drawLocalIcon(image, in: rect, clipPath: path, alpha: alpha, muted: muted)
            return
        }

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

    private static func localIcon(for kind: AgentKind) -> NSImage? {
        switch kind {
        case .claude:
            return localClaudeIcon
        case .codex:
            return localCodexIcon
        }
    }

    private static func loadIcon(named name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        let projectAsset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Assets")
            .appendingPathComponent("\(name).png")
        return NSImage(contentsOf: projectAsset)
    }

    private static func drawLocalIcon(_ image: NSImage, in rect: CGRect, clipPath: NSBezierPath, alpha: CGFloat, muted: Bool) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(muted ? 0.05 : 0.18)
        shadow.shadowOffset = NSSize(width: 0, height: -0.6)
        shadow.shadowBlurRadius = 2.4
        shadow.set()
        NSColor.black.withAlphaComponent(0.08).setFill()
        clipPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        clipPath.addClip()
        image.draw(
            in: rect,
            from: .zero,
            operation: .sourceOver,
            fraction: alpha,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()

        NSColor.black.withAlphaComponent(muted ? 0.08 : 0.14).setStroke()
        clipPath.lineWidth = 0.6
        clipPath.stroke()
    }

    static func drawLight(state: AgentState?, center: CGPoint, radius: CGFloat) {
        guard let state else {
            drawIdleLight(center: center, radius: radius, empty: true)
            return
        }

        switch state {
        case .waitingApproval:
            drawApprovalLight(center: center, radius: radius)
        case .running:
            drawRunningLight(center: center, radius: radius)
        case .idle:
            drawIdleLight(center: center, radius: radius, empty: false)
        case .stale:
            drawIdleLight(center: center, radius: radius, empty: false)
        case .unknown:
            drawUnknownLight(center: center, radius: radius)
        }
    }

    static func drawVerticalUsageBar(
        usedPercent: Double?,
        in rect: CGRect,
        fillColor: NSColor = .white
    ) {
        fillColor.withAlphaComponent(0.18).setFill()
        rect.fill()

        guard let usedPercent else {
            return
        }

        let clamped = min(100, max(0, usedPercent))
        guard clamped > 0 else {
            return
        }

        let fillHeight = max(2, rect.height * CGFloat(clamped) / 100)
        let fillRect = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: min(rect.height, fillHeight)
        )

        fillColor.setFill()
        fillRect.fill()
    }

    private static func drawIdleLight(center: CGPoint, radius: CGFloat, empty: Bool) {
        drawRingBase(center: center, radius: radius)
        let ringRadius = radius - 1.25
        let ringAlpha: CGFloat = empty ? 0.36 : 0.82
        drawRingGlow(center: center, radius: ringRadius, color: .white, alpha: ringAlpha, width: 2.6, blur: empty ? 4.0 : 6.5)
        drawRing(center: center, radius: ringRadius, color: .white, alpha: ringAlpha, width: 1.9)
    }

    private static func drawRunningLight(center: CGPoint, radius: CGFloat) {
        drawRingBase(center: center, radius: radius)
        drawRingGlow(center: center, radius: radius - 1.25, color: .systemGreen, alpha: 0.95, width: 3.0, blur: 7.5)
        drawRing(center: center, radius: radius - 1.25, color: .systemGreen, alpha: 0.98, width: 2.4)
    }

    private static func drawApprovalLight(center: CGPoint, radius: CGFloat) {
        drawRingBase(center: center, radius: radius)
        drawRingGlow(center: center, radius: radius - 1.25, color: .systemRed, alpha: 0.95, width: 3.2, blur: 9.5)
        drawRing(center: center, radius: radius - 1.25, color: .systemRed, alpha: 0.98, width: 2.5)
    }

    private static func drawUnknownLight(center: CGPoint, radius: CGFloat) {
        drawRingBase(center: center, radius: radius)
        drawRingGlow(center: center, radius: radius - 1.2, color: .systemRed, alpha: 0.36, width: 2.4, blur: 5)
        drawRing(center: center, radius: radius - 1.2, color: .systemRed, alpha: 0.72, width: 2.2)
    }

    private static func drawRingBase(center: CGPoint, radius: CGFloat) {
        drawDisc(center: center, radius: radius - 0.8, color: .black, alpha: 0.10)
        drawRing(center: center, radius: radius - 0.4, color: .black, alpha: 0.24, width: 0.9)
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
    static func render(snapshot: AgentSnapshot, credits: AgentCreditSnapshot = .empty) -> NSImage {
        let claude = sorted(snapshot.clients.filter { $0.kind == .claude })
        let codex = sorted(snapshot.clients.filter { $0.kind == .codex })
        let claudeOverflow = max(0, claude.count - StatusVisuals.maxMenuBarLights)
        let codexOverflow = max(0, codex.count - StatusVisuals.maxMenuBarLights)
        let claudeCredit = credits.status(for: .claude)
        let codexCredit = credits.status(for: .codex)

        let claudeWidth = groupWidth(for: claude, overflow: claudeOverflow, credit: claudeCredit)
        let codexWidth = groupWidth(for: codex, overflow: codexOverflow, credit: codexCredit)
        let groupGap: CGFloat = 10
        let size = NSSize(width: claudeWidth + groupGap + codexWidth, height: 24)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()

        drawGroup(kind: .claude, clients: claude, overflow: claudeOverflow, credit: claudeCredit, atX: 0)
        drawGroup(kind: .codex, clients: codex, overflow: codexOverflow, credit: codexCredit, atX: claudeWidth + groupGap)

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func groupWidth(for clients: [AgentClient], overflow: Int, credit: AgentCreditStatus?) -> CGFloat {
        let visibleCount = min(clients.count, StatusVisuals.maxMenuBarLights)
        let iconWidth: CGFloat = 24
        let creditWidth = credit.map { menuBarCreditWidth($0) } ?? 0
        guard visibleCount > 0 else {
            return iconWidth + creditWidth
        }

        let firstLightX: CGFloat = 38
        let lightStep: CGFloat = 24
        let lastLightRadius: CGFloat = 9.5
        let overflowWidth: CGFloat = overflow > 0 ? 27 : 5
        return firstLightX + CGFloat(visibleCount - 1) * lightStep + lastLightRadius + overflowWidth + creditWidth
    }

    private static func drawGroup(kind: AgentKind, clients: [AgentClient], overflow: Int, credit: AgentCreditStatus?, atX x: CGFloat) {
        let iconRect = CGRect(x: x + 3, y: 3, width: 18, height: 18)
        StatusVisuals.drawAgentIcon(kind: kind, in: iconRect, muted: clients.isEmpty)

        let visible = Array(clients.prefix(StatusVisuals.maxMenuBarLights))
        var lightX = x + 38
        for client in visible {
            StatusVisuals.drawLight(
                state: client.state,
                center: CGPoint(x: lightX, y: 12),
                radius: 9.5
            )
            lightX += 24
        }

        var creditX: CGFloat = clients.isEmpty ? x + 27 : lightX - 7
        if overflow > 0 {
            let text = "+\(overflow)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
            text.draw(at: CGPoint(x: lightX - 2, y: 3.6), withAttributes: attributes)
            creditX = lightX + textWidth(String(text), attributes: attributes) + 4
        }

        if let credit {
            drawMenuBarCreditMeters(credit, atX: creditX)
        }
    }

    private static func drawMenuBarCreditMeters(_ credit: AgentCreditStatus, atX x: CGFloat) {
        let barY: CGFloat = 3
        let barWidth: CGFloat = 7
        let barHeight: CGFloat = 18
        let windowStep: CGFloat = 24
        for (index, window) in credit.displayWindows.enumerated() {
            let windowX = x + CGFloat(index) * windowStep
            StatusVisuals.drawVerticalUsageBar(
                usedPercent: window.usedPercent.map(Double.init),
                in: CGRect(x: windowX, y: barY, width: barWidth, height: barHeight),
                fillColor: .white
            )
            StatusVisuals.drawVerticalUsageBar(
                usedPercent: window.resetElapsedPercent(),
                in: CGRect(x: windowX + 10, y: barY, width: barWidth, height: barHeight),
                fillColor: .white
            )
        }
    }

    private static func menuBarCreditWidth(_ credit: AgentCreditStatus) -> CGFloat {
        let count = credit.displayWindows.count
        guard count > 0 else {
            return 0
        }
        return 7 + CGFloat(count - 1) * 24 + 17
    }

    private static func textWidth(_ text: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        ceil((text as NSString).size(withAttributes: attributes).width)
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
    private let credit: AgentCreditStatus?

    init(kind: AgentKind, clients: [AgentClient], credit: AgentCreditStatus? = nil) {
        self.kind = kind
        self.clients = clients
        self.credit = credit
        super.init(frame: CGRect(x: 0, y: 0, width: 492, height: 58))
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let iconRect = CGRect(x: 12, y: 29, width: 18, height: 18)
        StatusVisuals.drawAgentIcon(kind: kind, in: iconRect, muted: clients.isEmpty)

        let title = kind.displayName as NSString
        title.draw(
            in: CGRect(x: 40, y: 38, width: 105, height: 15),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )

        if let credit {
            drawCreditMeters(credit, at: CGPoint(x: 145, y: 8))
        }

        let countText = "\(clients.count) 个会话" as NSString
        countText.draw(
            in: CGRect(x: 40, y: 16, width: 72, height: 15),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )

        let visible = Array(clients.prefix(8))
        var x: CGFloat = 284
        for client in visible {
            StatusVisuals.drawLight(
                state: client.state,
                center: CGPoint(x: x, y: 22),
                radius: 9.5
            )
            x += 22
        }

        if clients.count > visible.count {
            let overflow = "+\(clients.count - visible.count)" as NSString
            overflow.draw(
                at: CGPoint(x: x - 1, y: 15),
                withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        }
    }

    private func drawCreditMeters(_ credit: AgentCreditStatus, at origin: CGPoint) {
        let windowStep: CGFloat = 42
        for (index, window) in credit.displayWindows.enumerated() {
            let windowX = origin.x + CGFloat(index) * windowStep
            drawMeter(
                usedPercent: window.usedPercent.map(Double.init),
                at: CGPoint(x: windowX, y: origin.y),
                fillColor: .white
            )
            drawMeter(
                usedPercent: window.resetElapsedPercent(),
                at: CGPoint(x: windowX + 18, y: origin.y),
                fillColor: .white
            )
        }
    }

    private func drawMeter(usedPercent: Double?, at origin: CGPoint, fillColor: NSColor) {
        StatusVisuals.drawVerticalUsageBar(
            usedPercent: usedPercent,
            in: CGRect(x: origin.x, y: origin.y, width: 14, height: 42),
            fillColor: fillColor
        )
    }
}

final class AgentClientRowView: NSView {
    private let client: AgentClient
    private let title: String
    private let subtitle: String

    init(client: AgentClient, title: String, subtitle: String) {
        self.client = client
        self.title = title
        self.subtitle = subtitle
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
            radius: 9.5
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
