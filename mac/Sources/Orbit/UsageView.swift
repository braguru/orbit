import Charts
import SwiftUI

struct UsageView: View {
    @Environment(OrbitStore.self) private var store
    var state: OrbitState
    @AppStorage("usageRange") private var range = "7d"
    @State private var usage: Usage?
    @State private var failed: String?

    private let ranges = [("24h", "24 hours"), ("7d", "7 days"), ("30d", "30 days")]
    private var longRange: String { ["24h": "the last 24 hours", "7d": "the last 7 days", "30d": "the last 30 days"][range] ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Range", selection: $range) {
                    ForEach(ranges, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 320)

                if let u = usage {
                    content(u)
                } else if let failed {
                    ContentUnavailableView("Couldn’t load usage", systemImage: "exclamationmark.triangle", description: Text(failed))
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(24)
        }
        .navigationTitle("Usage")
        .task(id: range) {
            // Load now, then refresh every minute while this page is open.
            while !Task.isCancelled {
                do { usage = try await store.get("api/usage?range=\(range)"); failed = nil } catch { failed = error.localizedDescription }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    @ViewBuilder
    private func content(_ u: Usage) -> some View {
        let total = u.total.down + u.total.up
        let busiest = u.bars.max { ($0.down + $0.up) < ($1.down + $1.up) }
        let peak = u.speed.compactMap(\.downMax).max() ?? 0
        let perDay = range != "24h"
        if u.rangeS > 0, u.recordedS / u.rangeS < 0.95 {
            Label("Orbit has recorded \(Format.duration(ms: u.recordedS * 1000)) of \(longRange). Totals only cover the time it was running.", systemImage: "clock.arrow.circlepath")
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orbitAccent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }
        EqualRow {
            StatTile(icon: "arrow.down", label: "Downloaded", value: Format.bytes(u.total.down), note: "Whole home, \(longRange)")
            StatTile(icon: "arrow.up", label: "Uploaded", value: Format.bytes(u.total.up),
                     note: total > 0 ? "\(Int((u.total.up / total * 100).rounded()))% of all traffic" : "Nothing yet")
            StatTile(icon: "calendar", label: perDay ? "Busiest day" : "Busiest hour", value: busiest.map { Format.bytes($0.down + $0.up) } ?? "–",
                     note: busiest.map { perDay ? Format.date($0.t).formatted(.dateTime.weekday(.wide).day().month()) : Format.clock($0.t) } ?? "")
        }
        EqualRow {
            StatTile(icon: "speedometer", label: "Fastest download", value: Format.mbps(peak), unit: "Mbps", note: "The highest one-second reading. Not a speed test.")
            StatTile(icon: "exclamationmark.triangle", label: "Dropouts", value: "\(u.outages.count)",
                     note: u.outages.count > 0 ? "\(Format.seconds(u.outages.seconds)) offline in total" : "None recorded")
            StatTile(icon: "laptopcomputer.and.iphone", label: "Devices that used data", value: "\(u.devices.count)",
                     note: u.devices.first.map { "Most: \($0.name)" } ?? "None yet")
        }

        Card("Data used per \(perDay ? "day" : "hour")", subtitle: "\(Format.bytes(total)) in \(longRange), measured at the dish") {
            Chart(u.bars) { b in
                BarMark(x: .value("When", Format.date(b.t), unit: perDay ? .day : .hour), y: .value("GB", (b.down + b.up) / 1e9))
                    .foregroundStyle(Color.orbitAccent.gradient)
            }
            .chartYAxisLabel("GB")
            .frame(height: 200)
        }

        EqualRow(spacing: 16) {
            Card("Internet use over time", subtitle: "Average download and upload. Gaps are times Orbit wasn’t recording.") {
                Chart {
                    ForEach(u.speed) { p in
                        if let down = p.down {
                            LineMark(x: .value("When", Format.date(p.t)), y: .value("Mbps", down), series: .value("Direction", "Download"))
                                .foregroundStyle(by: .value("Direction", "Download"))
                        }
                        if let up = p.up {
                            LineMark(x: .value("When", Format.date(p.t)), y: .value("Mbps", up), series: .value("Direction", "Upload"))
                                .foregroundStyle(by: .value("Direction", "Upload"))
                        }
                    }
                }
                .chartForegroundStyleScale(["Download": Color.orbitAccent, "Upload": Color.gray])
                .chartYAxisLabel("Mbps")
                .frame(height: 180)
            }
            Card("Latency over time", subtitle: "Under 40 ms is great") {
                Chart(u.speed.filter { $0.lat != nil }) { p in
                    LineMark(x: .value("When", Format.date(p.t)), y: .value("ms", p.lat ?? 0)).foregroundStyle(Color.orbitAccent)
                }
                .chartYAxisLabel("ms")
                .frame(height: 180)
            }
        }

        Card("By device", subtitle: "Download and upload together, \(longRange)") {
            let devTotal = max(1, u.devices.reduce(0) { $0 + $1.down + $1.up })
            VStack(spacing: 10) {
                ForEach(u.devices.prefix(15)) { d in
                    let p = state.person(d.owner)
                    HStack(spacing: 10) {
                        Image(systemName: Icons.device(d.type)).frame(width: 22).foregroundStyle(p.map { Color.person($0.color) } ?? .orbitNone)
                        Text(d.name).frame(width: 180, alignment: .leading).lineLimit(1)
                        ShareBar(fraction: (d.down + d.up) / devTotal, color: p.map { Color.person($0.color) } ?? .orbitNone)
                        Text(Format.bytes(d.down + d.up)).monospacedDigit().frame(width: 80, alignment: .trailing)
                    }
                }
                if u.devices.isEmpty { Text("No device usage recorded yet.").foregroundStyle(.secondary) }
            }
        }
        Text("Whole-home numbers come from your dish. Per-device numbers come from your router and include traffic that stays inside your home, like casting to a TV, so they can add up to more.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
