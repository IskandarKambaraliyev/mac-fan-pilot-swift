import Foundation
import IOKit

enum SMCError: Error, CustomStringConvertible {
    case open(kern_return_t), io(kern_return_t), smc(UInt8), unsupportedType(String), sizeMismatch
    var description: String {
        switch self {
        case .open(let k): return "SMC open failed (\(k))"
        case .io(let k): return "IOKit call failed (0x\(String(UInt32(bitPattern: k), radix: 16)))"
        case .smc(let r): return "SMC result 0x\(String(r, radix: 16))"   // 0x84 = key not found
        case .unsupportedType(let t): return "Unsupported type '\(t)'"
        case .sizeMismatch: return "Data size mismatch"
        }
    }
}

/// Not thread-safe. Use one instance per serial queue / actor.
final class SMC: SMCAccess {
    private var conn: io_connect_t = 0
    private var infoCache: [String: SMCKeyInfoData] = [:]

    init() throws {
        let kr = SMCOpen(&conn)
        guard kr == kIOReturnSuccess else { throw SMCError.open(kr) }
    }
    deinit { SMCClose(conn) }

    // MARK: Low level

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        let kr = SMCCall(conn, &input, &output)
        guard kr == kIOReturnSuccess else { throw SMCError.io(kr) }
        guard output.result == 0 else { throw SMCError.smc(output.result) }
        return output
    }

    func keyInfo(_ key: String) throws -> SMCKeyInfoData {
        if let cached = infoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = key.fourCC
        input.data8 = UInt8(kSMCCmdKeyInfo)
        let info = try call(&input).keyInfo
        infoCache[key] = info
        return info
    }

    func read(_ key: String) throws -> SMCValue {
        let info = try keyInfo(key)
        var input = SMCParamStruct()
        input.key = key.fourCC
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(kSMCCmdReadKey)
        let out = try call(&input)
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return SMCValue(key: key, type: info.dataType.fourCCString, bytes: bytes)
    }

    func write(_ key: String, bytes: [UInt8]) throws {
        let info = try keyInfo(key)
        guard bytes.count == Int(info.dataSize), bytes.count <= 32 else { throw SMCError.sizeMismatch }
        var input = SMCParamStruct()
        input.key = key.fourCC
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(kSMCCmdWriteKey)
        withUnsafeMutableBytes(of: &input.bytes) { buf in
            for (i, b) in bytes.enumerated() { buf[i] = b }
        }
        _ = try call(&input)
    }

    // MARK: Convenience

    func double(_ key: String) throws -> Double {
        let v = try read(key)
        guard let d = v.doubleValue else { throw SMCError.unsupportedType(v.type) }
        return d
    }

    func write(_ key: String, value: Double) throws {
        let type = try keyInfo(key).dataType.fourCCString
        guard let bytes = SMCValue.encode(value, type: type) else { throw SMCError.unsupportedType(type) }
        try write(key, bytes: bytes)
    }

    func keyCount() throws -> Int { Int(try double("#KEY")) }

    func key(at index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = UInt8(kSMCCmdKeyByIndex)
        input.data32 = UInt32(index)
        return try call(&input).key.fourCCString
    }

    func allKeys() -> [String] {
        guard let n = try? keyCount() else { return [] }
        return (0..<n).compactMap { try? key(at: $0) }
    }

    func isFloat(_ key: String) -> Bool {
        (try? keyInfo(key)).map { $0.dataType.fourCCString == "flt " && $0.dataSize == 4 } ?? false
    }
}
