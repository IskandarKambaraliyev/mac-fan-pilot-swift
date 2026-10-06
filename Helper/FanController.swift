import Foundation
import os

enum ControlError: Error, CustomStringConvertible {
    case noFans, sensorsUnreadable, superseded
    var description: String {
        switch self {
        case .noFans: return "This Mac has no controllable fans."
        case .sensorsUnreadable: return "Temperature sensors could not be read."
        case .superseded: return "Replaced by a newer request."
        }
    }
}

final class FanController {
    /// The clock, the waits and the marker file. Tests replace them to step the loop by hand.
    struct Environment {
        /// Seconds on a clock that keeps running during sleep, so a long sleep trips the watchdog.
        var now: () -> Double = { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
        var markerPath = FP.helperActiveMarker
        /// Off in tests, which call `tick()` themselves.
        var runsTimer = true
    }

    private let log = Logger(subsystem: FP.helperLabel, category: "fan")
    private let queue = DispatchQueue(label: FP.helperLabel + ".control")
    private let smc: SMCAccess
    private let env: Environment
    private let sampler: SensorSampler

    struct FanLimits { let min: Double; let max: Double }
    private var limits: [Int: FanLimits] = [:]

    private var preset: Preset?
    private var status: HelperStatus = .idle
    private var timer: DispatchSourceTimer?
    private var lastHeartbeat: Double
    private var unlocked = false          // we raised Ftst
    private var held = Set<Int>()         // fans we switched to manual
    private var markerWritten = false
    private var emergency = false
    private var lastTarget: [Int: Double] = [:]
    private var smoothedTemp: [SensorGroup: Double] = [:]
    private var sensorFailures = 0
    private var controlFailures = 0
    private var releaseRetries = 0
    private var releaseRetryPending = false

    /// Bumped by every new command, so a tick stuck waiting for macOS to release a fan gives way.
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    init(smc: SMCAccess, environment: Environment = Environment()) {
        self.smc = smc
        env = environment
        sampler = SensorSampler(smc: smc)
        lastHeartbeat = environment.now()
        for i in 0..<smc.fanCount() {
            guard let mn = try? smc.double("F\(i)Mn"), let mx = try? smc.double("F\(i)Mx"),
                  mn >= 0, mx > mn else { continue }
            limits[i] = FanLimits(min: mn, max: mx)
        }
        log.info("fans: \(self.limits.count), cpu sensors: \(self.sampler.catalog.cpuKeys.count), gpu sensors: \(self.sampler.catalog.gpuKeys.count)")

        // A previous instance died while holding the fans: hand them back before anything else.
        if FileManager.default.fileExists(atPath: env.markerPath) {
            log.warning("found stale control marker → auto")
            markerWritten = true
            held = Set(limits.keys.filter { (try? smc.double("F\($0)Md")) == 1 })
            unlocked = (try? smc.double("Ftst")) == 1
            releaseLocked(status: .idle)
        }
    }

    // MARK: Public API (thread-safe via queue)

    func apply(_ requested: Preset) throws {
        let gen = generation.withLock { $0 += 1; return $0 }
        try queue.sync {
            lastHeartbeat = env.now()
            let p = requested.sanitized
            if p.isAllAuto { releaseLocked(status: .idle); return }
            guard !limits.isEmpty else { throw ControlError.noFans }

            preset = p
            status = .controlling
            emergency = false
            lastTarget.removeAll()
            smoothedTemp.removeAll()
            sensorFailures = 0
            controlFailures = 0
            sampler.alwaysFullCPU = p.uses(.cpuAverage)
            sampler.reset()
            do {
                try tickLocked(generation: gen, unlockTimeout: FP.unlockTimeout)
            } catch {
                log.error("apply failed: \(String(describing: error), privacy: .public)")
                releaseLocked(status: .idle)   // the caller gets the error directly
                throw error
            }
            startTimerLocked()
        }
    }

    /// false while a fan could not be handed back yet. The controller keeps retrying on its own,
    /// and the process must stay alive until it succeeds.
    @discardableResult
    func resetToAuto() -> Bool {
        generation.withLock { $0 += 1 }
        return queue.sync {
            releaseLocked(status: .idle)
            return !isHolding
        }
    }

    func heartbeat(_ reply: @escaping (HelperStatus) -> Void) {
        queue.async {
            self.lastHeartbeat = self.env.now()
            reply(self.status == .controlling && self.emergency ? .emergency : self.status)
        }
    }

    /// One pass of the control loop. The timer does this every `FP.controlInterval`; tests call
    /// it to step the loop by hand.
    func tick() { queue.sync { timerFiredLocked() } }

    // MARK: Loop

    private func startTimerLocked() {
        guard timer == nil, env.runsTimer else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + FP.controlInterval, repeating: FP.controlInterval, leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.timerFiredLocked() }
        t.resume()
        timer = t
    }

    private func timerFiredLocked() {
        guard preset != nil else { return }

        // Watchdog: app gone or frozen → give control back to the system.
        if env.now() - lastHeartbeat > FP.heartbeatTimeout {
            log.warning("heartbeat timeout → auto")
            releaseLocked(status: .watchdogReset)
            return
        }

        do {
            try tickLocked(generation: generation.withLock { $0 }, unlockTimeout: FP.retakeTimeout)
            controlFailures = 0
        } catch ControlError.sensorsUnreadable {
            log.error("sensors unreadable → auto")
            releaseLocked(status: .sensorFailure)
        } catch ControlError.superseded {
            // A new command is waiting for this queue and will decide what happens next.
        } catch {
            controlFailures += 1
            log.error("control error \(self.controlFailures): \(String(describing: error), privacy: .public)")
            if controlFailures >= FP.maxControlFailures { releaseLocked(status: .controlFailure) }
        }
    }

    /// One control pass. Throws `sensorsUnreadable` when temperatures are gone for good, and SMC
    /// errors when a fan write fails.
    private func tickLocked(generation gen: Int, unlockTimeout: TimeInterval) throws {
        guard let preset else { return }

        let temps = sampler.sample()
        guard let hottest = temps[.hottest] else {
            sensorFailures += 1
            // Nothing to hold on the very first pass, so fail the apply outright.
            if sensorFailures >= FP.maxSensorFailures || lastTarget.isEmpty { throw ControlError.sensorsUnreadable }
            return   // keep the previous targets for a tick or two
        }
        sensorFailures = 0

        // Emergency: anything very hot → max on all fans. Hysteresis stops it flapping at 100 °C.
        if hottest >= FP.emergencyTemp {
            if !emergency { log.warning("emergency: \(hottest, format: .fixed(precision: 1)) °C → max") }
            emergency = true
        } else if hottest <= FP.emergencyReleaseTemp {
            emergency = false
        }

        // Exponential smoothing so short spikes don't cause audible jumps. Once per tick, not per fan.
        for (group, raw) in temps {
            smoothedTemp[group] = smoothedTemp[group].map { $0 * (1 - FP.tempSmoothing) + raw * FP.tempSmoothing } ?? raw
        }

        for fan in limits.keys.sorted() {
            guard let lim = limits[fan] else { continue }
            let mode = emergency ? .fixedPercent(1.0) : preset.mode(forFan: fan)
            if let rpm = targetRPM(for: mode, limits: lim, fan: fan) {
                try setManual(fan: fan, rpm: rpm, generation: gen, unlockTimeout: unlockTimeout)
            } else {
                try setAuto(fan: fan)
            }
        }
    }

    /// nil = this fan should be on Auto.
    private func targetRPM(for mode: FanMode, limits l: FanLimits, fan: Int) -> Double? {
        var target: Double
        switch mode {
        case .auto:
            // Raising Ftst takes every fan away from macOS, so a fan left on "auto" next to a
            // manual one would be driven by nobody. Give it a conservative curve instead.
            guard unlocked else { return nil }
            target = l.min + (l.max - l.min) * Curve.balanced.percent(at: smoothedTemp[.hottest] ?? FP.emergencyTemp)
        case .fixedRPM(let r):
            target = r
        case .fixedPercent(let p):
            target = l.min + (l.max - l.min) * p
        case .curve(let curve):
            // An unrecognised chip has no CPU/GPU groups; the hottest sensor stands in.
            guard let t = smoothedTemp[curve.sensor] ?? smoothedTemp[.hottest] else { return lastTarget[fan] ?? l.max }
            target = l.min + (l.max - l.min) * curve.percent(at: t)
        }
        guard target.isFinite else { return l.max }
        // Ramp up immediately, ramp down slowly.
        if let last = lastTarget[fan], target < last {
            target = max(target, last - FP.maxRampDownPerTick)
        }
        target = min(max(target, l.min), l.max)     // never below Apple's minimum
        lastTarget[fan] = target
        return target
    }

    // MARK: SMC writes

    private func setManual(fan: Int, rpm: Double, generation gen: Int, unlockTimeout: TimeInterval) throws {
        let md = "F\(fan)Md"
        if (try? smc.double(md)) != 1 {
            writeMarker()
            do {
                try smc.write(md, value: 1)
            } catch {
                // M3 and newer: thermalmonitord owns the fans until Ftst is raised, and even then
                // it needs a few seconds to let go.
                if !unlocked { try smc.write("Ftst", value: 1); unlocked = true }
                try retry(timeout: unlockTimeout, interval: 0.25, generation: gen) { try self.smc.write(md, value: 1) }
            }
        }
        held.insert(fan)
        try smc.write("F\(fan)Tg", value: rpm)   // re-asserted every tick
    }

    private func setAuto(fan: Int) throws {
        lastTarget[fan] = nil
        guard held.contains(fan) else { return }
        try smc.write("F\(fan)Md", value: 0)
        held.remove(fan)
    }

    /// A fan is still in manual mode, or the unlock flag is still raised.
    private var isHolding: Bool { !held.isEmpty || unlocked }

    /// Hands every fan back to macOS, and keeps trying in the background while a write is refused.
    private func releaseLocked(status newStatus: HelperStatus) {
        timer?.cancel(); timer = nil
        preset = nil
        status = newStatus
        emergency = false
        lastTarget.removeAll()
        smoothedTemp.removeAll()

        held = held.filter { !giveBack(fan: $0) }
        if unlocked, (try? smc.write("Ftst", value: 0)) != nil { unlocked = false }

        guard isHolding else {
            releaseRetries = 0
            if markerWritten {
                try? FileManager.default.removeItem(atPath: env.markerPath)
                markerWritten = false
                log.info("all fans → auto")
            }
            return
        }
        guard !releaseRetryPending else { return }   // one retry chain, however often this is called
        releaseRetryPending = true
        releaseRetries += 1
        let fast = releaseRetries <= FP.fastReleaseRetries
        if fast {
            log.error("could not release fans \(self.held.sorted(), privacy: .public); retrying")
        } else if releaseRetries == FP.fastReleaseRetries + 1 {
            log.fault("fans \(self.held.sorted(), privacy: .public) still held; retrying every 10 s")
        }
        queue.asyncAfter(deadline: .now() + (fast ? 2 : 10)) { [weak self] in
            guard let self else { return }
            self.releaseRetryPending = false
            guard self.preset == nil, self.isHolding else { return }
            self.releaseLocked(status: self.status)
        }
    }

    /// true once the fan is no longer in manual mode.
    private func giveBack(fan: Int) -> Bool {
        let md = "F\(fan)Md"
        for _ in 0..<5 {
            try? smc.write(md, value: 0)
            if (try? smc.double(md)) != 1 { return true }
            env.sleep(0.05)
        }
        return false
    }

    private func writeMarker() {
        guard !markerWritten else { return }
        markerWritten = FileManager.default.createFile(atPath: env.markerPath, contents: nil)
    }

    private func retry(timeout: TimeInterval, interval: TimeInterval, generation gen: Int,
                       _ body: () throws -> Void) throws {
        let deadline = env.now() + timeout
        while true {
            do { try body(); return } catch {
                guard generation.withLock({ $0 }) == gen else { throw ControlError.superseded }
                guard env.now() + interval < deadline else { throw error }
            }
            env.sleep(interval)
        }
    }
}
