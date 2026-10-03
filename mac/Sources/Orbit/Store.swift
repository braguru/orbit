import Foundation
import Observation

/// Talks to the Orbit server running on this Mac: a live stream of the whole picture every second,
/// plus a few requests. The server does the watching and keeps the history; this app only shows it.
@MainActor @Observable
final class OrbitStore {
    enum Connection { case connecting, live, lost }

    var state: OrbitState?
    var connection: Connection = .connecting
    var points: [Point] = []           // whole-home readings, last 2 minutes
    var deviceHistory: [String: [Double]] = [:]  // live Mbps per device, last minute
    var lastError: String?

    var serverURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "serverURL") ?? "") ?? URL(string: "http://127.0.0.1:8787")!
    }

    private var streamTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var lastMessage = Date.distantPast
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    init() {
        connect()
        // If the stream goes quiet (the server stopped, or the Mac slept), start it again.
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if Date().timeIntervalSince(self.lastMessage) > 8 {
                    if self.state != nil { self.connection = .lost }
                    self.connect()
                }
            }
        }
    }

    func connect() {
        streamTask?.cancel()
        lastMessage = Date()  // give the new connection a moment before calling it quiet
        streamTask = Task { [weak self] in await self?.stream() }
    }

    private func stream() async {
        if let pts: [Point] = try? await get("api/live") { merge(pts) }
        do {
            let (bytes, response) = try await session.bytes(from: url("api/stream"))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            for try await line in bytes.lines {
                guard line.hasPrefix("data: ") else { continue }
                apply(try decoder.decode(OrbitState.self, from: Data(line.dropFirst(6).utf8)))
            }
        } catch {
            if !Task.isCancelled && state == nil { connection = .lost }
        }
    }

    private func apply(_ s: OrbitState) {
        merge(s.points)
        for d in s.devices {
            var h = deviceHistory[d.id] ?? []
            h.append(d.online ? d.now : 0)
            deviceHistory[d.id] = Array(h.suffix(60))
        }
        state = s
        connection = .live
        lastMessage = Date()
    }

    private func merge(_ list: [Point]) {
        let newest = points.last?.t ?? 0
        points.append(contentsOf: list.filter { $0.t > newest })
        if points.count > 120 { points.removeFirst(points.count - 120) }
    }

    // MARK: - requests

    /// "api/usage?range=7d" against the server address. (URL.appending(path:) would escape the "?".)
    private func url(_ path: String) -> URL {
        URL(string: path, relativeTo: serverURL)?.absoluteURL ?? serverURL
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(from: url(path))
        try check(response, data)
        return try decoder.decode(T.self, from: data)
    }

    private func post(_ path: String, _ body: [String: Any]) async throws {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: req)
        try check(response, data)
    }

    private func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw NSError(domain: "Orbit", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: message ?? "The server said no (\(http.statusCode))."])
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { lastError = error.localizedDescription }
        }
    }

    func runSpeedTest() { run { try await self.post("api/speedtest", [:]) } }
    func rename(_ id: String, to name: String) { run { try await self.post("api/devices/\(id)", ["name": name]) } }
    func assign(_ id: String, to owner: String?) { run { try await self.post("api/devices/\(id)", ["owner": owner ?? NSNull()]) } }
    func setType(_ id: String, to type: String) { run { try await self.post("api/devices/\(id)", ["type": type]) } }
    func acknowledge(_ id: String) { run { try await self.post("api/devices/\(id)", ["acknowledged": true]) } }
}

// MARK: - what more than one screen needs

extension OrbitState {
    var connected: [Device] { devices.filter(\.online) }
    var active: [Device] { devices.filter(\.active) }
    var newDevices: [Device] { devices.filter(\.isNew) }
    var me: Person? { people.first { $0.id == "me" } }
    func person(_ id: String?) -> Person? { id.flatMap { id in people.first { $0.id == id } } }

    /// What "In use now" is measured against: the last speed test from the past 2 weeks, else the fastest reading seen.
    var capacity: (mbps: Double, label: String) {
        if let t = tests.first(where: { $0.error == nil && ($0.down ?? 0) > 0 && now - $0.ts < 14 * 86_400_000 }), let down = t.down {
            return (max(50, down.rounded()), "your last speed test")
        }
        return (max(50, (dish.fastestMbps ?? 0).rounded()), "the fastest seen this week")
    }

    var dropoutSeconds: Double { outages.reduce(0) { $0 + $1.durationS } }

    var health: (title: String, detail: String, tone: Tone) {
        if dish.reachable == false {
            return ("Orbit can’t reach your dish.", "It may be restarting, or a cable may be unplugged. Devices at home can still reach each other over Wi-Fi.", .bad)
        }
        if dish.online == false {
            return ("Starlink is offline right now.", "\(dish.outage?.text.map { $0 + ". " } ?? "")It usually comes back by itself within a minute.", .bad)
        }
        if router.reachable == false {
            return ("Orbit can’t reach your router.", "The device list may be out of date until the router answers again.", .warn)
        }
        if speedtest.running {
            return ("Testing your internet speed…", "The router is measuring download, then upload. It takes about 30 seconds.", .neutral)
        }
        let cap = capacity
        if dish.downMbps / cap.mbps > 0.85, let hog = connected.max(by: { $0.downMbps < $1.downMbps }), hog.downMbps > 1 {
            return ("Your internet is busy right now.", "\(hog.name) is using \(Format.mbps(hog.downMbps)) Mbps, close to \(cap.label).", .warn)
        }
        if let lat = dish.latencyMs, lat > 80 {
            return ("Your internet is responding slowly.", "Latency is \(Int(lat)) ms right now. Under 40 ms is normal for Starlink.", .warn)
        }
        let online = dish.onlineSince.map { " Starlink has been online for \(Format.duration(ms: now - $0))." } ?? ""
        return (newDevices.isEmpty ? "Everything’s running smoothly." : "Your internet is running smoothly.",
                "\(Format.plural(connected.count, "device")) connected, \(active.count) using the internet right now.\(online)", .good)
    }
}

enum Tone { case good, warn, bad, neutral }
