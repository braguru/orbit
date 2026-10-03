import SwiftUI

/// Numbers and times, written the same way as the web version.
enum Format {
    static func mbps(_ v: Double) -> String {
        if v < 0.05 { return "0" }
        return v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded()))
    }

    static func bytes(_ b: Double) -> String {
        if b <= 0 { return "0 MB" }
        let mb = b / 1e6
        if mb < 1 { return "<1 MB" }
        if mb < 1000 { return "\(Int(mb.rounded())) MB" }
        let gb = mb / 1000
        if gb < 1000 { return gb < 100 ? String(format: "%.1f GB", gb) : "\(Int(gb.rounded())) GB" }
        return String(format: "%.2f TB", gb / 1000)
    }

    static func duration(ms: Double) -> String {
        let m = Int((ms / 60_000).rounded())
        if m < 1 { return "under a minute" }
        if m < 60 { return "\(m) min" }
        let h = m / 60, mm = m % 60
        if h < 24 { return mm > 0 ? "\(h) h \(mm) min" : "\(h) h" }
        let d = h / 24, hh = h % 24
        return d < 7 && hh > 0 ? "\(d) d \(hh) h" : "\(d) days"
    }

    static func seconds(_ s: Double) -> String { s < 60 ? "\(Int(s.rounded())) s" : duration(ms: s * 1000) }

    static func ago(_ ts: Double, now: Double) -> String {
        let d = now - ts
        if d < 45_000 { return "just now" }
        if d < 3_600_000 { return "\(max(1, Int((d / 60_000).rounded()))) min ago" }
        if d < 86_400_000 { return "\(Int(d / 3_600_000)) h ago" }
        let days = Int(d / 86_400_000)
        return days == 1 ? "yesterday" : "\(days) days ago"
    }

    static func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
    static func clock(_ ms: Double) -> String { date(ms).formatted(date: .omitted, time: .shortened) }
    static func plural(_ n: Int, _ word: String, _ many: String? = nil) -> String { "\(n) \(n == 1 ? word : many ?? word + "s")" }
}

// MARK: - colors, from the web palette

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static let orbitAccent = Color(hex: 0x5847DD)
    static let orbitNone = Color(hex: 0x8B94A5)
    static let orbitNew = Color(hex: 0xEDA100)

    static func person(_ name: String?) -> Color {
        switch name {
        case "blue": return Color(hex: 0x2A78D6)
        case "orange": return Color(hex: 0xEB6834)
        case "green": return Color(hex: 0x1BAF7A)
        case "amber": return Color(hex: 0xEDA100)
        case "pink": return Color(hex: 0xE87BA4)
        case "violet": return Color(hex: 0x8B5CF6)
        default: return .orbitNone
        }
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .good: return .green
        case .warn: return .orange
        case .bad: return .red
        case .neutral: return .orbitAccent
        }
    }
}

// MARK: - icons

enum Icons {
    /// A device type as an SF Symbol.
    static func device(_ type: String) -> String {
        switch type {
        case "phone": return "iphone"
        case "laptop": return "laptopcomputer"
        case "desktop": return "desktopcomputer"
        case "tablet": return "ipad"
        case "watch": return "applewatch"
        case "tv": return "tv"
        case "console": return "gamecontroller"
        case "speaker": return "hifispeaker"
        case "camera": return "video"
        case "thermostat": return "thermometer.medium"
        case "lights": return "lightbulb"
        case "vacuum": return "fan"
        case "plug": return "powerplug"
        case "ereader": return "book"
        case "printer": return "printer"
        default: return "questionmark.circle"
        }
    }

    /// The server names activity icons after the web's icon set; these are the matching SF Symbols.
    static func event(_ name: String) -> String {
        switch name {
        case "shield-alert": return "exclamationmark.shield"
        case "wifi": return "wifi"
        case "wifi-off": return "wifi.slash"
        case "satellite-dish": return "antenna.radiowaves.left.and.right"
        case "rotate-cw": return "arrow.clockwise"
        case "gauge": return "speedometer"
        case "pencil": return "pencil"
        case "tag": return "tag"
        case "user-plus": return "person.badge.plus"
        case "user": return "person"
        case "trash-2": return "trash"
        case "radar": return "dot.radiowaves.left.and.right"
        case "router": return "wifi.router"
        case "ban": return "nosign"
        case "play": return "play.circle"
        case "triangle-alert": return "exclamationmark.triangle"
        default: return "circle"
        }
    }

    static let types: [(key: String, label: String)] = [
        ("phone", "Phone"), ("laptop", "Laptop"), ("desktop", "Computer"), ("tablet", "Tablet"), ("watch", "Watch"),
        ("tv", "TV"), ("console", "Game console"), ("speaker", "Smart speaker"), ("camera", "Camera"),
        ("thermostat", "Thermostat"), ("lights", "Lights hub"), ("vacuum", "Robot vacuum"), ("plug", "Smart plug"),
        ("ereader", "E-reader"), ("printer", "Printer"), ("unknown", "Unknown device"),
    ]
}

// MARK: - signal

struct Signal {
    let level: Int
    let word: String

    init(_ dbm: Double?) {
        guard let dbm else { level = 4; word = "Wired"; return }
        if dbm >= -55 { (level, word) = (4, "Excellent") }
        else if dbm >= -63 { (level, word) = (3, "Good") }
        else if dbm >= -70 { (level, word) = (2, "Fair") }
        else { (level, word) = (1, "Weak") }
    }

    var color: Color { level >= 3 ? .green : level == 2 ? .orange : .red }
}

extension Device {
    var wired: Bool { band == "eth" }
    var bandLabel: String { wired ? "Ethernet" : band.map { "\($0) GHz" } ?? "Wi-Fi" }
    var networkLabel: String { wired ? "Wired" : network == "guest" ? "Guest Wi-Fi" : "Main Wi-Fi" }
    var connectionLabel: String { wired ? "Wired · Ethernet" : "\(network == "guest" ? "Guest · " : "")\(bandLabel) · \(Signal(signal).word)" }
}
