import SwiftUI

// Cards for the read-only router and dish details. Everything here is shown, never changed:
// the settings can only be changed in the Starlink app.

enum RouterText {
    static let readOnly = "Orbit shows what your router is set to. Change it in the Starlink app."

    /// "Automatic" or the number, for a channel (0 means the router picks it).
    static func channel(_ v: Double?) -> String { (v ?? 0) == 0 ? "Automatic" : String(Int(v!)) }
    static func width(_ v: Double?) -> String { v.map { "\(Int($0)) MHz" } ?? "Automatic" }

    /// A software update in plain words, or nil when there is nothing to say beyond "up to date".
    static func update(state: String?, pending: String?, progress: Double?, ready: Bool = false, waitS: Double? = nil) -> (text: String, tone: SecChip.Tone) {
        let st = (state ?? "").uppercased()
        if ready { return ("Ready to install", .warn) }
        if let w = waitS, w > 0 { return ("Waiting for the overnight slot", .neutral) }
        if st.contains("FAIL") { return ("The last update didn’t finish", .warn) }
        if st.contains("FETCH") || st.contains("DOWNLOAD") || ((progress ?? 0) > 0 && (progress ?? 0) < 1 && pending != nil) {
            let p = progress ?? 0
            return (p > 0 ? "Downloading \(Int((p <= 1 ? p * 100 : p).rounded()))%" : "Downloading", .neutral)
        }
        if st.contains("REBOOT") { return ("Ready to install", .warn) }
        if st.contains("WRIT") || st.contains("CHECK") || st.contains("INSTALL") { return ("Installing", .neutral) }
        if pending != nil { return ("Waiting for the overnight slot", .neutral) }
        return ("Up to date", .good)
    }

    static func dropTone(_ f: Double?) -> SecChip.Tone { guard let f else { return .neutral }; return f < 0.02 ? .good : f < 0.05 ? .warn : .bad }
    static func dropWord(_ f: Double?) -> String { f.map { String(format: "%.0f%% lost", $0 * 100) } ?? "–" }
}

/// One setting: its name, a small tone chip, and a plain line about what it means.
struct SettingRow: View {
    var title: String
    var chip: String
    var tone: SecChip.Tone
    var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).fontWeight(.medium)
                Spacer(minLength: 8)
                SecChip(text: chip, tone: tone)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Security page

struct RouterSettingsCard: View {
    var router: Router

    static func securityChip(_ n: WifiNetwork) -> (text: String, tone: SecChip.Tone, icon: String) {
        if n.open == true || n.security == "open" { return ("No password", .bad, "lock.open") }
        switch (n.security ?? "").lowercased() {
        case "wpa3": return ("WPA3", .good, "lock")
        case "wpa2": return ("WPA2", .good, "lock")
        case "": return ("Password", .good, "lock")
        case let other: return (other.uppercased(), .warn, "lock")
        }
    }

    var body: some View {
        let st = router.settings
        Card("Router settings", subtitle: "Read from your router") {
            if st == nil && router.networks.isEmpty {
                Text("Your router hasn’t shared its settings yet.").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                ForEach(router.networks) { n in
                    let c = Self.securityChip(n)
                    SettingRow(title: "Wi-Fi protection, \(n.name)", chip: c.text, tone: c.tone,
                               note: (n.open == true ? "Anyone nearby can join without a password." : n.security == "wpa3" ? "The newest and strongest kind of Wi-Fi protection."
                                      : n.security == "wpa2" ? "A solid, widely used kind of Wi-Fi protection." : nil)
                               .map { $0 + (n.hidden == true ? " The name is hidden. That doesn’t add real security." : "") }
                               ?? (n.hidden == true ? "The name is hidden. That doesn’t add real security." : nil))
                }
                if let st {
                    if let dns = st.dns {
                        let servers = dns.servers ?? []
                        SettingRow(title: "DNS", chip: dns.custom == true && !servers.isEmpty ? "Custom: " + servers.joined(separator: ", ") : "Router default", tone: .neutral,
                                   note: "DNS decides where website names lead." + (dns.custom == true ? " Make sure you chose these servers yourself." : ""))
                        SettingRow(title: "Secure DNS", chip: dns.secure == true ? "On" : "Off", tone: dns.secure == true ? .good : .neutral,
                                   note: dns.secure == true ? "Website lookups are scrambled so others on the way can’t read or change them."
                                                           : "Website lookups travel unscrambled. That’s normal for most homes.")
                    }
                    if st.bypass == true {
                        SettingRow(title: "Bypass mode", chip: "On", tone: .warn, note: "Another router handles your Wi-Fi, so Orbit can’t see the devices behind it.")
                    } else if let b = st.bypass {
                        SettingRow(title: "Bypass mode", chip: b ? "On" : "Off", tone: .neutral, note: nil)
                    }
                    if st.apMode == true {
                        SettingRow(title: "Access point mode", chip: "On", tone: .warn, note: "Another router hands out addresses, so Orbit can’t see the devices behind it.")
                    } else if let a = st.apMode {
                        SettingRow(title: "Access point mode", chip: a ? "On" : "Off", tone: .neutral, note: nil)
                    }
                    if let m = st.meshOnboarding {
                        SettingRow(title: "Mesh onboarding", chip: m ? "On" : "Off", tone: .neutral,
                                   note: m ? "The router is open to adding Starlink mesh nodes." : nil)
                    }
                    let chans = [("2.4 GHz", st.channel("2.4")), ("5 GHz", st.channel("5")), ("Upper 5 GHz", st.channel("5_upper"))]
                    let auto = chans.allSatisfy { ($0.1 ?? 0) == 0 }
                    SettingRow(title: "Wi-Fi channels", chip: auto ? "Automatic" : "Chosen by hand", tone: .neutral,
                               note: chans.map { "\($0.0): \(RouterText.channel($0.1))" }.joined(separator: " · ") + ". Automatic means the router picks the least crowded one.")
                    if st.widths?.isEmpty == false {
                        let ws = [("5 GHz", st.width("5")), ("Upper 5 GHz", st.width("5_upper"))]
                        SettingRow(title: "Channel widths", chip: ws.allSatisfy { $0.1 == nil } ? "Automatic" : "Chosen by hand", tone: .neutral,
                                   note: ws.map { "\($0.0): \(RouterText.width($0.1))" }.joined(separator: " · ") + ". Wider is faster but more easily disturbed.")
                    }
                    if let d = st.dfs { SettingRow(title: "DFS channels", chip: d ? "On" : "Off", tone: .neutral, note: "Extra 5 GHz channels shared with weather radar. The router steps aside if it hears radar.") }
                    if let c = st.country { SettingRow(title: "Country", chip: c, tone: .neutral, note: "Sets which Wi-Fi channels and power levels are allowed.") }
                    if let a = st.autoSpeedtests { SettingRow(title: "Automatic speed tests", chip: a ? "On" : "Off", tone: .neutral, note: a ? "The router tests your speed now and then, which uses a little data." : nil) }
                }
            }
            Text(RouterText.readOnly).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Starlink page

struct ConnectionChainCard: View {
    var router: Router

    var body: some View {
        let l = router.link
        Card("Connection chain", subtitle: "Where a slowdown starts, measured by your router over the last 5 minutes") {
            if let l {
                VStack(alignment: .leading, spacing: 12) {
                    step(1, "Router to dish", "The cable and Wi-Fi hop at home", l.dishMs, l.dishDrop5M)
                    step(2, "Dish to Starlink’s gateway", "Up to the satellites and back down to the ground", l.popMs, l.popDrop5M)
                    step(3, "On to the internet", "From the gateway to a test server", l.internetMs, l.internetDrop5M)
                }
                Text("If the first step is slow, the problem is at home. If a later step is slow, it’s Starlink or beyond.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    GridRow {
                        Text("Public address").foregroundStyle(.secondary)
                        Text(l.publicIpAgeS.map { "The same for \(Format.duration(ms: $0 * 1000))" } ?? "–")
                    }
                    GridRow {
                        Text("Power feed").foregroundStyle(.secondary)
                        Text(power(l.poe))
                    }
                    GridRow {
                        Text("Router to dish").foregroundStyle(.secondary)
                        Text(l.noWanLink == true ? "No link. Check the cable" : l.noWanLink == false ? "Connected" : "–")
                            .foregroundStyle(l.noWanLink == true ? Color.red : Color.primary)
                    }
                }
            } else {
                Text("Your router hasn’t shared its link details yet.").foregroundStyle(.secondary)
            }
        }
    }

    private func power(_ p: PoeStatus?) -> String {
        guard let p, let on = p.on else { return "–" }
        var t = on ? "On" : "Off"
        if on, let w = p.powerW { t += String(format: ", %.0f W", w) }
        t += (p.faults ?? 0) > 0 ? ", \(Format.plural(p.faults ?? 0, "fault"))" : ", no faults"
        return t
    }

    private func step(_ n: Int, _ title: String, _ sub: String, _ ms: Double?, _ drop: Double?) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(n)").font(.caption.weight(.bold)).frame(width: 22, height: 22)
                .background(Color.orbitAccent.opacity(0.14), in: Circle()).foregroundStyle(Color.orbitAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(sub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(ms.map { $0 < 10 ? String(format: "%.1f ms", $0) : "\(Int($0.rounded())) ms" } ?? "–").monospacedDigit().fontWeight(.semibold).fixedSize()
            SecChip(text: RouterText.dropWord(drop), tone: RouterText.dropTone(drop)).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}

struct PointingCard: View {
    var dish: Dish

    var body: some View {
        let p = dish.pointing
        let side = p.flatMap { a in a.az.flatMap { x in a.wantAz.map { abs(x - $0) } } }
        let up = p.flatMap { a in a.el.flatMap { x in a.wantEl.map { abs(x - $0) } } }
        let far = ((side ?? 0) * (side ?? 0) + (up ?? 0) * (up ?? 0)).squareRoot() > 15
        Card("Dish pointing", subtitle: "Where the dish faces, and where it would like to face") {
            if p == nil && dish.gps == nil && dish.check == nil {
                Text("Your dish hasn’t shared this yet.").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                if let side, let up {
                    GridRow {
                        Text("Gap, sideways").foregroundStyle(.secondary)
                        Text(String(format: "%.0f°", side)).monospacedDigit()
                    }
                    GridRow {
                        Text("Gap, up and down").foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Text(String(format: "%.0f°", up)).monospacedDigit()
                            if far { SecChip(text: "Large", tone: .warn) }
                        }
                    }
                }
                if let settled = p?.settled {
                    GridRow { Text("Position").foregroundStyle(.secondary); Text(settled ? "Settled" : "Still adjusting") }
                }
                if let g = dish.gps, let valid = g.valid {
                    GridRow { Text("GPS").foregroundStyle(.secondary); Text(valid ? "Locked, \(Format.plural(g.sats ?? 0, "satellite"))" : "No lock yet") }
                }
                if let t = dish.check?.selfTest {
                    GridRow {
                        Text("Self-test").foregroundStyle(.secondary)
                        SecChip(text: t.capitalized, tone: t.uppercased() == "PASSED" ? .good : .warn)
                    }
                }
            }
            Text("Standard dishes without motors can’t adjust, so some gap is common. It matters only if you see weak signal or dropouts.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
