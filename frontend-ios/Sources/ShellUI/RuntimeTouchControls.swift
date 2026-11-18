#if canImport(UIKit)
import UIKit
import SwiftUI

/// Interactive use of the same geometry and outlines as the shell's control editor.
/// Unclaimed touches pass through to the game's touchscreen.
@MainActor public final class RuntimeTouchControls: UIView {
    public var onClose: (() -> Void)?
    public var showsPad = true { didSet { reset() } }
    public var onChange: ((UInt64, Float, Float, Float, Float) -> Void)?
    private enum Control: Equatable { case button(Int), face, dpad, stick(Int), menu }
    private final class CloseAccessibility: UIAccessibilityElement {
        weak var controls: RuntimeTouchControls?
        override func accessibilityActivate() -> Bool {
            guard let controls, controls.isUserInteractionEnabled else { return false }
            controls.reset(); controls.onClose?(); return true
        }
    }
    private lazy var closeAccessibility: CloseAccessibility = {
        let element = CloseAccessibility(accessibilityContainer: self)
        element.controls = self
        element.accessibilityLabel = ShellStrings.text("Close")
        element.accessibilityTraits = .button
        return element
    }()
    private var held: [ObjectIdentifier: (Control, CGPoint, CGPoint)] = [:]
    private let settings = ShellSettingsStore()
    private var geometry = PadGeo.make(.proMax, full: true)
    private var shapes: [(TouchPadPreviewGeometry.Shape, Control)] = []

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isOpaque = false
        backgroundColor = .clear
        accessibilityElements = [closeAccessibility]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        reset()
        let i = safeAreaInsets
        geometry = PadGeo.make(PadScreen(size: bounds.size,
            insets: .init(top: i.top, left: i.left, bottom: i.bottom, right: i.right)), full: settings.touchMode != "2d",
            size: settings.touchSize, stick: settings.touchStick, layout: settings.touchLayout)
        let closeRadius = max(geometry.swapR * 1.6, 22)
        closeAccessibility.accessibilityFrameInContainerSpace = CGRect(
            x: geometry.swap.x - closeRadius, y: geometry.swap.y - closeRadius,
            width: closeRadius * 2, height: closeRadius * 2)
        shapes = TouchPadPreviewGeometry.shapes(geometry).compactMap { shape in
            let label: String?
            switch shape {
            case .circle(_, _, let text): label = text
            case .drop(_, _, _, let text), .pill(_, let text): label = text
            case .dpad: return (shape, .dpad)
            case .ring: return (shape, .stick(0))
            }
            let bits = ["A": 0, "B": 1, "X": 2, "Y": 3, "L3": 4, "R3": 5,
                        "L": 6, "R": 7, "ZL": 8, "ZR": 9, "+": 10, "−": 11]
            guard let label, let bit = bits[label] else { return (shape, .menu) }
            return (shape, .button(bit))
        }
        setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        for (shape, control) in shapes where showsPad || control == .menu {
            let pressed = held.values.contains { $0.0 == control || ($0.0 == .face && faceBits(at: $0.2) & buttonMask(control) != 0) }
            context.addPath(PadDrawing.outline(shape).cgPath)
            context.setFillColor(UIColor.white.withAlphaComponent(pressed ? 0.3 : control == .stick(0) ? 0.06 : 0.14).cgColor)
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.38).cgColor)
            context.setLineWidth(1.5)
            context.drawPath(using: .fillStroke)
            if case .ring(let center, let radius, let knob) = shape {
                let point = held.values.first(where: { $0.0 == .stick(0) })?.2 ?? center
                let dx = point.x - center.x, dy = point.y - center.y
                let scale = max(1, hypot(dx, dy) / max(1, radius))
                context.fillEllipse(in: CGRect(x: center.x + dx / scale - knob,
                    y: center.y + dy / scale - knob, width: knob * 2, height: knob * 2))
            }
            if control == .menu {
                let size = 13 * geometry.u
                UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: geometry.swap.x - size / 2, y: geometry.swap.y - size / 2, width: size, height: size))
            }
            let label: String?, center: CGPoint, fontSize: CGFloat
            switch shape {
            case .circle(let c, let r, let text): label = text; center = c; fontSize = r * 0.75
            case .drop(let c, let r, _, let text): label = text; center = c; fontSize = r * 0.62
            case .pill(let rect, let text): label = text; center = CGPoint(x: rect.midX, y: rect.midY); fontSize = rect.height * 0.64
            default: label = nil; center = .zero; fontSize = 0
            }
            if let label {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.6)]
                let size = (label as NSString).size(withAttributes: attributes)
                (label as NSString).draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
            }
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
    private func buttonMask(_ control: Control) -> UInt64 {
        if case .button(let bit) = control { return 1 << bit }; return 0
    }
    private func faceBits(at point: CGPoint) -> UInt64 {
        geometry.faceKey.enumerated().reduce(0) { mask, key in
            mask | (distance(point, key.element) <= geometry.faceHitR ? UInt64(1) << key.offset : 0)
        }
    }
    // DmPadGeometry.h: locked shoulders/±/clicks, then nearest normalized grab region.
    private func control(at point: CGPoint) -> Control? {
        let g = geometry, sep = geometry.region.separated
        var locked: Control?, nearest: CGFloat = 1
        for bit in [8, 6, 9, 7, 11, 10, 4, 5] {
            if bit < 6 && !g.full { continue }
            let d: CGFloat
            if let index = [8, 6, 9, 7].firstIndex(of: bit) {
                d = distance(point, g.drop[index]) / max(g.dropR[index] * 1.35, sep ? 22 : 0)
            } else if bit < 6 {
                d = distance(point, g.click[bit - 4]) / max(g.clickR * 1.35, sep ? 22 : 0)
            } else {
                let r = g.pill[bit == 11 ? 0 : 1].insetBy(dx: -8 * g.u, dy: -8 * g.u)
                d = max(abs(point.x - r.midX) / (max(r.width, sep ? 28 : 0) / 2),
                        abs(point.y - r.midY) / (max(r.height, sep ? 28 : 0) / 2))
            }
            if d <= 1 && (locked == nil || d < nearest) {
                locked = .button(bit); nearest = d
                if !sep && g.moved.isEmpty { break }
            }
        }
        let menu = distance(point, g.swap) / max(g.swapR * 1.6, 22)
        if menu <= 1 && (!showsPad || locked == nil || menu < nearest) { return .menu }
        guard showsPad, !sep || g.region.controls.contains(point) else { return nil }
        if let locked { return locked }
        var result: Control?, best: CGFloat = 1
        let face = g.faceSplit
            ? g.faceKey.map { distance(point, $0) / max(g.faceR * 1.6, g.faceHitR) }.min()!
            : distance(point, g.face) / (g.faceGap + max(g.faceR * 1.6, g.faceHitR))
        if face <= best { best = face; result = .face }
        let dpad = distance(point, g.dpad) / max(g.dpadR * 1.3, sep ? 22 : 0)
        if g.full && dpad < best { best = dpad; result = .dpad }
        let stick = distance(point, g.stick) / max(g.stickR * 1.4, sep ? 22 : 0)
        if !held.values.contains(where: { $0.0 == .stick(0) }) && stick < best { result = .stick(0) }
        if result == nil && g.full && !held.values.contains(where: { $0.0 == .stick(1) }),
           point.x >= g.region.controls.maxX - g.region.controls.width / 3 { result = .stick(1) }
        return result
    }
    public override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        control(at: point) != nil
    }
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let point = touch.location(in: self)
            guard let control = control(at: point) else { continue }
            if case .stick = control, held.values.contains(where: { $0.0 == control }) { continue }
            let origin = control == .stick(0) ? geometry.stick : point
            held[ObjectIdentifier(touch)] = (control, origin, point)
        }
        send()
    }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            guard let value = held[id] else { continue }
            let point = touch.location(in: self)
            var origin = value.1
            let radius = 60 * geometry.u, d = distance(point, origin)
            if value.0 == .stick(1) && d > radius {
                origin = CGPoint(x: point.x - (point.x - origin.x) * radius / d,
                                 y: point.y - (point.y - origin.y) * radius / d)
            }
            held[id] = (value.0, origin, point)
        }
        send()
    }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let menu = touches.contains { held[ObjectIdentifier($0)]?.0 == .menu && control(at: $0.location(in: self)) == .menu }
        end(touches)
        if menu { reset(); onClose?() }
    }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
    private func end(_ touches: Set<UITouch>) {
        for touch in touches { held.removeValue(forKey: ObjectIdentifier(touch)) }
        send()
    }
    public func reset() { held.removeAll(); send() }
    private func send() {
        var buttons: UInt64 = 0
        var sticks = [Float](repeating: 0, count: 4)
        for (control, origin, point) in held.values {
            switch control {
            case .button(let bit): buttons |= 1 << bit
            case .menu: break
            case .face: buttons |= faceBits(at: point)
            case .dpad:
                let x = point.x - geometry.dpad.x, y = point.y - geometry.dpad.y
                if hypot(x, y) < geometry.dpadR * 0.25 { continue }
                let angle = atan2(-y, x) * 180 / .pi
                if angle > -67.5 && angle < 67.5 { buttons |= 1 << 14 }
                if angle > 22.5 && angle < 157.5 { buttons |= 1 << 13 }
                if angle > 112.5 || angle < -112.5 { buttons |= 1 << 12 }
                if angle < -22.5 && angle > -157.5 { buttons |= 1 << 15 }
            case .stick(let index):
                let radius = index == 0 ? geometry.stickR : 60 * geometry.u
                let x = point.x - origin.x, y = origin.y - point.y, d = hypot(x, y)
                let dead = radius * 0.1
                if d <= dead { continue }
                let magnitude = min((d - dead) / (radius * 0.8 - dead), 1) / d
                sticks[index * 2] = Float(x * magnitude); sticks[index * 2 + 1] = Float(y * magnitude)
            }
        }
        onChange?(buttons, sticks[0], sticks[1], sticks[2], sticks[3])
        setNeedsDisplay()
    }
}
#endif
