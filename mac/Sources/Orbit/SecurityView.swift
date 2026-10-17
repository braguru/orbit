import SwiftUI

extension OrbitState {
    /// How many different sources are contacting this Mac right now (the sidebar badge).
    var probeSourceCount: Int { Set(activeProbes.map { $0.device ?? $0.ip }).count }
}

/// Who can reach whom, who has been knocking on this Mac, and what Orbit can and can't promise about either.
struct SecurityView: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    var open: (String) -> Void  // shows a device on the Devices page
    @State private var selected: String?
    @State private var tripwireWish: Bool?  // the switch as just flipped, until the server's answer arrives

    var body: some View {
        let layout = SecLayout.make(state)
        GeometryReader { geo in
            let wide = geo.size.width >= 1100
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("See which devices can talk to each other, and who is knocking on this Mac. Each Wi-Fi network is a separate part of the map.")
                        .font(.title3).foregroundStyle(.secondary)
                    banners
                    if wide {
                        HStack(alignment: .top, spacing: 20) {
                            SecurityMap(layout: layout, state: state, selected: $selected).frame(maxWidth: .infinity)
                            cards(layout).frame(width: min(430, geo.size.width * 0.36))
                        }
                    } else {
                        SecurityMap(layout: layout, state: state, selected: $selected)
                        cards(layout)
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle("Security")
        .onChange(of: state.devices.map(\.online)) { _, _ in
            if let s = selected, layout.node(s) == nil { selected = nil }  // a device that left the map
        }
        .onChange(of: state.security?.tripwire?.on) { _, _ in tripwireWish = nil }
    }

    // MARK: banners

    private func displayName(_ p: Probe) -> String { state.device(p.device)?.name ?? p.name ?? p.ip }

    @ViewBuilder
    private var banners: some View {
        let active = state.activeProbes
        if active.isEmpty {
            if state.security?.tripwire?.on == false {
                SecBanner(icon: "shield.slash", tint: .secondary, title: "The tripwire is off",
                          message: "Orbit isn’t listening for anyone knocking on this Mac. Turn it on to be told when a device probes it.") {
                    Button("Turn it on") { tripwire(true) }.controlSize(.small)
                }
            } else if state.security?.tripwire != nil {
                SecBanner(icon: "checkmark.shield", tint: .green, title: "No one is probing your Mac",
                          message: "The tripwire hasn’t seen anything suspicious in the past hour.") { EmptyView() }
            }
        } else {
            ForEach(active.prefix(3)) { p in
                let tries = p.tries ?? (p.ports ?? []).reduce(0) { $0 + ($1.tries ?? 0) }
                let doors = (p.ports ?? []).count
                let where_ = p.network == "guest" ? "It’s on a guest Wi-Fi network, which should be walled off from this Mac."
                    : p.network == "outside" ? "It came from outside your Wi-Fi networks."
                    : "It’s on your main Wi-Fi."
                SecBanner(icon: "exclamationmark.shield", tint: .red,
                          title: "\(displayName(p)) is \(p.scan == true ? "scanning" : "probing") your Mac",
                          message: "\(Format.plural(tries, "try", "tries")) on \(Format.plural(doors, "door")), last \(Format.ago(p.last, now: state.now)). \(where_) Orbit can’t change your router, so to cut it off, pause it in the Starlink app and consider changing your Wi-Fi password.") {
                    if let d = state.device(p.device) {
                        Button("Open device") { open(d.id) }.controlSize(.small)
                    }
                }
            }
            if active.count > 3 {
                Text("and \(active.count - 3) more below").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: cards

    private func cards(_ layout: SecLayout) -> some View {
        VStack(spacing: 16) {
            networksCard(layout)
            RouterSettingsCard(router: state.router)
            selectedCard(layout)
            tripwireCard
            attemptsCard
            limitsCard
        }
    }

    private func networksCard(_ layout: SecLayout) -> some View {
        Card("Your Wi-Fi networks", subtitle: "Read from your router") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(layout.zones.enumerated()), id: \.element.id) { i, z in
                    let count = layout.nodes.filter { $0.zone == i && !$0.ghost }.count
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: z.guest ? "person.2" : "wifi")
                                .frame(width: 32, height: 32)
                                .foregroundStyle(z.danger ? .red : z.guest ? Color.green : Color.orbitAccent)
                                .background((z.danger ? Color.red : z.guest ? Color.green : Color.orbitAccent).opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(z.name).fontWeight(.bold).lineLimit(1)
                                    if !z.enabled { SecChip(text: "Off", tone: .neutral) }
                                }
                                Text("\(Format.plural(count, "device")) connected" + (z.guest ? " · Guest" : " · Main"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        FlowLayout(spacing: 6, lineSpacing: 6) { ForEach(chips(z), id: \.text) { SecChip(text: $0.text, tone: $0.tone, icon: $0.icon) } }
                        Text(note(z)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 12)
                    .opacity(z.enabled ? 1 : 0.6)
                    if i < layout.zones.count - 1 { Divider() }
                }
                if layout.zones.isEmpty { Text("Your router hasn’t shared its networks yet.").foregroundStyle(.secondary) }
            }
        }
    }

    private struct ChipSpec { var text: String; var tone: SecChip.Tone; var icon: String }

    private func chips(_ z: SecZone) -> [ChipSpec] {
        var out = [z.open ? ChipSpec(text: "No password", tone: .bad, icon: "lock.open")
                          : ChipSpec(text: "Password", tone: .good, icon: "lock")]
        if let n = state.router.networks.first(where: { $0.domain == z.id }) {
            let c = RouterSettingsCard.securityChip(n)
            out = [ChipSpec(text: c.text, tone: c.tone, icon: c.icon)]
            if n.hidden == true { out.append(ChipSpec(text: "Hidden name", tone: .neutral, icon: "eye.slash")) }
        }
        if z.guest {
            out.append(z.isolated == false ? ChipSpec(text: "Client isolation OFF", tone: .bad, icon: "xmark.shield")
                                           : ChipSpec(text: "Client isolation on", tone: .good, icon: "checkmark.shield"))
            out.append(ChipSpec(text: "Can’t reach main Wi-Fi", tone: .good, icon: "checkmark.shield"))
        } else if z.isolated == true {
            out.append(ChipSpec(text: "Client isolation on", tone: .good, icon: "checkmark.shield"))
        } else {
            out.append(ChipSpec(text: "Devices can reach each other", tone: .neutral, icon: "link"))
        }
        return out
    }

    private func note(_ z: SecZone) -> String {
        if !z.enabled { return "This network is switched off right now." }
        if !z.guest { return "Normal for a home network. It means any device that gets in can see the rest, so strangers must not get in." }
        if z.isolated == false {
            return (z.open ? "Anyone can join without a password, and now they can reach each other. " : "Guests can reach each other. ")
                + "Turn client isolation back on in the Starlink app."
        }
        return z.open ? "Anyone can join, but isolation keeps each visitor in their own room. Orbit tells you if that setting ever turns off."
                      : "Each guest gets the internet and nothing else. They can’t see each other or your devices."
    }

    @ViewBuilder
    private func selectedCard(_ layout: SecLayout) -> some View {
        if let n = selected.flatMap({ layout.node($0) }), !n.ghost {
            let reach = layout.nodes.filter { layout.canReach(n, $0) }
            let z = layout.zones[n.zone]
            Card(n.name, subtitle: "\(z.name) · \(z.guest ? "Guest" : "Main") Wi-Fi", accessory: {
                Button { selected = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Clear selection")
                    .accessibilityLabel("Clear selection")
            }) {
                if reach.isEmpty {
                    Label("Can’t reach any other device. It only gets the internet.", systemImage: "checkmark.shield").foregroundStyle(.green)
                } else {
                    Text("Can reach \(Format.plural(reach.count, "other device"))").font(.subheadline.weight(.semibold))
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(reach) { r in
                            Button { selected = r.id } label: { SecChip(text: r.name, tone: .good) }.buttonStyle(.plain)
                        }
                    }
                }
                Text(z.guest ? "The wall around this network keeps it away from your main Wi-Fi."
                             : "It can also reach your router. Nothing on a guest network can reach it.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open device") { open(n.id) }.buttonStyle(.link)
            }
        } else {
            Card("Pick a device", subtitle: "Tap any dot on the map to see what it can reach and what it can’t.") { EmptyView() }
        }
    }

    // MARK: tripwire

    private func tripwire(_ on: Bool) {
        tripwireWish = on
        store.setTripwire(on)
    }

    private var tripwireCard: some View {
        let tw = state.security?.tripwire
        let on = tripwireWish ?? tw?.on ?? false
        let doors = tw?.listening ?? []
        let status = !on ? "Off" : tw?.running == false ? "On, but it isn’t listening yet" : "Listening on \(Format.plural(doors.count, "door"))"
        return Card("Tripwire", subtitle: "A few doors on this Mac that nothing should knock on", accessory: {
            if tw != nil {
                Toggle("Tripwire", isOn: Binding(get: { on }, set: { tripwire($0) })).labelsHidden().toggleStyle(.switch)
            }
        }) {
            if let tw {
                HStack(spacing: 8) {
                    Circle().fill(on ? Color.green : Color.secondary).frame(width: 8, height: 8)
                    Text(status).fontWeight(.semibold)
                    if on, let since = tw.since { Text("since \(Format.clock(since))").font(.callout).foregroundStyle(.secondary) }
                }
                if on && !doors.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(doors) { d in SecChip(text: "Door \(d.port)" + (Self.doorLabel(d.label)), tone: .neutral) }
                    }
                }
                if on {
                    ForEach(tw.busy ?? []) { d in
                        Label(d.port == 22 ? "Remote Login is switched on, so Orbit can’t watch door 22."
                                           : "Something on this Mac already uses door \(d.port)\(d.label.map { " (\($0))" } ?? ""), so Orbit can’t watch it.",
                              systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let ip = tw.hostIp, let port = doors.first?.port {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Test it").font(.subheadline.weight(.semibold))
                            Text("From a phone on your Wi-Fi, open http://\(ip):\(String(port)) in a browser. It should appear here within a few seconds. Devices you’ve marked as known on your main Wi-Fi are allowed to connect, so test with one that isn’t known yet.")
                                .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                } else {
                    Text("Turn it on and Orbit will tell you when a device on your network knocks on this Mac.").font(.callout).foregroundStyle(.secondary)
                }
                Text("It only sees completed connections to those doors on this Mac. It can’t see half-open scans, pings, attempts on other devices, or anything inside guest networks.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This version of the Orbit server doesn’t have a tripwire. Update the server to use it.").foregroundStyle(.secondary)
            }
        }
    }

    /// The service a door is named for, unless it's only named after its number.
    static func doorLabel(_ l: String?) -> String { l.flatMap { $0.hasPrefix("Port ") ? nil : " · \($0)" } ?? "" }

    // MARK: contact attempts

    private var attemptsCard: some View {
        let probes = (state.security?.probes ?? []).sorted { $0.last > $1.last }
        let events = Array(state.events.filter { $0.cat == "security" }.prefix(5))
        let anyActive = !state.activeProbes.isEmpty
        return Card("Contact attempts", subtitle: "Seen by the tripwire on this Mac, past 24 hours", accessory: {
            SecChip(text: anyActive ? "Active now" : "Quiet", tone: anyActive ? .bad : .good)
        }) {
            if probes.isEmpty {
                Text("Nothing to show. When a device probes this Mac, it appears here and on the map.").foregroundStyle(.secondary)
            }
            ForEach(probes) { p in probeRow(p) }
            if !events.isEmpty {
                Divider()
                Text("Latest security notes").font(.subheadline.weight(.semibold))
                ForEach(events) { e in
                    HStack(alignment: .top, spacing: 12) {
                        Text(Format.ago(e.ts, now: state.now)).font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 80, alignment: .leading)
                        Image(systemName: Icons.event(e.icon))
                            .foregroundStyle(e.tone == "crit" ? .red : e.tone == "good" ? .green : .orange)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.title).fontWeight(.medium)
                            if let d = e.detail { Text(d).font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func probeRow(_ p: Probe) -> some View {
        let live = state.now - p.last < OrbitState.probeWindow
        let ports = p.ports ?? []
        return HStack(alignment: .top, spacing: 12) {
            let tint: Color = p.known == true ? .accentColor : live ? .red : .orange
            Image(systemName: p.known == true ? "arrow.left.arrow.right" : p.scan == true ? "dot.radiowaves.left.and.right" : "scope")
                .frame(width: 30, height: 30)
                .foregroundStyle(tint)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(displayName(p)) \(p.known == true ? "connected to this Mac" : p.scan == true ? "scanned this Mac" : "tried to connect to this Mac")").fontWeight(.medium)
                Text(p.known == true ? "A known device on your main Wi-Fi. Devices there are allowed to talk to each other, so this is only a note, not an alert."
                     : p.scan == true ? "It tried many doors in a row, which is how scanners look for a way in."
                                    : "These doors aren’t used by anything you’ve set up, so nobody should knock on them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    if p.known == true { SecChip(text: "Allowed", tone: .good) }
                    ForEach(ports) { port in
                        SecChip(text: "Door \(port.port)" + (Self.doorLabel(port.label)) + (port.tries.map { " × \($0)" } ?? ""), tone: live && p.known != true ? .bad : .neutral)
                    }
                    SecChip(text: p.network == "guest" ? "Guest Wi-Fi" : p.network == "outside" ? "Outside your Wi-Fi" : "Main Wi-Fi", tone: .neutral)
                    Text(p.ip).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
            Text(Format.ago(p.last, now: state.now)).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: limits

    private var limitsCard: some View {
        let rows: [(String, String, Color)] = [
            ("checkmark.circle", "Which network each device is on, and each network’s settings: a password or none, isolation on or off.", .green),
            ("checkmark.circle", "Who can reach whom. It’s worked out from those settings, so it’s as reliable as your router’s own settings.", .green),
            ("exclamationmark.circle", "Attempts aimed at this Mac. Orbit’s tripwire notices completed connections to a few doors. It only covers this Mac.", .orange),
            ("xmark.circle", "Traffic between two other devices. The Starlink router doesn’t report it.", .secondary),
            ("xmark.circle", "Attempts inside a guest network. Isolation drops them before anyone can see them, which is also why they can’t hurt.", .secondary),
            ("xmark.circle", "The router’s firewall log. Starlink’s router doesn’t share it.", .secondary),
        ]
        return Card("What Orbit can and can’t see", subtitle: "So you know what this page can promise") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: r.0).foregroundStyle(r.2).frame(width: 20)
                        Text(r.1).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct SecBanner<Actions: View>: View {
    var icon: String
    var tint: Color
    var title: String
    var message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tint.opacity(0.3)))
        .accessibilityElement(children: .contain)
    }
}

struct SecChip: View {
    enum Tone { case good, warn, bad, neutral }
    var text: String
    var tone: Tone
    var icon: String?

    init(text: String, tone: Tone, icon: String? = nil) { self.text = text; self.tone = tone; self.icon = icon }

    var body: some View {
        let color: Color = tone == .good ? .green : tone == .warn ? .orange : tone == .bad ? .red : .secondary
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}
