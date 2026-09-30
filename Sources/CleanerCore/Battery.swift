import Foundation
import IOKit

/// The battery's health and state right now. Read-only.
public struct BatteryHealth: Sendable, Equatable {
    public var cycleCount: Int
    /// Cycles the battery is designed for (1000 on recent MacBooks).
    public var designCycleCount: Int?
    /// Capacity compared to new, as macOS reports it in Settings › Battery.
    public var maximumCapacityPercent: Int?
    /// macOS's own verdict: "Good", "Normal", "Service Recommended"…
    public var condition: String?
    public var chargePercent: Int
    public var isCharging: Bool
    public var isPluggedIn: Bool
    /// Minutes until empty (or full, while charging); nil while macOS is still estimating.
    public var minutesRemaining: Int?
    /// Watts flowing out of (negative) or into (positive) the battery.
    public var watts: Double?
    public var designCapacity: Int?
    public var fullChargeCapacity: Int?

    public var needsService: Bool {
        guard let condition else { return false }
        let lower = condition.lowercased()
        return lower.contains("service") || lower.contains("replace") || lower.contains("poor")
    }
}

/// Energy use of a running process, as `top` measures it (the same scale as Activity Monitor's Energy Impact).
public struct EnergyUse: Identifiable, Hashable, Sendable {
    public let pid: Int32
    public let command: String
    public let power: Double
    public var id: Int32 { pid }
}

public enum BatteryReader {
    /// nil on Macs without a battery.
    public static func read(runner: CommandRunner = ProcessRunner()) async -> BatteryHealth? {
        guard let registry = registryProperties() else { return nil }
        let profiler = await runner.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]).output
        return parse(registry: registry, profiler: profiler)
    }

    /// The processes using the most energy right now.
    public static func topEnergyUsers(runner: CommandRunner = ProcessRunner(), limit: Int = 6) async -> [EnergyUse] {
        // Two samples one second apart: the first sample's power column is always zero.
        let result = await runner.run("/usr/bin/top", ["-l", "2", "-s", "1", "-o", "power", "-stats", "pid,power,command", "-n", "\(limit + 4)"])
        return Array(parseTop(result.output).prefix(limit))
    }

    static func registryProperties() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any],
              dictionary["BatteryInstalled"] as? Bool != false
        else { return nil }
        return dictionary
    }

    static func parse(registry: [String: Any], profiler: String) -> BatteryHealth {
        let data = registry["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String, in dictionary: [String: Any]) -> Int? { (dictionary[key] as? NSNumber)?.intValue }

        // 65535 means "still estimating".
        let charging = registry["IsCharging"] as? Bool ?? false
        let remaining = int(charging ? "AvgTimeToFull" : "AvgTimeToEmpty", in: registry).flatMap { $0 > 0 && $0 < 65535 ? $0 : nil }
        // Amperage is a signed 64-bit value delivered as unsigned; reinterpret it.
        let amperage = (registry["Amperage"] as? NSNumber).map { Int64(bitPattern: $0.uint64Value) }
        let voltage = int("Voltage", in: registry)
        let watts = amperage.flatMap { amps in voltage.map { Double(amps) * Double($0) / 1_000_000 } }

        var health = BatteryHealth(
            cycleCount: int("CycleCount", in: registry) ?? 0,
            designCycleCount: int("DesignCycleCount9C", in: registry),
            maximumCapacityPercent: nil,
            condition: nil,
            chargePercent: int("CurrentCapacity", in: registry) ?? 0,
            isCharging: charging,
            isPluggedIn: registry["ExternalConnected"] as? Bool ?? false,
            minutesRemaining: remaining,
            watts: watts.flatMap { abs($0) < 0.05 ? nil : $0 },
            designCapacity: int("DesignCapacity", in: data),
            fullChargeCapacity: int("NominalChargeCapacity", in: data) ?? int("FullChargeCapacity", in: data))

        // Settings › Battery shows system_profiler's figures; use them so the numbers match.
        if let json = profiler.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
           let entries = root["SPPowerDataType"] as? [[String: Any]],
           let info = entries.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first {
            health.condition = info["sppower_battery_health"] as? String
            if let text = info["sppower_battery_health_maximum_capacity"] as? String {
                health.maximumCapacityPercent = Int(text.filter(\.isNumber))
            }
            if let cycles = (info["sppower_battery_cycle_count"] as? NSNumber)?.intValue { health.cycleCount = cycles }
        }
        if health.maximumCapacityPercent == nil, let design = health.designCapacity, let full = health.fullChargeCapacity, design > 0 {
            health.maximumCapacityPercent = min(100, full * 100 / design)
        }
        return health
    }

    /// The last sample of `top -stats pid,power,command`, highest power first, idle processes left out.
    static func parseTop(_ output: String) -> [EnergyUse] {
        let samples = output.components(separatedBy: "PID ")
        guard let last = samples.last else { return [] }
        return last.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let power = Double(parts[1]), power > 0 else { return nil }
            let command = String(parts[2]).trimmingCharacters(in: .whitespaces)
            // top itself and the kernel aren't anything the user can act on.
            guard command != "top", command != "kernel_task" else { return nil }
            return EnergyUse(pid: pid, command: command, power: power)
        }
        .sorted { $0.power > $1.power }
    }
}
