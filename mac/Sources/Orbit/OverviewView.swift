import Charts
import SwiftUI

struct OverviewView: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    @Binding var section: Page

    var body: some View {
        let s = state
        let health = s.health
        let cap = s.capacity
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(greeting)\(s.me.map { ", " + $0.name } ?? "") · \(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Circle().fill(health.tone.color).frame(width: 10, height: 10)
                        Text(health.title).font(.system(size: 30, weight: .bold, design: .rounded))
                    }
                    Text(health.detail).font(.title3).foregroundStyle(.secondary)
                }

                if !s.newDevices.isEmpty { NewDeviceBanner(devices: s.newDevices, state: s) }

                EqualRow {
                    StatTile(icon: "timer", label: "Latency", value: s.dish.latencyMs.map { "\(Int($0.rounded()))" } ?? "–",
                             unit: s.dish.latencyMs == nil ? "" : "ms",
                             note: latencyNote(s.dish.latencyMs), live: s.dish.latencyMs != nil) {
                        Sparkline(values: store.points.suffix(40).map(\.lat), maxValue: 80).frame(height: 26)
                    }
                    StatTile(icon: "waveform", label: "In use now", value: Format.mbps(s.dish.downMbps), unit: "Mbps",
                             note: "of ~\(Int(cap.mbps)) Mbps, \(cap.label)", live: s.dish.online == true) {
                        ProgressView(value: min(1, s.dish.downMbps / cap.mbps)).tint(.orbitAccent)
                    }
                    StatTile(icon: "arrow.up.arrow.down", label: "Data used today", value: Format.bytes(s.home.down + s.home.up),
                             note: "↓ \(Format.bytes(s.home.down)) · ↑ \(Format.bytes(s.home.up))")
                    StatTile(icon: "exclamationmark.triangle", label: "Dropouts, 24 h", value: "\(s.outages.count)",
                             note: s.outages.isEmpty ? "Not one in the last 24 hours" : "\(Format.seconds(s.dropoutSeconds)) offline in total")
                }

                Card("Live traffic", subtitle: "Whole home, last 2 minutes, updated every second") {
                    TrafficChart(points: store.points).frame(height: 220)
                }

                EqualRow(spacing: 16) {
                    Card("Using the most right now", subtitle: "Share of ~\(Int(cap.mbps)) Mbps",
                         accessory: { Button("All devices") { section = .devices }.buttonStyle(.link) }) {
                        TopUsers(state: s, capacity: cap.mbps)
                    }
                    Card("Recent activity", accessory: { Button("See all") { section = .activity }.buttonStyle(.link) }) {
                        EventList(events: Array(s.events.prefix(6)), now: s.now)
                    }
                }

                EqualRow(spacing: 16) {
                    Card("Starlink", accessory: { Button("Details") { section = .starlink }.buttonStyle(.link) }) {
                        StarlinkGlance(state: s)
                    }
                    Card("Data used today, by person", subtitle: "\(Format.bytes(s.home.down + s.home.up)) for the whole home") {
                        PersonUsage(state: s)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Overview")
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 ? "Hello" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : "Good evening"
    }

    private func latencyNote(_ lat: Double?) -> String {
        guard let lat else { return "No connection right now" }
        return lat < 40 ? "Great for gaming and calls" : lat < 80 ? "Fine for most things" : "Responses feel slow"
    }
}

struct TrafficChart: View {
    var points: [Point]

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", Format.date(p.t)), y: .value("Mbps", p.down), series: .value("", "Download area"))
                    .foregroundStyle(Color.orbitAccent.opacity(0.15))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", Format.date(p.t)), y: .value("Mbps", p.down), series: .value("Direction", "Download"))
                    .foregroundStyle(Color.orbitAccent)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", Format.date(p.t)), y: .value("Mbps", p.up), series: .value("Direction", "Upload"))
                    .foregroundStyle(.gray)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYAxisLabel("Mbps")
        .chartForegroundStyleScale(["Download": Color.orbitAccent, "Upload": Color.gray])
        .chartLegend(position: .bottom, alignment: .leading)
    }
}

struct TopUsers: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    var capacity: Double

    var body: some View {
        let top = state.connected.filter { $0.now > 0.05 }.sorted { $0.now > $1.now }.prefix(5)
        VStack(spacing: 10) {
            ForEach(Array(top)) { d in
                let p = state.person(d.owner)
                HStack(spacing: 10) {
                    DeviceIcon(device: d, person: p)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(d.name).fontWeight(.semibold).lineLimit(1)
                            Spacer()
                            Text("\(Format.mbps(d.downMbps)) Mbps").fontWeight(.semibold).monospacedDigit()
                        }
                        ShareBar(fraction: d.downMbps / capacity, color: p.map { Color.person($0.color) } ?? .orbitNone)
                        Text(p?.name ?? (d.isNew ? "New device" : "No owner yet")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if top.isEmpty { Text("Nothing is using the internet right now.").foregroundStyle(.secondary).frame(maxWidth: .infinity) }
        }
    }
}

struct EventList: View {
    var events: [Event]
    var now: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(events) { e in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Icons.event(e.icon))
                        .foregroundStyle(e.tone == "warn" || e.tone == "crit" || e.cat == "security" ? .orange : e.tone == "good" ? .green : .secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.title).fontWeight(.medium)
                        if let d = e.detail { Text(d).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Text(Format.ago(e.ts, now: now)).font(.caption).foregroundStyle(.secondary)
                }
            }
            if events.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
        }
    }
}

struct StarlinkGlance: View {
    var state: OrbitState

    var body: some View {
        let d = state.dish
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow { Text("Status").foregroundStyle(.secondary); Text(d.reachable == false ? "Can’t reach it" : d.online == false ? "Offline" : "Online") }
            GridRow { Text("Online for").foregroundStyle(.secondary); Text(d.onlineSince.map { Format.duration(ms: state.now - $0) } ?? "–") }
            GridRow { Text("Sky view").foregroundStyle(.secondary); Text((d.obstructed ?? 0) > 0.0005 ? String(format: "%.2f%% blocked", (d.obstructed ?? 0) * 100) : "Clear, nothing blocking it") }
            GridRow { Text("Dropouts, 24 h").foregroundStyle(.secondary); Text(state.outages.isEmpty ? "None" : "\(state.outages.count), \(Format.seconds(state.dropoutSeconds)) in total") }
            if let t = state.tests.first(where: { $0.error == nil }), let down = t.down {
                GridRow { Text("Last speed test").foregroundStyle(.secondary); Text("\(Int(down)) ↓ / \(Int(t.up ?? 0)) ↑ Mbps, \(Format.ago(t.ts, now: state.now))") }
            }
        }
    }
}

struct PersonUsage: View {
    var state: OrbitState

    var body: some View {
        let rows: [(String, Color, Double)] = (state.people.map { p in
            (p.name, Color.person(p.color), state.devices.filter { $0.owner == p.id }.reduce(0) { $0 + $1.today })
        } + [("No owner yet", Color.orbitNone, state.devices.filter { $0.owner == nil }.reduce(0) { $0 + $1.today })])
            .filter { $0.2 >= 1e6 }.sorted { $0.2 > $1.2 }
        let maxValue = rows.map(\.2).max() ?? 1
        VStack(spacing: 10) {
            ForEach(rows, id: \.0) { name, color, value in
                HStack(spacing: 10) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(name).frame(width: 110, alignment: .leading).lineLimit(1)
                    ShareBar(fraction: value / maxValue, color: color)
                    Text(Format.bytes(value)).monospacedDigit().frame(width: 70, alignment: .trailing)
                }
            }
            if rows.isEmpty { Text("Nothing measured yet today.").foregroundStyle(.secondary) }
        }
    }
}

struct NewDeviceBanner: View {
    @Environment(OrbitStore.self) private var store
    var devices: [Device]
    var state: OrbitState
    @State private var merging: (new: Device, known: Device)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(devices.count == 1 ? "A device you may not know joined" : "\(devices.count) devices you may not know joined", systemImage: "exclamationmark.shield")
                .font(.headline)
            Text("If nobody at home recognizes it, change your Wi-Fi password in the Starlink app.").foregroundStyle(.secondary)
            ForEach(devices.prefix(2)) { d in
                HStack {
                    DeviceIcon(device: d, person: nil, size: 26)
                    Text(d.name).fontWeight(.semibold)
                    Text("· \(d.networkLabel)").foregroundStyle(.secondary)
                    Spacer()
                    if let same = state.device(d.maybeSame) {
                        Button("Same as \(same.name)?") { merging = (d, same) }
                            .help("It has the same name as \(same.name), which isn’t connected. It may be the same device with a new address.")
                    } else {
                        Menu("It’s ours") {
                            ForEach(state.people) { p in Button(p.name) { store.assign(d.id, to: p.id) } }
                        }
                        .fixedSize()
                    }
                    Button("Dismiss") { store.acknowledge(d.id) }
                }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .confirmationDialog("Merge \(merging?.new.name ?? "") with \(merging?.known.name ?? "")?",
                            isPresented: Binding(get: { merging != nil }, set: { if !$0 { merging = nil } })) {
            Button("Merge") {
                if let m = merging { Task { _ = await store.merge(m.new.id, with: m.known.id) } }
                merging = nil
            }
        } message: {
            Text("They become one device, with both histories added together. You can separate them later from its details on the Devices page.")
        }
    }
}
