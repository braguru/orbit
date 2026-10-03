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
}

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
}

struct WifiNetwork: Decodable, Identifiable {
    var domain: String
    var guest: Bool
    var isolated: Bool?
    var ssids: [String: String]
    var id: String { domain }
}

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

    var today: Double { todayDown + todayUp }
    var now: Double { downMbps + upMbps }
    var active: Bool { online && now > 0.15 }
}

struct Person: Decodable, Identifiable, Hashable { var id: String; var name: String; var color: String }

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
