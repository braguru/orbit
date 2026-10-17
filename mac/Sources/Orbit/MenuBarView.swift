import AppKit
import ServiceManagement
import SwiftUI

/// The panel that opens from the menu bar: a quick look, without opening the window.
struct MenuBarView: View {
    @Environment(OrbitStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = store.state, store.connection == .live {
                let health = s.health
                HStack(spacing: 8) {
                    Circle().fill(health.tone.color).frame(width: 9, height: 9)
                    Text(health.title).font(.headline)
                }
                Text(health.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    mini("Latency", s.dish.latencyMs.map { "\(Int($0.rounded())) ms" } ?? "–")
                    mini("In use", "\(Format.mbps(s.dish.downMbps)) Mbps")
                    mini("Today", Format.bytes(s.home.down + s.home.up))
                }

                let top = s.connected.filter { $0.now > 0.05 }.sorted { $0.now > $1.now }.prefix(3)
                if !top.isEmpty {
                    Divider()
                    Text("Using the most").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(top)) { d in
                        HStack {
                            DeviceIcon(device: d, person: s.person(d.owner), size: 22)
                            Text(d.name).lineLimit(1)
                            Spacer()
                            Text("\(Format.mbps(d.downMbps)) Mbps").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                if s.speedtest.running {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(s.speedtest.phase == "up" ? "Testing upload… \(Format.mbps(s.speedtest.upNow ?? 0)) Mbps"
                             : "Testing download… \(Format.mbps(s.speedtest.downNow ?? 0)) Mbps").monospacedDigit()
                    }
                } else {
                    Button { store.runSpeedTest() } label: { Label("Run a speed test", systemImage: "speedometer") }
                        .disabled(s.dish.online != true || (s.tests.first.map { s.now - $0.ts < 60_000 } ?? false))
                    if let t = s.tests.first, t.error == nil, let down = t.down {
                        Text("Last: \(Int(down)) ↓ / \(Int(t.up ?? 0)) ↑ Mbps, \(Format.ago(t.ts, now: s.now))").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if store.server.canControl && !store.server.busy {
                    ServerStopButton().buttonStyle(.link).font(.caption)
                }
            } else {
                let server = store.server
                Label(server.busy ? server.phaseText : store.connection == .lost ? (server.canControl && !server.loaded ? "Orbit is stopped" : "Orbit’s server isn’t answering") : "Connecting to Orbit…",
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.headline)
                if store.connection == .lost && server.canControl {
                    ServerStartButton()
                    if let p = server.problem { Text(p).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                } else if store.connection == .lost {
                    Text(server.isLocal ? ServerText.notInstalled : ServerText.remote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()
            HStack {
                Button("Open Orbit") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o")
                Button("Open in browser") { openURL(store.serverURL) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func mini(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct SettingsView: View {
    @Environment(OrbitStore.self) private var store
    @AppStorage("serverURL") private var serverURL = "http://127.0.0.1:8787"
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            ServerSettingsSection()
            Section {
                TextField("Orbit server", text: $serverURL)
                    .onSubmit { store.connect() }
                Text("The Orbit server running on this Mac. Change it only if you run the server somewhere else.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Open Orbit when I log in", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            openAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Text("The server records in the background either way. This only opens this app and its menu bar icon.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
