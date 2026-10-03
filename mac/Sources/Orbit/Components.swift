import Charts
import SwiftUI

/// Tiles or cards side by side, all as tall as the tallest and lined up at the top.
struct EqualRow<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: spacing) { content() }
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A titled panel, like the cards on the web dashboard.
struct Card<Content: View, Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer()
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary))
    }
}

/// A big number with a label and a note.
struct StatTile<Extra: View>: View {
    var icon: String
    var label: String
    var value: String
    var unit: String = ""
    var note: String = ""
    var live = false
    @ViewBuilder var extra: () -> Extra

    init(icon: String, label: String, value: String, unit: String = "", note: String = "", live: Bool = false,
         @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.icon = icon; self.label = label; self.value = value; self.unit = unit; self.note = note; self.live = live; self.extra = extra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(.secondary)
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if live { LiveBadge() }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                if !unit.isEmpty { Text(unit).font(.callout.weight(.semibold)).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            extra()
            Spacer(minLength: 0)  // notes line up at the bottom when tiles share a row
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
    }
}

struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text("LIVE").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
        }
    }
}

/// The device's type icon, tinted with its owner's color.
struct DeviceIcon: View {
    var device: Device
    var person: Person?
    var size: CGFloat = 32

    var tint: Color { person.map { Color.person($0.color) } ?? (device.isNew ? .orbitNew : .orbitNone) }

    var body: some View {
        Image(systemName: Icons.device(device.type))
            .font(.system(size: size * 0.5))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28))
            .opacity(device.online ? 1 : 0.5)
    }
}

struct StatusBadge: View {
    var device: Device

    var body: some View {
        let (text, color): (String, Color) = !device.online ? ("Offline", .secondary)
            : device.blocked == true ? ("Blocked", .red)
            : device.active ? ("Online", .green) : ("Idle", .secondary)
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct SignalBars: View {
    var dbm: Double?

    var body: some View {
        let s = Signal(dbm)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i <= s.level ? s.color : Color.secondary.opacity(0.3))
                    .frame(width: 3.5, height: 3 + CGFloat(i) * 2.5)
            }
        }
        .accessibilityLabel("\(s.word) signal")
    }
}

/// A small line chart. nil values are gaps.
struct Sparkline: View {
    var values: [Double?]
    var color: Color = .orbitAccent
    var maxValue: Double?

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                if let v {
                    LineMark(x: .value("t", i), y: .value("v", v))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(maxValue ?? max(1, (values.compactMap { $0 }.max() ?? 1) * 1.15)))
    }
}

/// A thin bar showing a share of something.
struct ShareBar: View {
    var fraction: Double
    var color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(3, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: 6)
    }
}

/// Shown while the app can't reach the Orbit server.
struct NotConnected: View {
    @Environment(OrbitStore.self) private var store

    var body: some View {
        ContentUnavailableView {
            Label(store.connection == .lost ? "Orbit’s server isn’t answering" : "Connecting to Orbit…", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text(store.connection == .lost
                 ? "This app shows what the Orbit server on this Mac records. Check it’s running with scripts/service.sh status, or start it with scripts/service.sh start."
                 : "Asking the Orbit server on this Mac for the latest picture.")
        } actions: {
            if store.connection == .lost { Button("Try again") { store.connect() } }
        }
    }
}
