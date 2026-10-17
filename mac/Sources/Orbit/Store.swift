import Foundation
import Observation

/// Talks to the Orbit server running on this Mac: a live stream of the whole picture every second,
/// plus a few requests. The server does the watching and keeps the history; this app only shows it.
/// The menu bar item: an antenna, and the latency while Starlink is online.
struct MenuLabel: Equatable {
    var symbol: String
    var text: String?

    static let offline = MenuLabel(symbol: "antenna.radiowaves.left.and.right.slash", text: nil)

    init(symbol: String, text: String?) { self.symbol = symbol; self.text = text }

    init(state: OrbitState?, live: Bool) {
        if live, let s = state, s.dish.online == true, let lat = s.dish.latencyMs {
            self.init(symbol: "antenna.radiowaves.left.and.right", text: "\(Int(lat.rounded())) ms")
        } else {
            self = .offline
        }
    }
}

@MainActor @Observable
final class OrbitStore {
    enum Connection { case connecting, live, lost }

    var state: OrbitState?
    var connection: Connection = .connecting
    var points: [Point] = []           // whole-home readings, last 2 minutes
    var deviceHistory: [String: [Double]] = [:]  // live Mbps per device, last minute
    var lastError: String?
    /// Starts and stops the server (the background service) from this app.
    let server = ServerControl()
    /// What the menu bar shows. Kept apart from `state` so the status item is redrawn only when this changes:
    /// macOS redraws a status item as a picture each time, which cost more than everything else the app did.
    private(set) var menuLabel = MenuLabel.offline

    var serverURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "serverURL") ?? "") ?? URL(string: "http://127.0.0.1:8787")!
    }

    private var menuLabelAt = Date.distantPast
    private var streamTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var lastMessage = Date.distantPast
    private var lastEventID: Int?          // the newest activity entry seen, so only new ones notify
    private var askedToNotify = false
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
        server.host = self
        Task { await server.refresh() }
        connect()
        // If the stream goes quiet (the server stopped, or the Mac slept), start it again.
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if Date().timeIntervalSince(self.lastMessage) > 8 {
                    if self.state != nil { self.markLost() }
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
            if !Task.isCancelled && state == nil { markLost() }
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
        server.noteLive()
        refreshMenuLabel()
        notify(s)
    }

    /// The stream stopped. Ask macOS once whether the background service is loaded, so the app can offer to start it.
    private func markLost() {
        guard connection != .lost else { return }
        connection = .lost
        refreshMenuLabel()
        Task { await server.refresh() }
    }

    /// The latency in the menu bar moves a few milliseconds every second, so it refreshes every few seconds;
    /// anything bigger (going offline, coming back, the connection dropping) shows at once.
    func refreshMenuLabel() {
        let next = MenuLabel(state: state, live: connection == .live)
        guard next != menuLabel else { return }
        let sameKind = next.symbol == menuLabel.symbol
        if sameKind, Date().timeIntervalSince(menuLabelAt) < 5 { return }
        menuLabel = next
        menuLabelAt = Date()
    }

    /// A Mac notification when a device or person uses up most or all of their allowance.
    /// Only for entries that arrive while the app runs: what was there when it connected isn't news.
    private func notify(_ s: OrbitState) {
        if !askedToNotify, Snapshot.folder == nil,
           s.devices.contains(where: { $0.allowance != nil }) || s.people.contains(where: { $0.allowance != nil })
            || s.security?.tripwire?.on == true {
            askedToNotify = true
            Notifier.prepare()
        }
        let newest = s.events.map(\.id).max() ?? 0
        if let last = lastEventID, askedToNotify {
            for e in s.events.sorted(by: { $0.id < $1.id }) where e.id > last && Notifier.worthAlerting(e) { Notifier.post(e) }
        }
        lastEventID = max(lastEventID ?? 0, newest)
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

    @discardableResult
    private func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        try await post(path, json: try JSONSerialization.data(withJSONObject: body))
    }

    @discardableResult
    private func post(_ path: String, json: Data) async throws -> Data {
        var req = URLRequest(url: url(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = json
        let (data, response) = try await session.data(for: req)
        try check(response, data)
        return data
    }

    private func delete(_ path: String) async throws {
        var req = URLRequest(url: url(path))
        req.httpMethod = "DELETE"
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

    /// The floor plan lives on the Orbit server, so the web page and this app share it. Orbit only keeps its own
    /// drawing there: nothing is ever sent to the dish or the router.
    func fetchPlan() async throws -> PlanReply { try await get("api/plan") }

    /// Keeps the plan and answers with its new revision. A refusal (the server says why) is thrown.
    func savePlan(_ plan: FloorPlan) async throws -> Int {
        let data = try await post("api/plan", json: try JSONEncoder().encode(plan))
        return try decoder.decode(PlanSaved.self, from: data).rev
    }

    /// The tripwire: Orbit listens on a few doors of this Mac and notes who knocks.
    func setTripwire(_ on: Bool) { run { try await self.post("api/security/tripwire", ["on": on]) } }
    func runSpeedTest() { run { try await self.post("api/speedtest", [:]) } }
    func rename(_ id: String, to name: String) { run { try await self.post("api/devices/\(id)", ["name": name]) } }
    func assign(_ id: String, to owner: String?) { run { try await self.post("api/devices/\(id)", ["owner": owner ?? NSNull()]) } }
    func setType(_ id: String, to type: String) { run { try await self.post("api/devices/\(id)", ["type": type]) } }
    func acknowledge(_ id: String) { run { try await self.post("api/devices/\(id)", ["acknowledged": true]) } }
    func setNotes(_ id: String, to notes: String) { run { try await self.post("api/devices/\(id)", ["notes": notes]) } }
    func setHidden(_ id: String, _ hidden: Bool) { run { try await self.post("api/devices/\(id)", ["hidden": hidden]) } }
    func separate(_ id: String, cid: String) { run { try await self.delete("api/devices/\(id)/aliases/\(cid)") } }
    func forget(_ ids: [String]) { run { try await self.post("api/devices/forget", ["ids": ids]) } }

    /// bytes nil removes the allowance. period: "day" or "month".
    func setAllowance(_ id: String, bytes: Double?, period: String) {
        run { try await self.post("api/devices/\(id)", ["allowance": Self.allowance(bytes, period)]) }
    }
    func setPersonAllowance(_ pid: String, bytes: Double?, period: String) {
        run { try await self.post("api/people/\(pid)", ["allowance": Self.allowance(bytes, period)]) }
    }
    private static func allowance(_ bytes: Double?, _ period: String) -> Any {
        bytes.map { ["bytes": $0.rounded(), "period": period] as [String: Any] } ?? NSNull()
    }

    /// The same change to several devices, such as ["owner": "me"] or ["hidden": true].
    func bulk(_ ids: [String], _ fields: [String: Any]) {
        let changes: [[String: Any]] = ids.map { id in fields.merging(["id": id]) { _, new in new } }
        run { try await self.post("api/devices/bulk", ["changes": changes]) }
    }

    /// Two entries for the same device become one. Returns the id the device keeps.
    func merge(_ id: String, with other: String) async -> String? {
        do {
            let data = try await post("api/devices/\(id)/merge", ["other": other])
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}

// MARK: - what more than one screen needs

extension OrbitState {
    var connected: [Device] { devices.filter(\.online) }
    func device(_ id: String?) -> Device? { id.flatMap { id in devices.first { $0.id == id } } }
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

    // MARK: security

    /// Contact attempts from the past hour count as happening now.
    static let probeWindow = 3_600_000.0
    var activeProbes: [Probe] { (security?.probes ?? []).filter { $0.known != true && now - $0.last < Self.probeWindow }.sorted { $0.last > $1.last } }
    /// Known devices that talked to this Mac in the past hour. Allowed, so shown calmly and never as an alert.
    var friendlyProbes: [Probe] { (security?.probes ?? []).filter { $0.known == true && now - $0.last < Self.probeWindow }.sorted { $0.last > $1.last } }

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

// MARK: - ServerHost

extension OrbitStore: ServerHost {
    var serverIsLive: Bool { connection == .live && Date().timeIntervalSince(lastMessage) < 3 }

    func serverAnswers() async -> Bool {
        var req = URLRequest(url: url("api/session"))
        req.timeoutInterval = 2
        do { _ = try await session.data(for: req); return true } catch { return false }
    }

    /// The server was stopped from this app: show the "stopped" screen rather than a stale picture.
    func serverStopped() {
        streamTask?.cancel()
        state = nil
        points = []
        deviceHistory = [:]
        connection = .lost
        refreshMenuLabel()
    }

    func showError(_ text: String) { lastError = text }
}
