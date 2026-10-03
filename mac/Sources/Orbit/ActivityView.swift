import SwiftUI

struct ActivityView: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    @State private var filter = "all"
    @State private var events: [Event] = []

    private let filters = [("all", "All"), ("security", "Security"), ("devices", "Devices"), ("network", "Starlink"), ("you", "Your changes")]

    var body: some View {
        let groups = Dictionary(grouping: events) { Calendar.current.startOfDay(for: Format.date($0.ts)) }
            .sorted { $0.key > $1.key }
        List {
            ForEach(groups, id: \.key) { day, items in
                SwiftUI.Section(dayLabel(day)) {
                    ForEach(items.sorted { $0.ts > $1.ts }) { e in
                        HStack(alignment: .top, spacing: 12) {
                            Text(Format.clock(e.ts)).font(.callout).foregroundStyle(.secondary).monospacedDigit().frame(width: 70, alignment: .leading)
                            Image(systemName: Icons.event(e.icon))
                                .foregroundStyle(e.tone == "warn" || e.tone == "crit" || e.cat == "security" ? .orange : e.tone == "good" ? .green : .secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(e.title).fontWeight(.medium)
                                if let d = e.detail { Text(d).font(.callout).foregroundStyle(.secondary) }
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .overlay { if events.isEmpty { ContentUnavailableView("Nothing here yet", systemImage: "clock") } }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) { ForEach(filters, id: \.0) { Text($0.1).tag($0.0) } }.pickerStyle(.menu)
            }
        }
        .navigationTitle("Activity")
        .task(id: "\(filter)-\(state.events.first?.id ?? 0)") {
            let query = filter == "all" ? "" : "&cat=\(filter)"
            if let list: [Event] = try? await store.get("api/events?limit=300\(query)") { events = list }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}

struct PeopleView: View {
    var state: OrbitState

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                ForEach(state.people) { p in card(name: p.name, color: Color.person(p.color), devices: state.devices.filter { $0.owner == p.id }) }
                let unowned = state.devices.filter { $0.owner == nil }
                if !unowned.isEmpty { card(name: "No owner yet", color: .orbitNone, devices: unowned) }
            }
            .padding(24)
            Text("Choose who owns a device from its details on the Devices page.").font(.caption).foregroundStyle(.secondary).padding(.bottom, 24)
        }
        .navigationTitle("People")
    }

    private func card(name: String, color: Color, devices: [Device]) -> some View {
        let live = devices.filter(\.online).reduce(0) { $0 + $1.downMbps }
        let today = devices.reduce(0) { $0 + $1.today }
        return Card(name, subtitle: "\(Format.plural(devices.count, "device")) · \(devices.filter(\.online).count) connected",
                    accessory: { Circle().fill(color).frame(width: 12, height: 12) }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading) { Text("Using now").font(.caption).foregroundStyle(.secondary); Text("\(Format.mbps(live)) Mbps").font(.title3.weight(.semibold)).monospacedDigit() }
                Spacer()
                VStack(alignment: .leading) { Text("Today").font(.caption).foregroundStyle(.secondary); Text(Format.bytes(today)).font(.title3.weight(.semibold)).monospacedDigit() }
                Spacer()
            }
            ForEach(devices) { d in
                HStack {
                    DeviceIcon(device: d, person: state.person(d.owner), size: 24)
                    Text(d.name).lineLimit(1)
                    Spacer()
                    StatusBadge(device: d)
                }
            }
        }
    }
}
