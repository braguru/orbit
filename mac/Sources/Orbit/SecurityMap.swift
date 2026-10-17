import AppKit
import SwiftUI

/// The Security page's map: your router in the middle, a wedge of sky for each Wi-Fi network, walls between
/// them, and the devices as dots. Like the Overview map, what never moves is drawn once in an Equatable Canvas;
/// the only thing that moves, the dashes along a contact attempt, is a Core Animation layer.

// MARK: - what is on the map

extension Sky {
    static let crit = Color(hex: 0xF0605E)
    static let critInk = Color(hex: 0xFFB4B4)
    static let reach = Color(hex: 0x2FBF71)
}

struct SecZone: Equatable, Identifiable {
    let id: String  // the network's domain
    let name: String
    let guest: Bool
    let open: Bool
    let enabled: Bool
    let isolated: Bool?
    let a0: Double  // degrees around the router: 0 is to the right, 90 straight down
    let a1: Double
    var mid: Double { (a0 + a1) / 2 }
    /// Devices on it can't reach each other: a guest network with client isolation on.
    var walledIn: Bool { guest && isolated != false }
    var danger: Bool { open || (guest && isolated == false) }
}

struct SecNode: Equatable, Identifiable {
    let id: String
    let name: String
    let type: String
    let zone: Int
    let x: Double
    let y: Double
    let angle: Double
    let ghost: Bool       // an address with no device on the network
    let color: String?    // the owner's color
    let unowned: Bool
}

struct SecArc: Equatable, Identifiable {
    let id: String
    let from: CGPoint
    let to: CGPoint
    let control: CGPoint
    var known = false  // a known device talking to this Mac: a calm dotted line, not an alert
}

struct SecLayout: Equatable {
    var zones: [SecZone]
    var nodes: [SecNode]
    var arcs: [SecArc]
    var hot: Set<String>  // nodes that are the source of a contact attempt right now
    var hostID: String?

    static func polar(_ a: Double, _ r: Double) -> CGPoint {
        CGPoint(x: 300 + r * cos(a * .pi / 180), y: 300 + r * sin(a * .pi / 180))
    }

    func node(_ id: String) -> SecNode? { nodes.first { $0.id == id } }

    /// Two devices can reach each other when they share a network, unless it's a guest network with client isolation.
    func canReach(_ a: SecNode, _ b: SecNode) -> Bool {
        a.id != b.id && !a.ghost && !b.ghost && a.zone == b.zone && !zones[a.zone].walledIn
    }

    /// Wall angles: where one network's wedge meets another's.
    var walls: [Double] {
        let starts = Set(zones.map { Int($0.a0.rounded()) % 360 })
        let ends = Set(zones.map { Int($0.a1.rounded()) % 360 })
        return starts.intersection(ends).sorted().map(Double.init)
    }

    static func make(_ s: OrbitState) -> SecLayout {
        var nets = s.router.networks
        if nets.isEmpty {  // an older server doesn't say: two rooms are all we can promise
            nets = [WifiNetwork(domain: "main", guest: false, isolated: false, subnet: nil, ssids: [:], open: false, enabled: true)]
            if s.devices.contains(where: { $0.network == "guest" }) {
                nets.append(WifiNetwork(domain: "guest", guest: true, isolated: nil, subnet: nil, ssids: [:], open: false, enabled: true))
            }
        }
        let main = nets.filter { !$0.guest }, guests = nets.filter(\.guest)
        var zones: [SecZone] = []
        func add(_ list: [WifiNetwork], from start: Double) {
            let each = 180 / Double(max(1, list.count))
            for (i, n) in list.enumerated() {
                zones.append(SecZone(id: n.domain, name: n.name, guest: n.guest, open: n.open == true, enabled: n.isOn, isolated: n.isolated,
                                     a0: start + each * Double(i), a1: start + each * Double(i + 1)))
            }
        }
        add(main, from: 180)  // non-guest networks share the top half, guests split the bottom
        add(guests, from: 0)
        guard !zones.isEmpty else { return SecLayout(zones: [], nodes: [], arcs: [], hot: [], hostID: nil) }
        let mainDomain = main.first?.domain ?? zones[0].id
        func zoneIndex(_ d: Device) -> Int {
            if let i = zones.firstIndex(where: { $0.id == (d.domain ?? (d.network == "guest" ? "" : mainDomain)) }) { return i }
            if d.network == "guest", let i = zones.firstIndex(where: \.guest) { return i }
            return zones.firstIndex { !$0.guest } ?? 0
        }

        var nodes: [SecNode] = []
        let shown = s.devices.filter { $0.online && !$0.isHidden }.sorted { $0.id < $1.id }
        for (zi, z) in zones.enumerated() {
            let here = shown.filter { zoneIndex($0) == zi }
            let n = here.count
            for (i, d) in here.enumerated() {
                let pad = 6.0
                let a = z.a0 + pad + (z.a1 - z.a0 - 2 * pad) * (Double(i) + 0.5) / Double(n)
                let r = n <= 4 ? 170 : [150.0, 192, 234][i % 3]
                let p = polar(a, r)
                let person = s.person(d.owner)
                nodes.append(SecNode(id: d.id, name: d.name, type: d.type, zone: zi, x: p.x, y: p.y, angle: a, ghost: false,
                                     color: person?.color, unowned: person == nil))
            }
        }

        // Contact attempts from the past hour: an arc from whoever it was to this Mac.
        let hostID = s.security?.tripwire?.hostDevice
        let host = hostID.flatMap { id in nodes.first { $0.id == id } }
        let target = host.map { CGPoint(x: $0.x, y: $0.y) } ?? CGPoint(x: 300, y: 300)
        let mainZone = zones.firstIndex { !$0.guest } ?? 0
        var arcs: [SecArc] = []
        var hot = Set<String>()
        let ghosts = s.activeProbes.filter { p in p.device.map { id in !nodes.contains { $0.id == id } } ?? true }
        for p in s.activeProbes {
            var source = p.device.flatMap { id in nodes.first { $0.id == id } }
            if source == nil, let gi = ghosts.firstIndex(where: { $0.ip == p.ip }) {
                let z = zones[mainZone]
                let a = z.a0 + 14 + (z.a1 - z.a0 - 28) * (Double(gi) + 0.5) / Double(ghosts.count)
                let pt = polar(a, 244)
                let node = SecNode(id: "ghost:\(p.ip)", name: p.ip, type: "unknown", zone: mainZone, x: pt.x, y: pt.y, angle: a, ghost: true,
                                   color: nil, unowned: true)
                nodes.append(node)
                source = node
            }
            guard let source, source.id != hostID else { continue }
            hot.insert(source.id)
            let mx = (source.x + target.x) / 2, my = (source.y + target.y) / 2
            arcs.append(SecArc(id: p.ip, from: CGPoint(x: source.x, y: source.y), to: target,
                               control: CGPoint(x: mx + (300 - mx) * 0.35, y: my + (300 - my) * 0.35)))
        }
        for p in s.friendlyProbes {
            guard let source = p.device.flatMap({ id in nodes.first { $0.id == id } }), source.id != hostID else { continue }
            let mx = (source.x + target.x) / 2, my = (source.y + target.y) / 2
            arcs.append(SecArc(id: "known:\(p.ip)", from: CGPoint(x: source.x, y: source.y), to: target,
                               control: CGPoint(x: mx + (300 - mx) * 0.2, y: my + (300 - my) * 0.2), known: true))
        }
        return SecLayout(zones: zones, nodes: nodes, arcs: arcs, hot: hot, hostID: host?.id)
    }
}

// MARK: - the map

struct SecurityMap: View {
    var layout: SecLayout
    var state: OrbitState
    @Binding var selected: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geo in
                stage(side: min(geo.size.width, geo.size.height))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            keys
        }
        .padding(16)
        .background(RadialGradient(colors: [Sky.sky2, Sky.sky], center: UnitPoint(x: 0.5, y: 0.38), startRadius: 0, endRadius: 620),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Sky.line))
        .environment(\.colorScheme, .dark)  // a night sky in both themes
    }

    private var header: some View {
        let watching = !state.activeProbes.isEmpty
        let off = state.security?.tripwire?.on == false
        let word = watching ? "Contact attempt" : off ? "Tripwire off" : "All quiet"
        let tint = watching ? Sky.crit : off ? Sky.none : Sky.reach
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Who can reach whom").font(.headline).foregroundStyle(Sky.ink)
                Text("\(Format.plural(layout.zones.count, "Wi-Fi network")) around your router. Tap a device to see what it can reach.")
                    .font(.caption).foregroundStyle(Sky.ink2)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(word).font(.caption.weight(.semibold))
            }
            .foregroundStyle(Sky.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Sky.ink2.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(Sky.line))
        }
    }

    private func stage(side: CGFloat) -> some View {
        let scale = side / 600
        let sel = selected.flatMap { layout.node($0) }
        return ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle()).onTapGesture { selected = nil }
            SecBackdrop(layout: layout, side: side).equatable()
            SecReach(layout: layout, selected: sel?.id, side: side).equatable()
            SecArcs(arcs: layout.arcs, side: side, motion: !reduceMotion)
                .frame(width: side, height: side)
            ForEach(layout.arcs) { arc in
                Text(arc.known ? "Allowed" : "Probing").font(.system(size: 10, weight: .bold)).foregroundStyle(arc.known ? Sky.accent : Sky.critInk)
                    .shadow(color: Sky.sky, radius: 2)
                    .position(x: (0.5625 * arc.from.x + 0.375 * arc.control.x + 0.0625 * arc.to.x) * scale,
                              y: (0.5625 * arc.from.y + 0.375 * arc.control.y + 0.0625 * arc.to.y) * scale - 12)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ForEach(layout.nodes) { n in nodeView(n, sel: sel, scale: scale, side: side) }
        }
        .frame(width: side, height: side)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map of your devices grouped by Wi-Fi network. Walls separate the networks.")
    }

    @ViewBuilder
    private func nodeView(_ n: SecNode, sel: SecNode?, scale: CGFloat, side: CGFloat) -> some View {
        let size = max(26, 30 * scale)
        let hot = layout.hot.contains(n.id)
        let isHost = n.id == layout.hostID
        let isSel = n.id == sel?.id
        let dim = sel != nil && !isSel && !layout.canReach(sel!, n)
        let color = hot ? Sky.crit : n.color.map { Color.sky($0) } ?? Sky.warn
        let labelled = isSel || hot || isHost || n.ghost || n.unowned
        let zone = layout.zones[n.zone]
        let dot = ZStack {
            if hot { Circle().stroke(Sky.crit.opacity(0.5), lineWidth: 1.5).frame(width: size + 8, height: size + 8) }
            Circle().fill(isSel ? Sky.sky3 : Sky.sky2).frame(width: size, height: size)
            Circle().strokeBorder(color, style: StrokeStyle(lineWidth: isSel ? 3 : 2, dash: n.unowned ? [3, 3] : [])).frame(width: size, height: size)
            Image(systemName: n.ghost ? "questionmark" : Icons.device(n.type)).font(.system(size: size * 0.45, weight: .medium)).foregroundStyle(Sky.ink)
            if isSel { Circle().strokeBorder(Sky.ink, style: StrokeStyle(lineWidth: 1.4, dash: [3, 3])).frame(width: size + 8, height: size + 8) }
        }
        .frame(width: size + 10, height: size + 10)
        .overlay(alignment: .top) {
            if labelled {
                Text(isHost ? "This Mac" : n.name.count > 17 ? String(n.name.prefix(16)) + "…" : n.name)
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Sky.ink2).lineLimit(1).fixedSize()
                    .shadow(color: Sky.sky, radius: 2).shadow(color: Sky.sky, radius: 2)
                    .offset(y: size + 8)
                    .allowsHitTesting(false)
            }
        }
        if n.ghost {
            dot.position(x: n.x * scale, y: n.y * scale).opacity(dim ? 0.3 : 1)
                .accessibilityElement()
                .accessibilityLabel("\(n.name), an address that is not a device on your networks, probing this Mac")
        } else {
            Button { selected = isSel ? nil : n.id } label: { dot }.buttonStyle(.plain)
                .position(x: n.x * scale, y: n.y * scale).opacity(dim ? 0.3 : 1)
                .accessibilityLabel("\(n.name), \(zone.guest ? "guest Wi-Fi" : "main Wi-Fi")\(zone.open ? ", no password" : "")\(hot ? ", probing this Mac" : "")\(isHost ? ", this Mac" : "")")
                .accessibilityAddTraits(isSel ? .isSelected : [])
                .accessibilityHint("Shows what it can reach")
        }
    }

    private var keys: some View {
        FlowLayout(spacing: 18, lineSpacing: 6) {
            key(Path { $0.move(to: CGPoint(x: 1, y: 9)); $0.addLine(to: CGPoint(x: 21, y: 9)) },
                StrokeStyle(lineWidth: 1.8, lineCap: .round), Sky.reach, "Can reach it")
            key(Path { $0.move(to: CGPoint(x: 1, y: 9)); $0.addLine(to: CGPoint(x: 21, y: 9)) },
                StrokeStyle(lineWidth: 3, lineCap: .round), Sky.ink2, "Wall: can’t cross")
            key(Path { $0.move(to: CGPoint(x: 1, y: 9)); $0.addLine(to: CGPoint(x: 21, y: 9)) },
                StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4]), Sky.crit, "Contact attempt")
            key(Path(ellipseIn: CGRect(x: 2, y: 1, width: 16, height: 16)),
                StrokeStyle(lineWidth: 1.2, dash: [2, 3]), Sky.ink2, "Its own private room")
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Sky.line).frame(height: 1) }
    }

    private func key(_ path: Path, _ style: StrokeStyle, _ color: Color, _ text: String) -> some View {
        HStack(spacing: 7) {
            path.stroke(color, style: style).frame(width: 22, height: 18)
            Text(text).font(.caption).foregroundStyle(Sky.ink3)
        }
    }
}

// MARK: - what never moves

private func wedge(_ a0: Double, _ a1: Double, _ r0: Double, _ r1: Double) -> Path {
    var p = Path()
    let steps = max(2, Int((a1 - a0) / 3))
    for i in 0...steps {
        let pt = SecLayout.polar(a0 + (a1 - a0) * Double(i) / Double(steps), r1)
        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    for i in stride(from: steps, through: 0, by: -1) { p.addLine(to: SecLayout.polar(a0 + (a1 - a0) * Double(i) / Double(steps), r0)) }
    p.closeSubpath()
    return p
}

private struct SecBackdrop: View, Equatable {
    let layout: SecLayout
    let side: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: side / 600, y: side / 600)
            for s in OrbitDrawing.stars { ctx.fill(OrbitDrawing.circle(s.x, s.y, s.r), with: .color(Sky.ink.opacity(s.opacity))) }
            for z in layout.zones { drawZone(&ctx, z) }
            for a in layout.walls {
                var line = Path()
                line.move(to: SecLayout.polar(a, 46))
                line.addLine(to: SecLayout.polar(a, 268))
                ctx.stroke(line, with: .color(Sky.ink2.opacity(0.75)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                let at = SecLayout.polar(a, 100)
                let badge = OrbitDrawing.circle(at.x, at.y, 12)
                ctx.fill(badge, with: .color(Sky.sky3))
                ctx.stroke(badge, with: .color(Sky.ink2), lineWidth: 1.2)
                if let icon = ctx.resolveSymbol(id: "shield") { ctx.draw(icon, at: at) }
            }
            for (zi, z) in layout.zones.enumerated() where z.enabled {
                let mine = layout.nodes.filter { $0.zone == zi && !$0.ghost }
                if mine.count > 1, !z.walledIn {  // devices that can reach each other, joined by a dotted line
                    var mesh = Path()
                    for (i, n) in mine.sorted(by: { $0.angle < $1.angle }).enumerated() {
                        if i == 0 { mesh.move(to: CGPoint(x: n.x, y: n.y)) } else { mesh.addLine(to: CGPoint(x: n.x, y: n.y)) }
                    }
                    ctx.stroke(mesh, with: .color((z.guest ? Sky.crit : Sky.reach).opacity(0.4)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 5]))
                }
                if z.walledIn {
                    for n in mine {
                        ctx.stroke(OrbitDrawing.circle(n.x, n.y, 21), with: .color(Sky.line2), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
                    }
                }
            }
            let body = OrbitDrawing.circle(300, 300, 30)
            ctx.fill(body, with: .color(Sky.sky3))
            ctx.stroke(body, with: .color(Sky.accent), lineWidth: 1.5)
            if let icon = ctx.resolveSymbol(id: OrbitDrawing.router) { ctx.draw(icon, at: CGPoint(x: 300, y: 300)) }
            ctx.draw(OrbitDrawing.label("ROUTER", size: 10, weight: .bold, color: Sky.ink2, tracking: 1.1), at: CGPoint(x: 300, y: 346))
        } symbols: {
            Image(systemName: OrbitDrawing.router).font(.system(size: 21, weight: .medium)).foregroundStyle(Sky.ink).tag(OrbitDrawing.router)
            Image(systemName: "checkmark.shield").font(.system(size: 12, weight: .semibold)).foregroundStyle(Sky.ink).tag("shield")
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }

    private func drawZone(_ ctx: inout GraphicsContext, _ z: SecZone) {
        let tint = z.danger ? Sky.crit : z.guest ? Sky.ink : Sky.accent
        let dim = z.enabled ? 1.0 : 0.45
        let fill = (z.guest && z.isolated == false ? 0.16 : z.danger ? 0.07 : z.guest ? 0.035 : 0.07) * dim
        let stroke = (z.danger ? 0.55 : z.guest ? 0.3 : 0.4) * dim
        let shape = wedge(z.a0 + 1.5, z.a1 - 1.5, 46, 266)
        ctx.fill(shape, with: .color(tint.opacity(fill)))
        ctx.stroke(shape, with: .color(tint.opacity(stroke)), style: StrokeStyle(lineWidth: 1.2, dash: z.danger || !z.enabled ? [5, 4] : []))

        let name = (z.name.count > 22 ? String(z.name.prefix(21)) + "…" : z.name) + (z.open ? " · No password" : "") + (z.enabled ? "" : " · Off")
        let sub = !z.enabled ? "Switched off right now"
            : z.guest ? (z.isolated == false ? "Isolation off: guests can reach each other" : "Each guest in their own room")
            : "One big room: everything can reach everything"
        let at = SecLayout.polar(z.mid, 282)
        let ink = z.danger ? Sky.critInk : z.guest ? Sky.ink2 : Sky.accent
        ctx.draw(OrbitDrawing.label(name.uppercased(), size: 9.5, weight: .bold, color: ink.opacity(z.enabled ? 1 : 0.6), tracking: 0.9), at: CGPoint(x: at.x, y: at.y - 6))
        ctx.draw(OrbitDrawing.label(sub, size: 9.5, weight: .medium, color: Sky.ink3), at: CGPoint(x: at.x, y: at.y + 6))
    }
}

/// Green lines from the chosen device to everything it can reach.
private struct SecReach: View, Equatable {
    let layout: SecLayout
    let selected: String?
    let side: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            guard let s = selected.flatMap({ layout.node($0) }) else { return }
            ctx.scaleBy(x: side / 600, y: side / 600)
            for n in layout.nodes where layout.canReach(s, n) {
                var line = Path()
                line.move(to: CGPoint(x: s.x, y: s.y))
                line.addLine(to: CGPoint(x: n.x, y: n.y))
                ctx.stroke(line, with: .color(Sky.reach.opacity(0.85)), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - what moves

/// The red dashed arcs of contact attempts. Core Animation moves the dashes, so the app does no drawing per frame.
private struct SecArcs: NSViewRepresentable {
    let arcs: [SecArc]
    let side: CGFloat
    let motion: Bool

    func makeNSView(context: Context) -> SecArcView { SecArcView() }
    func updateNSView(_ view: SecArcView, context: Context) { view.update(arcs, side: side, motion: motion) }
}

final class SecArcView: NSView {
    private let root = CALayer()
    private var shown: [SecArc] = []
    private var motion: Bool?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        root.anchorPoint = .zero
        root.bounds = CGRect(x: 0, y: 0, width: 600, height: 600)
        layer?.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError("Not made from a coder") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ arcs: [SecArc], side: CGFloat, motion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.transform = CATransform3DMakeScale(side / 600, side / 600, 1)
        guard arcs != shown || motion != self.motion else { return }
        shown = arcs
        self.motion = motion
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        for arc in arcs {
            let up = { (p: CGPoint) in CGPoint(x: p.x, y: 600 - p.y) }  // Core Animation's y goes up
            let path = CGMutablePath()
            path.move(to: up(arc.from))
            path.addQuadCurve(to: up(arc.to), control: up(arc.control))
            let l = CAShapeLayer()
            l.path = path
            l.fillColor = nil
            l.strokeColor = NSColor(arc.known ? Sky.accent : Sky.crit).cgColor
            l.lineWidth = arc.known ? 1.6 : 2.2
            l.lineCap = .round
            l.lineDashPattern = arc.known ? [1, 6] : [5, 6]
            if motion && !arc.known {
                let flow = CABasicAnimation(keyPath: "lineDashPhase")
                flow.fromValue = 11
                flow.toValue = 0
                flow.duration = 0.9
                flow.repeatCount = .infinity
                l.add(flow, forKey: "flow")
            }
            root.addSublayer(l)
        }
    }
}
