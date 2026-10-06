import Foundation

/// The part of the SMC that sensor discovery and the control loop use. `SMC` is the real one;
/// the tests run the same code against a fake.
protocol SMCAccess: AnyObject {
    func double(_ key: String) throws -> Double
    func write(_ key: String, value: Double) throws
    func allKeys() -> [String]
    /// A 4-byte `flt ` key, which is how Apple Silicon reports temperatures.
    func isFloat(_ key: String) -> Bool
}

extension SMCAccess {
    func fanCount() -> Int { Int((try? double("FNum")) ?? 0) }
}
