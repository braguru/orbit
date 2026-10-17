import Foundation
import Observation

/// What ServerControl needs from the app: whether the live stream is flowing, a way to reconnect it,
/// and somewhere to say that the server was stopped on purpose.
@MainActor
protocol ServerHost: AnyObject {
    var serverURL: URL { get }
    /// The stream from the server is connected and its last message is fresh.
    var serverIsLive: Bool { get }
    func connect()
    /// Does anything answer at the server address? (Any reply counts, even "sign in".)
    func serverAnswers() async -> Bool
    /// The server was stopped on purpose: forget the picture it sent.
    func serverStopped()
    func showError(_ text: String)
}

/// Starts, stops and restarts the Orbit server, which runs on this Mac as a background service for your
/// user account (a LaunchAgent, set up with scripts/service.sh). The app asks macOS's launchctl to do it,
/// exactly as scripts/service.sh does, so the two always agree.
@MainActor @Observable
final class ServerControl {
    enum Phase: Equatable { case idle, starting, stopping, restarting }

    private(set) var phase = Phase.idle
    /// The background service has been set up (its launch file exists).
    private(set) var installed = false
    /// macOS has the service loaded: running, or about to run.
    private(set) var loaded = false
    /// The last thing that went wrong, until the next try.
    private(set) var problem: String?
    /// Set to show the window's "Stop the Orbit server?" question.
    var askToStop = false

    weak var host: ServerHost?
    let label: String
    private let domain = "gui/\(getuid())"

    /// `label` is for development: a throwaway service, so tests never touch the real one.
    init(label: String? = nil) {
        self.label = label ?? ProcessInfo.processInfo.environment["ORBIT_SERVICE_LABEL"] ?? "local.orbit.dashboard"
        installed = FileManager.default.fileExists(atPath: plist.path)
    }

    /// The service's launch file. Kept in Orbit's own folder, so macOS doesn't start it at login (it starts every
    /// file in LaunchAgents); the app starts it by path. A file in LaunchAgents (scripts/service.sh install --login)
    /// is used if it's there, and then Orbit also starts at login.
    private var plist: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let atLogin = home.appending(path: "Library/LaunchAgents/\(label).plist")
        if FileManager.default.fileExists(atPath: atLogin.path) { return atLogin }
        return home.appending(path: "Library/Application Support/Orbit/\(label).plist")
    }

    var busy: Bool { phase != .idle }

    /// The app can only manage a server on this Mac, and only once its background service is set up.
    var isLocal: Bool {
        guard let h = host?.serverURL.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(h)
    }
    var canControl: Bool { isLocal && installed }

    var phaseText: String {
        switch phase {
        case .idle: return ""
        case .starting: return "Starting Orbit…"
        case .stopping: return "Stopping Orbit…"
        case .restarting: return "Restarting Orbit…"
        }
    }

    func statusText(live: Bool) -> String {
        if busy { return phaseText }
        if live { return "Orbit is running" }
        return loaded ? "Orbit is loaded but not answering" : "Orbit is stopped"
    }

    /// The stream is flowing, so the service is certainly running. (Cheap: no launchctl.)
    func noteLive() { if !loaded { loaded = true } }

    func refresh() async {
        installed = FileManager.default.fileExists(atPath: plist.path)
        loaded = await Self.launchctl(["print", "\(domain)/\(label)"]).ok
    }

    // MARK: - actions

    /// "Start" when it's stopped, "Restart" when it's loaded but not answering.
    func startOrRestart() async {
        if loaded { await restart() } else { await start() }
    }

    func start() async {
        guard !busy, canControl else { return }
        phase = .starting
        problem = nil
        await refresh()
        let service = "\(domain)/\(label)"
        // A switch in System Settings > General > Login Items & Extensions can leave the service "disabled", and macOS
        // then refuses to load it ("Could not find service"). Pressing Start is the user asking for it, so allow it.
        _ = await Self.launchctl(["enable", service])
        var r = loaded ? await Self.launchctl(["kickstart", service]) : await Self.launchctl(["bootstrap", domain, plist.path])
        if !r.ok && !loaded {
            await refresh()
            if loaded { r = await Self.launchctl(["kickstart", service]) }  // it was loaded after all
        }
        guard r.ok else { return await fail("Couldn’t start Orbit. \(r.text)") }
        await waitUntilLive()
        phase = .idle
        await refresh()
    }

    func restart() async {
        guard !busy, canControl else { return }
        phase = .restarting
        problem = nil
        await refresh()
        guard loaded else { phase = .idle; return await start() }
        let r = await Self.launchctl(["kickstart", "-k", "\(domain)/\(label)"])
        guard r.ok else { return await fail("Couldn’t restart Orbit. \(r.text)") }
        // The old process has to go before the new one counts: wait for the address to stop answering.
        for _ in 0..<40 {
            if await host?.serverAnswers() != true { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await waitUntilLive()
        phase = .idle
        await refresh()
    }

    func stop() async {
        guard !busy else { return }
        phase = .stopping
        problem = nil
        let r = await Self.launchctl(["bootout", "\(domain)/\(label)"])
        if !r.ok {
            await refresh()
            if loaded { return await fail("Couldn’t stop Orbit. \(r.text)") }
        }
        // macOS tells the server to quit and it saves what it has first, which can take several seconds.
        // launchctl still lists the service until the process has gone, so wait for that.
        for _ in 0..<90 {
            await refresh()
            if !loaded { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if loaded { return await fail("Orbit was told to stop but is still saving. Give it a moment, then check again.") }
        if await host?.serverAnswers() == true {
            // The service's copy is gone but something still answers: a server started in a terminal, for instance.
            await fail("Orbit’s background service is stopped, but a server is still answering at \(host?.serverURL.absoluteString ?? "that address"). If you started it yourself in a terminal, stop it there.")
        } else {
            host?.serverStopped()
            phase = .idle
        }
    }

    // MARK: - helpers

    /// After a start: reconnect until the stream is flowing, or give up after a while.
    private func waitUntilLive(seconds: Int = 45) async {
        for i in 0..<seconds {
            if host?.serverIsLive == true { return }
            if i % 3 == 0 { host?.connect() }
            try? await Task.sleep(for: .seconds(1))
        }
        if host?.serverIsLive != true {
            await fail("Orbit was started but isn’t answering yet. Its log is at ~/Library/Logs/Orbit/orbit.log.")
        }
    }

    private func fail(_ text: String) async {
        problem = text
        phase = .idle
        host?.showError(text)
        await refresh()
    }

    /// Runs /bin/launchctl without blocking the app, and returns whether it succeeded and what it printed.
    nonisolated private static func launchctl(_ args: [String]) async -> (ok: Bool, text: String) {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = out
            do { try p.run() } catch { return (false, error.localizedDescription) }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return (p.terminationStatus == 0, text)
        }.value
    }
}
