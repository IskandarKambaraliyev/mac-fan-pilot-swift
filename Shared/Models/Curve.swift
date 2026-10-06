import Foundation

struct CurvePoint: Codable, Hashable, Identifiable {
    var id = UUID()
    var temp: Double      // °C
    var percent: Double   // 0...1 of the fan's [min, max] range
}

struct Curve: Codable, Hashable {
    static let minPoints = 2
    static let maxPoints = 8

    var sensor: SensorGroup = .cpuMax
    var points: [CurvePoint]

    /// Linear interpolation, clamped at both ends.
    func percent(at t: Double) -> Double {
        let p = points.sorted { $0.temp < $1.temp }
        guard let first = p.first, let last = p.last else { return 0 }
        if t <= first.temp { return first.percent }
        guard let i = p.firstIndex(where: { $0.temp > t }), i > 0 else { return last.percent }
        let a = p[i - 1], b = p[i]
        return a.percent + (b.percent - a.percent) * (t - a.temp) / (b.temp - a.temp)
    }

    /// Drops unusable points and clamps the rest; nil if nothing usable is left.
    var sanitized: Curve? {
        let clean = points
            .filter { $0.temp.isFinite && $0.percent.isFinite }
            .prefix(Self.maxPoints)
            .map { CurvePoint(id: $0.id, temp: $0.temp, percent: min(max($0.percent, 0), 1)) }
        return clean.isEmpty ? nil : Curve(sensor: sensor, points: clean)
    }

    static let balanced = Curve(points: [
        .init(temp: 50, percent: 0), .init(temp: 65, percent: 0.25),
        .init(temp: 80, percent: 0.6), .init(temp: 92, percent: 1.0)])

    static let performance = Curve(points: [
        .init(temp: 40, percent: 0.15), .init(temp: 55, percent: 0.4),
        .init(temp: 70, percent: 0.75), .init(temp: 85, percent: 1.0)])
}

// Decoding accepts files written by other versions: fields added after 1.0 are optional, and an
// unknown sensor falls back to the hottest one, which never asks for less cooling.
extension CurvePoint {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  temp: try c.decode(Double.self, forKey: .temp),
                  percent: try c.decode(Double.self, forKey: .percent))
    }
}

extension Curve {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sensor = try c.decodeIfPresent(String.self, forKey: .sensor).map { SensorGroup(rawValue: $0) ?? .hottest }
        self.init(sensor: sensor ?? .cpuMax, points: try c.decode([CurvePoint].self, forKey: .points))
    }
}
