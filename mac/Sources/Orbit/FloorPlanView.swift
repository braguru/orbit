import SwiftUI

/// Everything about the plan being edited: the drawing, what is picked, what the tools are doing, and keeping it
/// saved on the server. It saves a moment after you stop editing, and when you leave the page, but never before the
/// plan has been fetched once (a blank plan must not overwrite a saved one). When another window saves, it fetches again.
@MainActor @Observable
final class PlanEditor {
    enum Mode: Equatable { case none, wall, room, place(String) }
    enum Pick: Equatable { case router, device(String), wall(String), room(String) }
    enum Layer: Equatable { case devices, coverage }
    enum Status { case saved, saving, failed }

    private(set) var plan: FloorPlan?   // nil until one is drawn
    private(set) var loaded = false
    private(set) var loadError: String?
    private(set) var status = Status.saved
    private(set) var pick: Pick?
    private(set) var mode = Mode.none
    private(set) var wallStart: PlanPoint?  // the first end of a wall being drawn
    private(set) var roomSpot: PlanPoint?   // where a new room name will go, until it has its name
    var layer = Layer.devices
    var band = "5"

    @ObservationIgnored var dragging = false
    @ObservationIgnored private weak var store: OrbitStore?
    @ObservationIgnored private var rev = 0                 // the revision last loaded or saved here
    @ObservationIgnored private var seen: [Int] = []        // revisions this window has held, so a late echo isn't news
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var debounce: Task<Void, Never>?

    func attach(_ store: OrbitStore) { self.store = store }

    // MARK: loading and saving

    func load() async {
        guard let store, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let reply = try await store.fetchPlan()
            guard !dragging, !dirty, !saving else { return }  // something here changed meanwhile: it wins, and is saved next
            adopt(reply.plan, rev: reply.rev)
            loaded = true
            loadError = nil
        } catch {
            if !loaded { loadError = error.localizedDescription }
        }
    }

    func retry() {
        loadError = nil
        Task { await load() }
    }

    private func adopt(_ p: FloorPlan?, rev: Int) {
        plan = p
        remember(rev)
        status = .saved
        guard let p else { pick = nil; return }
        switch pick {  // what was picked may be gone
        case .wall(let id)?: if !p.walls.contains(where: { $0.id == id }) { pick = nil }
        case .room(let id)?: if !p.rooms.contains(where: { $0.id == id }) { pick = nil }
        default: break
        }
    }

    private func remember(_ r: Int) {
        rev = r
        seen.append(r)
        if seen.count > 8 { seen.removeFirst() }
    }

    /// Another window saved the plan: fetch it. Not while you are dragging or have changes still waiting to be saved.
    func syncIfNeeded() {
        guard loaded, !dragging, !dirty, !saving, !loading, let server = store?.state?.planRev, server != rev, !seen.contains(server) else { return }
        Task { await load() }
    }

    private func change(_ new: FloorPlan, force: Bool = false) {
        guard loaded, force || new != plan else { return }
        plan = new
        dirty = true
        status = .saving
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    private func edit(_ change: (inout FloorPlan) -> Void) {
        guard var p = plan else { return }
        change(&p)
        self.change(p)
    }

    /// Leaving the page: keep what is waiting right away.
    func flush() {
        debounce?.cancel()
        if dirty && status != .failed { Task { await saveNow() } }
    }

    private func saveNow() async {
        guard loaded, dirty, !saving, let plan, let store else { return }
        saving = true
        dirty = false
        status = .saving
        do {
            remember(try await store.savePlan(plan))
            status = dirty ? .saving : .saved
        } catch {
            dirty = true  // still waiting; the next change tries again
            status = .failed
            store.lastError = error.localizedDescription
        }
        saving = false
        if dirty && status != .failed { await saveNow() }  // edited while saving
    }

    // MARK: tools

    func select(_ p: Pick?) {
        pick = p
        if p != nil { roomSpot = nil }
    }

    func toggle(_ m: Mode) {
        mode = mode == m ? .none : m
        wallStart = nil
        roomSpot = nil
    }

    /// Escape: let go of the last thing started. False when there was nothing to let go of.
    func cancel() -> Bool {
        if wallStart != nil { wallStart = nil; return true }
        if mode != .none { mode = .none; return true }
        if roomSpot != nil { roomSpot = nil; return true }
        if pick != nil { pick = nil; return true }
        return false
    }

    // MARK: changes to the drawing

    func start(w: Double, h: Double, outline: Bool) {
        guard loaded, plan == nil else { return }
        var p = outline ? FloorPlan.outline(w: w, h: h) : FloorPlan()
        if !outline {
            p.w = w
            p.h = h
            p.router = PlanPoint(x: (w / 2 * 10).rounded() / 10, y: (h / 2 * 10).rounded() / 10)
        }
        change(p, force: true)
    }

    func resize(w: Double, h: Double) {
        let r = FloorPlan.sizeRange
        edit { p in
            p.w = min(max(w, r.lowerBound), r.upperBound)
            p.h = min(max(h, r.lowerBound), r.upperBound)
            p.clampInside()
        }
    }

    func moveRouter(to q: PlanPoint) { edit { $0.router = q } }
    func moveDevice(_ id: String, to q: PlanPoint) { edit { $0.devices[id] = q } }

    func nudge(_ target: Pick, dx: Double, dy: Double) {
        guard let plan else { return }
        func moved(_ p: PlanPoint) -> PlanPoint { PlanSnap.point(PlanPoint(x: p.x + dx, y: p.y + dy), step: 0.1, w: plan.w, h: plan.h) }
        switch target {
        case .router: moveRouter(to: moved(plan.router))
        case .device(let id): if let p = plan.devices[id] { moveDevice(id, to: moved(p)) }
        default: break
        }
    }

    func place(_ id: String, at q: PlanPoint) {
        edit { $0.devices[id] = q }
        pick = .device(id)
        mode = .none
    }

    func wallTap(_ q: PlanPoint) {
        guard let a = wallStart else { wallStart = q; return }
        guard hypot(q.x - a.x, q.y - a.y) >= 0.3 else { wallStart = nil; return }  // too short: start again
        let id = Self.newID("w")
        edit { $0.walls.append(PlanWall(id: id, a: a, b: q, mat: PlanMaterial.drywall.rawValue)) }
        pick = .wall(id)
        wallStart = nil
        mode = .none
    }

    func setMaterial(_ id: String, _ m: PlanMaterial) {
        edit { p in if let i = p.walls.firstIndex(where: { $0.id == id }) { p.walls[i].mat = m.rawValue } }
    }

    func removeWall(_ id: String) {
        edit { $0.walls.removeAll { $0.id == id } }
        pick = nil
    }

    func roomTap(_ q: PlanPoint) {
        roomSpot = q
        mode = .none
        pick = nil
    }

    func addRoom(_ name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard let spot = roomSpot, !name.isEmpty else { return }
        let id = Self.newID("r")
        edit { $0.rooms.append(PlanRoom(id: id, name: name, x: spot.x, y: spot.y)) }
        roomSpot = nil
        pick = .room(id)
    }

    func renameRoom(_ id: String, _ name: String) {
        let name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30))
        guard !name.isEmpty else { return }
        edit { p in if let i = p.rooms.firstIndex(where: { $0.id == id }) { p.rooms[i].name = name } }
    }

    func removeRoom(_ id: String) {
        edit { $0.rooms.removeAll { $0.id == id } }
        pick = nil
    }

    /// A short id nobody else will use for another wall or name, even from the web page at the same time.
    private static func newID(_ prefix: String) -> String { prefix + UUID().uuidString.prefix(7).lowercased() }
}

// MARK: - the page

/// Where walls weaken the signal: draw your home, place your devices, and Orbit compares what each device measures
/// with what the walls you drew predict.
struct FloorPlanView: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    var open: (String) -> Void  // shows a device on the Devices page
    @State private var editor = PlanEditor()

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 1100
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text("Draw your walls and place your devices. Orbit compares each device’s Wi-Fi signal with what your plan predicts, and points out the ones with something in the way.")
                            .font(.title3).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        saveNote
                    }
                    if let plan = editor.plan {
                        editorBody(plan, wide: wide, width: geo.size.width)
                    } else if editor.loaded {
                        PlanStartCard(editor: editor)
                    } else if let message = editor.loadError {
                        Card("Orbit couldn’t load your plan", subtitle: message) {
                            Text("Your plan is kept by the Orbit server. Nothing was changed.").foregroundStyle(.secondary)
                            Button("Try again") { editor.retry() }
                        }
                        .frame(maxWidth: 560)
                    } else {
                        Text("Loading your plan…").foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Floor plan")
        .task {
            editor.attach(store)
            await editor.load()
        }
        .onDisappear { editor.flush() }
        .onChange(of: state.now) { _, _ in editor.syncIfNeeded() }  // another window may have saved the plan
    }

    @ViewBuilder
    private var saveNote: some View {
        if editor.plan != nil {
            switch editor.status {
            case .saved: Text("Saved").font(.caption).foregroundStyle(.secondary)
            case .saving: Text("Saving…").font(.caption).foregroundStyle(.secondary)
            case .failed: Text("Not saved").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            }
        }
    }

    private func editorBody(_ plan: FloorPlan, wide: Bool, width: CGFloat) -> some View {
        let analysis = PlanAnalysis.make(plan: plan, devices: state.devices)
        let map = FloorPlanMap(editor: editor, plan: plan, analysis: analysis, state: state)
        return VStack(alignment: .leading, spacing: 16) {
            banner(plan, analysis)
            if wide {
                HStack(alignment: .top, spacing: 20) {
                    map.frame(maxWidth: .infinity)
                    cards(plan, analysis).frame(width: min(430, width * 0.36))
                }
            } else {
                map
                cards(plan, analysis)
            }
        }
    }

    // MARK: banner

    @ViewBuilder
    private func banner(_ plan: FloorPlan, _ analysis: PlanAnalysis) -> some View {
        let problems = analysis.problems
        if !analysis.tuned {
            SecBanner(icon: "mappin.and.ellipse", tint: .secondary, title: "Place at least 3 devices so Orbit can tune its guess",
                      message: "\(Format.plural(analysis.readings.count, "device")) on the plan so far. Pick one from “Not on the plan yet”, then tap its spot on the plan. Until then you can still see what each one measures.") { EmptyView() }
        } else if let worst = problems.first, let d = state.device(worst.id) {
            let how = plan.walls.isEmpty ? "from distance alone" : "with the walls you drew"
            SecBanner(icon: "exclamationmark.triangle", tint: .orange,
                      title: problems.count == 1 ? "\(d.name) is weaker than your plan predicts" : "\(problems.count) devices are weaker than your plan predicts",
                      message: "\(d.name) measures \(PlanMath.dBm(worst.measured)) dBm, but \(how) it should be about \(PlanMath.dBm(worst.expected)) dBm. Something that isn’t on the plan is in the way, such as a metal cabinet, a mirror, a fish tank or a thick wall.") {
                HStack(spacing: 8) {
                    Button("Draw what’s in the way") {
                        editor.select(.device(worst.id))
                        editor.layer = .devices
                        editor.toggle(.wall)
                    }.controlSize(.small)
                    Button("Show on the plan") { editor.select(.device(worst.id)); editor.layer = .devices }.controlSize(.small)
                }
            }
        } else {
            SecBanner(icon: "checkmark.circle", tint: .green, title: "Every device matches your plan",
                      message: "Orbit tuned its guess using \(analysis.readings.count) devices. Nothing unexpected is in the way."
                        + (plan.walls.isEmpty ? " No walls are drawn yet, so this only counts distance." : "")) { EmptyView() }
        }
    }

    // MARK: cards

    private func cards(_ plan: FloorPlan, _ analysis: PlanAnalysis) -> some View {
        VStack(spacing: 16) {
            pickedCard(plan, analysis)
            trayCard(plan)
            howCard(plan, analysis)
        }
        .fixedSize(horizontal: false, vertical: true)  // each card as tall as its own contents, not stretched to the map
    }

    @ViewBuilder
    private func pickedCard(_ plan: FloorPlan, _ analysis: PlanAnalysis) -> some View {
        if let spot = editor.roomSpot {
            NewRoomCard(editor: editor, spot: spot)
        } else {
            switch editor.pick {
            case .device(let id)?:
                if let r = analysis.reading(id), let d = state.device(id) { deviceCard(r, d, plan, analysis) } else { pickCard }
            case .wall(let id)?:
                if let w = plan.walls.first(where: { $0.id == id }) { wallCard(w) } else { pickCard }
            case .room(let id)?:
                if let r = plan.rooms.first(where: { $0.id == id }) { roomCard(r) } else { pickCard }
            case .router?:
                routerCard(plan)
            case nil:
                pickCard
            }
        }
    }

    private var pickCard: some View {
        Card("Pick a device or a wall", subtitle: "Tap one on the plan to see its signal, or to change what a wall is made of.") { EmptyView() }
    }

    private func clearButton() -> some View {
        Button { editor.select(nil) } label: { Image(systemName: "xmark") }
            .buttonStyle(.borderless).help("Clear selection").accessibilityLabel("Clear selection")
    }

    private func deviceCard(_ r: PlanReading, _ d: Device, _ plan: FloorPlan, _ analysis: PlanAnalysis) -> some View {
        Card(d.name, subtitle: "\(d.bandLabel) · \(String(format: "%.1f", r.distance)) m from the router", accessory: { clearButton() }) {
            HStack(spacing: 8) {
                PlanNumber(label: "Measured", value: PlanMath.dBm(r.measured), unit: "dBm")
                if r.verdict != nil {
                    PlanNumber(label: "Plan predicts", value: PlanMath.dBm(r.expected), unit: "dBm")
                    PlanNumber(label: "Gap", value: PlanMath.dB(r.gap), unit: "dB")
                }
            }
            if let v = r.verdict {
                PlanChip(text: v.word, color: v.tint, icon: v.icon)
            } else {
                Label("Place at least 3 devices so Orbit can tune its guess", systemImage: "mappin.and.ellipse")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(r.crossed.isEmpty ? "A clear line to the router" : "Walls between it and the router").font(.subheadline.weight(.semibold))
            if r.crossed.isEmpty {
                Text(plan.walls.isEmpty ? "No walls are drawn yet, so the prediction counts distance only." : "No walls are drawn between them.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(r.crossed) { w in
                        Button { editor.select(.wall(w.id)) } label: {
                            PlanChip(text: "\(w.material.name) · −\(Int(w.material.loss(band: r.band))) dB", color: .secondary, swatch: w.material.color)
                        }.buttonStyle(.plain)
                    }
                }
            }
            if let v = r.verdict {
                Text(advice(v))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button("Open device") { open(d.id) }.buttonStyle(.link)
        }
    }

    private func advice(_ v: PlanVerdict) -> String {
        switch v {
        case .much: return "Much weaker than the walls explain. Something not on the plan is probably in the way: a metal cabinet, a mirror, a fish tank, or a thicker wall than you drew. Draw it, or move the device a little to test."
        case .little: return "A bit weaker than expected. Furniture or a closed door could be the cause."
        case .stronger: return "Stronger than expected. A door may be open, or a wall on the plan may be thinner than you set."
        case .matches: return "About what the plan predicts. The signal is explained by the distance and walls."
        }
    }

    private func wallCard(_ w: PlanWall) -> some View {
        let m = w.material
        return Card("\(m.name) wall",
                    subtitle: "\(String(format: "%.1f", w.length)) m long · takes \(Int(m.loss.ghz24)) dB off 2.4 GHz and \(Int(m.loss.ghz5)) dB off 5 GHz",
                    accessory: { clearButton() }) {
            Text("What is it made of?").font(.subheadline.weight(.semibold))
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(PlanMaterial.allCases) { k in
                    Button { editor.setMaterial(w.id, k) } label: {
                        PlanChip(text: k.name, color: k == m ? .orbitAccent : .secondary, swatch: k.color, selected: k == m)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(k == m ? .isSelected : [])
                }
            }
            Text("Thicker, denser walls take more signal. 5 GHz loses more through a wall than 2.4 GHz does.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) { editor.removeWall(w.id) } label: { Label("Remove this wall", systemImage: "trash") }
                .controlSize(.small)
            Text("You can also select it and press Delete.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func roomCard(_ r: PlanRoom) -> some View {
        Card("Room name", subtitle: "Shown on the plan so you can find your way around", accessory: { clearButton() }) {
            RoomNameField(editor: editor, room: r).id(r.id)
            Button(role: .destructive) { editor.removeRoom(r.id) } label: { Label("Remove this name", systemImage: "trash") }
                .controlSize(.small)
        }
    }

    private func routerCard(_ plan: FloorPlan) -> some View {
        Card("Your router", subtitle: "Every device is compared from here", accessory: { clearButton() }) {
            Text("Drag it to where the router really is, or use the arrow keys to nudge it 10 cm at a time. Moving it changes which walls are between it and each device.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func trayCard(_ plan: FloorPlan) -> some View {
        let wifi = state.devices.filter(\.onPlan).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let waiting = wifi.filter { plan.devices[$0.id] == nil }
        let away = plan.devices.keys.filter { id in !wifi.contains { $0.id == id } }.count
        return Card("Not on the plan yet",
                    subtitle: wifi.isEmpty ? "No Wi-Fi devices are online right now" : waiting.isEmpty ? "Every device is placed" : "Tap one, then tap its spot on the plan") {
            if waiting.isEmpty {
                Text(wifi.isEmpty ? "Wi-Fi devices appear here when they connect." : "Orbit uses every placed device to tune its guess.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(waiting) { d in
                        let active = editor.mode == .place(d.id)
                        Button { editor.toggle(.place(d.id)) } label: {
                            PlanChip(text: d.name, color: active ? .orbitAccent : .secondary, icon: Icons.device(d.type), selected: active)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Place \(d.name) on the plan")
                        .accessibilityAddTraits(active ? .isSelected : [])
                    }
                }
            }
            if away > 0 {
                Text("Devices that are offline keep their place on the plan and come back when they reconnect.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func howCard(_ plan: FloorPlan, _ analysis: PlanAnalysis) -> some View {
        let tuning = analysis.tuned
            ? "Orbit works out what each device should get from the distance and the walls you draw, then tunes that guess using all your devices (\(PlanMath.dB(analysis.offset)) dB so far)."
            : "Orbit works out what each device should get from the distance and the walls you draw, then tunes that guess once at least 3 devices are placed."
        var rows: [(String, String, Color)] = [
            ("exclamationmark.circle", "Your router can’t see walls. It only reports how strong each device’s signal is.", .orange),
            ("checkmark.circle", tuning, .green),
        ]
        if plan.walls.isEmpty {
            rows.append(("info.circle", "No walls are drawn yet, so for now the prediction counts distance only.", .secondary))
        }
        rows.append(("exclamationmark.circle", "It’s an estimate, good to about 6 dB. Use it to spot odd cases, not to measure.", .orange))
        return Card("How this works") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: r.0).foregroundStyle(r.2).frame(width: 20)
                        Text(r.1).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Orbit only keeps this drawing. It never changes anything on your router or dish.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - small pieces

/// The first time: no plan yet. How big is the home, and an outline or a blank page.
private struct PlanStartCard: View {
    var editor: PlanEditor
    @State private var w = Int(FloorPlan.defaultSize.w)
    @State private var h = Int(FloorPlan.defaultSize.h)

    var body: some View {
        let range = Int(FloorPlan.sizeRange.lowerBound)...Int(FloorPlan.sizeRange.upperBound)
        Card("Draw your home so Orbit can tell where walls weaken the signal",
             subtitle: "Orbit only keeps this drawing. Nothing is sent to your router or dish.") {
            Text("Roughly how big is your home? A guess is fine, and you can change it later.")
                .foregroundStyle(.secondary)
            HStack(spacing: 28) {
                Stepper(value: $w, in: range) { Text("Width: \(w) m").monospacedDigit() }
                Stepper(value: $h, in: range) { Text("Depth: \(h) m").monospacedDigit() }
            }
            HStack(spacing: 10) {
                Button("Start with an outline") { editor.start(w: Double(w), h: Double(h), outline: true) }
                    .buttonStyle(.borderedProminent)
                Button("Start empty") { editor.start(w: Double(w), h: Double(h), outline: false) }
            }
            Text("An outline puts four brick walls round the edge and the router in the middle, ready for you to adjust.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 620)
    }
}

/// A new room name: tap a spot on the plan, then type it here and press Return.
private struct NewRoomCard: View {
    var editor: PlanEditor
    var spot: PlanPoint
    @State private var name = ""
    @FocusState private var typing: Bool

    var body: some View {
        Card("Name this spot", subtitle: "Type a short name, like Kitchen, and press Return", accessory: {
            Button { editor.select(nil) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Cancel").accessibilityLabel("Cancel")
        }) {
            TextField("Room name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .onSubmit { editor.addRoom(name) }
            HStack {
                Button("Add name") { editor.addRoom(name) }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { editor.select(nil) }.controlSize(.small)
            }
        }
        .onAppear { typing = true }
    }
}

/// Renames a room name: change it and press Return.
private struct RoomNameField: View {
    var editor: PlanEditor
    var room: PlanRoom
    @State private var name: String

    init(editor: PlanEditor, room: PlanRoom) {
        self.editor = editor
        self.room = room
        _name = State(initialValue: room.name)
    }

    var body: some View {
        TextField("Room name", text: $name)
            .textFieldStyle(.roundedBorder)
            .onSubmit { editor.renameRoom(room.id, name) }
    }
}

/// A small tinted capsule, like the chips on the Security page, in any colour.
private struct PlanChip: View {
    var text: String
    var color: Color
    var icon: String?
    var swatch: Color?
    var selected = false

    init(text: String, color: Color, icon: String? = nil, swatch: Color? = nil, selected: Bool = false) {
        self.text = text; self.color = color; self.icon = icon; self.swatch = swatch; self.selected = selected
    }

    var body: some View {
        HStack(spacing: 5) {
            if let swatch { Capsule().fill(swatch).frame(width: 12, height: 4) }
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(selected ? 0.2 : 0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color, lineWidth: selected ? 1.2 : 0))
    }
}

private struct PlanNumber: View {
    var label: String
    var value: String
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
