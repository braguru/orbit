import AppKit
import SwiftUI

@main
struct OrbitApp: App {
    @State private var store = OrbitStore()

    var body: some Scene {
        Window("Orbit", id: "main") {
            MainView()
                .environment(store)
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1200, height: 800)

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store)
        }
    }
}

/// In the menu bar: an antenna, and the latency while Starlink is online.
struct MenuBarLabel: View {
    var store: OrbitStore

    var body: some View {
        let m = store.menuLabel
        if let text = m.text {
            Label(text, systemImage: m.symbol).labelStyle(.titleAndIcon)
        } else {
            Image(systemName: m.symbol)
        }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", devices = "Devices", people = "People", usage = "Usage", starlink = "Starlink", security = "Security", floorPlan = "Floor plan", activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "house"
        case .devices: return "laptopcomputer.and.iphone"
        case .people: return "person.2"
        case .usage: return "chart.bar.xaxis"
        case .starlink: return "antenna.radiowaves.left.and.right"
        case .security: return "checkmark.shield"
        case .floorPlan: return "square.split.2x2"
        case .activity: return "waveform.path.ecg"
        }
    }
}

struct MainView: View {
    @Environment(OrbitStore.self) private var store
    @Environment(\.openURL) private var openURL
    @SceneStorage("page") private var section: Page = .overview
    @State private var showSpeedTest = false
    @State private var focusDevice: String?  // a device to show on the Devices page, picked elsewhere

    var body: some View {
        @Bindable var store = store
        @Bindable var server = store.server
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { section }, set: { if let v = $0 { section = v } })) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .badge(s == .devices ? store.state?.newDevices.count ?? 0 : s == .security ? store.state?.probeSourceCount ?? 0 : 0)
                    .badgeProminence(s == .security ? .increased : .standard)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { RecordingFooter().padding(12) }
        } detail: {
            if let s = store.state {
                switch section {
                case .overview: OverviewView(state: s, section: $section, open: { id in focusDevice = id; section = .devices })
                case .devices: DevicesView(state: s, focus: $focusDevice)
                case .people: PeopleView(state: s)
                case .usage: UsageView(state: s)
                case .starlink: StarlinkView(state: s, showSpeedTest: $showSpeedTest)
                case .security: SecurityView(state: s, open: { id in focusDevice = id; section = .devices })
                case .floorPlan: FloorPlanView(state: s, open: { id in focusDevice = id; section = .devices })
                case .activity: ActivityView(state: s)
                }
            } else {
                NotConnected()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ConnectionPill()
                ServerMenu()
                Button { showSpeedTest = true } label: { Label("Speed test", systemImage: "speedometer") }
                    .help("Run a speed test")
                    .disabled(store.state == nil)
                Button { openURL(store.serverURL) } label: { Label("Open in browser", systemImage: "safari") }
                    .help("Open the web version")
            }
        }
        .sheet(isPresented: $showSpeedTest) { SpeedTestSheet().environment(store) }
        .confirmationDialog("Stop the Orbit server?", isPresented: $server.askToStop, titleVisibility: .visible) {
            Button("Stop Orbit", role: .destructive) { Task { await store.server.stop() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(ServerText.stopWarning)
        }
        .task {
            // Development aid: ORBIT_START_PAGE=Security opens on that page, for measuring what a page costs at rest.
            if let start = ProcessInfo.processInfo.environment["ORBIT_START_PAGE"], let page = Page(rawValue: start) { section = page }
            guard let folder = Snapshot.folder else { return }
            try? await Task.sleep(for: .seconds(1))
            Snapshot.resizeWindow()
            try? await Task.sleep(for: .seconds(3))
            for page in Page.allCases {
                section = page
                try? await Task.sleep(for: .seconds(3))
                let name = page.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
                Snapshot.window(to: "\(folder)/\(name).png")
                if page == .starlink {  // the middle of the long page, too
                    Snapshot.scrollToEnd(fraction: 0.45)
                    try? await Task.sleep(for: .seconds(1))
                    Snapshot.window(to: "\(folder)/starlink-mid.png")
                }
                if (page == .devices && !Snapshot.devices.isEmpty) || page == .security || page == .floorPlan || page == .starlink {  // the rest of the inspector, too
                    Snapshot.scrollToEnd()
                    try? await Task.sleep(for: .seconds(1))
                    Snapshot.window(to: "\(folder)/\(name)-end.png")
                }
            }
            if let hold = ProcessInfo.processInfo.environment["ORBIT_SNAPSHOT_HOLD"], let page = Page(rawValue: hold) {
                section = page  // stay on this page, for measuring what it costs at rest
                return
            }
            NSApp.terminate(nil)
        }
        .alert("That didn’t work", isPresented: Binding(get: { store.lastError != nil }, set: { if !$0 { store.lastError = nil } })) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

struct ConnectionPill: View {
    @Environment(OrbitStore.self) private var store

    var body: some View {
        let s = store.state
        let (text, color): (String, Color) = store.connection != .live ? ("Not connected", .secondary)
            : s?.dish.reachable == false ? ("Can’t reach dish", .red)
            : s?.dish.online == false ? ("Starlink offline", .red)
            : ("Starlink online" + (s?.dish.latencyMs.map { " · \(Int($0.rounded())) ms" } ?? ""), .green)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.callout.weight(.medium)).monospacedDigit()
        }
        .padding(.horizontal, 10)
    }
}

struct RecordingFooter: View {
    @Environment(OrbitStore.self) private var store

    var body: some View {
        if let s = store.state {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Recording").font(.caption.weight(.semibold))
                }
                Text("A reading every second\(s.watchingSince.map { ", since " + Format.date($0).formatted(.dateTime.day().month()) } ?? "").")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
