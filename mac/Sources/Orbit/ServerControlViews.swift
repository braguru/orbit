import SwiftUI

/// What stopping the server means, in the words used wherever the question is asked.
enum ServerText {
    static let stopWarning = "While it’s stopped, Orbit records nothing: no per-device usage, dropouts or alerts, and the tripwire stops watching. Start it again here whenever you like. Usage for the time it was off isn’t recorded."
    static let notInstalled = "Orbit’s background service isn’t set up on this Mac. Run scripts/service.sh install once, then you can start and stop it here."
    static let remote = "This app is set to use a server on another computer, so it can’t start or stop it."
}

/// "Start Orbit" when the server is stopped, "Restart Orbit" when it's loaded but not answering,
/// and progress while it works. Used on the empty screen and in the menu bar panel.
struct ServerStartButton: View {
    @Environment(OrbitStore.self) private var store

    var body: some View {
        let server = store.server
        if server.busy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(server.phaseText)
            }
        } else {
            Button { Task { await server.startOrRestart() } } label: {
                Label(server.loaded ? "Restart Orbit" : "Start Orbit", systemImage: server.loaded ? "arrow.clockwise" : "play.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// "Stop Orbit…" that asks once, in place, before it does anything. For the menu bar panel and Settings,
/// which have no window to hang a question on.
struct ServerStopButton: View {
    @Environment(OrbitStore.self) private var store
    @State private var asking = false

    var body: some View {
        let server = store.server
        if server.busy {
            EmptyView()
        } else if asking {
            VStack(alignment: .leading, spacing: 6) {
                Text(ServerText.stopWarning).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Stop Orbit", role: .destructive) { asking = false; Task { await server.stop() } }
                    Button("Cancel") { asking = false }
                }
            }
        } else {
            Button { asking = true } label: { Label("Stop Orbit…", systemImage: "stop.fill") }
        }
    }
}

/// The toolbar's power menu: what the server is doing, and start, restart or stop.
struct ServerMenu: View {
    @Environment(OrbitStore.self) private var store

    var body: some View {
        let server = store.server
        if server.canControl {
            Menu {
                Text(server.statusText(live: store.connection == .live))
                Divider()
                if !server.busy {
                    if store.connection == .live || server.loaded {
                        Button("Restart Orbit") { Task { await server.restart() } }
                        Button("Stop Orbit…") { server.askToStop = true }
                    } else {
                        Button("Start Orbit") { Task { await server.start() } }
                    }
                }
            } label: {
                Label("Orbit server", systemImage: server.busy ? "hourglass" : "power")
            }
            .help("Start, stop or restart the Orbit server")
        }
    }
}

/// The server section of Settings.
struct ServerSettingsSection: View {
    @Environment(OrbitStore.self) private var store

    var body: some View {
        let server = store.server
        Section("Orbit server") {
            LabeledContent("Status", value: server.statusText(live: store.connection == .live))
            if server.canControl {
                if server.busy {
                    ServerStartButton()  // shows the progress
                } else if store.connection == .live {
                    Button { Task { await server.restart() } } label: { Label("Restart Orbit", systemImage: "arrow.clockwise") }
                    ServerStopButton()
                } else {
                    ServerStartButton()
                }
                if let p = server.problem { Text(p).font(.caption).foregroundStyle(.red) }
            } else {
                Text(server.isLocal ? ServerText.notInstalled : ServerText.remote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
