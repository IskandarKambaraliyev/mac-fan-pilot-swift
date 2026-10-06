import Foundation

enum FanMode: Codable, Hashable {
    case auto
    case fixedPercent(Double)   // 0...1 of [min, max]
    case fixedRPM(Double)
    case curve(Curve)

    /// Anything the helper can't safely act on becomes `.auto`.
    var sanitized: FanMode {
        switch self {
        case .auto: return .auto
        case .fixedPercent(let p): return p.isFinite ? .fixedPercent(min(max(p, 0), 1)) : .auto
        case .fixedRPM(let r): return r.isFinite ? .fixedRPM(max(r, 0)) : .auto
        case .curve(let c): return c.sanitized.map(FanMode.curve) ?? .auto
        }
    }

    var curveSensor: SensorGroup? {
        if case .curve(let c) = self { return c.sensor }
        return nil
    }
}

struct Preset: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var symbol: String          // SF Symbol for the menu
    var isBuiltIn: Bool
    var mode: FanMode           // applies to all fans
    var perFan: [Int: FanMode] = [:]   // optional overrides by fan index

    func mode(forFan index: Int) -> FanMode { perFan[index] ?? mode }

    var isAllAuto: Bool {
        mode == .auto && perFan.values.allSatisfy { $0 == .auto }
    }

    func uses(_ sensor: SensorGroup) -> Bool {
        ([mode] + perFan.values).contains { $0.curveSensor == sensor }
    }

    var sanitized: Preset {
        var p = self
        p.mode = mode.sanitized
        p.perFan = perFan.mapValues(\.sanitized)
        return p
    }

    // Stable IDs so built-ins survive app updates.
    static let automatic = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                  name: "Automatic", symbol: "a.circle", isBuiltIn: true, mode: .auto)
    static let balanced  = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                                  name: "Balanced", symbol: "dial.medium", isBuiltIn: true, mode: .curve(.balanced))
    static let performance = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                                  name: "Performance", symbol: "bolt", isBuiltIn: true, mode: .curve(.performance))
    static let fullBlast = Preset(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                                  name: "Full Blast", symbol: "wind", isBuiltIn: true, mode: .fixedPercent(1.0))

    static let builtIns = [automatic, balanced, performance, fullBlast]
}
