import Foundation

struct FanReading: Identifiable, Hashable {
    let id: Int
    let rpm: Double, min: Double, max: Double
    let manual: Bool
    var fraction: Double { max > min ? (rpm - min) / (max - min) : 0 }
}

struct SensorReading: Identifiable, Hashable {
    let id: String   // SMC key
    let name: String // "" when the key's meaning isn't known
    let value: Double
}

/// Read-only sensor polling for the UI. Runs off the main thread; publishes snapshots via callback.
final class SensorMonitor {
    struct Snapshot {
        var fans: [FanReading] = []
        var groups: [SensorGroup: Double] = [:]
        var raw: [SensorReading] = []
    }

    private let queue = DispatchQueue(label: FP.appBundleID + ".monitor", qos: .utility)
    // Everything below is touched on `queue` only.
    private var smc: SMC?
    private var sampler: SensorSampler?
    private var fanLimits: [(min: Double, max: Double)] = []
    private var rawKeys: [(key: String, name: String)] = []
    private var timer: DispatchSourceTimer?
    private var onUpdate: ((Snapshot) -> Void)?
    private var includeRaw = false

    func start(interval: Double, onUpdate: @escaping (Snapshot) -> Void) {
        queue.async {
            self.onUpdate = onUpdate
            if self.smc == nil, let smc = try? SMC() {
                self.smc = smc
                let sampler = SensorSampler(smc: smc)
                self.sampler = sampler
                // A fixed order (CPU, GPU, the rest) so rows in the Sensors tab don't jump around.
                let catalog = sampler.catalog
                let rank = ["CPU": 0, "GPU": 1]
                self.rawKeys = catalog.allTempKeys
                    .sorted { (rank[catalog.kind(of: $0)] ?? 2, $0) < (rank[catalog.kind(of: $1)] ?? 2, $1) }
                    .map { ($0, catalog.name(of: $0)) }
                self.fanLimits = (0..<smc.fanCount()).map { i in
                    ((try? smc.double("F\(i)Mn")) ?? 0, (try? smc.double("F\(i)Mx")) ?? 0)
                }
            }
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(200))
            t.setEventHandler { [weak self] in self?.publish() }
            t.resume()
            self.timer = t
        }
    }

    /// Raw per-key readings are only needed while the Sensors tab is on screen.
    func setIncludeRaw(_ on: Bool) {
        queue.async {
            self.includeRaw = on
            if on { self.publish() }
        }
    }

    /// Publish a fresh snapshot now instead of waiting for the next tick.
    func refreshNow(fullPass: Bool = false) {
        queue.async {
            if fullPass { self.sampler?.reset() }
            self.publish()
        }
    }

    /// Fans and sensors as plain text, for a diagnostics report. Read on the monitor's queue.
    func report(_ completion: @escaping ([String]) -> Void) {
        queue.async { completion(self.reportLines()) }
    }

    private func reportLines() -> [String] {
        guard let smc, let sampler else { return ["SMC: not available"] }
        func value(_ key: String) -> String { (try? smc.double(key)).map { String(Int($0.rounded())) } ?? "?" }

        var lines = fanLimits.indices.map { i in
            "Fan \(i + 1): \(value("F\(i)Ac")) rpm, range \(value("F\(i)Mn"))–\(value("F\(i)Mx")), mode \(value("F\(i)Md"))"
        }
        if lines.isEmpty { lines = ["Fans: none"] }
        lines.append("Unlock flag (Ftst): \(value("Ftst"))")

        let catalog = sampler.catalog
        lines.append("Sensors: \(catalog.cpuKeys.count) CPU, \(catalog.gpuKeys.count) GPU, \(catalog.allTempKeys.count) in total")
        // One line per key family rather than one per key: a Mac exposes a couple of hundred.
        let families = Dictionary(grouping: catalog.allTempKeys) { String($0.prefix(2)) }
        for prefix in families.keys.sorted() {
            let readings = families[prefix, default: []].compactMap { try? smc.double($0) }
            guard let low = readings.min(), let high = readings.max() else { continue }
            lines.append("  \(prefix)** ×\(readings.count): \(Int(low.rounded()))–\(Int(high.rounded())) °C")
        }
        return lines
    }

    private func publish() {
        guard let onUpdate, let snap = read() else { return }
        DispatchQueue.main.async { onUpdate(snap) }
    }

    private func read() -> Snapshot? {
        guard let smc, let sampler else { return nil }
        var s = Snapshot()
        for (i, limits) in fanLimits.enumerated() {
            s.fans.append(FanReading(
                id: i,
                rpm: (try? smc.double("F\(i)Ac")) ?? 0,
                min: limits.min,
                max: limits.max,
                manual: (try? smc.double("F\(i)Md")) == 1))
        }
        s.groups = sampler.sample()
        if includeRaw {
            s.raw = rawKeys.compactMap { entry in
                (try? smc.double(entry.key)).map { SensorReading(id: entry.key, name: entry.name, value: $0) }
            }
        }
        return s
    }
}
