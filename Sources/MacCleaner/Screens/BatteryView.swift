import AppKit
import CleanerCore
import SwiftUI

/// Battery health at a glance: capacity compared to new, cycles, what's draining it right now.
struct BatteryView: View {
    let model: AppModel

    static let symbol = "battery.75percent"
    static let tint = Color.green

    var body: some View {
        Group {
            if let battery = model.battery {
                content(battery)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Live figures: refresh while the screen is open.
        .task {
            while !Task.isCancelled {
                model.refreshBattery(includingEnergy: true)
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    private func content(_ battery: BatteryHealth) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                HStack(alignment: .center, spacing: Space.xl) {
                    CapacityGauge(percent: battery.maximumCapacityPercent ?? 0, needsService: battery.needsService)
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Maximum capacity").font(.headline).foregroundStyle(.textSecondary)
                        Text(conditionText(battery))
                            .font(.system(.title, design: .rounded, weight: .bold))
                        Text("Compared to when it was new. Below 80%, macOS recommends service.")
                            .foregroundStyle(.textSecondary)
                        CyclesBar(cycles: battery.cycleCount, design: battery.designCycleCount)
                            .padding(.top, Space.s)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Space.xl)
                .surface()

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Space.l)], spacing: Space.l) {
                    StatCard(title: Text("Charge"), value: Text("\(battery.chargePercent)%"),
                             detail: Text(battery.isCharging ? "Charging" : battery.isPluggedIn ? "Plugged in" : "On battery"))
                    StatCard(title: Text(battery.isCharging ? "Until full" : "Time left"),
                             value: Text(battery.minutesRemaining.map(duration) ?? "—"),
                             detail: Text(battery.minutesRemaining == nil ? "Estimating…" : "At the current rate"))
                    StatCard(title: Text(battery.isCharging ? "Charging at" : "Using"),
                             value: Text(battery.watts.map { String(format: "%.1f W", abs($0)) } ?? "—"),
                             detail: Text("Power right now"))
                    if let full = battery.fullChargeCapacity, let design = battery.designCapacity {
                        StatCard(title: Text("Holds"), value: Text("\(full) mAh"), detail: Text("of \(design) mAh when new"))
                    }
                }

                if let trend = trendText(battery) {
                    Label(trend, systemImage: "chart.line.downtrend.xyaxis")
                        .padding(Space.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .surface()
                }

                EnergyList(users: model.energyUsers)

                HStack(spacing: Space.s) {
                    Image(systemName: "info.circle").foregroundStyle(.textSecondary).accessibilityHidden(true)
                    Text("To slow down wear, keep Optimized Battery Charging on in System Settings › Battery.")
                        .foregroundStyle(.textSecondary)
                    Spacer()
                    Button("Battery Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .secondaryButtonStyle()
                }
                .font(.callout)
            }
            .padding(Metrics.windowPadding)
            .frame(maxWidth: Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private func conditionText(_ battery: BatteryHealth) -> String {
        guard let condition = battery.condition else { return String(localized: "Unknown condition") }
        switch condition.lowercased() {
        case "good": return String(localized: "Good")
        case "normal": return String(localized: "Normal")
        case let text where text.contains("service"): return String(localized: "Service recommended")
        default: return condition
        }
    }

    private func duration(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    /// How capacity changed since Ferah first read it.
    private func trendText(_ battery: BatteryHealth) -> String? {
        guard let first = model.batteryHistory.first, let now = battery.maximumCapacityPercent,
              !Calendar.current.isDateInToday(first.date)
        else { return nil }
        let since = first.date.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "Since \(since): capacity \(first.capacity)% → \(now)%, cycles \(first.cycles) → \(battery.cycleCount).")
    }
}

/// Capacity as a ring: green while healthy, orange near the service threshold, red past it.
private struct CapacityGauge: View {
    let percent: Int
    let needsService: Bool

    private var color: Color {
        if needsService || percent < 80 { return .red }
        if percent < 85 { return .orange }
        return .green
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.barFree, lineWidth: 14)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                .rotationEffect(.degrees(-90))
            FigureText(text: Text("\(percent)%"), size: 34)
        }
        .frame(width: 140, height: 140)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Maximum capacity \(percent) percent"))
    }
}

private struct CyclesBar: View {
    let cycles: Int
    let design: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let design {
                ProgressView(value: Double(min(cycles, design)), total: Double(design))
                    .tint(.accentColor)
                Text("\(cycles) of \(design) charge cycles").font(.callout).monospacedDigit()
            } else {
                Text("\(cycles) charge cycles").font(.callout).monospacedDigit()
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }
}

private struct StatCard: View {
    let title: Text
    let value: Text
    let detail: Text

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            title.font(.callout).foregroundStyle(.textSecondary)
            FigureText(text: value, size: 24)
            detail.font(.caption).foregroundStyle(.textSecondary)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface()
    }
}

/// Open apps using the most energy, with a way to quit them. System processes are left out.
private struct EnergyList: View {
    let users: [EnergyUse]

    private var apps: [(app: NSRunningApplication, power: Double)] {
        var seen: Set<pid_t> = []
        return users.compactMap { use in
            // Finder is always running and can't be quit; Ferah itself isn't worth listing.
            guard let app = NSRunningApplication(processIdentifier: use.pid), app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier, app.bundleIdentifier != "com.apple.finder",
                  seen.insert(use.pid).inserted
            else { return nil }
            return (app, use.power)
        }
        .prefix(6)
        .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Using the most energy").font(.headline)
            if apps.isEmpty {
                Text("No open app is using much energy right now.").foregroundStyle(.textSecondary)
            }
            ForEach(apps, id: \.app.processIdentifier) { entry in
                HStack(spacing: Space.m) {
                    if let icon = entry.app.icon {
                        Image(nsImage: icon).resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                    }
                    Text(verbatim: entry.app.localizedName ?? "")
                    Spacer()
                    Text(String(format: "%.1f", entry.power))
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                        .help(Text("Energy impact, as in Activity Monitor"))
                    Button("Quit") { entry.app.terminate() }
                        .secondaryButtonStyle()
                        .controlSize(.small)
                }
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.s)
                .surface()
            }
        }
    }
}
