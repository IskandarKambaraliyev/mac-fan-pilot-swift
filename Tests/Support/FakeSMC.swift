import Foundation

/// An in-memory SMC: two fans on Auto and a few CPU and GPU sensors. Tests script failures by
/// setting `refuse`, and make a sensor unreadable by setting its value to nil.
final class FakeSMC: SMCAccess {
    struct Refused: Error {}

    static let cpuKeys = ["Tp01", "Tp05", "Te05"]
    static let gpuKeys = ["Tg05", "Tg0D"]

    var values: [String: Double] = [:]
    /// Return true to make that write fail.
    var refuse: (_ key: String, _ value: Double) -> Bool = { _, _ in false }
    private(set) var reads: [String] = []

    init(fans: Int = 2, temp: Double = 50) {
        values["FNum"] = Double(fans)
        values["Ftst"] = 0
        for i in 0..<fans {
            values["F\(i)Mn"] = 1200
            values["F\(i)Mx"] = 6000
            values["F\(i)Md"] = 0
            values["F\(i)Tg"] = 0
        }
        setTemps(cpu: temp, gpu: temp)
    }

    func setTemps(cpu: Double?, gpu: Double?) {
        for key in Self.cpuKeys { values[key] = cpu }
        for key in Self.gpuKeys { values[key] = gpu }
    }

    func clearReads() { reads.removeAll() }

    func double(_ key: String) throws -> Double {
        reads.append(key)
        guard let value = values[key] else { throw Refused() }
        return value
    }

    func write(_ key: String, value: Double) throws {
        if refuse(key, value) { throw Refused() }
        values[key] = value
    }

    func allKeys() -> [String] { values.keys.sorted() }
    func isFloat(_ key: String) -> Bool { values[key] != nil && key != "FNum" && key != "Ftst" && !key.hasSuffix("Md") }
}
