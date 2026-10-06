import Foundation

// Usage: smcdump [--temps]
// Prints every readable SMC key. Reading needs no privileges.

let smc = try SMC()
let onlyTemps = CommandLine.arguments.contains("--temps")
for key in smc.allKeys() {
    if onlyTemps && !key.hasPrefix("T") { continue }
    guard let v = try? smc.read(key) else { continue }
    let num = v.doubleValue.map { String(format: "%.2f", $0) } ?? v.bytes.map { String(format: "%02x", $0) }.joined()
    print("\(key)  [\(v.type)]  \(num)")
}
