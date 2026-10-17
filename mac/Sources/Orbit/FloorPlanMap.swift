import AppKit
import SwiftUI

/// The Floor plan page's map: your walls, room names, the router and the devices that have a spot on the plan.
/// What never moves while you work (the grid, room names, coverage squares and walls) is drawn once in an
/// Equatable Canvas. The router and devices are small SwiftUI views you can drag; while one is dragged only its
/// own position changes, and it is saved when you let go. Nothing on this page animates, so it costs next to
/// nothing at rest and Reduce Motion has nothing to turn off.

// MARK: - how things look

extension PlanMaterial {
    var color: Color {
        switch self {
        case .drywall: return Sky.ink2
        case .glass: return Sky.accent
        case .brick: return Color(hex: 0xD9915C)
        case .concrete: return Color(hex: 0xE5675F)
        case .metal: return Color(hex: 0xF0C24D)
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .drywall, .glass: return 3
        case .brick: return 5
        case .concrete: return 6
        case .metal: return 4
        }
    }

    var dash: [CGFloat] {
        switch self {
        case .glass: return [6, 4]
        case .metal: return [2, 3]
        default: return []
        }
    }

    var stroke: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: dash) }
}

extension PlanVerdict {
    /// On the night-sky map.
    var ink: Color {
        switch self {
        case .stronger: return Sky.accent
        case .matches: return Sky.reach
        case .little: return Sky.warn
        case .much: return Sky.crit
        }
    }

    /// On the ordinary cards.
    var tint: Color {
        switch self {
        case .stronger: return .orbitAccent
        case .matches: return .green
        case .little: return .orange
        case .much: return .red
        }
    }
}

/// Where a click or a drag lands: on a grid, and inside the plan.
enum PlanSnap {
    static func clean(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    static func point(_ p: PlanPoint, step: Double, w: Double, h: Double) -> PlanPoint {
        func one(_ v: Double, _ limit: Double) -> Double { clean((min(max(v, 0.2), limit - 0.2) / step).rounded() * step) }
        return PlanPoint(x: one(p.x, w), y: one(p.y, h))
    }
}

/// How big a room name looks on the plan (for clicking it).
enum PlanLabel {
    static func size(_ name: String) -> CGSize { CGSize(width: CGFloat(name.count) * 8.4 + 14, height: 22) }
}

// MARK: - coverage, worked out only when the plan, the tuning or the band changes

final class PlanCoverageCache {
    private struct Key: Equatable {
        var w: Double, h: Double
        var router: PlanPoint
        var walls: [PlanWall]
        var band: String
        var offset: Double
    }

    private var key: Key?
    private var value = PlanCoverage()

    func get(_ plan: FloorPlan, band: String, offset: Double) -> PlanCoverage {
        let k = Key(w: plan.w, h: plan.h, router: plan.router, walls: plan.walls, band: band, offset: offset)
        if k != key {
            key = k
            value = PlanCoverage.make(plan, band: band, offset: offset)
        }
        return value
    }
}

// MARK: - the map

struct FloorPlanMap: View {
    var editor: PlanEditor
    var plan: FloorPlan
    var analysis: PlanAnalysis
    var state: OrbitState

    private enum Target: Hashable {
        case router, device(String)
        var pick: PlanEditor.Pick { if case .device(let id) = self { return .device(id) } else { return .router } }
    }

    private struct Drag {
        var target: Target
        var pos: PlanPoint
        var grab: CGSize  // from where it was grabbed to its middle, so it doesn't jump
        var moved = false
    }

    @State private var drag: Drag?
    @State private var coverage = PlanCoverageCache()
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            GeometryReader { geo in
                stage(ps: geo.size.width / plan.w)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .aspectRatio(plan.w / plan.h, contentMode: .fit)
            .frame(maxWidth: 800 * plan.w / plan.h)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 18)  // room for the scale under the plan
            bar
            keys
        }
        .padding(16)
        .background(RadialGradient(colors: [Sky.sky2, Sky.sky], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 700),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Sky.line))
        .environment(\.colorScheme, .dark)  // a night sky in both themes
    }

    // MARK: header, tools and keys

    private var hint: String {
        switch editor.mode {
        case .wall: return editor.wallStart == nil ? "Tap where the wall starts." : "Tap where the wall ends."
        case .room: return "Tap where the room’s name should go."
        case .place: return "Tap the plan to place it."
        case .none: return "Drag the router or a device to move it. Tap one to see its signal."
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Your home").font(.headline).foregroundStyle(Sky.ink)
                Text(hint).font(.caption).foregroundStyle(Sky.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if editor.layer == .coverage {
                    Picker("Wi-Fi band", selection: Binding(get: { editor.band }, set: { editor.band = $0 })) {
                        Text("2.4 GHz").tag("2.4")
                        Text("5 GHz").tag("5")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 140)
                }
                Picker("What to show", selection: Binding(get: { editor.layer }, set: { editor.layer = $0 })) {
                    Text("Devices").tag(PlanEditor.Layer.devices)
                    Text("Coverage").tag(PlanEditor.Layer.coverage)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
        }
    }

    private var bar: some View {
        FlowLayout(spacing: 10, lineSpacing: 8) {
            Button { editor.toggle(.wall) } label: { Label(editor.mode == .wall ? "Cancel" : "Add a wall", systemImage: "pencil.line") }
                .buttonStyle(PlanButtonStyle(active: editor.mode == .wall))
            Button { editor.toggle(.room) } label: { Label(editor.mode == .room ? "Cancel" : "Add a room name", systemImage: "textformat") }
                .buttonStyle(PlanButtonStyle(active: editor.mode == .room))
            HStack(spacing: 10) {
                Text("House size").font(.caption.weight(.semibold)).foregroundStyle(Sky.ink2)
                sizeStepper("\(Self.metres(plan.w)) m wide", Binding(get: { plan.w }, set: { editor.resize(w: $0, h: plan.h) }))
                sizeStepper("\(Self.metres(plan.h)) m deep", Binding(get: { plan.h }, set: { editor.resize(w: plan.w, h: $0) }))
            }
        }
    }

    private func sizeStepper(_ text: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.caption).foregroundStyle(Sky.ink).monospacedDigit().fixedSize()
            Stepper(text, value: value, in: FloorPlan.sizeRange, step: 1).labelsHidden().controlSize(.small)
        }
    }

    static func metres(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    private var keys: some View {
        FlowLayout(spacing: 18, lineSpacing: 6) {
            if editor.layer == .coverage {
                swatch(Sky.reach, "Strong")
                swatch(Sky.warn, "Fair")
                swatch(Sky.crit, "Weak")
                Text(coverageNote).font(.caption).foregroundStyle(Sky.ink3)
            } else {
                ForEach(PlanMaterial.allCases) { m in
                    HStack(spacing: 7) {
                        Path { $0.move(to: CGPoint(x: 1, y: 9)); $0.addLine(to: CGPoint(x: 21, y: 9)) }
                            .stroke(m.color, style: m.stroke).frame(width: 22, height: 18)
                        Text(m.name).font(.caption).foregroundStyle(Sky.ink3)
                    }
                }
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Rectangle().fill(Sky.line).frame(height: 1) }
    }

    private var coverageNote: String {
        let base = plan.walls.isEmpty ? "Predicted signal, from distance only (no walls are drawn)" : "Predicted signal, from the walls you drew"
        return analysis.tuned ? base : base + ". Not tuned yet: place at least 3 devices"
    }

    private func swatch(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.7)).frame(width: 14, height: 10)
            Text(text).font(.caption).foregroundStyle(Sky.ink3)
        }
    }

    // MARK: the stage

    private func position(_ target: Target) -> PlanPoint {
        if let d = drag, d.target == target { return d.pos }
        switch target {
        case .router: return plan.router
        case .device(let id): return analysis.reading(id)?.pos ?? plan.router
        }
    }

    private func stage(ps: CGFloat) -> some View {
        let w = plan.w, h = plan.h
        let picked = editor.pick
        let pickedWall: PlanWall? = { if case .wall(let id)? = picked { return plan.walls.first { $0.id == id } } else { return nil } }()
        let pickedRoom: PlanRoom? = { if case .room(let id)? = picked { return plan.rooms.first { $0.id == id } } else { return nil } }()
        let reading: PlanReading? = { if case .device(let id)? = picked { return analysis.reading(id) } else { return nil } }()
        var link: PlanLink?
        var hot: [PlanWall] = []
        if let r = reading {  // from the router to the picked device, and the walls in the way (live while dragging)
            let at = position(.device(r.id)), from = position(.router)
            link = PlanLink(from: from, to: at, tone: r.verdict)
            hot = PlanMath.crossed(plan.walls, from: from, to: at)
        }
        let cells: PlanCoverage? = editor.layer == .coverage ? coverage.get(plan, band: editor.band, offset: analysis.offset) : nil
        let interactive = editor.mode == .none
        return ZStack(alignment: .topLeading) {
            PlanBackdrop(ps: ps, w: w, h: h, walls: plan.walls, rooms: plan.rooms, coverage: cells).equatable()
            PlanOverlay(ps: ps, w: w, h: h, hot: hot, picked: pickedWall, link: link,
                        wallStart: editor.wallStart, roomSpot: editor.roomSpot, pickedRoom: pickedRoom).equatable()
            PlanTapLayer(ps: ps, w: w, h: h, mode: editor.mode, wallStart: editor.wallStart) { tap($0, ps: ps) }
            ForEach(analysis.readings) { r in
                if let d = state.device(r.id) { deviceNode(r, d, ps: ps).allowsHitTesting(interactive) }
            }
            routerNode(ps: ps).allowsHitTesting(interactive)
            wallsForVoiceOver(ps: ps)
        }
        .frame(width: w * ps, height: h * ps, alignment: .topLeading)
        .coordinateSpace(name: "plan")
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { key($0) }
        .onDeleteCommand { removePicked() }  // the Backspace key arrives as this command
        .overlay(alignment: .bottomLeading) { scale(ps: ps) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floor plan with walls, the router and devices")
    }

    /// One metre, as long as it is drawn, under the bottom left corner of the plan.
    private func scale(ps: CGFloat) -> some View {
        HStack(spacing: 6) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 3)); p.addLine(to: CGPoint(x: 0, y: 9))
                p.move(to: CGPoint(x: 0, y: 6)); p.addLine(to: CGPoint(x: ps, y: 6))
                p.move(to: CGPoint(x: ps, y: 3)); p.addLine(to: CGPoint(x: ps, y: 9))
            }
            .stroke(Sky.ink2, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: ps, height: 12)
            Text("1 m").font(.caption2).foregroundStyle(Sky.ink2)
        }
        .offset(y: 17)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: nodes

    private func deviceNode(_ r: PlanReading, _ d: Device, ps: CGFloat) -> some View {
        let p = position(.device(r.id))
        let sel = editor.pick == .device(r.id)
        let weak = r.verdict != nil && r.gap < -5
        let tint = weak ? (r.verdict == .much ? Sky.crit : Sky.warn) : Sky.accent
        let name = d.name.count > 17 ? String(d.name.prefix(16)) + "…" : d.name
        var label = "\(d.name), \(d.bandLabel) Wi-Fi, measures \(PlanMath.dBm(r.measured)) dBm"
        if let v = r.verdict { label += ", \(v.word)" }
        return ZStack {
            if weak { Circle().strokeBorder(tint.opacity(0.5), lineWidth: 1.5).frame(width: 38, height: 38) }  // a still ring, not a pulse
            Circle().fill(sel ? Sky.sky3 : Sky.sky2).frame(width: 28, height: 28)
            Circle().strokeBorder(tint, lineWidth: sel ? 3.2 : 2).frame(width: 28, height: 28)
            Image(systemName: Icons.device(d.type)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Sky.ink)
        }
        .frame(width: 44, height: 44)
        .overlay(alignment: .top) {
            if sel || weak {
                Text(name + (weak ? " " + PlanMath.dB(r.gap) : ""))
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Sky.ink2).lineLimit(1).fixedSize()
                    .shadow(color: Sky.sky, radius: 2).shadow(color: Sky.sky, radius: 2)
                    .offset(y: 38)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Circle())
        .gesture(nodeDrag(.device(r.id), ps: ps))
        .simultaneousGesture(TapGesture().onEnded { focused = true; editor.select(.device(r.id)) })  // a plain click
        .help(d.name)
        .position(x: p.x * ps, y: p.y * ps)
        .zIndex(sel ? 2 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint("Drag to move it, or use the move actions")
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.select(.device(r.id)) }
        .accessibilityAction(named: "Move left 10 centimetres") { editor.nudge(.device(r.id), dx: -0.1, dy: 0) }
        .accessibilityAction(named: "Move right 10 centimetres") { editor.nudge(.device(r.id), dx: 0.1, dy: 0) }
        .accessibilityAction(named: "Move up 10 centimetres") { editor.nudge(.device(r.id), dx: 0, dy: -0.1) }
        .accessibilityAction(named: "Move down 10 centimetres") { editor.nudge(.device(r.id), dx: 0, dy: 0.1) }
    }

    private func routerNode(ps: CGFloat) -> some View {
        let p = position(.router)
        let sel = editor.pick == .router
        return ZStack {
            Circle().strokeBorder(Sky.accent.opacity(0.35), lineWidth: 1.2).frame(width: 46, height: 46)  // a still ring, not a pulse
            Circle().fill(sel ? Sky.sky3 : Sky.sky2).frame(width: 36, height: 36)
            Circle().strokeBorder(Sky.accent, lineWidth: sel ? 3 : 1.6).frame(width: 36, height: 36)
            Image(systemName: OrbitDrawing.router).font(.system(size: 16, weight: .medium)).foregroundStyle(Sky.ink)
        }
        .frame(width: 50, height: 50)
        .contentShape(Circle())
        .gesture(nodeDrag(.router, ps: ps))
        .simultaneousGesture(TapGesture().onEnded { focused = true; editor.select(.router) })
        .help("Your router")
        .position(x: p.x * ps, y: p.y * ps)
        .zIndex(sel ? 2 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Router")
        .accessibilityHint("Drag to move it, or use the move actions")
        .accessibilityAddTraits(sel ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { editor.select(.router) }
        .accessibilityAction(named: "Move left 10 centimetres") { editor.nudge(.router, dx: -0.1, dy: 0) }
        .accessibilityAction(named: "Move right 10 centimetres") { editor.nudge(.router, dx: 0.1, dy: 0) }
        .accessibilityAction(named: "Move up 10 centimetres") { editor.nudge(.router, dx: 0, dy: -0.1) }
        .accessibilityAction(named: "Move down 10 centimetres") { editor.nudge(.router, dx: 0, dy: 0.1) }
    }

    /// Press, drag, let go. While it is held only this view moves (a local position); the plan changes once, on release.
    private func nodeDrag(_ target: Target, ps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("plan"))
            .onChanged { v in
                if drag == nil {
                    editor.dragging = true
                    focused = true
                    editor.select(target.pick)
                    let at = position(target)
                    drag = Drag(target: target, pos: at,
                                grab: CGSize(width: at.x * ps - v.startLocation.x, height: at.y * ps - v.startLocation.y))
                }
                guard var d = drag, d.target == target else { return }
                if !d.moved && hypot(v.translation.width, v.translation.height) < 3 { return }  // a click is not a move
                d.moved = true
                let to = PlanSnap.point(PlanPoint(x: (v.location.x + d.grab.width) / ps, y: (v.location.y + d.grab.height) / ps),
                                        step: 0.1, w: plan.w, h: plan.h)
                if to != d.pos || !(drag?.moved ?? false) {
                    d.pos = to
                    drag = d
                }
            }
            .onEnded { _ in
                if let d = drag, d.moved {
                    switch d.target {
                    case .router: editor.moveRouter(to: d.pos)
                    case .device(let id): editor.moveDevice(id, to: d.pos)
                    }
                }
                drag = nil
                editor.dragging = false
                editor.syncIfNeeded()
            }
    }

    // MARK: clicking the plan itself

    private func tap(_ pt: CGPoint, ps: CGFloat) {
        focused = true
        let at = PlanPoint(x: Double(pt.x / ps), y: Double(pt.y / ps))
        switch editor.mode {
        case .place(let id): editor.place(id, at: PlanSnap.point(at, step: 0.1, w: plan.w, h: plan.h))
        case .wall: editor.wallTap(PlanSnap.point(at, step: 0.25, w: plan.w, h: plan.h))
        case .room: editor.roomTap(PlanSnap.point(at, step: 0.1, w: plan.w, h: plan.h))
        case .none:
            if let wall = nearestWall(to: pt, ps: ps) {
                editor.select(.wall(wall.id))
            } else if let room = plan.rooms.first(where: { r in
                let s = PlanLabel.size(r.name)
                return abs(pt.x - r.x * ps) <= s.width / 2 && abs(pt.y - r.y * ps) <= s.height / 2
            }) {
                editor.select(.room(room.id))
            } else {
                editor.select(nil)
            }
        }
    }

    /// The wall closest to a point of the stage, if one is within easy reach of the pointer.
    private func nearestWall(to pt: CGPoint, ps: CGFloat) -> PlanWall? {
        func distance(_ w: PlanWall) -> CGFloat {
            let a = CGPoint(x: w.a.x * ps, y: w.a.y * ps), b = CGPoint(x: w.b.x * ps, y: w.b.y * ps)
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t = len2 == 0 ? 0 : min(1, max(0, ((pt.x - a.x) * dx + (pt.y - a.y) * dy) / len2))
            return hypot(pt.x - (a.x + t * dx), pt.y - (a.y + t * dy))
        }
        return plan.walls.map { ($0, distance($0)) }.filter { $0.1 <= 9 }.min { $0.1 < $1.1 }?.0
    }

    // MARK: keyboard

    private func key(_ press: KeyPress) -> KeyPress.Result {
        func nudge(_ dx: Double, _ dy: Double) -> KeyPress.Result {
            switch editor.pick {
            case .router?, .device?: editor.nudge(editor.pick!, dx: dx, dy: dy); return .handled
            default: return .ignored
            }
        }
        switch press.key {
        case .leftArrow: return nudge(-0.1, 0)
        case .rightArrow: return nudge(0.1, 0)
        case .upArrow: return nudge(0, -0.1)
        case .downArrow: return nudge(0, 0.1)
        // The Mac's Delete key sends U+007F, which SwiftUI doesn't name as `.delete` (that is U+0008).
        case .delete, .deleteForward, KeyEquivalent("\u{7F}"): return removePicked() ? .handled : .ignored
        case .escape: return editor.cancel() ? .handled : .ignored
        default: return .ignored
        }
    }

    /// Delete or Backspace: remove the picked wall or room name. (Devices and the router stay; they can only be moved.)
    @discardableResult
    private func removePicked() -> Bool {
        switch editor.pick {
        case .wall(let id)?: editor.removeWall(id); return true
        case .room(let id)?: editor.removeRoom(id); return true
        default: return false
        }
    }

    /// For VoiceOver: the walls and room names are drawn, so they need a spoken stand-in.
    private func wallsForVoiceOver(ps: CGFloat) -> some View {
        Color.clear
            .frame(width: plan.w * ps, height: plan.h * ps)
            .allowsHitTesting(false)
            .accessibilityChildren {
                ForEach(plan.walls) { w in
                    Text("\(w.material.name) wall")
                        .accessibilityLabel("\(w.material.name) wall, \(String(format: "%.1f", w.length)) metres long")
                        .accessibilityHint("Shows what it is made of")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { editor.select(.wall(w.id)) }
                }
                ForEach(plan.rooms) { r in
                    Text(r.name)
                        .accessibilityLabel("Room name, \(r.name)")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { editor.select(.room(r.id)) }
                }
            }
    }
}

// MARK: - what never moves

private struct PlanBackdrop: View, Equatable {
    let ps: CGFloat
    let w: Double
    let h: Double
    let walls: [PlanWall]
    let rooms: [PlanRoom]
    let coverage: PlanCoverage?

    static func == (a: PlanBackdrop, b: PlanBackdrop) -> Bool {
        a.ps == b.ps && a.w == b.w && a.h == b.h && a.walls == b.walls && a.rooms == b.rooms && a.coverage == b.coverage
    }

    var body: some View {
        Canvas { ctx, _ in
            let (W, H) = (CGFloat(w) * ps, CGFloat(h) * ps)
            ctx.fill(Path(CGRect(x: 0, y: 0, width: W, height: H)), with: .color(Sky.ink.opacity(0.03)))
            for s in OrbitDrawing.stars.prefix(50) {  // the same stars as the other maps, held still
                ctx.fill(OrbitDrawing.circle(s.x / 600 * W, s.y / 600 * H, s.r), with: .color(Sky.ink.opacity(s.opacity * 0.8)))
            }
            var grid = Path()
            for i in 0...Int(w.rounded(.down)) { grid.move(to: CGPoint(x: CGFloat(i) * ps, y: 0)); grid.addLine(to: CGPoint(x: CGFloat(i) * ps, y: H)) }
            for j in 0...Int(h.rounded(.down)) { grid.move(to: CGPoint(x: 0, y: CGFloat(j) * ps)); grid.addLine(to: CGPoint(x: W, y: CGFloat(j) * ps)) }
            ctx.stroke(grid, with: .color(Sky.line), lineWidth: 1)

            if let cov = coverage { drawCoverage(&ctx, cov) }

            for r in rooms {
                ctx.draw(OrbitDrawing.label(r.name.uppercased(), size: 10.5, weight: .semibold, color: Sky.ink3, tracking: 1.2),
                         at: CGPoint(x: r.x * ps, y: r.y * ps))
            }
            for wall in walls {
                var line = Path()
                line.move(to: CGPoint(x: wall.a.x * ps, y: wall.a.y * ps))
                line.addLine(to: CGPoint(x: wall.b.x * ps, y: wall.b.y * ps))
                ctx.stroke(line, with: .color(wall.material.color), style: wall.material.stroke)
            }
        }
        .frame(width: CGFloat(w) * ps, height: CGFloat(h) * ps)
        .accessibilityHidden(true)
    }

    /// One filled shape for each level, with squares in a row joined up, so thousands of squares are four fills.
    private func drawCoverage(_ ctx: inout GraphicsContext, _ cov: PlanCoverage) {
        let cell = CGFloat(PlanCoverage.cell) * ps
        let look: [(Color, Double)] = [(Sky.crit, 0.34), (Sky.warn, 0.30), (Sky.reach, 0.20), (Sky.reach, 0.34)]
        for level in 0..<4 {
            var path = Path()
            for j in 0..<cov.rows {
                var i = 0
                while i < cov.cols {
                    guard cov.levels[j * cov.cols + i] == UInt8(level) else { i += 1; continue }
                    var end = i
                    while end < cov.cols && cov.levels[j * cov.cols + end] == UInt8(level) { end += 1 }
                    path.addRect(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: CGFloat(end - i) * cell, height: cell))
                    i = end
                }
            }
            ctx.fill(path, with: .color(look[level].0.opacity(look[level].1)))
        }
    }
}

struct PlanLink: Equatable {
    var from: PlanPoint
    var to: PlanPoint
    var tone: PlanVerdict?
}

/// What changes with a click: the picked wall or name, the line from the router to the picked device, the walls in its way.
private struct PlanOverlay: View, Equatable {
    let ps: CGFloat
    let w: Double
    let h: Double
    let hot: [PlanWall]
    let picked: PlanWall?
    let link: PlanLink?
    let wallStart: PlanPoint?
    let roomSpot: PlanPoint?
    let pickedRoom: PlanRoom?

    var body: some View {
        Canvas { ctx, _ in
            func pt(_ p: PlanPoint) -> CGPoint { CGPoint(x: p.x * ps, y: p.y * ps) }
            func line(_ a: PlanPoint, _ b: PlanPoint) -> Path {
                var p = Path()
                p.move(to: pt(a))
                p.addLine(to: pt(b))
                return p
            }
            for wall in hot {
                ctx.stroke(line(wall.a, wall.b), with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
            }
            if let wall = picked {
                ctx.stroke(line(wall.a, wall.b), with: .color(Sky.ink.opacity(0.22)), style: StrokeStyle(lineWidth: 11, lineCap: .round))
            }
            if let l = link {
                ctx.stroke(line(l.from, l.to), with: .color(l.tone?.ink ?? Sky.accent), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [3, 5]))
            }
            if let a = wallStart {
                ctx.fill(OrbitDrawing.circle(a.x * ps, a.y * ps, 4), with: .color(Sky.accent))
            }
            if let s = roomSpot {
                let c = pt(s)
                ctx.stroke(OrbitDrawing.circle(c.x, c.y, 9), with: .color(Sky.accent), style: StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
                ctx.fill(OrbitDrawing.circle(c.x, c.y, 2.5), with: .color(Sky.accent))
            }
            if let r = pickedRoom {
                let s = PlanLabel.size(r.name)
                let box = CGRect(x: r.x * ps - s.width / 2, y: r.y * ps - s.height / 2, width: s.width, height: s.height)
                ctx.stroke(Path(roundedRect: box, cornerRadius: 6), with: .color(Sky.ink), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
            }
        }
        .frame(width: CGFloat(w) * ps, height: CGFloat(h) * ps)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Catches clicks on the empty plan, and while you draw a wall or place something, shows where it would land.
private struct PlanTapLayer: View {
    let ps: CGFloat
    let w: Double
    let h: Double
    let mode: PlanEditor.Mode
    let wallStart: PlanPoint?
    let onTap: (CGPoint) -> Void
    @State private var hover: CGPoint?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { onTap($0) }
            .onContinuousHover(coordinateSpace: .local) { phase in
                guard mode != .none else { if hover != nil { hover = nil }; return }
                switch phase {
                case .active(let p):
                    NSCursor.crosshair.set()
                    hover = p
                case .ended:
                    NSCursor.arrow.set()
                    hover = nil
                }
            }
            .overlay { preview }
            .frame(width: CGFloat(w) * ps, height: CGFloat(h) * ps)
            .accessibilityHidden(true)
    }

    private var preview: some View {
        Canvas { ctx, _ in
            guard mode != .none, let at = hover else { return }
            let raw = PlanPoint(x: Double(at.x / ps), y: Double(at.y / ps))
            switch mode {
            case .wall:
                let q = PlanSnap.point(raw, step: 0.25, w: w, h: h)
                let c = CGPoint(x: q.x * ps, y: q.y * ps)
                if let a = wallStart {
                    var line = Path()
                    line.move(to: CGPoint(x: a.x * ps, y: a.y * ps))
                    line.addLine(to: c)
                    ctx.stroke(line, with: .color(Sky.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [5, 5]))
                }
                ctx.fill(OrbitDrawing.circle(c.x, c.y, 3.5), with: .color(Sky.accent))
            case .place:
                let q = PlanSnap.point(raw, step: 0.1, w: w, h: h)
                ctx.stroke(OrbitDrawing.circle(q.x * ps, q.y * ps, 14), with: .color(Sky.accent), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
            case .room:
                let q = PlanSnap.point(raw, step: 0.1, w: w, h: h)
                ctx.stroke(OrbitDrawing.circle(q.x * ps, q.y * ps, 9), with: .color(Sky.accent), style: StrokeStyle(lineWidth: 1.6, dash: [3, 3]))
            case .none: break
            }
        }
        .allowsHitTesting(false)
    }
}

/// A button for the map's tools, on the night sky.
struct PlanButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(active ? Color.white : Sky.ink)
            .background(active ? Color.orbitAccent : Sky.ink2.opacity(configuration.isPressed ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Sky.line2))
    }
}
