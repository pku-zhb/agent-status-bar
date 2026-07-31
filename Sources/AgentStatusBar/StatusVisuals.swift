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
    private static let meterBarWidth: CGFloat = 11
    private static let meterBarGap: CGFloat = 2
    private static let meterWindowStep: CGFloat = 29
    private static let meterTrailingPadding: CGFloat = 3

    static func render(
        snapshot: AgentSnapshot,
        credits: AgentCreditSnapshot = .empty,
        showsStatusHalos: Bool = true,
        showsUsage: Bool = true,
        showsUsageNumbers: Bool = true
    ) -> NSImage {
        let claude = sorted(snapshot.clients.filter { $0.kind == .claude })
        let codex = sorted(snapshot.clients.filter { $0.kind == .codex })
        let claudeOverflow = showsStatusHalos ? max(0, claude.count - StatusVisuals.maxMenuBarLights) : 0
        let codexOverflow = showsStatusHalos ? max(0, codex.count - StatusVisuals.maxMenuBarLights) : 0
        let claudeCredit = showsUsage ? credits.status(for: .claude) : nil
        let codexCredit = showsUsage ? credits.status(for: .codex) : nil

        let claudeWidth = groupWidth(
            for: claude,
            overflow: claudeOverflow,
            credit: claudeCredit,
            showsStatusHalos: showsStatusHalos
        )
        let codexWidth = groupWidth(
            for: codex,
            overflow: codexOverflow,
            credit: codexCredit,
            showsStatusHalos: showsStatusHalos
        )
        let groupGap: CGFloat = 10
        let size = NSSize(width: claudeWidth + groupGap + codexWidth, height: 24)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: size).fill()

        drawGroup(
            kind: .claude,
            clients: claude,
            overflow: claudeOverflow,
            credit: claudeCredit,
            showsStatusHalos: showsStatusHalos,
            showsUsageNumbers: showsUsageNumbers,
            atX: 0
        )
        drawGroup(
            kind: .codex,
            clients: codex,
            overflow: codexOverflow,
            credit: codexCredit,
            showsStatusHalos: showsStatusHalos,
            showsUsageNumbers: showsUsageNumbers,
            atX: claudeWidth + groupGap
        )

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func groupWidth(
        for clients: [AgentClient],
        overflow: Int,
        credit: AgentCreditStatus?,
        showsStatusHalos: Bool
    ) -> CGFloat {
        let visibleCount = showsStatusHalos ? min(clients.count, StatusVisuals.maxMenuBarLights) : 0
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

    private static func drawGroup(
        kind: AgentKind,
        clients: [AgentClient],
        overflow: Int,
        credit: AgentCreditStatus?,
        showsStatusHalos: Bool,
        showsUsageNumbers: Bool,
        atX x: CGFloat
    ) {
        let iconRect = CGRect(x: x + 3, y: 3, width: 18, height: 18)
        StatusVisuals.drawAgentIcon(
            kind: kind,
            in: iconRect,
            muted: showsStatusHalos && clients.isEmpty
        )

        let visible = showsStatusHalos ? Array(clients.prefix(StatusVisuals.maxMenuBarLights)) : []
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
            drawMenuBarCreditMeters(
                credit,
                atX: creditX,
                showsNumbers: showsUsageNumbers,
                now: Date()
            )
        }
    }

    private static func drawMenuBarCreditMeters(
        _ credit: AgentCreditStatus,
        atX x: CGFloat,
        showsNumbers: Bool,
        now: Date
    ) {
        let barY: CGFloat = 3
        let barHeight: CGFloat = 18
        for (index, window) in credit.displayWindows.enumerated() {
            let windowX = x + CGFloat(index) * meterWindowStep
            let usageRect = CGRect(
                x: windowX,
                y: barY,
                width: meterBarWidth,
                height: barHeight
            )
            let resetRect = CGRect(
                x: windowX + meterBarWidth + meterBarGap,
                y: barY,
                width: meterBarWidth,
                height: barHeight
            )
            StatusVisuals.drawVerticalUsageBar(
                usedPercent: window.usedPercent.map(Double.init),
                in: usageRect,
                fillColor: .white
            )
            StatusVisuals.drawVerticalUsageBar(
                usedPercent: window.resetElapsedPercent(now: now),
                in: resetRect,
                fillColor: .white
            )
            if showsNumbers {
                drawCompactMeterLabel(
                    usageMeterLabel(usedPercent: window.usedPercent),
                    in: usageRect
                )
                drawCompactMeterLabel(
                    remainingHoursLabel(resetAt: window.resetAt, now: now),
                    in: resetRect
                )
            }
        }
    }

    static func usageMeterLabel(usedPercent: Int?) -> String? {
        guard let usedPercent else {
            return nil
        }
        return String(min(100, max(0, usedPercent)))
    }

    static func remainingHoursLabel(resetAt: Date?, now: Date = Date()) -> String? {
        guard let resetAt else {
            return nil
        }
        let remainingSeconds = max(0, resetAt.timeIntervalSince(now))
        return String(Int(ceil(remainingSeconds / (60 * 60))))
    }

    private static func drawCompactMeterLabel(_ label: String?, in rect: CGRect) {
        guard let label else {
            return
        }
        let fontSize: CGFloat = label.count <= 2 ? 6.5 : 5.25
        let text = label as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.white,
            .strokeColor: NSColor.black.withAlphaComponent(0.92),
            .strokeWidth: -2.5
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2 - 0.5
            ),
            withAttributes: attributes
        )
    }

    private static func menuBarCreditWidth(_ credit: AgentCreditStatus) -> CGFloat {
        let count = credit.displayWindows.count
        guard count > 0 else {
            return 0
        }
        let meterPairWidth = meterBarWidth * 2 + meterBarGap
        return meterPairWidth
            + CGFloat(count - 1) * meterWindowStep
            + meterTrailingPadding
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
