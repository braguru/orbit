import Foundation

// The shapes of the Orbit server's JSON (/api/state, /api/usage, ...). Keys arrive in snake_case
// and are decoded with .convertFromSnakeCase, so `latency_ms` becomes `latencyMs`.
// Times are milliseconds since 1970, speeds Mbps, data bytes.

struct OrbitState: Decodable {
    var now: Double
    var started: Double
    var watchingSince: Double?
    var dish: Dish
    var router: Router
    var home: Home
    var points: [Point]
    var devices: [Device]
    var people: [Person]
    var events: [Event]
    var outages: [Outage]
    var speedtest: SpeedTestStatus
    var tests: [SpeedTest]
    var security: Security?  // optional: an older server doesn't send it
    var planRev: Int?        // changes whenever any window saves the floor plan
}

struct Dish: Decodable {
    var reachable: Bool?
    var online: Bool?
    var outage: DishOutage?
    var latencyMs: Double?
    var dropRate: Double?
    var downMbps: Double
    var upMbps: Double
    var uptimeS: Double?
    var onlineSince: Double?
    var obstructed: Double?
    var obstructedNow: Bool?
    var alerts: [DishAlert]
    var powerW: Double?
    var fastestMbps: Double?
    var hardware: String?
    var software: String?
    var actuated: Bool?
    var ethMbps: Double?
    var snowMelt: String?
    var updateHour: Double?
    var sleep: SleepSchedule?
    var dlLimit: String?
    var updateState: String?
    var updateReady: Bool?
    var updateWaitS: Double?
    var deferral: Bool?
    var rebootReason: String?
    var pointing: DishPointing?
    var gps: DishGps?
    var check: DishCheck?
}

struct DishPointing: Decodable { var az: Double?; var el: Double?; var wantAz: Double?; var wantEl: Double?; var tilt: Double?; var uncertainty: Double?; var settled: Bool? }
struct DishGps: Decodable { var valid: Bool?; var sats: Int? }
struct DishCheck: Decodable { var selfTest: String?; var codes: [String]?; var disablement: String?; var stowed: Bool? }

struct DishOutage: Decodable { var cause: String; var since: Double?; var text: String? }
struct DishAlert: Decodable, Identifiable { var key: String; var text: String; var tone: String; var id: String { key } }
struct SleepSchedule: Decodable { var on: Bool; var startMin: Double?; var durationMin: Double? }

struct Router: Decodable {
    var reachable: Bool?
    var hardware: String?
    var software: String?
    var uptimeS: Double?
    var bypass: Bool?
    var networks: [WifiNetwork]
    var settings: RouterSettings?
    var link: RouterLink?
    var update: RouterUpdate?
}

struct RouterSettings: Decodable {
    var country: String?
    var dns: DnsSettings?
    var bypass: Bool?
    var apMode: Bool?
    var repeater: Bool?
    var dfs: Bool?
    var meshOnboarding: Bool?
    var channels: [String: Double]?
    var widths: [String: Double?]?
    var autoSpeedtests: Bool?
    var publicServices: Bool?

    // The keys arrive as "5_upper", which the snake-case decoding may rewrite to "5Upper".
    func channel(_ key: String) -> Double? { channels?[key] ?? channels?[key.replacingOccurrences(of: "_upper", with: "Upper")] }
    func width(_ key: String) -> Double? { (widths?[key] ?? widths?[key.replacingOccurrences(of: "_upper", with: "Upper")]) ?? nil }
}

struct DnsSettings: Decodable { var servers: [String]?; var custom: Bool?; var secure: Bool? }

struct RouterLink: Decodable {
    var internetMs: Double?
    var dishMs: Double?
    var popMs: Double?
    var internetDrop5M: Double?
    var dishDrop5M: Double?
    var popDrop5M: Double?
    var noWanLink: Bool?
    var publicIpAgeS: Double?
    var poe: PoeStatus?
}

struct PoeStatus: Decodable { var on: Bool?; var powerW: Double?; var faults: Int? }
struct RouterUpdate: Decodable { var state: String?; var running: String?; var pending: String?; var progress: Double? }





struct WifiNetwork: Decodable, Identifiable {
    var domain: String
    var guest: Bool
    var isolated: Bool?
    var subnet: String?
    var ssids: [String: String]
    var open: Bool?       // no password
    var enabled: Bool?
    var security: String?  // open, wpa2, wpa3, wpa, ...
    var hidden: Bool?
    var id: String { domain }
    /// The network's name: its first SSID, in a steady order.
    var name: String { ssids.sorted { $0.key < $1.key }.first?.value ?? (guest ? "Guest Wi-Fi" : "Main Wi-Fi") }
    var isOn: Bool { enabled != false }
}

/// What the tripwire on this Mac has seen, and what it watches for.
struct Security: Decodable {
    var tripwire: Tripwire?
    var probes: [Probe]?
}

struct Tripwire: Decodable {
    var on: Bool
    var running: Bool?
    var since: Double?
    var listening: [Door]?
    var busy: [Door]?
    var dropped: Int?
    var hostIp: String?
    var hostDevice: String?
}

struct Door: Decodable, Identifiable, Hashable { var port: Int; var label: String?; var id: Int { port } }

/// Someone (a device, or an address with no device) that tried the tripwire's doors.
struct Probe: Decodable, Identifiable {
    var ip: String
    var device: String?
    var name: String?
    var network: String?   // main, guest or outside
    var domain: String?
    var first: Double?
    var last: Double
    var tries: Int?
    var scan: Bool?
    var known: Bool?       // a known device on the main Wi-Fi: allowed to talk to this Mac, so only a note
    var ports: [ProbePort]?
    var id: String { ip }
}

struct ProbePort: Decodable, Identifiable, Hashable { var port: Int; var label: String?; var tries: Int?; var id: Int { port } }

struct Home: Decodable { var day: String; var down: Double; var up: Double }

struct Point: Decodable, Identifiable {
    var t: Double
    var down: Double
    var up: Double
    var lat: Double?
    var id: Double { t }
}

struct Device: Decodable, Identifiable, Hashable {
    var id: String
    var mac: String?
    var name: String
    var customName: String?
    var routerName: String?
    var hostname: String?
    var owner: String?
    var type: String
    var online: Bool
    var since: Double?
    var firstSeen: Double?
    var lastSeen: Double?
    var ip: String?
    var band: String?
    var network: String?
    var domain: String?
    var ssid: String?
    var signal: Double?
    var downMbps: Double
    var upMbps: Double
    var rateDown: Double?
    var rateUp: Double?
    var todayDown: Double
    var todayUp: Double
    var isNew: Bool
    var blocked: Bool?
    var schedules: Int?
    var privateMac: Bool?
    var typeSet: Bool?
    var notes: String?
    var hidden: Bool?
    var allowance: Allowance?
    var aliases: [DeviceAlias]?
    var maybeSame: String?  // for a new device: a known one with the same name, probably it with a new address

    var today: Double { todayDown + todayUp }
    var now: Double { downMbps + upMbps }
    var active: Bool { online && now > 0.15 }
    var isHidden: Bool { hidden == true }
}

/// Another client ID merged into a device: the same phone with a new private address, or on the guest Wi-Fi.
struct DeviceAlias: Decodable, Identifiable, Hashable {
    var cid: String
    var name: String?
    var mac: String?
    var lastSeen: Double?
    var id: String { cid }
}

/// A data allowance and what's used of it this period. period: "day" or "month". level: 0, 80 or 100.
struct Allowance: Decodable, Hashable {
    var bytes: Double
    var period: String
    var used: Double
    var level: Int?

    var fraction: Double { bytes > 0 ? used / bytes : 0 }
    var per: String { period == "month" ? "a month" : "a day" }
    var when: String { period == "month" ? "this month" : "today" }
}

struct Person: Decodable, Identifiable, Hashable { var id: String; var name: String; var color: String; var allowance: Allowance? }

struct Event: Decodable, Identifiable {
    var id: Int
    var ts: Double
    var cat: String
    var icon: String
    var title: String
    var detail: String?
    var device: String?
    var tone: String?
}

struct Outage: Decodable, Identifiable {
    var start: Double
    var durationS: Double
    var cause: String
    var text: String
    var id: Double { start }
}

struct SpeedTestStatus: Decodable {
    var running: Bool
    var phase: String?
    var downNow: Double?
    var upNow: Double?
    var result: SpeedTest?
}

struct SpeedTest: Decodable, Identifiable {
    var ts: Double
    var down: Double?
    var up: Double?
    var downPeak: Double?
    var upPeak: Double?
    var latency: Double?
    var error: String?
    var errorText: String?
    var id: Double { ts }
}

struct Usage: Decodable {
    var range: String
    var bars: [UsageBar]
    var speed: [UsageSpeed]
    var bucketS: Double
    var total: Traffic
    var devices: [UsageDevice]
    var outages: OutageStats
    var recordedS: Double
    var rangeS: Double
}

struct UsageBar: Decodable, Identifiable { var t: Double; var down: Double; var up: Double; var id: Double { t } }
struct UsageSpeed: Decodable, Identifiable { var t: Double; var down: Double?; var downMax: Double?; var up: Double?; var lat: Double?; var id: Double { t } }
struct Traffic: Decodable { var down: Double; var up: Double }
struct UsageDevice: Decodable, Identifiable { var id: String; var name: String; var owner: String?; var type: String; var down: Double; var up: Double }
struct OutageStats: Decodable { var count: Int; var seconds: Double }
struct DeviceDays: Decodable { var days: [UsageBar] }

struct ObstructionMap: Decodable {
    var rows: Int
    var cols: Int
    var snr: [Double]
    var maxThetaDeg: Double?
    var updated: Double?
}


// MARK: - floor plan

// The floor plan the user draws (walls, room names, where the router and devices sit), kept by the server at
// /api/plan so the web page and this app share it. Units are metres. The signal model below is the same one the
// web page uses, number for number: change one and the other must change too.

struct PlanPoint: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
}

struct PlanWall: Codable, Equatable, Identifiable {
    var id: String
    var a: PlanPoint
    var b: PlanPoint
    var mat: String  // drywall, glass, brick, concrete or metal

    init(id: String, a: PlanPoint, b: PlanPoint, mat: String) { self.id = id; self.a = a; self.b = b; self.mat = mat }

    // The server writes a point of a wall as [x, y].
    private enum Keys: String, CodingKey { case id, a, b, mat }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func point(_ key: Keys) throws -> PlanPoint {
            let v = try c.decode([Double].self, forKey: key)
            guard v.count == 2 else { throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "A point needs two numbers") }
            return PlanPoint(x: v[0], y: v[1])
        }
        id = try c.decode(String.self, forKey: .id)
        a = try point(.a)
        b = try point(.b)
        mat = try c.decode(String.self, forKey: .mat)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode([a.x, a.y], forKey: .a)
        try c.encode([b.x, b.y], forKey: .b)
        try c.encode(mat, forKey: .mat)
    }

    var material: PlanMaterial { PlanMaterial(rawValue: mat) ?? .drywall }
    var length: Double { hypot(b.x - a.x, b.y - a.y) }
}

struct PlanRoom: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var x: Double
    var y: Double
}

struct FloorPlan: Codable, Equatable {
    static let sizeRange = 4.0...40.0
    static let defaultSize = (w: 12.0, h: 8.0)

    var v = 1
    var w = FloorPlan.defaultSize.w
    var h = FloorPlan.defaultSize.h
    var router = PlanPoint(x: 6, y: 4)
    var walls: [PlanWall] = []
    var rooms: [PlanRoom] = []
    var devices: [String: PlanPoint] = [:]  // a saved spot for each device id

    init() {}

    // Missing parts take their usual value and unknown fields are ignored, so a newer server doesn't break this app.
    // A part that is there but wrong fails the whole read: better no plan on screen than one saved back with a hole in it.
    private enum Keys: String, CodingKey { case v, w, h, router, walls, rooms, devices }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        w = try c.decodeIfPresent(Double.self, forKey: .w) ?? Self.defaultSize.w
        h = try c.decodeIfPresent(Double.self, forKey: .h) ?? Self.defaultSize.h
        w = min(max(w, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        h = min(max(h, Self.sizeRange.lowerBound), Self.sizeRange.upperBound)
        router = try c.decodeIfPresent(PlanPoint.self, forKey: .router) ?? PlanPoint(x: w / 2, y: h / 2)
        walls = try c.decodeIfPresent([PlanWall].self, forKey: .walls) ?? []
        rooms = try c.decodeIfPresent([PlanRoom].self, forKey: .rooms) ?? []
        devices = try c.decodeIfPresent([String: PlanPoint].self, forKey: .devices) ?? [:]
    }

    /// Four outer brick walls half a metre in from the edge, and the router in the middle.
    static func outline(w: Double, h: Double) -> FloorPlan {
        var p = FloorPlan()
        p.w = w
        p.h = h
        p.router = PlanPoint(x: (w / 2 * 10).rounded() / 10, y: (h / 2 * 10).rounded() / 10)
        let (x0, y0, x1, y1) = (0.5, 0.5, w - 0.5, h - 0.5)
        let corners = [PlanPoint(x: x0, y: y0), PlanPoint(x: x1, y: y0), PlanPoint(x: x1, y: y1), PlanPoint(x: x0, y: y1)]
        p.walls = (0..<4).map { PlanWall(id: "w\($0 + 1)", a: corners[$0], b: corners[($0 + 1) % 4], mat: "brick") }
        return p
    }

    /// Keeps every wall, name, the router and each device inside the plan (after the house shrinks).
    mutating func clampInside() {
        func clamp(_ p: PlanPoint, inset: Double = 0) -> PlanPoint {
            PlanPoint(x: min(max(p.x, inset), max(inset, w - inset)), y: min(max(p.y, inset), max(inset, h - inset)))
        }
        router = clamp(router, inset: 0.2)
        for i in walls.indices { walls[i].a = clamp(walls[i].a); walls[i].b = clamp(walls[i].b) }
        walls.removeAll { $0.length < 0.05 }  // a wall squeezed to nothing
        for i in rooms.indices { let p = clamp(PlanPoint(x: rooms[i].x, y: rooms[i].y)); rooms[i].x = p.x; rooms[i].y = p.y }
        devices = devices.mapValues { clamp($0, inset: 0.2) }
    }
}

/// What GET /api/plan answers: the plan (nil until one is saved) and its revision.
struct PlanReply: Decodable {
    var plan: FloorPlan?
    var rev: Int
}

struct PlanSaved: Decodable { var rev: Int }

enum PlanMaterial: String, CaseIterable, Identifiable {
    case drywall, glass, brick, concrete, metal
    var id: String { rawValue }

    var name: String {
        switch self {
        case .drywall: return "Plasterboard"
        case .glass: return "Glass"
        case .brick: return "Brick"
        case .concrete: return "Concrete"
        case .metal: return "Metal or mirror"
        }
    }

    /// Decibels a wall takes off the signal: [2.4 GHz, 5 GHz].
    var loss: (ghz24: Double, ghz5: Double) {
        switch self {
        case .drywall: return (3, 4)
        case .glass: return (2, 3)
        case .brick: return (7, 10)
        case .concrete: return (11, 15)
        case .metal: return (12, 16)
        }
    }

    func loss(band: String) -> Double { band == "2.4" ? loss.ghz24 : loss.ghz5 }
}

enum PlanVerdict {
    case stronger, matches, little, much

    var word: String {
        switch self {
        case .stronger: return "Stronger than the plan says"
        case .matches: return "Matches the plan"
        case .little: return "A little weak"
        case .much: return "Much weaker than the plan says"
        }
    }

    var icon: String {
        switch self {
        case .stronger: return "arrow.up"
        case .matches: return "checkmark.circle"
        case .little: return "exclamationmark.circle"
        case .much: return "exclamationmark.triangle"
        }
    }
}

enum PlanMath {
    /// Signal one metre from the router before any tuning, per band, in dBm.
    static let p1: [String: Double] = ["2.4": -38, "5": -44]
    /// Orbit tunes its guess with the devices on the plan, so it wants at least this many.
    static let minDevices = 3

    /// Whether the line p to q properly crosses the wall a to b (touching an end doesn't count).
    static func crosses(_ p: PlanPoint, _ q: PlanPoint, _ a: PlanPoint, _ b: PlanPoint) -> Bool {
        func cr(_ o: PlanPoint, _ u: PlanPoint, _ v: PlanPoint) -> Double { (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x) }
        let d1 = cr(p, q, a), d2 = cr(p, q, b), d3 = cr(a, b, p), d4 = cr(a, b, q)
        return d1 * d2 < 0 && d3 * d4 < 0
    }

    static func crossed(_ walls: [PlanWall], from p: PlanPoint, to q: PlanPoint) -> [PlanWall] {
        walls.filter { crosses(p, q, $0.a, $0.b) }
    }

    /// What the plan predicts at p, in dBm: the signal at one metre, plus the tuning, minus 20 log10 of the distance
    /// (never closer than a metre), minus what every wall in the way takes off.
    static func model(_ p: PlanPoint, band: String, extraDb: Double, router: PlanPoint, walls: [PlanWall]) -> Double {
        let d = max(1, hypot(p.x - router.x, p.y - router.y))
        let lost = crossed(walls, from: router, to: p).reduce(0) { $0 + $1.material.loss(band: band) }
        return (p1[band] ?? p1["5"]!) + extraDb - 20 * log10(d) - lost
    }

    /// The middle value; with an even count, the upper of the two middle ones (as the web page does).
    static func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }

    static func verdict(gap: Double) -> PlanVerdict {
        gap >= 5 ? .stronger : gap >= -5 ? .matches : gap >= -10 ? .little : .much
    }

    /// 0 weak, 1 fair, 2 good, 3 excellent: the same steps as the device signal words.
    static func level(_ dbm: Double) -> UInt8 { dbm >= -55 ? 3 : dbm >= -63 ? 2 : dbm >= -70 ? 1 : 0 }

    static func dBm(_ v: Double) -> String { "−\(abs(Int(v.rounded())))" }
    static func dB(_ v: Double) -> String {
        let n = Int(v.rounded())
        return (n > 0 ? "+" : n < 0 ? "−" : "") + String(abs(n))
    }
}

/// A Wi-Fi device as the model needs it.
struct PlanInput {
    var id: String
    var band: String
    var signal: Double
}

/// One device that has a spot on the plan: what it measures, what the plan predicts, and the gap.
struct PlanReading: Identifiable {
    var id: String
    var band: String
    var pos: PlanPoint
    var measured: Double
    var distance: Double
    var crossed: [PlanWall]
    var expected: Double
    var gap: Double
    var verdict: PlanVerdict?  // only once there are enough devices to tune the guess
}

struct PlanAnalysis {
    var readings: [PlanReading]
    var offset: Double  // how far the plan's first guess is tuned, in dB (0 until there are enough devices)
    var tuned: Bool { readings.count >= PlanMath.minDevices }

    func reading(_ id: String) -> PlanReading? { readings.first { $0.id == id } }
    /// Devices clearly weaker than the plan says, the worst first.
    var problems: [PlanReading] { readings.filter { $0.verdict != nil && $0.gap < -5 }.sorted { $0.gap < $1.gap } }

    static func make(plan: FloorPlan, devices: [Device]) -> PlanAnalysis {
        make(plan: plan, inputs: devices.filter(\.onPlan).map { PlanInput(id: $0.id, band: $0.band ?? "5", signal: $0.signal ?? 0) })
    }

    static func make(plan: FloorPlan, inputs: [PlanInput]) -> PlanAnalysis {
        let placed = inputs.compactMap { i in plan.devices[i.id].map { (i, $0) } }.sorted { $0.0.id < $1.0.id }
        let tuned = placed.count >= PlanMath.minDevices
        let offset = tuned ? PlanMath.median(placed.map { i, p in
            i.signal - PlanMath.model(p, band: i.band, extraDb: 0, router: plan.router, walls: plan.walls)
        }) : 0
        let readings = placed.map { i, p -> PlanReading in
            let expected = PlanMath.model(p, band: i.band, extraDb: offset, router: plan.router, walls: plan.walls)
            let gap = i.signal - expected
            return PlanReading(id: i.id, band: i.band, pos: p, measured: i.signal,
                               distance: hypot(p.x - plan.router.x, p.y - plan.router.y),
                               crossed: PlanMath.crossed(plan.walls, from: plan.router, to: p),
                               expected: expected, gap: gap, verdict: tuned ? PlanMath.verdict(gap: gap) : nil)
        }
        return PlanAnalysis(readings: readings, offset: offset)
    }
}

extension Device {
    /// A device the floor plan can say something about: online, shown, on 2.4 or 5 GHz Wi-Fi, with a signal reading.
    var onPlan: Bool { online && !isHidden && (band == "2.4" || band == "5") && signal != nil }
}

/// What the plan predicts across the home, in squares half a metre wide: a level for each, 255 where there is no square.
struct PlanCoverage: Equatable {
    static let cell = 0.5
    var cols = 0
    var rows = 0
    var levels: [UInt8] = []

    static func make(_ plan: FloorPlan, band: String, offset: Double) -> PlanCoverage {
        let cols = Int((plan.w / cell).rounded(.up)), rows = Int((plan.h / cell).rounded(.up))
        var levels = [UInt8](repeating: 255, count: cols * rows)
        for j in 0..<rows {
            for i in 0..<cols {
                let p = PlanPoint(x: Double(i) * cell + cell / 2, y: Double(j) * cell + cell / 2)
                if p.x < 0.5 || p.x > plan.w - 0.5 || p.y < 0.5 || p.y > plan.h - 0.5 { continue }  // the margin outside the house
                levels[j * cols + i] = PlanMath.level(PlanMath.model(p, band: band, extraDb: offset, router: plan.router, walls: plan.walls))
            }
        }
        return PlanCoverage(cols: cols, rows: rows, levels: levels)
    }
}
