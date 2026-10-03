import SwiftUI

struct StarlinkView: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    @Binding var showSpeedTest: Bool
    @State private var map: ObstructionMap?

    var body: some View {
        let s = state, d = s.dish
        let last = s.tests.first
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                EqualRow {
                    StatTile(icon: "antenna.radiowaves.left.and.right", label: "Connection",
                             value: d.reachable == false ? "Can’t reach it" : d.online == false ? "Offline" : "Online",
                             note: d.onlineSince.map { "Online for " + Format.duration(ms: s.now - $0) } ?? d.outage?.text ?? "")
                    StatTile(icon: "timer", label: "Latency", value: d.latencyMs.map { "\(Int($0.rounded()))" } ?? "–", unit: d.latencyMs == nil ? "" : "ms",
                             note: "Under 40 ms is great." + (d.dropRate.map { String(format: " %.0f%% of pings lost.", $0 * 100) } ?? ""), live: d.latencyMs != nil) {
                        Sparkline(values: store.points.suffix(40).map(\.lat), maxValue: 80).frame(height: 26)
                    }
                    StatTile(icon: "speedometer", label: "Last speed test", value: last.flatMap { $0.down.map { "\(Int($0))" } } ?? "–",
                             unit: last?.down == nil ? "" : "Mbps",
                             note: s.speedtest.running ? "Testing now…" : last.map { t in t.error == nil ? "\(Int(t.up ?? 0)) Mbps up · \(Format.ago(t.ts, now: s.now))" : t.errorText ?? "" } ?? "No test yet")
                }
                EqualRow {
                    StatTile(icon: "exclamationmark.triangle", label: "Dropouts, 24 h", value: "\(s.outages.count)", note: "\(Format.seconds(s.dropoutSeconds)) offline in total")
                    StatTile(icon: "eye.slash", label: "Sky blocked", value: String(format: "%.1f", (d.obstructed ?? 0) * 100), unit: "%",
                             note: d.obstructedNow == true ? "Something is blocking it right now" : (d.obstructed ?? 0) > 0.0005 ? "Some of the time" : "Nothing is in the way")
                    StatTile(icon: "bolt", label: "Power use", value: d.powerW.map { "\(Int($0.rounded()))" } ?? "–", unit: d.powerW == nil ? "" : "W",
                             note: d.powerW.map { String(format: "About %.1f kWh a day", $0 * 24 / 1000) } ?? "Measuring…")
                }

                EqualRow(spacing: 16) {
                    Card("What your dish sees", subtitle: map.flatMap { $0.updated }.map { "Its own map of the sky, updated \(Format.ago($0, now: s.now)). North is at the top." }) {
                        SkyMap(map: map).frame(width: 300, height: 300).frame(maxWidth: .infinity)
                    }
                    .frame(width: 380)
                    Card("Dropouts in the last 24 hours", subtitle: "\(Format.plural(s.outages.count, "dropout")) · \(Format.seconds(s.dropoutSeconds)) offline") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(s.outages.sorted { $0.start > $1.start }.prefix(10)) { o in
                                HStack(alignment: .top) {
                                    Image(systemName: o.cause == "BOOTING" ? "arrow.clockwise" : "exclamationmark.triangle")
                                        .foregroundStyle(o.durationS >= 10 ? .red : .orange).frame(width: 20)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(o.cause == "BOOTING" ? "Restarted, back after \(Format.seconds(o.durationS))"
                                             : o.durationS < 1 ? "Dropped for under a second" : "Dropped for \(Format.seconds(o.durationS))").fontWeight(.medium)
                                        Text(o.text).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(Format.clock(o.start)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                            if s.outages.isEmpty { Text("No dropouts. Nice.").foregroundStyle(.secondary) }
                        }
                    }
                }

                EqualRow(spacing: 16) {
                    Card("Dish", subtitle: d.hardware) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            row("Software", d.software ?? "–")
                            row("Up for", d.uptimeS.map { Format.duration(ms: $0 * 1000) } ?? "–")
                            row("Snow melt", ["AUTO": "Automatic", "ALWAYS_ON": "Pre-heat", "ALWAYS_OFF": "Off"][d.snowMelt ?? ""] ?? d.snowMelt ?? "–")
                            row("Sleep schedule", d.sleep?.on == true ? "On" : "Off")
                            row("Motors", d.actuated == true ? "Yes, it can stow itself" : "None, you aim it by hand")
                            row("Cable to router", d.ethMbps.map { $0 >= 1000 ? "\(Int($0 / 1000)) Gbps" : "\(Int($0)) Mbps" } ?? "–")
                            row("Alerts", d.alerts.isEmpty ? "None" : d.alerts.map(\.text).joined(separator: "\n"))
                        }
                        Text("To change these, use the Starlink app. Orbit only reads from your dish.").font(.caption).foregroundStyle(.secondary)
                    }
                    Card("Router and Wi-Fi", subtitle: s.router.hardware.map { "Starlink Router \($0)" }) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            row("Software", s.router.software ?? "–")
                            row("Up for", s.router.uptimeS.map { Format.duration(ms: $0 * 1000) } ?? "–")
                            row("Devices", "\(s.connected.count) connected · \(s.devices.count) known")
                            ForEach(s.router.networks.filter { n in !n.guest || s.devices.contains { $0.online && $0.network == "guest" } || n.domain == s.router.networks.first(where: \.guest)?.domain }) { n in
                                row(n.guest ? "Guest Wi-Fi" : "Main Wi-Fi", Set(n.ssids.values).sorted().joined(separator: " · "))
                            }
                        }
                    }
                }

                Card("Speed tests", subtitle: "Run by your router, between your home and the internet",
                     accessory: { Button(s.speedtest.running ? "Running…" : "Run one") { showSpeedTest = true } }) {
                    if s.tests.isEmpty {
                        Text("No speed tests yet.").foregroundStyle(.secondary)
                    } else {
                        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                            GridRow { Text("When"); Text("Download"); Text("Upload"); Text("Latency") }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(s.tests) { t in
                                GridRow {
                                    Text("\(Format.ago(t.ts, now: s.now)), \(Format.clock(t.ts))")
                                    if t.error == nil {
                                        Text("\(Int(t.down ?? 0)) Mbps"); Text("\(Int(t.up ?? 0)) Mbps"); Text(t.latency.map { "\(Int($0)) ms" } ?? "–")
                                    } else {
                                        Text(t.errorText ?? "Failed").foregroundStyle(.secondary).gridCellColumns(3)
                                    }
                                }
                                .monospacedDigit()
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Starlink")
        .task {
            while !Task.isCancelled {
                map = try? await store.get("api/obstruction")
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }
}

/// The dish's own map of the sky: each cell is signal quality from 0 (blocked) to 1 (clear); -1 not measured yet.
/// The middle is straight up; the edge is the horizon at the map's lowest elevation.
struct SkyMap: View {
    var map: ObstructionMap?

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x111C31))
            if let m = map, m.rows > 0 {
                Canvas { ctx, size in
                    let cw = size.width / CGFloat(m.cols), ch = size.height / CGFloat(m.rows)
                    for r in 0..<m.rows {
                        for c in 0..<m.cols {
                            let v = m.snr[r * m.cols + c]
                            guard v >= 0 else { continue }
                            let color: Color = v >= 0.9 ? Color(hex: 0xA59BFF).opacity(0.6) : v >= 0.5 ? .orange : .red
                            ctx.fill(Path(CGRect(x: CGFloat(c) * cw, y: CGFloat(r) * ch, width: cw + 0.5, height: ch + 0.5)), with: .color(color))
                        }
                    }
                }
                .clipShape(Circle())
            }
            ForEach([1.0, 0.75, 0.375], id: \.self) { f in
                Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1).scaleEffect(f)
            }
            Circle().fill(.white).frame(width: 6, height: 6)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .top) { Text("N").font(.caption2.bold()).offset(y: -14) }
        .overlay(alignment: .bottom) { Text("S").font(.caption2.bold()).offset(y: 14) }
        .overlay(alignment: .leading) { Text("W").font(.caption2.bold()).offset(x: -14) }
        .overlay(alignment: .trailing) { Text("E").font(.caption2.bold()).offset(x: 14) }
        .padding(18)
        .accessibilityLabel("The dish’s map of the sky")
    }
}

/// Runs a speed test on the router and shows it live.
struct SpeedTestSheet: View {
    @Environment(OrbitStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var startedHere = false

    var body: some View {
        let s = store.state
        let t = s?.speedtest
        let result = (t?.running == false && startedHere) ? t?.result : nil
        VStack(spacing: 18) {
            Text("Speed test").font(.title2.bold())
            if let t, t.running {
                let up = t.phase == "up"
                let value = (up ? t.upNow : t.downNow) ?? 0
                Gauge(value: min(value, up ? 50 : 500), in: 0...(up ? 50 : 500)) {
                    Text("Mbps")
                } currentValueLabel: {
                    Text(Format.mbps(value)).monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .scaleEffect(2.2)
                .frame(height: 140)
                .tint(Color.orbitAccent)
                Text(up ? "Testing upload…" : t.phase == "down" ? "Testing download…" : "Starting the test…").font(.headline)
                Text("Your router is measuring the link to the internet. This takes about 30 seconds.").foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else if let r = result, r.error == nil {
                HStack(spacing: 14) {
                    resultTile("Download", "\(Int(r.down ?? 0)) Mbps")
                    resultTile("Upload", "\(Int(r.up ?? 0)) Mbps")
                    resultTile("Latency", r.latency.map { "\(Int($0)) ms" } ?? "–")
                }
                Text(verdict(r.down ?? 0, r.up ?? 0)).multilineTextAlignment(.center)
                Text("The fastest moments reached \(Int(r.downPeak ?? 0)) Mbps down and \(Int(r.upPeak ?? 0)) Mbps up.").font(.caption).foregroundStyle(.secondary)
            } else if let r = result {
                Label(r.errorText ?? "The test didn’t finish.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Text("Your router measures the speed between your home and the internet. It takes about 30 seconds and uses a few hundred MB of data, and streams in the house may stutter while it runs.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                if let last = s?.tests.first, last.error == nil, let down = last.down {
                    Text("Last test, \(Format.ago(last.ts, now: s?.now ?? 0)): \(Int(down)) Mbps down, \(Int(last.up ?? 0)) Mbps up.").font(.callout)
                }
            }
            HStack {
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                if t?.running != true {
                    Button(result == nil ? "Start the test" : "Test again") {
                        startedHere = true
                        store.runSpeedTest()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(s?.dish.online != true || cooldown(s) > 0)
                }
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private func resultTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private func cooldown(_ s: OrbitState?) -> Double {
        guard let s, let last = s.tests.first else { return 0 }
        return max(0, 60_000 - (s.now - last.ts))
    }

    private func verdict(_ down: Double, _ up: Double) -> String {
        let d = down >= 150 ? "Fast. About \(Int(down / 25)) people can stream in 4K at the same time."
            : down >= 50 ? "Good for streaming and calls. Big downloads take a little while."
            : "Slower than usual for Starlink. Restarting the dish, or checking what blocks its view, can help."
        let u = up >= 10 ? " Uploads and video calls will be smooth." : up >= 5 ? " Uploads are fine for video calls." : " Uploads and video calls may struggle."
        return d + u
    }
}
