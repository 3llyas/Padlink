import UIKit

/// Full-screen multitouch gamepad surface.
///
/// - Buttons react to whatever finger is over them, so you can slide your thumb
///   from A to B (or rest it between them to press both).
/// - Sticks are "floating": the base re-centres where your thumb lands, and
///   follows your thumb if you drag past the edge.
/// - Double-tap a stick and keep holding to press L3 / R3.
final class GamepadView: UIView {
    var onChange: ((ControllerState) -> Void)?
    private(set) var state = ControllerState()

    // MARK: - Model

    private enum Side { case left, right }
    private enum Owner { case stick(Side), buttons }

    private struct PadButton {
        enum Kind { case digital(Buttons), leftTrigger, rightTrigger }
        let kind: Kind
        let label: String
        let frame: CGRect
        let isCircle: Bool
        let tint: UIColor

        func hit(_ p: CGPoint) -> Bool {
            if isCircle {
                return hypot(p.x - frame.midX, p.y - frame.midY) <= frame.width / 2 * 1.25
            }
            return frame.insetBy(dx: -frame.width * 0.12, dy: -frame.height * 0.2).contains(p)
        }
    }

    private struct Stick {
        var home: CGPoint = .zero
        var radius: CGFloat = 1
        var zoneRadius: CGFloat = 1
        var origin: CGPoint = .zero
        var knob: CGPoint = .zero
        var value: CGVector = .zero
        weak var touch: UITouch?
        var touchStart: TimeInterval = 0
        var lastTap: TimeInterval = -1
        var clicked = false
    }

    private var buttons: [PadButton] = []
    private var dpadCenter: CGPoint = .zero
    private var dpadRadius: CGFloat = 1
    private var sticks: [Side: Stick] = [.left: Stick(), .right: Stick()]
    private var owners: [UITouch: Owner] = [:]
    private var pressedButtons = Set<Int>()
    private var dpadBits: Buttons = []

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = UIColor(white: 0.06, alpha: 1)
        contentMode = .redraw
        haptic.prepare()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Release everything (e.g. when the app goes to the background).
    func reset() {
        owners.removeAll()
        for side in [Side.left, .right] { releaseStick(side, at: 0) }
        update()
    }

    // MARK: - Layout

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        buildLayout()
        setNeedsDisplay()
    }

    private func buildLayout() {
        let s = bounds.inset(by: safeAreaInsets)
        let w = s.width, h = s.height
        guard w > 0, h > 0 else { return }

        func centered(_ cx: CGFloat, _ cy: CGFloat, _ bw: CGFloat, _ bh: CGFloat) -> CGRect {
            CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh)
        }

        var b: [PadButton] = []

        // Shoulders / triggers
        let shW = w * 0.17, shH = h * 0.11
        let leftX = s.minX + w * 0.02, rightX = s.maxX - w * 0.02 - shW
        let row1 = s.minY + h * 0.03, row2 = row1 + shH + h * 0.025
        let shoulderTint = UIColor.systemTeal
        b.append(PadButton(kind: .leftTrigger, label: "LT",
                           frame: CGRect(x: leftX, y: row1, width: shW, height: shH), isCircle: false, tint: shoulderTint))
        b.append(PadButton(kind: .digital(.leftShoulder), label: "LB",
                           frame: CGRect(x: leftX, y: row2, width: shW, height: shH), isCircle: false, tint: shoulderTint))
        b.append(PadButton(kind: .rightTrigger, label: "RT",
                           frame: CGRect(x: rightX, y: row1, width: shW, height: shH), isCircle: false, tint: shoulderTint))
        b.append(PadButton(kind: .digital(.rightShoulder), label: "RB",
                           frame: CGRect(x: rightX, y: row2, width: shW, height: shH), isCircle: false, tint: shoulderTint))

        // Face buttons
        let fc = CGPoint(x: s.maxX - w * 0.17, y: s.minY + h * 0.55)
        let br = h * 0.075, off = h * 0.13
        let face: [(Buttons, String, CGFloat, CGFloat, UIColor)] = [
            (.a, "A", 0, off, .systemGreen),
            (.b, "B", off, 0, .systemRed),
            (.x, "X", -off, 0, .systemBlue),
            (.y, "Y", 0, -off, .systemYellow),
        ]
        for (bit, label, dx, dy, tint) in face {
            b.append(PadButton(kind: .digital(bit), label: label,
                               frame: centered(fc.x + dx, fc.y + dy, br * 2, br * 2), isCircle: true, tint: tint))
        }

        // Back / Guide / Start
        let my = s.minY + h * 0.40
        let pillW = w * 0.075, pillH = h * 0.085
        let menuTint = UIColor.systemGray
        b.append(PadButton(kind: .digital(.back), label: "BACK",
                           frame: centered(s.midX - w * 0.09, my, pillW, pillH), isCircle: false, tint: menuTint))
        b.append(PadButton(kind: .digital(.guide), label: "◉",
                           frame: centered(s.midX, my, pillH * 1.3, pillH * 1.3), isCircle: true, tint: menuTint))
        b.append(PadButton(kind: .digital(.start), label: "START",
                           frame: centered(s.midX + w * 0.09, my, pillW, pillH), isCircle: false, tint: menuTint))
        buttons = b

        // D-pad
        dpadCenter = CGPoint(x: s.minX + w * 0.34, y: s.minY + h * 0.80)
        dpadRadius = h * 0.13

        // Sticks
        let r = h * 0.14
        let homes: [(Side, CGPoint)] = [
            (.left, CGPoint(x: s.minX + w * 0.17, y: s.minY + h * 0.55)),
            (.right, CGPoint(x: s.maxX - w * 0.34, y: s.minY + h * 0.80)),
        ]
        for (side, home) in homes {
            var st = sticks[side]!
            st.home = home
            st.radius = r
            st.zoneRadius = r * 1.8
            if st.touch == nil {
                st.origin = home
                st.knob = home
            }
            sticks[side] = st
        }
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let p = t.location(in: self)
            if !hitsAnyButton(p), let side = freeStickZone(at: p) {
                owners[t] = .stick(side)
                var st = sticks[side]!
                st.touch = t
                st.touchStart = t.timestamp
                st.origin = p
                st.knob = p
                st.value = .zero
                st.clicked = st.lastTap >= 0 && (t.timestamp - st.lastTap) < 0.3
                sticks[side] = st
                if st.clicked { haptic.impactOccurred(); haptic.prepare() }
            } else {
                owners[t] = .buttons
            }
        }
        update()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if case .stick(let side)? = owners[t] {
                moveStick(side, to: t.location(in: self))
            }
        }
        update()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endTouches(touches)
    }

    private func endTouches(_ touches: Set<UITouch>) {
        for t in touches {
            if case .stick(let side)? = owners[t] {
                releaseStick(side, at: t.timestamp)
            }
            owners[t] = nil
        }
        update()
    }

    private func hitsAnyButton(_ p: CGPoint) -> Bool {
        if inDpad(p) { return true }
        return buttons.contains { $0.hit(p) }
    }

    private func inDpad(_ p: CGPoint) -> Bool {
        hypot(p.x - dpadCenter.x, p.y - dpadCenter.y) <= dpadRadius * 1.25
    }

    private func freeStickZone(at p: CGPoint) -> Side? {
        for side in [Side.left, .right] {
            let st = sticks[side]!
            if st.touch == nil, hypot(p.x - st.home.x, p.y - st.home.y) <= st.zoneRadius {
                return side
            }
        }
        return nil
    }

    private func moveStick(_ side: Side, to p: CGPoint) {
        var st = sticks[side]!
        var dx = p.x - st.origin.x, dy = p.y - st.origin.y
        let len = hypot(dx, dy)
        if len > st.radius {
            // Clamp to the rim and drag the base along with the thumb.
            dx *= st.radius / len
            dy *= st.radius / len
            st.origin = CGPoint(x: p.x - dx, y: p.y - dy)
        }
        st.knob = CGPoint(x: st.origin.x + dx, y: st.origin.y + dy)
        st.value = CGVector(dx: dx / st.radius, dy: -dy / st.radius)
        sticks[side] = st
    }

    private func releaseStick(_ side: Side, at timestamp: TimeInterval) {
        var st = sticks[side]!
        let wasTap = st.touch != nil && !st.clicked && (timestamp - st.touchStart) < 0.25
        st.lastTap = wasTap ? timestamp : -1
        st.touch = nil
        st.clicked = false
        st.value = .zero
        st.origin = st.home
        st.knob = st.home
        sticks[side] = st
    }

    private func dpadDirection(_ p: CGPoint) -> Buttons {
        let dx = p.x - dpadCenter.x, dy = p.y - dpadCenter.y
        let len = hypot(dx, dy)
        guard len > dpadRadius * 0.2 else { return [] }
        let ux = dx / len, uy = -dy / len
        // Cardinal directions get 60° each, diagonals 30°.
        var out: Buttons = []
        if ux > 0.5 { out.insert(.dpadRight) }
        if ux < -0.5 { out.insert(.dpadLeft) }
        if uy > 0.5 { out.insert(.dpadUp) }
        if uy < -0.5 { out.insert(.dpadDown) }
        return out
    }

    private func update() {
        var newPressed = Set<Int>()
        var dpad: Buttons = []
        for (t, owner) in owners {
            guard case .buttons = owner else { continue }
            let p = t.location(in: self)
            if inDpad(p) {
                dpad.formUnion(dpadDirection(p))
                continue
            }
            for (i, btn) in buttons.enumerated() where btn.hit(p) {
                newPressed.insert(i)
            }
        }

        if !newPressed.subtracting(pressedButtons).isEmpty || !dpad.subtracting(dpadBits).isEmpty {
            haptic.impactOccurred()
            haptic.prepare()
        }
        pressedButtons = newPressed
        dpadBits = dpad

        var s = ControllerState()
        var bits = dpad
        for i in newPressed {
            switch buttons[i].kind {
            case .digital(let bit): bits.insert(bit)
            case .leftTrigger: s.lt = 1
            case .rightTrigger: s.rt = 1
            }
        }
        let l = sticks[.left]!, r = sticks[.right]!
        if l.clicked { bits.insert(.leftThumb) }
        if r.clicked { bits.insert(.rightThumb) }
        s.buttons = bits
        s.lx = Float(l.value.dx)
        s.ly = Float(l.value.dy)
        s.rx = Float(r.value.dx)
        s.ry = Float(r.value.dy)

        setNeedsDisplay()
        if s != state {
            state = s
            onChange?(s)
        }
    }

    // MARK: - Drawing

    private let outline = UIColor(white: 1, alpha: 0.28)
    private let idleFill = UIColor(white: 1, alpha: 0.07)

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        drawStick(sticks[.left]!, ctx)
        drawStick(sticks[.right]!, ctx)
        drawDpad(ctx)
        for (i, b) in buttons.enumerated() {
            drawButton(b, pressed: pressedButtons.contains(i), ctx)
        }
    }

    private func drawStick(_ st: Stick, _ ctx: CGContext) {
        // Faint zone hint at home position.
        let zone = CGRect(x: st.home.x - st.zoneRadius, y: st.home.y - st.zoneRadius,
                          width: st.zoneRadius * 2, height: st.zoneRadius * 2)
        ctx.setStrokeColor(UIColor(white: 1, alpha: 0.08).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 6])
        ctx.strokeEllipse(in: zone)
        ctx.setLineDash(phase: 0, lengths: [])

        let base = CGRect(x: st.origin.x - st.radius, y: st.origin.y - st.radius,
                          width: st.radius * 2, height: st.radius * 2)
        ctx.setFillColor(idleFill.cgColor)
        ctx.fillEllipse(in: base)
        ctx.setStrokeColor(outline.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: base)

        let kr = st.radius * 0.48
        let knob = CGRect(x: st.knob.x - kr, y: st.knob.y - kr, width: kr * 2, height: kr * 2)
        let knobColor: UIColor = st.clicked ? .systemOrange
            : (st.touch != nil ? UIColor(white: 1, alpha: 0.55) : UIColor(white: 1, alpha: 0.3))
        ctx.setFillColor(knobColor.cgColor)
        ctx.fillEllipse(in: knob)
    }

    private func drawDpad(_ ctx: CGContext) {
        let c = dpadCenter, R = dpadRadius, aw = R * 0.66
        let arms: [(Buttons, CGRect, String)] = [
            (.dpadUp, CGRect(x: c.x - aw / 2, y: c.y - R, width: aw, height: R - aw / 2), "▲"),
            (.dpadDown, CGRect(x: c.x - aw / 2, y: c.y + aw / 2, width: aw, height: R - aw / 2), "▼"),
            (.dpadLeft, CGRect(x: c.x - R, y: c.y - aw / 2, width: R - aw / 2, height: aw), "◀"),
            (.dpadRight, CGRect(x: c.x + aw / 2, y: c.y - aw / 2, width: R - aw / 2, height: aw), "▶"),
        ]
        let centerSq = CGRect(x: c.x - aw / 2, y: c.y - aw / 2, width: aw, height: aw)
        ctx.setFillColor(idleFill.cgColor)
        ctx.fill(centerSq)
        for (bit, r, label) in arms {
            let path = UIBezierPath(roundedRect: r, cornerRadius: aw * 0.18)
            ctx.setFillColor((dpadBits.contains(bit) ? UIColor(white: 1, alpha: 0.75) : idleFill).cgColor)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
            ctx.setStrokeColor(outline.cgColor)
            ctx.setLineWidth(1.5)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
            drawLabel(label, in: r, size: aw * 0.32, color: UIColor(white: 1, alpha: 0.7))
        }
    }

    private func drawButton(_ b: PadButton, pressed: Bool, _ ctx: CGContext) {
        let path = b.isCircle
            ? UIBezierPath(ovalIn: b.frame)
            : UIBezierPath(roundedRect: b.frame, cornerRadius: b.frame.height * 0.35)
        ctx.setFillColor((pressed ? b.tint.withAlphaComponent(0.9) : idleFill).cgColor)
        ctx.addPath(path.cgPath)
        ctx.fillPath()
        ctx.setStrokeColor((pressed ? b.tint : b.tint.withAlphaComponent(0.6)).cgColor)
        ctx.setLineWidth(2)
        ctx.addPath(path.cgPath)
        ctx.strokePath()

        let size = b.isCircle ? b.frame.height * 0.42 : min(b.frame.height * 0.42, b.frame.width * 0.2)
        drawLabel(b.label, in: b.frame, size: size, color: pressed ? .white : b.tint)
    }

    private func drawLabel(_ text: String, in r: CGRect, size: CGFloat, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
        ]
        let str = text as NSString
        let sz = str.size(withAttributes: attrs)
        str.draw(at: CGPoint(x: r.midX - sz.width / 2, y: r.midY - sz.height / 2), withAttributes: attrs)
    }
}
