import Foundation

extension String {
    /// "F0Ac" -> 0x46304163
    var fourCC: UInt32 { utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
}

extension UInt32 {
    var fourCCString: String {
        let bytes = [24, 16, 8, 0].map { UInt8((self >> UInt32($0)) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}

struct SMCValue {
    let key: String
    let type: String      // e.g. "flt ", "ui8 "
    let bytes: [UInt8]

    var doubleValue: Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default:
            return nil
        }
    }

    static func encode(_ value: Double, type: String) -> [UInt8]? {
        guard value.isFinite else { return nil }
        switch type {
        case "flt ": return withUnsafeBytes(of: Float(value)) { Array($0) }   // little-endian on arm64
        case "ui8 ": return [UInt8(clamping: Int(value.rounded()))]
        case "ui16":
            let v = UInt16(clamping: Int(value.rounded()))
            return [UInt8(v >> 8), UInt8(v & 0xFF)]
        default: return nil
        }
    }
}
