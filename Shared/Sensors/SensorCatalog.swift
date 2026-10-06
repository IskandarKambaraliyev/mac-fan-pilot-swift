import Foundation

enum SensorGroup: String, Codable, CaseIterable, Identifiable {
    case cpuMax, cpuAverage, gpuMax, hottest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpuMax: "CPU (hottest core)"
        case .cpuAverage: "CPU (average)"
        case .gpuMax: "GPU"
        case .hottest: "Hottest sensor"
        }
    }
}

/// Which SMC keys are temperature sensors on this Mac.
///
/// Apple Silicon names its die sensors by cluster: `Tp**` performance cores, `Te**` efficiency
/// cores, `Tg**` GPU. Discovering by family works across M1–M4 without a per-chip table. Verified
/// on an M3 Pro: under CPU load every top riser is a `Tp` key, while other `T` keys (`Tf16`,
/// `TVHG`, …) are constants that never move and must stay out of the control groups.
struct SensorCatalog {
    /// Used only when a family scan finds nothing (M3 Max-class chips expose cores as `Tf**`).
    static let cpuFallback = ["Te05", "Te0L", "Te0P", "Te0S",
                              "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                              "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
    static let gpuFallback = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]

    let cpuKeys: [String]
    let gpuKeys: [String]
    /// Every `T***` float that currently reads like a temperature. For the Sensors tab, and the
    /// last-resort source for "hottest" on a chip where no CPU or GPU key was recognised.
    let allTempKeys: [String]

    static func plausible(_ v: Double?) -> Bool { v.map { (5...130).contains($0) } ?? false }

    /// Enumerates the whole key table (~0.4 s). Do it once per process.
    static func discover(using smc: SMCAccess) -> SensorCatalog {
        let temps = smc.allKeys().filter { $0.hasPrefix("T") && smc.isFloat($0) }.sorted()
        func family(_ prefixes: [String], fallback: [String]) -> [String] {
            let found = temps.filter { key in prefixes.contains { key.hasPrefix($0) } }
            return found.isEmpty ? fallback.filter(smc.isFloat) : found
        }
        return SensorCatalog(cpuKeys: family(["Tp", "Te"], fallback: cpuFallback),
                             gpuKeys: family(["Tg"], fallback: gpuFallback),
                             allTempKeys: temps.filter { plausible(try? smc.double($0)) })
    }

    func kind(of key: String) -> String {
        if cpuKeys.contains(key) { return "CPU" }
        if gpuKeys.contains(key) { return "GPU" }
        return ""
    }

    /// Keys outside the CPU and GPU families whose meaning is known. `TB*T` matches the battery
    /// temperature that `ioreg` reports on an M3 Pro; `TH0*` is the SSD in community key lists.
    private static let knownPrefixes = [(prefix: "TB", name: "Battery"), (prefix: "TH0", name: "SSD")]

    /// A readable name for the Sensors tab; empty when the key's meaning isn't known. A chip has
    /// several die sensors per core, so CPU and GPU keys are numbered rather than named by core.
    func name(of key: String) -> String {
        if let i = cpuKeys.firstIndex(of: key) { return "CPU sensor \(i + 1)" }
        if let i = gpuKeys.firstIndex(of: key) { return "GPU sensor \(i + 1)" }
        return Self.knownPrefixes.first { key.hasPrefix($0.prefix) }?.name ?? ""
    }
}

/// Reads the sensor groups without paying for every key on every tick.
///
/// One SMC read costs about 0.15 ms and a Mac exposes dozens of core sensors, so between full
/// passes only the hottest few keys of each family are polled.
final class SensorSampler {
    private static let hotCount = 6
    private static let fullEvery = 5

    private struct Family {
        let keys: [String]
        var hot: [String] = []
        var max: Double?
        var average: Double?

        mutating func refresh(full: Bool, smc: SMCAccess) {
            func read(_ keys: [String]) -> [(key: String, value: Double)] {
                keys.compactMap { k in (try? smc.double(k)).flatMap { SensorCatalog.plausible($0) ? (k, $0) : nil } }
            }
            if !full {
                if let m = read(hot).map(\.value).max() { max = m; return }
                // The hot set went quiet; fall through to a full pass before reporting a failure.
            }
            let all = read(keys).sorted { $0.value > $1.value }
            hot = all.prefix(SensorSampler.hotCount).map(\.key)
            max = all.first?.value
            average = all.isEmpty ? nil : all.reduce(0) { $0 + $1.value } / Double(all.count)
        }
    }

    private let smc: SMCAccess
    let catalog: SensorCatalog
    private var cpu: Family
    private var gpu: Family
    private var other: Family
    private var tick = 0

    /// Set when a curve follows `cpuAverage`, which needs every CPU key on every tick.
    var alwaysFullCPU = false

    init(smc: SMCAccess) {
        self.smc = smc
        catalog = SensorCatalog.discover(using: smc)
        cpu = Family(keys: catalog.cpuKeys)
        gpu = Family(keys: catalog.gpuKeys)
        // Only consulted on a chip where neither family was recognised.
        other = Family(keys: catalog.cpuKeys.isEmpty && catalog.gpuKeys.isEmpty ? catalog.allTempKeys : [])
    }

    /// Makes the next sample a full pass (after wake, or when a new preset starts).
    func reset() { tick = 0 }

    /// Groups that could not be read are absent from the result.
    func sample() -> [SensorGroup: Double] {
        let full = tick % Self.fullEvery == 0
        tick += 1
        cpu.refresh(full: full || alwaysFullCPU, smc: smc)
        gpu.refresh(full: full, smc: smc)
        other.refresh(full: full, smc: smc)

        var out: [SensorGroup: Double] = [:]
        out[.cpuMax] = cpu.max
        out[.cpuAverage] = cpu.average
        out[.gpuMax] = gpu.max
        out[.hottest] = [cpu.max, gpu.max, other.max].compactMap { $0 }.max()
        return out
    }
}
