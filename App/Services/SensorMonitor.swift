import Foundation

struct FanReading: Identifiable, Hashable {
    let id: Int
    let rpm: Double, min: Double, max: Double, target: Double
    let manual: Bool
    var fraction: Double { max > min ? (rpm - min) / (max - min) : 0 }
}

struct SensorReading: Identifiable, Hashable {
    let id: String   // SMC key
    let value: Double
    let kind: String // "CPU", "GPU" or ""
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
    private var rawKeys: [(key: String, kind: String)] = []
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
                self.rawKeys = catalog.allTempKeys.map { ($0, catalog.kind(of: $0)) }.sorted {
                    let rank = ["CPU": 0, "GPU": 1]
                    return (rank[$0.kind] ?? 2, $0.key) < (rank[$1.kind] ?? 2, $1.key)
                }
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
                target: (try? smc.double("F\(i)Tg")) ?? 0,
                manual: (try? smc.double("F\(i)Md")) == 1))
        }
        s.groups = sampler.sample()
        if includeRaw {
            s.raw = rawKeys.compactMap { entry in
                (try? smc.double(entry.key)).map { SensorReading(id: entry.key, value: $0, kind: entry.kind) }
            }
        }
        return s
    }
}
