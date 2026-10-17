import Charts
import SwiftUI

struct DevicesView: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    @Binding var focus: String?  // set from elsewhere, such as the Overview map, to select that device
    @State private var query = ""
    @State private var selection = Snapshot.devices
    @State private var showOffline = true
    @State private var showHidden = false
    @State private var sortOrder = [KeyPathComparator(\Device.now, order: .reverse)]
    @State private var forgetting: [Device] = []

    var rows: [Device] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return state.devices
            .filter { showOffline || $0.online }
            .filter { showHidden || !$0.isHidden || !q.isEmpty }  // a search finds hidden devices too
            .filter { d in
                q.isEmpty || [d.name, d.ip ?? "", d.routerName ?? "", d.hostname ?? "", d.notes ?? "", state.person(d.owner)?.name ?? ""]
                    .joined(separator: " ").lowercased().contains(q)
            }
            .sorted(using: sortOrder)
    }

    var body: some View {
        let shown = rows
        Table(shown, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Device", value: \.name) { d in
                HStack(spacing: 10) {
                    DeviceIcon(device: d, person: state.person(d.owner), size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(d.name).fontWeight(.semibold)
                            if d.isNew { Text("NEW").font(.caption2.bold()).foregroundStyle(.orange) }
                            if d.isHidden { Text("HIDDEN").font(.caption2.bold()).foregroundStyle(.secondary) }
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
                        if d.wired { Image(systemName: "cable.connector") } else { SignalBars(dbm: d.effSignal) }
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
                VStack(alignment: .leading, spacing: 4) {
                    Text(Format.bytes(d.today)).monospacedDigit()
                    if let a = d.allowance { AllowanceBar(allowance: a).frame(width: 64) }
                }
            }
            .width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: Device.ID.self) { ids in
            let chosen = state.devices.filter { ids.contains($0.id) }
            if !chosen.isEmpty {
                BulkActions(devices: chosen, state: state, inMenu: true, onForget: { forgetting = $0 })
            }
        }
        .onChange(of: shown.map(\.id)) { _, ids in selection.formIntersection(ids) }  // a device you hide leaves the selection
        .onChange(of: focus, initial: true) { _, id in
            guard let id else { return }
            if state.device(id)?.isHidden == true { showHidden = true }
            query = ""
            selection = [id]
            focus = nil
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search name, IP address, owner or notes")
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showOffline) { Label("Show offline", systemImage: "wifi.slash") }
                    .help("Show devices that aren’t connected right now")
            }
            ToolbarItem {
                Toggle(isOn: $showHidden) { Label("Show hidden", systemImage: "eye") }
                    .help("Show devices you hid from the list")
            }
        }
        .inspector(isPresented: Binding(get: { !selection.isEmpty }, set: { if !$0 { selection = [] } })) {
            let chosen = state.devices.filter { selection.contains($0.id) }
            Group {
                if chosen.count == 1, let d = chosen.first {
                    DeviceInspector(device: d, state: state, select: { selection = [$0] }, onForget: { forgetting = [$0] })
                } else if chosen.count > 1 {
                    BulkInspector(devices: chosen, state: state, onForget: { forgetting = $0 })
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .confirmationDialog(forgetting.count == 1 ? "Forget \(forgetting[0].name)?" : "Forget \(forgetting.count) devices?",
                            isPresented: Binding(get: { !forgetting.isEmpty }, set: { if !$0 { forgetting = [] } })) {
            Button(forgetting.count == 1 ? "Forget Device" : "Forget \(forgetting.count) Devices", role: .destructive) {
                store.forget(forgetting.map(\.id))
                selection.subtract(forgetting.map(\.id))
                forgetting = []
            }
        } message: {
            Text("Orbit removes \(forgetting.count == 1 ? "its name and owner" : "their names and owners"). If \(forgetting.count == 1 ? "it connects" : "they connect") again, \(forgetting.count == 1 ? "it shows" : "they show") up as new. Usage history stays in your totals.")
        }
        .navigationTitle("Devices")
        .navigationSubtitle(subtitle)
    }

    private var subtitle: String {
        let hidden = state.devices.filter(\.isHidden).count
        return "\(state.connected.count) connected · \(state.active.count) using the internet" + (hidden > 0 ? " · \(hidden) hidden" : "")
    }

    private func statusDetail(_ d: Device) -> String {
        if !d.online { return d.lastSeen.map { "Seen \(Format.ago($0, now: state.now))" } ?? "" }
        if d.blocked == true { return "From the Starlink app" }
        return d.since.map { "For \(Format.duration(ms: state.now - $0))" } ?? ""
    }
}

/// Changes for several devices at once: in the right-click menu and in the inspector.
struct BulkActions: View {
    @Environment(OrbitStore.self) private var store
    var devices: [Device]
    var state: OrbitState
    var inMenu = false  // in a menu, a line sets Forget apart; in a form it would be an empty row
    var onForget: ([Device]) -> Void

    var body: some View {
        let ids = devices.map(\.id)
        let allHidden = devices.allSatisfy(\.isHidden)
        Menu("Owner") {
            ForEach(state.people) { p in Button(p.name) { store.bulk(ids, ["owner": p.id]) } }
            Divider()
            Button("No Owner") { store.bulk(ids, ["owner": NSNull()]) }
        }
        Menu("Kind") {
            ForEach(Icons.types, id: \.key) { t in
                Button { store.bulk(ids, ["type": t.key]) } label: { Label(t.label, systemImage: Icons.device(t.key)) }
            }
        }
        if devices.contains(where: \.isNew) {
            Button("Mark as Known") { store.bulk(ids, ["acknowledged": true]) }
        }
        Button(allHidden ? "Show in Lists" : "Hide from Lists") { store.bulk(ids, ["hidden": !allHidden]) }
        if inMenu { Divider() }
        Button(devices.count == 1 ? "Forget…" : "Forget \(devices.count) Devices…", role: .destructive) { onForget(devices) }
            .disabled(devices.contains(where: \.online))
    }
}

struct BulkInspector: View {
    var devices: [Device]
    var state: OrbitState
    var onForget: ([Device]) -> Void

    var body: some View {
        Form {
            Section {
                Label("\(devices.count) devices selected", systemImage: "checklist").font(.headline)
                Text(devices.map(\.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            Section("Change all of them") {
                BulkActions(devices: devices, state: state, onForget: onForget)
            }
            if devices.contains(where: \.online) {
                Section { Text("Only offline devices can be forgotten.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

struct DeviceInspector: View {
    @Environment(OrbitStore.self) private var store
    var device: Device
    var state: OrbitState
    var select: (String) -> Void
    var onForget: (Device) -> Void
    @State private var name = ""
    @State private var notes = ""
    @State private var notesFor = ""  // which device the notes being edited belong to
    @FocusState private var notesFocused: Bool
    @State private var week: [UsageBar] = []
    @State private var merging = false
    @State private var separating: DeviceAlias?

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
                        HStack { StatusBadge(device: d); if d.isHidden { Text("Hidden").font(.caption).foregroundStyle(.secondary) } }
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
            if d.isNew, let same = state.device(d.maybeSame) {
                Section {
                    Label("It has the same name as \(same.name), which isn’t connected now. It may be the same device with a new address: phones make one up for each Wi-Fi network, and now and then a new one.", systemImage: "arrow.triangle.merge")
                    Button("Merge with \(same.name)…") { merging = true }
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
                        HStack { SignalBars(dbm: d.effSignal); Text("\(Signal(d.effSignal).word) (\(Int(d.signal ?? 0)) dBm)") }
                    }
                    if d.band == "2.4" {
                        Text("2.4 GHz reaches farther, so its signal is judged 6 dB more gently than 5 GHz.").font(.caption).foregroundStyle(.secondary)
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
            Section("Allowance") {
                AllowanceControls(allowance: d.allowance, subject: "it") { bytes, period in store.setAllowance(d.id, bytes: bytes, period: period) }
                    .id(d.id)
            }
            Section("Notes") {
                TextField("Notes", text: $notes, prompt: Text("Where it is, who to ask about it…"), axis: .vertical)
                    .lineLimit(2...6)
                    .labelsHidden()
                    .focused($notesFocused)
                    .onSubmit(saveNotes)
            }
            Section("Manage") {
                Toggle("Hide from lists", isOn: Binding(get: { d.isHidden }, set: { store.setHidden(d.id, $0) }))
                Text("A hidden device stays off the device list and the Overview. Orbit still records what it uses.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent {
                    Button("Merge…") { merging = true }
                } label: {
                    Text("Showing up twice?")
                    Text("Phones make up a new address now and then, and Orbit then sees a new device. Merge the two entries to count them as one.")
                }
                ForEach(d.aliases ?? []) { a in
                    LabeledContent {
                        Button("Separate…") { separating = a }
                    } label: {
                        Text(a.name ?? "No name")
                        Text("Merged in\(a.mac.map { " · " + $0.prefix(8) } ?? "")\(a.lastSeen.map { " · seen " + Format.ago($0, now: state.now) } ?? "")")
                    }
                }
                if !d.online {
                    Button("Forget This Device…", role: .destructive) { onForget(d) }
                }
            }
            Section {
                Text("Pausing and schedules are set in the Starlink app. Your router only accepts changes from there, and Orbit shows what you set.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: notesFocused) { _, focused in if !focused { saveNotes() } }
        .sheet(isPresented: $merging) {
            MergeSheet(device: d, state: state) { kept in select(kept) }.environment(store)
        }
        .confirmationDialog("Separate \(separating?.name ?? "this connection")?", isPresented: Binding(get: { separating != nil }, set: { if !$0 { separating = nil } })) {
            Button("Separate") {
                if let a = separating { store.separate(d.id, cid: a.cid) }
                separating = nil
            }
        } message: {
            Text("It becomes its own device again, so what it uses from now on counts separately. What it used so far stays with \(d.name).")
        }
        .task(id: d.id) {
            name = d.customName ?? d.name
            notes = d.notes ?? ""
            notesFor = d.id
            if let w: DeviceDays = try? await store.get("api/devices/\(d.id)/usage") { week = w.days }
        }
    }

    /// Saves to the device the text was typed for, even if you've just picked another one.
    private func saveNotes() {
        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notesFor.isEmpty, text != (state.device(notesFor)?.notes ?? "") else { return }
        store.setNotes(notesFor, to: text)
    }
}

/// A data allowance: what's used of it, and controls to set, change or remove it.
struct AllowanceControls: View {
    var allowance: Allowance?
    var subject: String  // "it" for a device, "them" for a person
    var save: (Double?, String) -> Void
    @State private var editing = false
    @State private var gb = 2.0
    @State private var period = "day"

    var body: some View {
        if editing {
            HStack {
                TextField("Amount", value: $gb, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 70)
                    .labelsHidden()
                    .onSubmit { if gb >= 0.01 { save(gb * 1e9, period); editing = false } }
                Text("GB")
                Picker("Per", selection: $period) {
                    Text("a day").tag("day")
                    Text("a month").tag("month")
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Button(allowance == nil ? "Set Allowance" : "Save") { save(gb * 1e9, period); editing = false }
                    .disabled(gb < 0.01)
                Button("Cancel") { editing = false }
                if allowance != nil {
                    Spacer()
                    Button("Remove", role: .destructive) { save(nil, period); editing = false }
                }
            }
        } else if let a = allowance {
            LabeledContent("\(Format.limit(a.bytes)) \(a.per)") {
                Button("Change") { gb = a.bytes / 1e9; period = a.period; editing = true }
            }
            VStack(alignment: .leading, spacing: 4) {
                AllowanceBar(allowance: a)
                HStack {
                    Text("\(Format.bytes(a.used)) of \(Format.limit(a.bytes)) used \(a.when)")
                    Spacer()
                    Text(a.used >= a.bytes ? "Used up" : "\(Format.bytes(a.bytes - a.used)) left")
                        .fontWeight(.semibold).foregroundStyle(a.fraction >= 1 ? .red : a.fraction >= 0.8 ? .orange : .green)
                }
                .font(.caption)
            }
        } else {
            LabeledContent {
                Button("Set…") { gb = 2; period = "day"; editing = true }
            } label: {
                Text("No allowance")
                Text("Give \(subject) an amount of data a day or a month. Orbit tells you when it’s nearly used up, and when it’s used up.")
            }
        }
        if allowance != nil || editing {
            Text("Orbit can’t cut \(subject) off, because your router only takes changes from the Starlink app. To pause \(subject == "it" ? "it" : "their devices"), use the app.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct AllowanceBar: View {
    var allowance: Allowance

    var body: some View {
        let f = allowance.fraction
        ShareBar(fraction: f, color: f >= 1 ? .red : f >= 0.8 ? .orange : .green)
            .help("\(Format.bytes(allowance.used)) of \(Format.limit(allowance.bytes)) used \(allowance.when)")
    }
}

/// Pick the other entry for the same device, and merge them.
struct MergeSheet: View {
    @Environment(OrbitStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var device: Device
    var state: OrbitState
    var done: (String) -> Void
    @State private var pick: String?
    @State private var busy = false

    var body: some View {
        let d = device
        let others = candidates
        let o = others.first { $0.id == pick && !clash($0) }
        VStack(alignment: .leading, spacing: 12) {
            Text("Merge \(d.name) with…").font(.title2.bold())
            Text("Pick the entry that’s the same device as \(d.name).").foregroundStyle(.secondary)
            List(others, selection: $pick) { x in
                HStack(spacing: 10) {
                    DeviceIcon(device: x, person: state.person(x.owner), size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(x.name).fontWeight(.semibold)
                            if sameName(x) { Text("SAME NAME").font(.caption2.bold()).foregroundStyle(Color.orbitAccent) }
                        }
                        Text(clash(x) ? "Also connected now, so it’s a different device"
                             : "\(state.person(x.owner)?.name ?? "No owner") · \(x.online ? "Connected now" : x.lastSeen.map { "Seen " + Format.ago($0, now: state.now) } ?? "Offline")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .opacity(clash(x) ? 0.5 : 1)
                .selectionDisabled(clash(x))
                .tag(x.id)
            }
            .frame(minHeight: 220)
            if let o { Text(preview(o)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") {
                    guard let o else { return }
                    busy = true
                    Task {
                        if let kept = await store.merge(d.id, with: o.id) { done(kept) }
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(o == nil || busy)
            }
        }
        .padding(20)
        .frame(width: 460, height: 520)
        .onAppear { pick = d.maybeSame }
    }

    private func names(_ x: Device) -> Set<String> {
        Set(([x.routerName, x.hostname] + (x.aliases ?? []).map(\.name)).compactMap { $0?.lowercased() })
    }
    private func sameName(_ x: Device) -> Bool { !names(x).isDisjoint(with: names(device)) }
    private func clash(_ x: Device) -> Bool { device.online && x.online }  // both connected at once: two devices

    private var candidates: [Device] {
        func score(_ x: Device) -> Int { (x.id == device.maybeSame ? 4 : 0) + (sameName(x) ? 2 : 0) + (x.type == device.type ? 1 : 0) }
        return state.devices.filter { $0.id != device.id }.sorted {
            (score($0), $0.online ? 0 : 1, $1.name) > (score($1), $1.online ? 0 : 1, $0.name)
        }
    }

    /// What the merged device will be, by the same rules as the server.
    private func preview(_ o: Device) -> String {
        let d = device
        let (base, extra) = (d.firstSeen ?? 0) <= (o.firstSeen ?? 0) ? (d, o) : (o, d)
        let keep = d.online || (!o.online && (d.lastSeen ?? 0) >= (o.lastSeen ?? 0)) ? d : o
        let final = base.customName ?? extra.customName ?? ((base.routerName ?? base.hostname) != nil ? base.name : keep.name)
        let owner = state.person(base.owner ?? extra.owner)
        return "They become one device, \(final)\(owner.map { ", owned by \($0.name)" } ?? ""), with both histories added together. Whichever one connects, Orbit counts it as \(final). You can separate them later, but the history stays combined."
    }
}
