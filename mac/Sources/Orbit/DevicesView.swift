import Charts
import SwiftUI

struct DevicesView: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    @State private var query = ""
    @State private var selection: Device.ID?
    @State private var showOffline = true
    @State private var sortOrder = [KeyPathComparator(\Device.now, order: .reverse)]

    var rows: [Device] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return state.devices
            .filter { showOffline || $0.online }
            .filter { d in
                q.isEmpty || [d.name, d.ip ?? "", d.routerName ?? "", d.hostname ?? "", state.person(d.owner)?.name ?? ""]
                    .joined(separator: " ").lowercased().contains(q)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Device", value: \.name) { d in
                HStack(spacing: 10) {
                    DeviceIcon(device: d, person: state.person(d.owner), size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(d.name).fontWeight(.semibold)
                            if d.isNew { Text("NEW").font(.caption2.bold()).foregroundStyle(.orange) }
                        }
                        Text("\(state.person(d.owner)?.name ?? "No owner yet") · \(d.networkLabel)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 220, ideal: 280)
            TableColumn("Status") { d in
                VStack(alignment: .leading, spacing: 2) {
                    StatusBadge(device: d)
                    Text(statusDetail(d)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .width(min: 100, ideal: 120)
            TableColumn("Connection") { d in
                HStack(spacing: 6) {
                    if d.online {
                        if d.wired { Image(systemName: "cable.connector") } else { SignalBars(dbm: d.signal) }
                        Text(d.connectionLabel)
                    } else {
                        Text(d.ip.map { "Last at \($0)" } ?? "Not connected").foregroundStyle(.secondary)
                    }
                }
            }
            .width(min: 150, ideal: 190)
            TableColumn("Right now", value: \.now) { d in
                Text(d.online ? "↓ \(Format.mbps(d.downMbps))  ↑ \(Format.mbps(d.upMbps)) Mbps" : "–").monospacedDigit()
            }
            .width(min: 130, ideal: 150)
            TableColumn("Today", value: \.today) { d in
                Text(Format.bytes(d.today)).monospacedDigit()
            }
            .width(min: 70, ideal: 90)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search name, IP address or owner")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showOffline) { Label("Show offline", systemImage: "wifi.slash") }
                    .help("Show devices that aren’t connected right now")
            }
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let id = selection, let d = state.devices.first(where: { $0.id == id }) {
                DeviceInspector(device: d, state: state).inspectorColumnWidth(min: 300, ideal: 340, max: 420)
            }
        }
        .navigationTitle("Devices")
        .navigationSubtitle("\(state.connected.count) connected · \(state.active.count) using the internet")
    }

    private func statusDetail(_ d: Device) -> String {
        if !d.online { return d.lastSeen.map { "Seen \(Format.ago($0, now: state.now))" } ?? "" }
        if d.blocked == true { return "From the Starlink app" }
        return d.since.map { "For \(Format.duration(ms: state.now - $0))" } ?? ""
    }
}

struct DeviceInspector: View {
    @Environment(OrbitStore.self) private var store
    var device: Device
    var state: OrbitState
    @State private var name = ""
    @State private var week: [UsageBar] = []

    var body: some View {
        let d = device
        let p = state.person(d.owner)
        Form {
            Section {
                HStack(spacing: 12) {
                    DeviceIcon(device: d, person: p, size: 44)
                    VStack(alignment: .leading) {
                        TextField("Name", text: $name, prompt: Text(d.routerName ?? d.hostname ?? "Name this device"))
                            .font(.title3.weight(.semibold))
                            .textFieldStyle(.plain)
                            .onSubmit { if name != (d.customName ?? d.name) { store.rename(d.id, to: name) } }
                        HStack { StatusBadge(device: d) }
                    }
                }
                Picker("Owner", selection: Binding(get: { d.owner ?? "" }, set: { store.assign(d.id, to: $0.isEmpty ? nil : $0) })) {
                    Text("No owner").tag("")
                    ForEach(state.people) { person in Text(person.name).tag(person.id) }
                }
                Picker("Kind", selection: Binding(get: { d.type }, set: { store.setType(d.id, to: $0) })) {
                    ForEach(Icons.types, id: \.key) { t in Label(t.label, systemImage: Icons.device(t.key)).tag(t.key) }
                }
            }
            if d.blocked == true {
                Section { Label("No internet access right now. It’s blocked from the Starlink app (paused or on a schedule).", systemImage: "nosign").foregroundStyle(.red) }
            }
            if d.online {
                Section("Right now") {
                    LabeledContent("Download", value: "\(Format.mbps(d.downMbps)) Mbps")
                    LabeledContent("Upload", value: "\(Format.mbps(d.upMbps)) Mbps")
                    Sparkline(values: (store.deviceHistory[d.id] ?? []).map { Optional($0) }, color: p.map { Color.person($0.color) } ?? .orbitAccent)
                        .frame(height: 44)
                }
            }
            Section("Connection") {
                LabeledContent("Network", value: d.networkLabel + (d.ssid.map { " · \($0)" } ?? ""))
                if d.online && !d.wired {
                    LabeledContent("Band", value: d.bandLabel)
                    LabeledContent("Signal") {
                        HStack { SignalBars(dbm: d.signal); Text("\(Signal(d.signal).word) (\(Int(d.signal ?? 0)) dBm)") }
                    }
                }
                if let since = d.since, d.online { LabeledContent("Connected", value: Format.duration(ms: state.now - since)) }
                if let ip = d.ip { LabeledContent("IP address", value: ip).textSelection(.enabled) }
                if let mac = d.mac { LabeledContent("MAC address", value: mac).textSelection(.enabled) }
            }
            Section("Data used") {
                LabeledContent("Today", value: "\(Format.bytes(d.today)) (↓ \(Format.bytes(d.todayDown)) · ↑ \(Format.bytes(d.todayUp)))")
                if !week.isEmpty {
                    LabeledContent("Last 7 days", value: Format.bytes(week.reduce(0) { $0 + $1.down + $1.up }))
                    Chart(week) { b in
                        BarMark(x: .value("Day", Format.date(b.t), unit: .day), y: .value("GB", (b.down + b.up) / 1e9))
                            .foregroundStyle(p.map { Color.person($0.color) } ?? .orbitAccent)
                    }
                    .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
                    .frame(height: 90)
                }
            }
            Section {
                Text("Pausing and schedules are set in the Starlink app. Your router only accepts changes from there, and Orbit shows what you set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: d.id) {
            name = d.customName ?? d.name
            if let w: DeviceDays = try? await store.get("api/devices/\(d.id)/usage") { week = w.days }
        }
    }
}
