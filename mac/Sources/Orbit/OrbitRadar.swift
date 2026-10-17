import SwiftUI

/// The live map of connected devices, as on the web Overview. The router sits in the middle. The closer a
/// device is to it, the stronger its Wi-Fi signal; wired devices sit on the inner ring. A bigger dot means
/// more traffic, and moving dashes mean data is flowing to it. The map turns slowly, and stops while the
/// pointer is over it. Click a device to see it on the Devices page. Hidden devices stay off the map.
struct OrbitRadar: View {
    var state: OrbitState
    var open: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = SpinClock()
    @State private var hovered: String?

    var body: some View {
        let nodes = OrbitNode.layout(state)
        VStack(alignment: .leading, spacing: 10) {
            header(nodes)
            GeometryReader { geo in
                stage(nodes, side: min(geo.size.width, geo.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            legend(nodes)
            keys
        }
        .padding(16)
        .background(RadialGradient(colors: [Sky.sky2, Sky.sky], center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 560),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Sky.line))
        .environment(\.colorScheme, .dark)  // a night sky in both themes, tooltip included
    }

    private func header(_ nodes: [OrbitNode]) -> some View {
        let active = nodes.filter(\.device.active).count
        let hidden = state.devices.filter { $0.online && $0.isHidden }.count
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your network right now").font(.headline).foregroundStyle(Sky.ink)
                Text("\(Format.plural(nodes.count, "device")) connected · \(active) using the internet" + (hidden > 0 ? " · \(hidden) hidden" : ""))
                    .font(.caption).foregroundStyle(Sky.ink2)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Sky.good).frame(width: 7, height: 7)
                Text("Live").font(.caption.weight(.semibold))
            }
            .foregroundStyle(Sky.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Sky.ink2.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Sky.line))
        }
    }

    /// What never moves is drawn once, by SwiftUI. What moves is made of Core Animation layers, which the
    /// system animates by itself. The pointer, clicks and VoiceOver are handled here, around both.
    private func stage(_ nodes: [OrbitNode], side: CGFloat) -> some View {
        let scale = side / 600
        let motion = !reduceMotion
        let labels = side >= 430
        return ZStack(alignment: .topLeading) {
            RadarBackdrop(side: side, motion: motion).equatable()
            RadarLayers(nodes: nodes, side: side, motion: motion, labels: labels, hovered: hovered, clock: clock)
                .frame(width: side, height: side)
            if let id = hovered, let p = placedNow(nodes, motion: motion).first(where: { $0.id == id }) {
                tooltip(p, scale: scale, side: side)
            }
        }
        .frame(width: side, height: side)
        .contentShape(Rectangle())
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point):
                if !clock.paused { clock.pause(at: .now) }  // the map stands still while you point at it
                let id = node(at: point, nodes, scale: scale, motion: motion)?.id
                if id != hovered { hovered = id }
            case .ended:
                clock.resume(at: .now)
                hovered = nil
            }
        }
        .onTapGesture(coordinateSpace: .local) { point in
            if let n = node(at: point, nodes, scale: scale, motion: motion) { open(n.id) }
        }
        .accessibilityLabel("Map of connected devices. Closer to the router means a stronger Wi-Fi signal.")
        .accessibilityChildren {
            ForEach(nodes) { n in
                Text(n.device.name)
                    .accessibilityLabel("\(n.device.name), \(n.ownerLabel), \(n.status), \(Format.mbps(n.device.downMbps)) megabits per second")
                    .accessibilityHint("Shows it on the Devices page")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { open(n.id) }
            }
        }
    }

    /// The devices where they are right now. While the pointer is over the map, it isn't turning.
    private func placedNow(_ nodes: [OrbitNode], motion: Bool) -> [PlacedNode] {
        nodes.map { $0.placed(spin: motion ? clock.degrees(at: .now) : 0) }
    }

    /// The device under a point of the map, if any: the nearest one within reach of its dot.
    private func node(at point: CGPoint, _ nodes: [OrbitNode], scale: CGFloat, motion: Bool) -> OrbitNode? {
        let x = point.x / scale, y = point.y / scale
        let distance = { (p: PlacedNode) in hypot(p.x - x, p.y - y) }
        return placedNow(nodes, motion: motion)
            .filter { distance($0) <= max($0.node.size + 7, 20) }
            .min { distance($0) < distance($1) }?
            .node
    }

    private func tooltip(_ p: PlacedNode, scale: CGFloat, side: CGFloat) -> some View {
        let n = p.node
        let d = n.device
        let above = p.y * scale > 120  // near the top, it shows below the dot instead
        let gap = (n.size + 8) * scale
        let card = VStack(alignment: .leading, spacing: 3) {
            Text(d.name).font(.callout.weight(.bold))
            HStack(spacing: 5) {
                Circle().fill(n.color).frame(width: 7, height: 7)
                Text("\(n.ownerLabel) · \(n.status)")
            }
            .font(.caption)
            Text("↓ \(Format.mbps(d.downMbps))  ↑ \(Format.mbps(d.upMbps)) Mbps").font(.caption.weight(.semibold)).monospacedDigit()
            Text(d.wired ? "Wired connection" : "\(Signal(d.effSignal).word) signal (\(Int(d.signal ?? 0)) dBm) · \(d.bandLabel)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(9)
        .fixedSize()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Sky.line2))
        return Color.clear
            .frame(width: 1, height: 1)
            .overlay(alignment: above ? .bottom : .top) { card.offset(y: above ? -gap : gap) }
            .position(x: min(max(p.x * scale, 95), side - 95), y: p.y * scale)
            .allowsHitTesting(false)
    }

    private func legend(_ nodes: [OrbitNode]) -> some View {
        let rows = state.people.map { p in
            LegendRow(id: p.id, name: p.name, color: Color.sky(p.color), hollow: false, count: nodes.filter { $0.person?.id == p.id }.count)
        } + [LegendRow(id: "", name: "No owner yet", color: Sky.none, hollow: true, count: nodes.filter { $0.person == nil }.count)]
        return FlowLayout(spacing: 14, lineSpacing: 6) {
            ForEach(rows.filter { $0.count > 0 }) { r in
                HStack(spacing: 6) {
                    Circle()
                        .fill(r.hollow ? Color.clear : r.color)
                        .overlay(Circle().strokeBorder(r.color, lineWidth: r.hollow ? 1.5 : 0))
                        .frame(width: 9, height: 9)
                    Text(r.name).foregroundStyle(Sky.ink2)
                    Text("\(r.count)").fontWeight(.bold).foregroundStyle(Sky.ink)
                }
                .font(.caption)
            }
        }
    }

    private var keys: some View {
        FlowLayout(spacing: 18, lineSpacing: 6) {
            key(.rings, "Closer to the middle = stronger Wi-Fi signal, not a distance. 2.4 GHz is judged 6 dB more gently.")
            key(.size, "Bigger = using more internet")
            key(.flow, "Moving dots = data flowing")
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Sky.line).frame(height: 1) }
    }

    private func key(_ kind: RadarKeyGlyph.Kind, _ text: String) -> some View {
        HStack(spacing: 7) {
            RadarKeyGlyph(kind: kind)
            Text(text).font(.caption).foregroundStyle(Sky.ink3)
        }
    }
}

/// The moving layer of the map, made of Core Animation layers. The system animates them by itself, so the app
/// spends next to no processor time per frame: drawn by SwiftUI 20 times a second, the same picture took a
/// tenth of a core or more. The layers use the map's 600 × 600 space with y going up, as Core Animation's does.
private struct RadarLayers: NSViewRepresentable {
    let nodes: [OrbitNode]
    let side: CGFloat
    let motion: Bool
    let labels: Bool
    let hovered: String?
    let clock: SpinClock

    func makeNSView(context: Context) -> RadarLayerView { RadarLayerView() }

    func updateNSView(_ view: RadarLayerView, context: Context) {
        view.update(nodes, side: side, motion: motion, labels: labels, hovered: hovered,
                    angle: motion ? clock.degrees(at: .now) * .pi / 180 : 0, turning: motion && !clock.paused)
    }
}

final class RadarLayerView: NSView {
    private let root = CALayer()  // the 600 × 600 map, scaled to fit the view
    private let effects = CALayer()  // twinkling stars, satellites and the router's pulse
    private let constellation = CALayer()  // the devices, turning around the router
    private let links = CALayer()  // under all the devices
    private let dots = CALayer()
    private var nodeLayers: [String: NodeLayers] = [:]
    private var motion: Bool?
    private var turning = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        constellation.bounds = root.bounds
        constellation.position = CGPoint(x: 300, y: 300)
        links.frame = root.bounds
        dots.frame = root.bounds
        constellation.addSublayer(links)
        constellation.addSublayer(dots)
        root.addSublayer(effects)
        root.addSublayer(constellation)
        layer?.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError("Not made from a coder") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // the pointer belongs to the SwiftUI views around it

    /// angle: how far the map has turned, in radians, clockwise on screen.
    func update(_ nodes: [OrbitNode], side: CGFloat, motion: Bool, labels: Bool, hovered: String?, angle: Double, turning: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // changes show at once; only the explicit animations move
        defer { CATransaction.commit() }
        root.transform = CATransform3DMakeScale(side / 600, side / 600, 1)
        let restart = self.motion != motion
        if restart { buildEffects(motion: motion) }
        let ids = Set(nodes.map(\.id))
        for (id, l) in nodeLayers where !ids.contains(id) {
            l.remove()
            nodeLayers[id] = nil
        }
        for n in nodes {
            let l: NodeLayers
            if let existing = nodeLayers[n.id] {
                l = existing
            } else {
                l = NodeLayers(links: links, dots: dots)
                nodeLayers[n.id] = l
                l.upright.setValue(angle, forKeyPath: "transform.rotation.z")
                if self.turning && !restart { l.upright.add(Self.turn(from: angle, by: 2 * .pi, at: CACurrentMediaTime()), forKey: "spin") }
            }
            l.show(n, labelled: labels && n.labelled, hovered: hovered == n.id, motion: motion)
        }
        if restart || turning != self.turning { spin(angle: angle, turning: turning) }
    }

    /// Starts or stops the turn at the given angle. Pointing at the map stops it.
    private func spin(angle: Double, turning: Bool) {
        self.turning = turning
        constellation.removeAnimation(forKey: "spin")
        constellation.setValue(-angle, forKeyPath: "transform.rotation.z")
        for l in nodeLayers.values {
            l.upright.removeAnimation(forKey: "spin")
            l.upright.setValue(angle, forKeyPath: "transform.rotation.z")
        }
        guard turning else { return }
        let now = CACurrentMediaTime()
        constellation.add(Self.turn(from: -angle, by: -2 * .pi, at: now), forKey: "spin")
        for l in nodeLayers.values { l.upright.add(Self.turn(from: angle, by: 2 * .pi, at: now), forKey: "spin") }
    }

    /// A full turn every lap, forever. Each device's icon and name turn back the other way to stay level.
    private static func turn(from: Double, by: Double, at begin: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = from
        a.toValue = from + by
        a.duration = SpinClock.lap
        a.repeatCount = .infinity
        a.beginTime = begin
        return a
    }

    /// Twinkling stars, a satellite train crossing now and then, and two rings pulsing out of the router.
    /// None of them with Reduce Motion.
    private func buildEffects(motion: Bool) {
        self.motion = motion
        effects.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard motion else { return }
        let now = CACurrentMediaTime()
        for s in OrbitDrawing.stars where s.twinkles {
            let star = Self.dot(at: Self.up(s.x, s.y), radius: s.r, color: Sky.ink)
            star.opacity = 0.15
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = 0.15
            twinkle.toValue = 0.9
            twinkle.duration = 1.8
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            twinkle.timeOffset = s.delay
            effects.addSublayer(star)
            star.add(twinkle, forKey: "twinkle")
        }
        // The train crosses the sky for 30% of every 46 seconds, the first time after 3.
        let train = CALayer()
        for i in 0..<5 {
            let d = Self.dot(at: CGPoint(x: -Double(i) * 13, y: -Double(i) * 3.4), radius: 1.5, color: Sky.ink)
            d.opacity = Float(0.85 - Double(i) * 0.12)
            train.addSublayer(d)
        }
        train.opacity = 0
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = [Self.up(-90, 170), Self.up(690, -30), Self.up(690, -30)].map { NSValue(point: $0) }
        move.keyTimes = [0, 0.3, 1]
        let show = CAKeyframeAnimation(keyPath: "opacity")
        show.values = [0, 1, 1, 0, 0]
        show.keyTimes = [0, 0.02, 0.3, 0.31, 1]
        effects.addSublayer(train)
        train.add(Self.forever([move, show], duration: 46, begin: now + 3), forKey: "cross")
        for offset in [0.0, 1.6] {  // half a beat apart
            let ring = CAShapeLayer()
            ring.bounds = CGRect(x: 0, y: 0, width: 60, height: 60)
            ring.position = CGPoint(x: 300, y: 300)
            ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NSColor(Sky.accent).cgColor
            ring.lineWidth = 1.2
            ring.opacity = 0
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 1
            grow.toValue = 2.4
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.55
            fade.toValue = 0
            let pulse = Self.forever([grow, fade], duration: 3.2, begin: now - offset)
            pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
            effects.addSublayer(ring)
            ring.add(pulse, forKey: "pulse")
        }
    }

    static func forever(_ parts: [CAAnimation], duration: Double, begin: CFTimeInterval) -> CAAnimationGroup {
        parts.forEach { $0.duration = duration }
        let group = CAAnimationGroup()
        group.animations = parts
        group.duration = duration
        group.repeatCount = .infinity
        group.beginTime = begin
        return group
    }

    static func dot(at p: CGPoint, radius r: Double, color: Color) -> CALayer {
        let d = CALayer()
        d.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        d.position = p
        d.cornerRadius = r
        d.backgroundColor = NSColor(color).cgColor
        return d
    }

    /// A point of the map, given with y going down as on the web page, in the layers' space where it goes up.
    static func up(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: 600 - y) }

    private static var icons: [String: (image: CGImage, size: CGSize)] = [:]

    /// A device-kind symbol in the sky's ink, drawn once per kind.
    static func icon(_ name: String) -> (image: CGImage, size: CGSize)? {
        if let cached = icons[name] { return cached }
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)) else { return nil }
        let size = symbol.size, scale = 3.0
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
                                         pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        symbol.draw(in: NSRect(origin: .zero, size: size))
        NSColor(Sky.ink).set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = rep.cgImage else { return nil }
        icons[name] = (image, size)
        return (image, size)
    }
}

/// The layers for one device: its line from the router, glow, halo and dot, and an upright part with its icon
/// and name, which turns back against the map so they stay level.
private final class NodeLayers {
    let link = CAShapeLayer()
    let glow = CAShapeLayer()
    let halo = CAShapeLayer()
    let body = CAShapeLayer()
    let upright = CALayer()
    let icon = CALayer()
    let label = CATextLayer()
    private var flowLap: Double?
    private var haloOn = false
    private var symbol: String?

    init(links: CALayer, dots: CALayer) {
        link.fillColor = nil
        link.lineCap = .round
        halo.fillColor = nil
        halo.lineWidth = 1.5
        halo.strokeColor = NSColor(Sky.warn).cgColor
        halo.isHidden = true
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.fontSize = 11
        label.alignmentMode = .center
        label.foregroundColor = NSColor(Sky.ink2).cgColor
        label.contentsScale = 3
        label.bounds = CGRect(x: 0, y: 0, width: 170, height: 15)
        label.shadowColor = NSColor(Sky.sky).cgColor  // an outline in the sky's color keeps it readable over the rings
        label.shadowOpacity = 1
        label.shadowRadius = 2
        label.shadowOffset = .zero
        upright.addSublayer(icon)
        upright.addSublayer(label)
        links.addSublayer(link)
        [glow, halo, body, upright].forEach(dots.addSublayer)
    }

    func remove() {
        [link, glow, halo, body, upright].forEach { $0.removeFromSuperlayer() }
    }

    func show(_ n: OrbitNode, labelled: Bool, hovered: Bool, motion: Bool) {
        let a = n.angle * .pi / 180
        let at = { (r: Double) in RadarLayerView.up(300 + r * cos(a), 300 + r * sin(a)) }
        let center = at(n.radius)
        let color = NSColor(n.color).cgColor
        func circle(_ r: Double) -> CGPath {
            CGPath(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2), transform: nil)
        }
        // The line from the router. While data flows, dashes move out along it, faster for more.
        let path = CGMutablePath()
        path.move(to: at(36))
        path.addLine(to: at(max(40, n.radius - n.size - 4)))
        link.path = path
        if n.hot {
            link.strokeColor = color
            link.lineWidth = 1.6
            link.lineDashPattern = [2.5, 7]
            let lap = n.device.downMbps > 25 ? 0.55 : n.device.downMbps > 6 ? 0.9 : 1.5
            if motion && lap != flowLap {
                let flow = CABasicAnimation(keyPath: "lineDashPhase")
                flow.fromValue = 19
                flow.toValue = 0
                flow.duration = lap
                flow.repeatCount = .infinity
                link.add(flow, forKey: "flow")
                flowLap = lap
            }
        } else {
            link.strokeColor = NSColor(Sky.line2).cgColor
            link.lineWidth = 1.2
            link.lineDashPattern = nil
            link.removeAnimation(forKey: "flow")
            flowLap = nil
        }
        glow.path = circle(n.size + 5)  // a glow while busy
        glow.fillColor = color.copy(alpha: 0.22)
        glow.isHidden = !n.hot
        let h = n.size + 3  // a halo while new
        halo.bounds = CGRect(x: 0, y: 0, width: h * 2, height: h * 2)
        halo.position = center
        halo.path = CGPath(ellipseIn: halo.bounds, transform: nil)
        let wantHalo = n.device.isNew && motion
        if wantHalo != haloOn {
            haloOn = wantHalo
            halo.isHidden = !wantHalo
            if wantHalo {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = 0.85
                grow.toValue = 1.6
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.9
                fade.toValue = 0
                halo.add(RadarLayerView.forever([grow, fade], duration: 1.8, begin: CACurrentMediaTime()), forKey: "halo")
            } else {
                halo.removeAnimation(forKey: "halo")
            }
        }
        body.path = circle(n.size)  // the dot, in the owner's color, dashed when nobody owns it
        body.fillColor = NSColor(hovered ? Sky.sky3 : Sky.sky2).cgColor
        body.strokeColor = color
        body.lineWidth = hovered ? 3 : 2
        body.lineDashPattern = n.person == nil ? [3, 3] : nil
        upright.position = center
        let symbol = Icons.device(n.device.type)
        if symbol != self.symbol, let made = RadarLayerView.icon(symbol) {
            self.symbol = symbol
            icon.contents = made.image
            icon.bounds = CGRect(origin: .zero, size: made.size)
            icon.position = .zero
        }
        label.isHidden = !labelled
        label.string = n.device.name.count > 17 ? String(n.device.name.prefix(16)) + "…" : n.device.name
        label.position = CGPoint(x: 0, y: -(n.size + 11))  // under the dot
    }
}

/// The parts of the map that never move. Equatable, so it's drawn again only when its size or motion changes.
private struct RadarBackdrop: View, Equatable {
    let side: CGFloat
    let motion: Bool  // with motion, the twinkling stars are left for the moving layer

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: side / 600, y: side / 600)
            OrbitDrawing.backdrop(&ctx, motion: motion)
        } symbols: {
            Image(systemName: OrbitDrawing.router)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Sky.ink)
                .tag(OrbitDrawing.router)
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

private struct LegendRow: Identifiable {
    let id: String
    let name: String
    let color: Color
    let hollow: Bool
    let count: Int
}

/// The night sky's colors, the same as the web page's in both themes.
enum Sky {
    static let sky = Color(hex: 0x0A1222)
    static let sky2 = Color(hex: 0x111C31)
    static let sky3 = Color(hex: 0x1A2742)
    static let ink = Color(hex: 0xEDF1FB)
    static let ink2 = Color(hex: 0xA8B3CB)
    static let ink3 = Color(hex: 0x75829C)
    static let line = Color(hex: 0xA8B3CB).opacity(0.15)
    static let line2 = Color(hex: 0xA8B3CB).opacity(0.3)
    static let accent = Color(hex: 0xA59BFF)
    static let warn = Color(hex: 0xFAB219)
    static let good = Color(hex: 0x0CA30C)
    static let none = Color(hex: 0x8A95AB)
}

/// The map's slow turn: a lap every 260 seconds, paused while the pointer is over it.
struct SpinClock {
    static let lap = 260.0
    private var turned = 0.0  // seconds of turning before runningSince
    private var runningSince: Date? = .now

    var paused: Bool { runningSince == nil }

    func degrees(at now: Date) -> Double {
        let s = turned + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
        return s.truncatingRemainder(dividingBy: Self.lap) / Self.lap * 360
    }

    mutating func pause(at now: Date) {
        guard let since = runningSince else { return }
        turned += now.timeIntervalSince(since)
        runningSince = nil
    }

    mutating func resume(at now: Date) {
        if runningSince == nil { runningSince = now }
    }
}

/// One connected device on the map, in a 600 × 600 space like the web version's SVG.
struct OrbitNode: Identifiable {
    let device: Device
    let person: Person?
    let angle: Double  // degrees around the router before the map turns: 0 is to the right, -90 straight up
    let radius: Double  // distance from the router
    let size: Double  // the dot's radius
    let labelled: Bool

    var id: String { device.id }
    var hot: Bool { device.downMbps + device.upMbps > 0.4 }
    var color: Color { person.map { Color.sky($0.color) } ?? (device.isNew ? Sky.warn : Sky.none) }
    var ownerLabel: String { person?.name ?? (device.isNew ? "New device" : "No owner yet") }
    var status: String { device.blocked == true ? "Blocked" : device.active ? "Online" : "Idle" }

    func placed(spin: Double) -> PlacedNode {
        let a = (angle + spin) * .pi / 180
        return PlacedNode(node: self, x: 300 + radius * cos(a), y: 300 + radius * sin(a))
    }

    /// Where each connected device goes: grouped by owner around the circle, the strongest signal first.
    /// The two using the most, and new devices, get a name label.
    static func layout(_ s: OrbitState) -> [OrbitNode] {
        let shown = s.devices.filter { $0.online && !$0.isHidden }
        let groups = (s.people.map { Optional($0.id) } + [nil])
            .map { pid in shown.filter { s.person($0.owner)?.id == pid }.sorted { strength($0) > strength($1) } }
            .filter { !$0.isEmpty }
        let gap = 9.0
        let per = (360 - gap * Double(groups.count)) / Double(max(1, shown.count))
        let busiest = Set(shown.filter { $0.downMbps > 2 }.sorted { $0.downMbps > $1.downMbps }.prefix(2).map(\.id))
        var at = -90 + gap / 2
        var out: [OrbitNode] = []
        for group in groups {
            for (i, d) in group.enumerated() {
                out.append(OrbitNode(device: d, person: s.person(d.owner), angle: at + per * (Double(i) + 0.5), radius: distance(d),
                                     size: 12 + 10 * min(1, d.downMbps / 45).squareRoot(), labelled: busiest.contains(d.id) || d.isNew))
            }
            at += per * Double(group.count) + gap
        }
        return out
    }

    private static func strength(_ d: Device) -> Double { d.wired ? 0 : d.signal ?? -99 }

    /// Wired devices sit on the inner ring; Wi-Fi ones sit further out the weaker their signal.
    private static func distance(_ d: Device) -> Double {
        if d.wired { return 66 }
        guard let dbm = d.effSignal else { return 200 }
        return min(272, max(96, 96 + (-dbm - 40) * 4.6))
    }
}

/// A device where it is at some moment, in the map's space with y going down.
struct PlacedNode: Identifiable {
    let node: OrbitNode
    let x: Double
    let y: Double
    var id: String { node.id }
}

/// The map's fixed parts, drawn in its 600 × 600 space with y going down, like the web version's SVG.
enum OrbitDrawing {
    static let router = "wifi.router"
    static let zones: [(radius: Double, label: String, labelY: Double)] = [
        (272, "WEAK · UNDER −70 dBm", 47), (234, "FAIR · −70 TO −63", 82), (202, "GOOD · −63 TO −55", 117), (165, "EXCELLENT · −55 OR BETTER", 157),
    ]

    struct Star {
        let x, y, r, opacity, delay: Double
        let twinkles: Bool
    }

    /// The same scattering of stars as the web page: a fixed pseudo-random sequence.
    static let stars: [Star] = {
        var a = 7
        func next() -> Double {
            a = (a * 16807) % 2147483647
            return Double(a) / 2147483647
        }
        return (0..<90).map { i in
            let x = next() * 600, y = next() * 600, r = 0.4 + next() * 1.1, opacity = 0.15 + next() * 0.55, delay = next() * 4
            return Star(x: x, y: y, r: r, opacity: opacity, delay: delay, twinkles: i % 6 == 0)
        }
    }()

    static func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }

    static func label(_ s: String, size: CGFloat, weight: Font.Weight = .semibold, color: Color, tracking: CGFloat = 0) -> Text {
        Text(s).font(.system(size: size, weight: weight)).tracking(tracking).foregroundStyle(color)
    }

    /// What never moves: the stars that don't twinkle, the signal rings and the router.
    static func backdrop(_ ctx: inout GraphicsContext, motion: Bool) {
        for s in stars where !(s.twinkles && motion) {
            ctx.fill(circle(s.x, s.y, s.r), with: .color(Sky.ink.opacity(s.opacity)))
        }
        for (i, zone) in zones.enumerated() {
            let ring = circle(300, 300, zone.radius)
            ctx.fill(ring, with: .color(Sky.ink.opacity(0.016 + Double(i) * 0.012)))
            ctx.stroke(ring, with: .color(Sky.line), lineWidth: 1)
            ctx.draw(label(zone.label, size: 9.5, color: Sky.ink3, tracking: 1.1), at: CGPoint(x: 300, y: zone.labelY))
        }
        ctx.stroke(circle(300, 300, 66), with: .color(Sky.line), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        ctx.draw(label("WIRED", size: 9.5, color: Sky.ink3, tracking: 1.1), at: CGPoint(x: 300, y: 251))
        let body = circle(300, 300, 30)
        ctx.fill(body, with: .color(Sky.sky3))
        ctx.stroke(body, with: .color(Sky.accent), lineWidth: 1.5)
        if let icon = ctx.resolveSymbol(id: router) { ctx.draw(icon, at: CGPoint(x: 300, y: 300)) }
        ctx.draw(label("ROUTER", size: 11, weight: .bold, color: Sky.ink2, tracking: 1.1), at: CGPoint(x: 300, y: 346))
    }
}

/// The little pictures in the map's key.
struct RadarKeyGlyph: View {
    enum Kind { case rings, size, flow }
    var kind: Kind

    var body: some View {
        switch kind {
        case .rings:
            ZStack {
                Circle().stroke(Sky.ink2, lineWidth: 1.4).frame(width: 15, height: 15)
                Circle().stroke(Sky.ink2, lineWidth: 1.4).frame(width: 8, height: 8)
                Circle().fill(Sky.ink2).frame(width: 2.6, height: 2.6)
            }
            .frame(width: 18, height: 18)
        case .size:
            HStack(spacing: 3) {
                Circle().stroke(Sky.ink2, lineWidth: 1.4).frame(width: 6, height: 6)
                Circle().stroke(Sky.ink2, lineWidth: 1.4).frame(width: 12, height: 12)
            }
            .frame(width: 22, height: 18)
        case .flow:
            Path { p in
                p.move(to: CGPoint(x: 1, y: 9))
                p.addLine(to: CGPoint(x: 21, y: 9))
            }
            .stroke(Sky.ink2, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [2.5, 3.5]))
            .frame(width: 22, height: 18)
        }
    }
}
