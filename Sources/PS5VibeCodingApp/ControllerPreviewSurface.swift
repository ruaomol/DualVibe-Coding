import AppKit
import ImageIO
import QuartzCore
import SwiftUI

enum ControllerFace: CaseIterable {
    case front, rear

    static let pixels = CGSize(width: 1536, height: 1024)
    private static let frontImage = loadImage("DualSense-front")
    private static let rearImage = loadImage("DualSense-rear")

    var angle: CGFloat { self == .front ? 0 : .pi }
    var image: CGImage? { self == .front ? Self.frontImage : Self.rearImage }

    private static func loadImage(_ name: String) -> CGImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

enum PreviewTone: Equatable {
    case selected, active

    var color: NSColor { self == .selected ? .controlAccentColor : .systemGreen }
}

struct PreviewHotspot: Equatable {
    let id: String
    let name: String
    let path: CGPath
    let tone: PreviewTone?
}

struct PreviewLink: Equatable {
    let start: CGPoint
    let end: CGPoint
    let tone: PreviewTone

    func path(in height: CGFloat, lift: CGFloat) -> CGPath {
        let start = CGPoint(x: start.x, y: height - start.y)
        let end = CGPoint(x: end.x, y: height - end.y + lift)
        let bend = min(88, abs(end.x - start.x) * 0.42) * (start.x < end.x ? 1 : -1)
        let path = CGMutablePath()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + bend, y: start.y),
                     control2: CGPoint(x: end.x - bend, y: end.y))
        return path
    }
}

struct ControllerPreviewSurface: NSViewRepresentable {
    let rect: CGRect
    let face: ControllerFace
    let hotspots: [ControllerFace: [PreviewHotspot]]
    let links: [PreviewLink]
    let animatesTurn: Bool
    let floats: Bool
    let onSelect: (String) -> Void

    func makeNSView(context: Context) -> PreviewRenderView { PreviewRenderView() }

    func updateNSView(_ view: PreviewRenderView, context: Context) {
        view.configure(rect: rect, face: face, hotspots: hotspots, links: links,
                       animatesTurn: animatesTurn, floats: floats, onSelect: onSelect)
    }
}

final class PreviewRenderView: NSView {
    private static let floatingCycle: CFTimeInterval = 7.2
    private static let lifts: [CGFloat] = (0...32).map {
        1.2 * sin(CGFloat($0) / 32 * 2 * .pi)
    }

    private let floatingLayer = CALayer()
    private let rotor = CATransformLayer()
    private let connectors = CALayer()
    private var panels: [ControllerFace: CALayer] = [:]
    private var outlines: [ControllerFace: CALayer] = [:]
    private var face: ControllerFace = .front
    private var artworkRect = CGRect.zero
    private var hotspots: [ControllerFace: [PreviewHotspot]] = [:]
    private var links: [PreviewLink] = []
    private var onSelect: (String) -> Void = { _ in }
    private var floatingSince: CFTimeInterval?
    private var turning = false
    private var turnID = UUID()
    private var downID: String?
    private var elements: [PreviewAccessibilityButton] = []

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(floatingLayer)
        layer?.addSublayer(connectors)
        floatingLayer.addSublayer(rotor)
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / 1100
        floatingLayer.sublayerTransform = perspective
        for side in ControllerFace.allCases {
            let panel = CALayer()
            panel.isDoubleSided = false
            panel.contents = side.image
            panel.contentsGravity = .resize
            panel.minificationFilter = .trilinear
            panel.transform = CATransform3DMakeRotation(side.angle, 0, 1, 0)
            let contourLayer = CALayer()
            panel.addSublayer(contourLayer)
            rotor.addSublayer(panel)
            panels[side] = panel
            outlines[side] = contourLayer
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { nil }

    func configure(rect: CGRect, face next: ControllerFace, hotspots nextHotspots: [ControllerFace: [PreviewHotspot]],
                   links nextLinks: [PreviewLink], animatesTurn: Bool, floats: Bool, onSelect: @escaping (String) -> Void) {
        self.onSelect = onSelect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rectChanged = artworkRect != rect
        artworkRect = rect
        let contoursChanged = hotspots != nextHotspots
        hotspots = nextHotspots
        let linksChanged = links != nextLinks
        links = nextLinks
        let faceChanged = face != next
        let wasFloating = floatingSince != nil
        if wasFloating != floats { setFloating(floats) }
        if rectChanged { positionArtwork() }
        if rectChanged || contoursChanged { rebuildOutlines() }
        if faceChanged || (!animatesTurn && turning) { turn(to: next, animated: animatesTurn) }
        if rectChanged || linksChanged || wasFloating != floats { rebuildLinks() }
        if faceChanged || rectChanged || contoursChanged { rebuildAccessibility() }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionArtwork()
        rebuildLinks()
        CATransaction.commit()
    }

    private func positionArtwork() {
        let size = artworkRect.size
        let frame = CGRect(x: artworkRect.minX, y: bounds.height - artworkRect.maxY,
                           width: size.width, height: size.height)
        // Set bounds and position separately so the looping translation stays independent of layout.
        floatingLayer.bounds = CGRect(origin: .zero, size: size)
        floatingLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        rotor.bounds = floatingLayer.bounds
        rotor.position = CGPoint(x: size.width / 2, y: size.height / 2)
        for (side, panel) in panels {
            panel.bounds = rotor.bounds
            panel.position = CGPoint(x: rotor.bounds.midX, y: rotor.bounds.midY)
            outlines[side]?.frame = panel.bounds
        }
        connectors.frame = bounds
    }

    private func rebuildOutlines() {
        var flipped = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: artworkRect.height)
        for (side, layer) in outlines {
            layer.sublayers = (hotspots[side] ?? []).compactMap { hotspot in
                guard let tone = hotspot.tone else { return nil }
                let shape = CAShapeLayer()
                shape.frame = layer.bounds
                shape.path = hotspot.path.copy(using: &flipped)
                shape.fillColor = tone.color.withAlphaComponent(0.15).cgColor
                shape.strokeColor = tone.color.cgColor
                shape.lineWidth = 2.1
                return shape
            }
        }
    }

    private func rebuildLinks() {
        connectors.sublayers = links.map { link in
            let shape = CAShapeLayer()
            shape.frame = connectors.bounds
            shape.path = link.path(in: bounds.height, lift: 0)
            shape.fillColor = nil
            shape.strokeColor = link.tone.color.withAlphaComponent(link.tone == .selected ? 0.82 : 0.75).cgColor
            shape.lineWidth = link.tone == .selected ? 1.8 : 1.4
            shape.lineCap = .round
            if link.tone == .active { shape.lineDashPattern = [3, 4] }
            return shape
        }
        if let since = floatingSince {
            for (link, layer) in zip(links, connectors.sublayers ?? []) {
                let paths = Self.lifts.map { link.path(in: bounds.height, lift: $0) }
                layer.add(breathAnimation("path", values: paths, since: since, layer: layer), forKey: "float")
            }
        }
    }

    private func setFloating(_ enabled: Bool) {
        guard enabled else {
            floatingSince = nil
            floatingLayer.removeAnimation(forKey: "float")
            return
        }
        let since = CACurrentMediaTime()
        floatingSince = since
        floatingLayer.add(breathAnimation("transform.translation.y", values: Self.lifts,
                                         since: since, layer: floatingLayer), forKey: "float")
    }

    private func breathAnimation(_ path: String, values: [Any], since: CFTimeInterval, layer: CALayer) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: path)
        animation.values = values
        animation.beginTime = layer.convertTime(since, from: nil)
        animation.duration = Self.floatingCycle
        animation.repeatCount = .infinity
        return animation
    }

    private func turn(to next: ControllerFace, animated: Bool) {
        let key = "transform.rotation.y"
        let transform = rotor.presentation()?.transform ?? rotor.transform
        let start = Double(atan2(max(0, -transform.m13), transform.m11))
        face = next
        let end = Double(next.angle)
        rotor.transform = CATransform3DMakeRotation(next.angle, 0, 1, 0)
        let id = UUID()
        turnID = id
        rotor.removeAnimation(forKey: "turn")
        connectors.removeAnimation(forKey: "reveal")
        guard animated, abs(end - start) > 0.005 else {
            finishTurn()
            return
        }
        turning = true
        connectors.opacity = 0
        let turn = CABasicAnimation(keyPath: key)
        turn.fromValue = start
        turn.toValue = end
        turn.duration = max(0.18, min(0.66, abs(end - start) / .pi * 0.66))
        turn.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.06, 0.24, 1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.turnID == id else { return }
            self.finishTurn(reveal: true)
        }
        rotor.add(turn, forKey: "turn")
        CATransaction.commit()
    }

    private func finishTurn(reveal: Bool = false) {
        turning = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        connectors.opacity = 1
        if reveal {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.duration = 0.14
            connectors.add(fade, forKey: "reveal")
        }
        CATransaction.commit()
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    private var renderedLift: CGFloat {
        let layer = floatingLayer.presentation() ?? floatingLayer
        return layer.transform.m42
    }

    private func hotspot(at point: CGPoint) -> PreviewHotspot? {
        guard !turning else { return nil }
        let local = CGPoint(x: point.x - artworkRect.minX, y: bounds.height - point.y - artworkRect.minY + renderedLift)
        return hotspots[face]?.reversed().first { $0.path.contains(local) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return hotspot(at: convert(point, from: superview)) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downID = hotspot(at: convert(event.locationInWindow, from: nil))?.id
    }

    override func mouseUp(with event: NSEvent) {
        let id = hotspot(at: convert(event.locationInWindow, from: nil))?.id
        if let id, downID == id { onSelect(id) }
        downID = nil
    }

    private func rebuildAccessibility() {
        setAccessibilityLabel(face == .front ? "DualSense 正面" : "DualSense 背面")
        elements = (hotspots[face] ?? []).map { PreviewAccessibilityButton(hotspot: $0, surface: self) }
    }

    override func accessibilityChildren() -> [Any]? { turning ? [] : elements }

    fileprivate func screenFrame(for path: CGPath) -> CGRect {
        guard let window else { return .zero }
        let box = path.boundingBoxOfPath.offsetBy(dx: artworkRect.minX, dy: artworkRect.minY)
        let local = CGRect(x: box.minX, y: bounds.height - box.maxY + renderedLift,
                           width: box.width, height: box.height)
        return window.convertToScreen(convert(local, to: nil))
    }

    fileprivate func press(_ id: String) -> Bool {
        guard !turning else { return false }
        onSelect(id)
        return true
    }
}

private final class PreviewAccessibilityButton: NSAccessibilityElement {
    private let hotspot: PreviewHotspot
    private weak var surface: PreviewRenderView?

    init(hotspot: PreviewHotspot, surface: PreviewRenderView) {
        self.hotspot = hotspot
        self.surface = surface
        super.init()
        setAccessibilityParent(surface)
        setAccessibilityRole(.button)
        setAccessibilityLabel(hotspot.name)
        setAccessibilityEnabled(true)
        setAccessibilitySelected(hotspot.tone == .selected)
    }

    override func accessibilityFrame() -> NSRect { surface?.screenFrame(for: hotspot.path) ?? .zero }
    override func accessibilityPerformPress() -> Bool { surface?.press(hotspot.id) ?? false }
}
