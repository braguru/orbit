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
        if let s = store.state, store.connection == .live {
            if s.dish.online == true, let lat = s.dish.latencyMs {
                Label("\(Int(lat.rounded())) ms", systemImage: "antenna.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
            }
        } else {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
        }
    }
}

enum Page: String, CaseIterable, Identifiable {
    case overview = "Overview", devices = "Devices", people = "People", usage = "Usage", starlink = "Starlink", activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .overview: return "house"
        case .devices: return "laptopcomputer.and.iphone"
        case .people: return "person.2"
        case .usage: return "chart.bar.xaxis"
        case .starlink: return "antenna.radiowaves.left.and.right"
        case .activity: return "waveform.path.ecg"
        }
    }
}

struct MainView: View {
    @Environment(OrbitStore.self) private var store
    @Environment(\.openURL) private var openURL
    @SceneStorage("page") private var section: Page = .overview
    @State private var showSpeedTest = false

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            List(Page.allCases, selection: Binding(get: { section }, set: { if let v = $0 { section = v } })) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .badge(s == .devices ? store.state?.newDevices.count ?? 0 : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { RecordingFooter().padding(12) }
        } detail: {
            if let s = store.state {
                switch section {
                case .overview: OverviewView(state: s, section: $section)
                case .devices: DevicesView(state: s)
                case .people: PeopleView(state: s)
                case .usage: UsageView(state: s)
                case .starlink: StarlinkView(state: s, showSpeedTest: $showSpeedTest)
                case .activity: ActivityView(state: s)
                }
            } else {
                NotConnected()
            }
        }
        .toolbar {
            ToolbarItemGroup {
                ConnectionPill()
                Button { showSpeedTest = true } label: { Label("Speed test", systemImage: "speedometer") }
                    .help("Run a speed test")
                    .disabled(store.state == nil)
                Button { openURL(store.serverURL) } label: { Label("Open in browser", systemImage: "safari") }
                    .help("Open the web version")
            }
        }
        .sheet(isPresented: $showSpeedTest) { SpeedTestSheet().environment(store) }
        .task {
            guard let folder = Snapshot.folder else { return }
            try? await Task.sleep(for: .seconds(4))
            for page in Page.allCases {
                section = page
                try? await Task.sleep(for: .seconds(3))
                Snapshot.window(to: "\(folder)/\(page.rawValue.lowercased()).png")
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
