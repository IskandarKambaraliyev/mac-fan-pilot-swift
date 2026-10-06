# FanPilot — Build Guide

> **Archived.** This is the specification MacFanPilot was first built from. It predates the final
> name, uses placeholder identifiers (`com.abdulloh.fanpilot`), and its code listings no longer
> match the source. It is kept for the background in §1 (how fan control works on Apple Silicon).
> For the current design read the [README](../../README.md); for testing and the safety rules read
> [docs/Testing.md](../Testing.md).

A native, minimal macOS menu bar app for monitoring temperatures and controlling fans on Apple Silicon Macs (developed and tested against an **M3 Pro MacBook Pro**).

This document is a full implementation spec: architecture, project setup, SMC layer, privileged helper, fan control logic, presets, UI, login items, signing, testing and troubleshooting. Code is given per file; names and bundle IDs are placeholders you can change.

---

## 0. Assumptions and decisions (gaps filled)

| Topic | Decision |
|---|---|
| App name | **FanPilot** (bundle prefix `com.abdulloh.fanpilot`) |
| Target hardware | Apple Silicon only (M1–M4). Primary target: M3 Pro. Intel code paths are intentionally omitted. |
| macOS | Deployment target **macOS 14 Sonoma** (needed for `@Observable`, `SettingsLink`, `plotFrame`). Works on 15 and 26. |
| Tooling | Xcode 16+, Swift 5 language mode (avoids Swift 6 strict-concurrency churn with XPC/IOKit), SwiftUI only, no third-party dependencies. |
| Distribution | Personal use first: signed with your Apple Development certificate (Team ID required). Developer ID + notarization described for later public release. **Not** Mac App Store (sandbox blocks SMC + root helpers). |
| Units | °C default, °F optional. |
| Control scope | One preset is active at a time; a preset defines a mode for all fans, with optional per-fan overrides. |
| Safety | Fans always return to **Auto** when the app quits, crashes, stops sending heartbeats, the Mac shuts down, or sensors can't be read. Emergency override to max RPM above 100 °C. |
| Dock | No Dock icon (`LSUIElement`). The app lives in the menu bar. |

---

## 1. How fan control works on Apple Silicon

### 1.1 The SMC

Fans and most thermal sensors are owned by the **System Management Controller**, exposed by the kernel as the IOKit service `AppleSMC`. Userspace talks to it through one IOKit external method (selector `2`) with an 80-byte parameter struct. The struct's `data8` field selects the command:

| Command | `data8` | Purpose |
|---|---|---|
| Read key | `5` | Read the bytes of a key |
| Write key | `6` | Write bytes to a key (**root only**) |
| Key by index | `8` | Get the name of key #N (for enumeration) |
| Key info | `9` | Get a key's size and data type |

Keys are 4-character codes. Each has a type, also a 4-char code (note the trailing space in `"flt "`).

### 1.2 Keys used by FanPilot

| Key | Type (Apple Silicon) | Meaning |
|---|---|---|
| `#KEY` | `ui32` | Total number of SMC keys |
| `FNum` | `ui8 ` | Number of fans |
| `F{n}Ac` | `flt ` | Fan n actual RPM |
| `F{n}Mn` | `flt ` | Fan n minimum RPM |
| `F{n}Mx` | `flt ` | Fan n maximum RPM |
| `F{n}Tg` | `flt ` | Fan n target RPM (written in manual mode) |
| `F{n}Md` | `ui8 ` | Fan n mode: `0` auto, `1` manual |
| `Ftst` | `ui8 ` | Fan "test" / unlock flag (see 1.3) |
| `T***` | mostly `flt ` | Temperature sensors (chip-specific names) |

Apple Silicon stores floats as **little-endian IEEE-754 float32** (`flt `). Integer types (`ui8`, `ui16`, `ui32`) are **big-endian**.

### 1.3 M3 / M4 specifics (important)

On M1/M2, writing `F{n}Md = 1` usually works directly. On **M3 and newer**, the mode key is commonly rejected while `thermalmonitord` owns the fans. The community-observed workaround:

1. Write `Ftst = 1`.
2. Retry writing `F{n}Md = 1` for a few seconds (the system needs time to release control).
3. Write `F{n}Tg` and keep re-asserting it every control tick.
4. To restore: write `F{n}Md = 0` for every fan, then `Ftst = 0`.

This is undocumented Apple behavior and can change with any macOS update. FanPilot treats every write as fallible and degrades to **monitoring-only** if control fails.

### 1.4 Temperature sensors on M3 Pro

Sensor key names differ per chip generation. Candidate keys for M3-family chips (as used by open-source monitors), **to be verified on your machine with the `smcdump` tool in §4**:

| Group | Candidate keys |
|---|---|
| CPU efficiency cores | `Te05`, `Te0L`, `Te0P`, `Te0S` |
| CPU performance cores | `Tf04`, `Tf09`, `Tf0A`, `Tf0B`, `Tf0D`, `Tf0E`, `Tf44`, `Tf49`, `Tf4A`, `Tf4B`, `Tf4D`, `Tf4E` |
| GPU | `Tf14`, `Tf18`, `Tf19`, `Tf1A`, `Tf24`, `Tf28`, `Tf29`, `Tf2A` |

FanPilot does not trust this list blindly. At startup it probes every candidate and keeps only keys that exist, are `flt `, and return a plausible value (5–130 °C). It also offers a **Hottest sensor** group built from *every* plausible `T***` key, which works on any chip even if the table is wrong.

---

## 2. Architecture

```
┌──────────────────────────── FanPilot.app (user, non-sandboxed) ───────────────────────────┐
│                                                                                            │
│  SwiftUI MenuBarExtra ── AppModel (@Observable) ── SensorMonitor ── SMC (read-only)        │
│        │                     │                                                             │
│  Settings window        PresetStore (JSON)        LoginItem (SMAppService.mainApp)         │
│                              │                                                             │
│                        HelperClient ── NSXPCConnection (.privileged) ─┐                    │
└───────────────────────────────────────────────────────────────────────┼────────────────────┘
                                                                        │ XPC (code-sign checked)
┌───────────────────────── FanPilotHelper (root, launchd daemon) ───────┼────────────────────┐
│  NSXPCListener ── HelperService ── FanController (serial queue, 1 s loop) ── SMC (r/w)     │
│                                     • evaluates presets / curves                           │
│                                     • heartbeat watchdog → Auto                            │
│                                     • SIGTERM → Auto                                       │
└────────────────────────────────────────────────────────────────────────────────────────────┘
```

Key design points:

- **Reading needs no privileges, writing needs root.** The app reads sensors itself for the UI. Only the helper writes.
- **The helper owns the control loop.** The app sends a whole preset; the helper evaluates curves every second using its own sensor reads. A UI hiccup never leaves fans in a bad state.
- **The helper is the safety net**, not the app: on app disconnect, missed heartbeats, or shutdown, it restores Auto.
- **Shared code is compiled into both targets** (target membership), not a framework, so the daemon has no embedded-framework rpath issues.

---

## 3. Project setup

### 3.1 File layout

```
FanPilot/
├── FanPilot.xcodeproj
├── Shared/                         # member of: FanPilot, FanPilotHelper, smcdump
│   ├── SMC/
│   │   ├── SMCBridge.h
│   │   ├── SMCBridge.c
│   │   ├── SMC.swift
│   │   └── SMCValue.swift
│   ├── Sensors/SensorCatalog.swift
│   ├── Models/Preset.swift
│   ├── Models/Curve.swift
│   ├── XPC/HelperProtocol.swift
│   └── Constants.swift
├── App/                            # member of: FanPilot
│   ├── FanPilotApp.swift
│   ├── AppModel.swift
│   ├── Services/
│   │   ├── SensorMonitor.swift
│   │   ├── PresetStore.swift
│   │   ├── HelperClient.swift
│   │   └── LoginItem.swift
│   ├── Views/
│   │   ├── MenuBarLabel.swift
│   │   ├── MenuContentView.swift
│   │   ├── SettingsView.swift
│   │   ├── PresetEditorView.swift
│   │   ├── CurveEditor.swift
│   │   └── SensorsView.swift
│   ├── FanPilot-Bridging-Header.h
│   └── FanPilot.entitlements
├── Helper/                         # member of: FanPilotHelper
│   ├── main.swift
│   ├── HelperService.swift
│   ├── FanController.swift
│   ├── Helper-Bridging-Header.h
│   └── com.abdulloh.fanpilot.helper.plist   # NOT a target member; copied by build phase
└── Tools/smcdump/main.swift        # member of: smcdump
```

### 3.2 Targets

**1. `FanPilot`** (macOS App, SwiftUI lifecycle)
- Bundle ID: `com.abdulloh.fanpilot`
- Deployment target: macOS 14.0
- Signing & Capabilities: **remove App Sandbox**, keep **Hardened Runtime**
- Info: `Application is agent (UIElement)` = `YES` (`LSUIElement`)
- Build Settings → Objective-C Bridging Header: `App/FanPilot-Bridging-Header.h`
- Swift Language Version: Swift 5

**2. `FanPilotHelper`** (macOS Command Line Tool)
- Bundle ID (`PRODUCT_BUNDLE_IDENTIFIER`): `com.abdulloh.fanpilot.helper`
- `CREATE_INFOPLIST_SECTION_IN_BINARY = YES` (gives the binary a signing identifier)
- `SKIP_INSTALL = YES`
- Hardened Runtime on, same Team as the app
- Bridging Header: `Helper/Helper-Bridging-Header.h`

**3. `smcdump`** (Command Line Tool, dev only, not embedded)

### 3.3 Embedding the helper in the app

On the `FanPilot` target:

1. **Target Dependencies:** add `FanPilotHelper`.
2. **Copy Files** phase → Destination `Executables` → add `FanPilotHelper` (lands in `Contents/MacOS/`). Check *Code Sign On Copy*.
3. **Copy Files** phase → Destination `Wrapper`, Subpath `Contents/Library/LaunchDaemons` → add `com.abdulloh.fanpilot.helper.plist`.

### 3.4 Bridging headers

`App/FanPilot-Bridging-Header.h` and `Helper/Helper-Bridging-Header.h` (and the same for `smcdump`):

```c
#import "SMCBridge.h"
```

Add `$(SRCROOT)/Shared/SMC` to **Header Search Paths** on all three targets.

### 3.5 Launch daemon plist

`Helper/com.abdulloh.fanpilot.helper.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.abdulloh.fanpilot.helper</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/FanPilotHelper</string>
    <key>MachServices</key>
    <dict>
        <key>com.abdulloh.fanpilot.helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.abdulloh.fanpilot</string>
    </array>
</dict>
</plist>
```

The daemon launches on demand when the app first connects to the Mach service, and stays alive while it is controlling fans.

---

## 4. SMC layer (Shared)

### 4.1 `Shared/SMC/SMCBridge.h`

```c
#ifndef SMCBridge_h
#define SMCBridge_h

#include <IOKit/IOKitLib.h>
#include <stdint.h>

typedef struct {
    uint8_t  major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct must be 80 bytes");

enum {
    kSMCCmdReadKey      = 5,
    kSMCCmdWriteKey     = 6,
    kSMCCmdKeyByIndex   = 8,
    kSMCCmdKeyInfo      = 9,
};

kern_return_t SMCOpen(io_connect_t *conn);
void          SMCClose(io_connect_t conn);
kern_return_t SMCCall(io_connect_t conn, SMCParamStruct *input, SMCParamStruct *output);

#endif
```

### 4.2 `Shared/SMC/SMCBridge.c`

```c
#include "SMCBridge.h"

kern_return_t SMCOpen(io_connect_t *conn) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, conn);
    IOObjectRelease(service);
    return kr;
}

void SMCClose(io_connect_t conn) {
    if (conn) IOServiceClose(conn);
}

kern_return_t SMCCall(io_connect_t conn, SMCParamStruct *input, SMCParamStruct *output) {
    size_t outSize = sizeof(SMCParamStruct);
    return IOConnectCallStructMethod(conn, 2 /* kSMCHandleYPCEvent */,
                                     input, sizeof(SMCParamStruct),
                                     output, &outSize);
}
```

### 4.3 `Shared/SMC/SMCValue.swift`

```swift
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
```

### 4.4 `Shared/SMC/SMC.swift`

```swift
import Foundation
import IOKit

enum SMCError: Error, CustomStringConvertible {
    case open(kern_return_t), io(kern_return_t), smc(UInt8), unsupportedType(String), sizeMismatch
    var description: String {
        switch self {
        case .open(let k): return "SMC open failed (\(k))"
        case .io(let k): return "IOKit call failed (\(k))"
        case .smc(let r): return "SMC result 0x\(String(r, radix: 16))"   // 0x84 = key not found
        case .unsupportedType(let t): return "Unsupported type '\(t)'"
        case .sizeMismatch: return "Data size mismatch"
        }
    }
}

final class SMC {
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
        guard bytes.count == Int(info.dataSize) else { throw SMCError.sizeMismatch }
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

    // MARK: Fans

    func fanCount() -> Int { Int((try? double("FNum")) ?? 0) }
}
```

`SMC` is **not thread-safe**. Use one instance per serial queue / actor.

### 4.5 `Tools/smcdump/main.swift` — first thing to build and run

```swift
import Foundation

let smc = try SMC()
let onlyTemps = CommandLine.arguments.contains("--temps")
for key in smc.allKeys() {
    if onlyTemps && !key.hasPrefix("T") { continue }
    guard let v = try? smc.read(key) else { continue }
    let num = v.doubleValue.map { String(format: "%.2f", $0) } ?? v.bytes.map { String(format: "%02x", $0) }.joined()
    print("\(key)  [\(v.type)]  \(num)")
}
```

Run `smcdump --temps` while idle and again under load (`yes > /dev/null &` × 12, then `killall yes`). Keys that rise sharply under CPU load are CPU sensors; compare with the table in §1.4 and edit `SensorCatalog` if needed. Run `smcdump | grep '^F'` to confirm your fan keys.

---

## 5. Shared models

### 5.1 `Shared/Constants.swift`

```swift
enum FP {
    static let appBundleID   = "com.abdulloh.fanpilot"
    static let helperLabel   = "com.abdulloh.fanpilot.helper"
    static let helperPlist   = "com.abdulloh.fanpilot.helper.plist"
    static let teamID        = "XXXXXXXXXX"   // ← your Team ID
    static let helperVersion = "1.0.0"

    static let appRequirement =
        #"anchor apple generic and identifier "com.abdulloh.fanpilot" and certificate leaf[subject.OU] = "XXXXXXXXXX""#
    static let helperRequirement =
        #"anchor apple generic and identifier "com.abdulloh.fanpilot.helper" and certificate leaf[subject.OU] = "XXXXXXXXXX""#

    static let controlInterval: Double = 1.0    // seconds
    static let heartbeatInterval: Double = 5.0
    static let heartbeatTimeout: Double = 20.0
    static let emergencyTemp: Double = 100.0    // °C → force max
    static let maxRampDownPerTick: Double = 150 // RPM
}
```

### 5.2 `Shared/Sensors/SensorCatalog.swift`

```swift
import Foundation

enum SensorGroup: String, Codable, CaseIterable, Identifiable {
    case cpuMax, cpuAverage, gpuMax, hottest
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpuMax: "CPU (hottest core)"
        case .cpuAverage: "CPU (average)"
        case .gpuMax: "GPU"
        case .hottest: "Hottest sensor"
        }
    }
}

struct SensorCatalog {
    static let cpuECandidates = ["Te05", "Te0L", "Te0P", "Te0S"]
    static let cpuPCandidates = ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
                                 "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"]
    static let gpuCandidates  = ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"]

    let cpuKeys: [String]
    let gpuKeys: [String]
    let allTempKeys: [String]

    static func plausible(_ v: Double?) -> Bool { v.map { (5...130).contains($0) } ?? false }

    /// Probe once at startup. Cheap enough to redo after wake.
    static func discover(using smc: SMC) -> SensorCatalog {
        func valid(_ keys: [String]) -> [String] {
            keys.filter { (try? smc.read($0)).flatMap { $0.type == "flt " ? $0.doubleValue : nil }.map { plausible($0) } ?? false }
        }
        let all = smc.allKeys().filter { $0.hasPrefix("T") }
        return SensorCatalog(cpuKeys: valid(cpuECandidates + cpuPCandidates),
                             gpuKeys: valid(gpuCandidates),
                             allTempKeys: valid(all))
    }

    /// Returns nil if no sensor in the group could be read.
    func read(_ group: SensorGroup, smc: SMC) -> Double? {
        func values(_ keys: [String]) -> [Double] {
            keys.compactMap { try? smc.double($0) }.filter { Self.plausible($0) }
        }
        switch group {
        case .cpuMax:     return values(cpuKeys).max()
        case .cpuAverage: let v = values(cpuKeys); return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        case .gpuMax:     return values(gpuKeys).max()
        case .hottest:    return values(allTempKeys).max()
        }
    }
}
```

If `cpuKeys` comes back empty on a future chip, the UI falls back to `hottest` automatically (see `AppModel`).

### 5.3 `Shared/Models/Curve.swift`

```swift
import Foundation

struct CurvePoint: Codable, Hashable, Identifiable {
    var id = UUID()
    var temp: Double      // °C
    var percent: Double   // 0...1 of the fan's [min, max] range
}

struct Curve: Codable, Hashable {
    var sensor: SensorGroup = .cpuMax
    var points: [CurvePoint]

    /// Linear interpolation, clamped at both ends.
    func percent(at t: Double) -> Double {
        let p = points.sorted { $0.temp < $1.temp }
        guard let first = p.first, let last = p.last else { return 0 }
        if t <= first.temp { return first.percent }
        if t >= last.temp { return last.percent }
        let i = p.firstIndex { $0.temp > t }!
        let a = p[i - 1], b = p[i]
        return a.percent + (b.percent - a.percent) * (t - a.temp) / (b.temp - a.temp)
    }

    static let balanced = Curve(points: [
        .init(temp: 50, percent: 0), .init(temp: 65, percent: 0.25),
        .init(temp: 80, percent: 0.6), .init(temp: 92, percent: 1.0)])

    static let performance = Curve(points: [
        .init(temp: 40, percent: 0.15), .init(temp: 55, percent: 0.4),
        .init(temp: 70, percent: 0.75), .init(temp: 85, percent: 1.0)])
}
```

### 5.4 `Shared/Models/Preset.swift`

```swift
import Foundation

enum FanMode: Codable, Hashable {
    case auto
    case fixedPercent(Double)   // 0...1 of [min, max]
    case fixedRPM(Double)
    case curve(Curve)
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
```

### 5.5 `Shared/XPC/HelperProtocol.swift`

Presets travel as JSON `Data` to avoid `NSSecureCoding` boilerplate.

```swift
import Foundation

@objc protocol HelperProtocol {
    /// reply(nil) on success, reply(errorMessage) otherwise.
    func apply(presetJSON: Data, reply: @escaping (String?) -> Void)
    func resetToAuto(reply: @escaping () -> Void)
    func heartbeat()
    func version(reply: @escaping (String) -> Void)
}
```

---

## 6. Privileged helper (Helper target)

### 6.1 `Helper/FanController.swift`

```swift
import Foundation
import os

final class FanController {
    private let log = Logger(subsystem: FP.helperLabel, category: "fan")
    private let queue = DispatchQueue(label: "fanpilot.control")
    private let smc: SMC
    private var catalog: SensorCatalog
    private var preset: Preset?
    private var timer: DispatchSourceTimer?
    private var lastHeartbeat = Date()
    private var unlocked = false
    private var lastTarget: [Int: Double] = [:]
    private var smoothedTemp: [SensorGroup: Double] = [:]
    private var sensorFailures = 0

    struct FanLimits { let min: Double; let max: Double }
    private var limits: [Int: FanLimits] = [:]

    init() throws {
        smc = try SMC()
        catalog = SensorCatalog.discover(using: smc)
        for i in 0..<smc.fanCount() {
            let mn = (try? smc.double("F\(i)Mn")) ?? 0
            let mx = (try? smc.double("F\(i)Mx")) ?? 0
            limits[i] = FanLimits(min: mn, max: mx)
        }
        log.info("fans: \(self.limits.count), cpu sensors: \(self.catalog.cpuKeys.count)")
    }

    // MARK: Public API (thread-safe via queue)

    func apply(_ p: Preset) throws {
        try queue.sync {
            lastHeartbeat = Date()
            if p.isAllAuto {
                resetAllLocked()
                return
            }
            preset = p
            lastTarget.removeAll()
            startTimerLocked()
            try tickLocked(throwing: true)
        }
    }

    func resetToAuto() { queue.sync { resetAllLocked() } }
    func heartbeat()   { queue.async { self.lastHeartbeat = Date() } }

    // MARK: Loop

    private func startTimerLocked() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + FP.controlInterval, repeating: FP.controlInterval)
        t.setEventHandler { [weak self] in try? self?.tickLocked(throwing: false) }
        t.resume()
        timer = t
    }

    private func tickLocked(throwing: Bool) throws {
        guard let preset else { return }

        // Watchdog: app gone or frozen → give control back to the system.
        if Date().timeIntervalSince(lastHeartbeat) > FP.heartbeatTimeout {
            log.warning("heartbeat timeout → auto")
            resetAllLocked(); return
        }

        // Emergency: anything very hot → max on all fans.
        let hottest = catalog.read(.hottest, smc: smc)
        if hottest == nil { sensorFailures += 1 } else { sensorFailures = 0 }
        if sensorFailures >= 3 { log.error("sensors unreadable → auto"); resetAllLocked(); return }
        let emergency = (hottest ?? 0) >= FP.emergencyTemp

        do {
            for (index, lim) in limits {
                let mode = emergency ? .fixedPercent(1.0) : preset.mode(forFan: index)
                guard let rpm = targetRPM(for: mode, limits: lim, fan: index) else {
                    try setAuto(fan: index); continue
                }
                try setManual(fan: index, rpm: rpm)
            }
        } catch {
            log.error("control error: \(String(describing: error))")
            if throwing { resetAllLocked(); throw error }
        }
    }

    /// nil = this fan should be on Auto.
    private func targetRPM(for mode: FanMode, limits l: FanLimits, fan: Int) -> Double? {
        var target: Double
        switch mode {
        case .auto:
            return nil
        case .fixedRPM(let r):
            target = r
        case .fixedPercent(let p):
            target = l.min + (l.max - l.min) * p
        case .curve(let curve):
            let group = catalog.cpuKeys.isEmpty && curve.sensor != .gpuMax ? .hottest : curve.sensor
            guard let raw = catalog.read(group, smc: smc) else { return nil }
            // Exponential smoothing so short spikes don't cause audible jumps.
            let t = smoothedTemp[group].map { $0 * 0.7 + raw * 0.3 } ?? raw
            smoothedTemp[group] = t
            target = l.min + (l.max - l.min) * curve.percent(at: t)
            // Ramp up immediately, ramp down slowly.
            if let last = lastTarget[fan], target < last {
                target = max(target, last - FP.maxRampDownPerTick)
            }
        }
        target = min(max(target, l.min), l.max)     // never below Apple's minimum
        lastTarget[fan] = target
        return target
    }

    // MARK: SMC writes

    private func setManual(fan: Int, rpm: Double) throws {
        let md = "F\(fan)Md"
        if (try? smc.double(md)) != 1 {
            do {
                try smc.write(md, value: 1)
            } catch {
                // M3+/M4: needs the unlock flag, then a few retries.
                if !unlocked { try smc.write("Ftst", value: 1); unlocked = true }
                try retry(timeout: 10, interval: 0.25) { try self.smc.write(md, value: 1) }
            }
        }
        try smc.write("F\(fan)Tg", value: rpm)   // re-asserted every tick
    }

    private func setAuto(fan: Int) throws {
        try smc.write("F\(fan)Md", value: 0)
        lastTarget[fan] = nil
    }

    private func resetAllLocked() {
        timer?.cancel(); timer = nil
        preset = nil
        for i in limits.keys { try? setAuto(fan: i) }
        if unlocked { try? smc.write("Ftst", value: 0); unlocked = false }
        smoothedTemp.removeAll()
        log.info("all fans → auto")
    }

    private func retry(timeout: TimeInterval, interval: TimeInterval, _ body: () throws -> Void) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do { try body(); return } catch { lastError = error; Thread.sleep(forTimeInterval: interval) }
        }
        throw lastError ?? SMCError.io(kIOReturnTimeout)
    }
}
```

Notes:
- The retry inside `setManual` blocks the control queue for up to 10 s on first unlock. That is acceptable; the queue is private to the helper.
- Re-writing `F{n}Tg` every tick is deliberate: if `thermalmonitord` reclaims a fan, the next tick takes it back (or the error path resets to Auto).

### 6.2 `Helper/HelperService.swift`

```swift
import Foundation
import os

final class HelperService: NSObject, HelperProtocol, NSXPCListenerDelegate {
    private let log = Logger(subsystem: FP.helperLabel, category: "xpc")
    let controller: FanController
    private var connections = Set<NSXPCConnection>()

    init(controller: FanController) { self.controller = controller }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        c.exportedObject = self
        c.invalidationHandler = { [weak self, weak c] in
            guard let self, let c else { return }
            DispatchQueue.main.async {
                self.connections.remove(c)
                if self.connections.isEmpty {
                    self.log.info("app disconnected → auto")
                    self.controller.resetToAuto()
                }
            }
        }
        connections.insert(c)
        c.resume()
        return true
    }

    func apply(presetJSON: Data, reply: @escaping (String?) -> Void) {
        do {
            let preset = try JSONDecoder().decode(Preset.self, from: presetJSON)
            try controller.apply(preset)
            reply(nil)
        } catch {
            reply(String(describing: error))
        }
    }

    func resetToAuto(reply: @escaping () -> Void) { controller.resetToAuto(); reply() }
    func heartbeat() { controller.heartbeat() }
    func version(reply: @escaping (String) -> Void) { reply(FP.helperVersion) }
}
```

### 6.3 `Helper/main.swift`

```swift
import Foundation
import os

let log = Logger(subsystem: FP.helperLabel, category: "main")

guard getuid() == 0 else { log.fault("helper must run as root"); exit(1) }

let controller: FanController
do { controller = try FanController() }
catch { log.fault("SMC unavailable: \(String(describing: error))"); exit(1) }

let service = HelperService(controller: controller)
let listener = NSXPCListener(machServiceName: FP.helperLabel)
listener.setConnectionCodeSigningRequirement(FP.appRequirement)   // only our app may connect
listener.delegate = service
listener.resume()

// Restore Auto on shutdown / launchctl stop / unregister.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler {
    controller.resetToAuto()
    exit(0)
}
sigterm.resume()

log.info("helper started")
dispatchMain()
```

---

## 7. App target

### 7.1 `App/Services/SensorMonitor.swift` (read-only, for the UI)

```swift
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
}

/// Runs off the main thread; publishes snapshots via callback.
final class SensorMonitor {
    struct Snapshot {
        var fans: [FanReading] = []
        var groups: [SensorGroup: Double] = [:]
        var raw: [SensorReading] = []
    }

    private let queue = DispatchQueue(label: "fanpilot.monitor")
    private var smc: SMC?
    private var catalog: SensorCatalog?
    private var timer: DispatchSourceTimer?
    var includeRaw = false

    func start(interval: Double, onUpdate: @escaping (Snapshot) -> Void) {
        queue.async {
            if self.smc == nil {
                self.smc = try? SMC()
                if let smc = self.smc { self.catalog = SensorCatalog.discover(using: smc) }
            }
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: interval)
            t.setEventHandler { [weak self] in
                guard let self, let snap = self.read() else { return }
                DispatchQueue.main.async { onUpdate(snap) }
            }
            t.resume()
            self.timer = t
        }
    }

    func rediscover() { queue.async { if let smc = self.smc { self.catalog = .discover(using: smc) } } }

    private func read() -> Snapshot? {
        guard let smc, let catalog else { return nil }
        var s = Snapshot()
        for i in 0..<smc.fanCount() {
            s.fans.append(FanReading(
                id: i,
                rpm: (try? smc.double("F\(i)Ac")) ?? 0,
                min: (try? smc.double("F\(i)Mn")) ?? 0,
                max: (try? smc.double("F\(i)Mx")) ?? 0,
                target: (try? smc.double("F\(i)Tg")) ?? 0,
                manual: (try? smc.double("F\(i)Md")) == 1))
        }
        for g in SensorGroup.allCases { s.groups[g] = catalog.read(g, smc: smc) }
        if includeRaw {
            s.raw = catalog.allTempKeys.compactMap { k in
                (try? smc.double(k)).map { SensorReading(id: k, value: $0) }
            }
        }
        return s
    }
}
```

### 7.2 `App/Services/PresetStore.swift`

```swift
import Foundation
import Observation

@Observable
final class PresetStore {
    private(set) var presets: [Preset] = Preset.builtIns
    var activeID: UUID {
        didSet { UserDefaults.standard.set(activeID.uuidString, forKey: "activePresetID") }
    }

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FanPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("presets.json")
    }()

    init() {
        activeID = UserDefaults.standard.string(forKey: "activePresetID").flatMap(UUID.init) ?? Preset.automatic.id
        load()
    }

    var active: Preset { presets.first { $0.id == activeID } ?? .automatic }
    var custom: [Preset] { presets.filter { !$0.isBuiltIn } }

    func load() {
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
        presets = Preset.builtIns + saved.filter { !$0.isBuiltIn }
        if !presets.contains(where: { $0.id == activeID }) { activeID = Preset.automatic.id }
    }

    private func save() {
        let data = try? JSONEncoder().encode(custom)
        try? data?.write(to: url, options: .atomic)
    }

    @discardableResult
    func add(basedOn base: Preset? = nil) -> Preset {
        var p = base ?? Preset(id: UUID(), name: "Custom", symbol: "slider.horizontal.3",
                               isBuiltIn: false, mode: .curve(.balanced))
        p.id = UUID(); p.isBuiltIn = false
        p.name = base.map { "\($0.name) copy" } ?? uniqueName("Custom")
        presets.append(p); save()
        return p
    }

    func update(_ p: Preset) {
        guard !p.isBuiltIn, let i = presets.firstIndex(where: { $0.id == p.id }) else { return }
        presets[i] = p; save()
    }

    func delete(_ p: Preset) {
        guard !p.isBuiltIn else { return }
        presets.removeAll { $0.id == p.id }
        if activeID == p.id { activeID = Preset.automatic.id }
        save()
    }

    private func uniqueName(_ base: String) -> String {
        var n = 1, name = base
        while presets.contains(where: { $0.name == name }) { n += 1; name = "\(base) \(n)" }
        return name
    }
}
```

### 7.3 `App/Services/HelperClient.swift`

```swift
import Foundation
import ServiceManagement
import os

@Observable
final class HelperClient {
    enum State: Equatable { case notInstalled, needsApproval, ready, error(String) }

    private(set) var state: State = .notInstalled
    private let log = Logger(subsystem: FP.appBundleID, category: "helper")
    private let service = SMAppService.daemon(plistName: FP.helperPlist)
    private var connection: NSXPCConnection?
    private var heartbeatTimer: Timer?

    // MARK: Install / status

    func refreshStatus() {
        switch service.status {
        case .enabled:          state = .ready
        case .requiresApproval: state = .needsApproval
        case .notRegistered, .notFound: state = .notInstalled
        @unknown default:       state = .notInstalled
        }
    }

    func install() {
        do {
            try service.register()
        } catch {
            log.error("register failed: \(error.localizedDescription)")
        }
        refreshStatus()
        if state == .needsApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func uninstall() async {
        await resetToAuto()
        try? await service.unregister()
        connection?.invalidate(); connection = nil
        refreshStatus()
    }

    // MARK: XPC

    private func proxy() -> HelperProtocol? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: FP.helperLabel, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
            c.setCodeSigningRequirement(FP.helperRequirement)   // only talk to our helper
            c.invalidationHandler = { [weak self] in
                DispatchQueue.main.async { self?.connection = nil }
            }
            c.resume()
            connection = c
            startHeartbeat()
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] err in
            self?.log.error("xpc: \(err.localizedDescription)")
        } as? HelperProtocol
    }

    func apply(_ preset: Preset) async throws {
        guard state == .ready, let p = proxy() else { throw NSError(domain: "FanPilot", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Helper not installed"]) }
        let data = try JSONEncoder().encode(preset)
        let err: String? = await withCheckedContinuation { cont in
            p.apply(presetJSON: data) { cont.resume(returning: $0) }
        }
        if let err { throw NSError(domain: "FanPilot", code: 2, userInfo: [NSLocalizedDescriptionKey: err]) }
    }

    func resetToAuto() async {
        guard state == .ready, let p = proxy() else { return }
        await withCheckedContinuation { cont in p.resetToAuto { cont.resume() } }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: FP.heartbeatInterval, repeats: true) { [weak self] _ in
            self?.proxy()?.heartbeat()
        }
    }
}
```

### 7.4 `App/Services/LoginItem.swift`

```swift
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else       { try SMAppService.mainApp.unregister() }
        } catch {
            // Usually "requires approval" → send the user to System Settings
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
```

Because the active preset ID is persisted, launching at login also restores the last preset automatically (see `AppModel.start()`).

### 7.5 `App/AppModel.swift`

```swift
import SwiftUI
import Observation

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case iconOnly = "Icon only", temp = "CPU temperature", rpm = "Fan speed", both = "Temperature + speed"
    var id: String { rawValue }
}

@Observable
@MainActor
final class AppModel {
    let presets = PresetStore()
    let helper = HelperClient()
    private let monitor = SensorMonitor()

    var snapshot = SensorMonitor.Snapshot()
    var lastError: String?

    // Settings (persisted)
    var useFahrenheit = UserDefaults.standard.bool(forKey: "useFahrenheit") {
        didSet { UserDefaults.standard.set(useFahrenheit, forKey: "useFahrenheit") }
    }
    var display = MenuBarDisplay(rawValue: UserDefaults.standard.string(forKey: "display") ?? "") ?? .both {
        didSet { UserDefaults.standard.set(display.rawValue, forKey: "display") }
    }
    var refreshInterval = UserDefaults.standard.object(forKey: "refresh") as? Double ?? 2 {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: "refresh"); startMonitor() }
    }

    var cpuTemp: Double? { snapshot.groups[.cpuMax] ?? snapshot.groups[.hottest] }
    var gpuTemp: Double? { snapshot.groups[.gpuMax] }
    var maxFanRPM: Double? { snapshot.fans.map(\.rpm).max() }
    var hasFans: Bool { !snapshot.fans.isEmpty }

    func start() {
        helper.refreshStatus()
        startMonitor()
        Task { await activate(presets.active) }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.monitor.rediscover()
                if let p = self?.presets.active { await self?.activate(p) }
            }
        }
    }

    func startMonitor() {
        monitor.start(interval: refreshInterval) { [weak self] snap in self?.snapshot = snap }
    }

    func setRawSensors(_ on: Bool) { monitor.includeRaw = on }

    func activate(_ preset: Preset) async {
        presets.activeID = preset.id
        guard helper.state == .ready else {
            if !preset.isAllAuto { lastError = "Install the helper to control fans." }
            return
        }
        do { try await helper.apply(preset); lastError = nil }
        catch {
            lastError = error.localizedDescription
            presets.activeID = Preset.automatic.id
        }
    }

    func prepareForQuit() async { await helper.resetToAuto() }

    // Formatting
    func format(temp: Double?) -> String {
        guard let t = temp else { return "–" }
        return useFahrenheit ? "\(Int((t * 9 / 5 + 32).rounded()))°F" : "\(Int(t.rounded()))°"
    }
    func format(rpm: Double?) -> String { rpm.map { "\(Int($0.rounded()))" } ?? "–" }
}
```

### 7.6 `App/FanPilotApp.swift`

```swift
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.prepareForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct FanPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
                .onAppear { delegate.model = model }
        } label: {
            MenuBarLabel()
                .environment(model)
                .task { delegate.model = model; model.start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}
```

The label's `.task` runs at launch (the label is always visible), so monitoring and preset restore begin immediately without opening the popover.

---

## 8. UI

### 8.1 Design principles

- **One glance, one click.** The menu bar shows the essentials; the popover changes preset in one click.
- **No chrome.** System fonts, SF Symbols, `.secondary` labels, monospaced digits so numbers don't jitter.
- **Native materials.** The `.window` MenuBarExtra style gives the standard translucent popover automatically, with Dark Mode support.
- Popover width **280 pt**; Settings window **520 × 420 pt**.

### 8.2 Popover layout

```
┌──────────────────────────────────┐
│  CPU 64°      GPU 52°            │  large, monospaced
├──────────────────────────────────┤
│  Left fan    2 450 rpm  ▓▓▓░░░░  │
│  Right fan   2 410 rpm  ▓▓▓░░░░  │
├──────────────────────────────────┤
│  ✓ Automatic                     │
│    Balanced                      │
│    Performance                   │
│    Full Blast                    │
│    My Gaming (custom)            │
├──────────────────────────────────┤
│  ⚠ Install helper to control fans│  only when needed
├──────────────────────────────────┤
│  Settings…                 Quit  │
└──────────────────────────────────┘
```

### 8.3 `App/Views/MenuBarLabel.swift`

```swift
import SwiftUI

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.display {
        case .iconOnly:
            Image(systemName: "fan")
        case .temp:
            Text(model.format(temp: model.cpuTemp)).monospacedDigit()
        case .rpm:
            Label(model.format(rpm: model.maxFanRPM), systemImage: "fan").labelStyle(.titleAndIcon)
        case .both:
            Text("\(model.format(temp: model.cpuTemp)) · \(model.format(rpm: model.maxFanRPM))").monospacedDigit()
        }
    }
}
```

(Menu bar labels render a single `Text`/`Image`/`Label`; avoid custom stacks there.)

### 8.4 `App/Views/MenuContentView.swift`

```swift
import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Temperatures
            HStack(spacing: 20) {
                tempBlock("CPU", model.cpuTemp)
                tempBlock("GPU", model.gpuTemp)
                Spacer()
            }

            Divider()

            // Fans
            if model.hasFans {
                ForEach(model.snapshot.fans) { fan in
                    HStack {
                        Text(fanName(fan.id)).frame(width: 70, alignment: .leading)
                        Text("\(Int(fan.rpm)) rpm").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                        ProgressView(value: min(max(fan.fraction, 0), 1)).progressViewStyle(.linear)
                    }
                    .font(.callout)
                }
            } else {
                Text("No fans detected").foregroundStyle(.secondary)
            }

            Divider()

            // Presets
            VStack(spacing: 2) {
                ForEach(model.presets.presets) { preset in
                    PresetRow(preset: preset, isActive: preset.id == model.presets.activeID) {
                        Task { await model.activate(preset) }
                    }
                }
            }

            if model.helper.state != .ready {
                Button("Install helper to control fans…") { model.helper.install() }
                    .buttonStyle(.link)
            } else if let err = model.lastError {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }

            Divider()

            HStack {
                SettingsLink { Text("Settings…") }
                    .simultaneousGesture(TapGesture().onEnded { NSApp.activate(ignoringOtherApps: true) })
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 280)
    }

    private func tempBlock(_ title: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(model.format(temp: value)).font(.title2.weight(.medium)).monospacedDigit()
        }
    }

    private func fanName(_ i: Int) -> String {
        model.snapshot.fans.count == 2 ? (i == 0 ? "Left" : "Right") : "Fan \(i + 1)"
    }
}

struct PresetRow: View {
    let preset: Preset
    let isActive: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: preset.symbol).frame(width: 18)
                Text(preset.name)
                Spacer()
                if isActive { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
```

The Left/Right naming for two fans is a convenience; verify which index is which on your machine by setting one fan to Full Blast via a per-fan override.

### 8.5 `App/Views/SettingsView.swift`

```swift
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PresetsSettings().tabItem { Label("Presets", systemImage: "slider.horizontal.3") }
            SensorsView().tabItem { Label("Sensors", systemImage: "thermometer.medium") }
        }
        .frame(width: 520, height: 420)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        @Bindable var model = model
        Form {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in LoginItem.set(v); launchAtLogin = LoginItem.isEnabled }

            Picker("Menu bar shows", selection: $model.display) {
                ForEach(MenuBarDisplay.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Units", selection: $model.useFahrenheit) {
                Text("Celsius").tag(false); Text("Fahrenheit").tag(true)
            }
            Picker("Refresh every", selection: $model.refreshInterval) {
                Text("1 s").tag(1.0); Text("2 s").tag(2.0); Text("5 s").tag(5.0)
            }

            Section("Fan control helper") {
                LabeledContent("Status") { Text(statusText) }
                HStack {
                    if model.helper.state == .ready {
                        Button("Uninstall") { Task { await model.helper.uninstall() } }
                    } else {
                        Button("Install…") { model.helper.install() }
                    }
                    Button("Refresh") { model.helper.refreshStatus() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.helper.refreshStatus() }
    }

    private var statusText: String {
        switch model.helper.state {
        case .ready: "Installed"
        case .needsApproval: "Waiting for approval in System Settings → Login Items"
        case .notInstalled: "Not installed (monitoring only)"
        case .error(let e): e
        }
    }
}
```

### 8.6 Presets tab + editor

```swift
import SwiftUI

struct PresetsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.presets.presets, selection: $selection) { p in
                    Label(p.name, systemImage: p.symbol).tag(p.id)
                }
                HStack {
                    Button { selection = model.presets.add().id } label: { Image(systemName: "plus") }
                    Button {
                        if let p = selectedPreset { selection = model.presets.add(basedOn: p).id }
                    } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate")
                    Button {
                        if let p = selectedPreset { model.presets.delete(p); selection = nil }
                    } label: { Image(systemName: "minus") }
                        .disabled(selectedPreset?.isBuiltIn ?? true)
                    Spacer()
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 160, maxWidth: 200)

            Group {
                if let p = selectedPreset {
                    PresetEditorView(preset: p).id(p.id)
                } else {
                    Text("Select a preset").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private var selectedPreset: Preset? { model.presets.presets.first { $0.id == selection } }
}
```

`App/Views/PresetEditorView.swift`:

```swift
import SwiftUI

struct PresetEditorView: View {
    @Environment(AppModel.self) private var model
    @State var preset: Preset

    private enum Kind: String, CaseIterable { case auto = "Automatic", fixed = "Fixed", curve = "Curve" }

    var body: some View {
        Form {
            TextField("Name", text: $preset.name).disabled(preset.isBuiltIn)

            Picker("Mode", selection: kindBinding) {
                ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(preset.isBuiltIn)

            switch preset.mode {
            case .fixedPercent(let p):
                LabeledContent("Speed") {
                    Slider(value: Binding(get: { p }, set: { preset.mode = .fixedPercent($0) }), in: 0...1)
                    Text("\(Int(p * 100))%").monospacedDigit().frame(width: 44)
                }
                .disabled(preset.isBuiltIn)
            case .curve(let c):
                Picker("Sensor", selection: Binding(get: { c.sensor }, set: { var n = c; n.sensor = $0; preset.mode = .curve(n) })) {
                    ForEach(SensorGroup.allCases) { Text($0.title).tag($0) }
                }
                .disabled(preset.isBuiltIn)
                CurveEditor(curve: Binding(get: { c }, set: { preset.mode = .curve($0) }),
                            liveTemp: model.snapshot.groups[c.sensor],
                            editable: !preset.isBuiltIn)
                    .frame(height: 200)
            default:
                Text("macOS controls the fans.").foregroundStyle(.secondary)
            }

            if preset.isBuiltIn {
                Text("Built-in presets are read-only. Duplicate to customize.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Activate") { Task { await model.activate(preset) } }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .onChange(of: preset) { _, new in
            model.presets.update(new)
            if new.id == model.presets.activeID { Task { await model.activate(new) } }
        }
    }

    private var kindBinding: Binding<Kind> {
        Binding(get: {
            switch preset.mode {
            case .auto: .auto
            case .fixedPercent, .fixedRPM: .fixed
            case .curve: .curve
            }
        }, set: { k in
            switch k {
            case .auto: preset.mode = .auto
            case .fixed: preset.mode = .fixedPercent(0.5)
            case .curve: preset.mode = .curve(.balanced)
            }
        })
    }
}
```

Editing the *active* preset re-applies it live, which makes tuning a curve under load easy. The update path is debounced naturally by the helper's 1 s loop; if slider dragging feels chatty, add a 300 ms debounce with a `Task` + `Task.sleep`.

### 8.7 `App/Views/CurveEditor.swift` (Swift Charts, draggable points)

```swift
import SwiftUI
import Charts

struct CurveEditor: View {
    @Binding var curve: Curve
    var liveTemp: Double?
    var editable: Bool
    @State private var dragging: UUID?

    var body: some View {
        let points = curve.points.sorted { $0.temp < $1.temp }
        Chart {
            ForEach(points) { p in
                LineMark(x: .value("°C", p.temp), y: .value("%", p.percent * 100))
                    .interpolationMethod(.linear)
                PointMark(x: .value("°C", p.temp), y: .value("%", p.percent * 100))
                    .symbolSize(dragging == p.id ? 120 : 60)
            }
            if let t = liveTemp {
                RuleMark(x: .value("Now", t))
                    .foregroundStyle(.orange.opacity(0.6))
                    .annotation(position: .top) { Text("\(Int(t))°").font(.caption2) }
            }
        }
        .chartXScale(domain: 30...100)
        .chartYScale(domain: 0...100)
        .chartXAxisLabel("Temperature °C")
        .chartYAxisLabel("Fan %")
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(editable ? drag(proxy: proxy, geo: geo) : nil)
            }
        }
    }

    private func drag(proxy: ChartProxy, geo: GeometryProxy) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard let frame = proxy.plotFrame else { return }
                let origin = geo[frame].origin
                let loc = CGPoint(x: v.location.x - origin.x, y: v.location.y - origin.y)
                guard let (t, pct) = proxy.value(at: loc, as: (Double, Double).self) else { return }

                if dragging == nil {   // pick nearest point on drag start
                    dragging = curve.points.min { abs($0.temp - t) + abs($0.percent * 100 - pct) / 2
                                                < abs($1.temp - t) + abs($1.percent * 100 - pct) / 2 }?.id
                }
                guard let id = dragging, let i = curve.points.firstIndex(where: { $0.id == id }) else { return }
                curve.points[i].temp = min(max(t.rounded(), 30), 100)
                curve.points[i].percent = min(max(pct / 100, 0), 1)
            }
            .onEnded { _ in dragging = nil }
    }
}
```

Optional additions: double-click to add a point, ⌫ to delete the selected one, minimum of 2 points enforced.

### 8.8 `App/Views/SensorsView.swift`

```swift
import SwiftUI

struct SensorsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading) {
            Table(model.snapshot.raw.sorted { $0.id < $1.id }) {
                TableColumn("Key", value: \.id)
                TableColumn("Value") { Text(model.format(temp: $0.value)).monospacedDigit() }
            }
            Text("Raw SMC temperature keys. Groups used by presets: CPU, GPU, Hottest.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear { model.setRawSensors(true) }
        .onDisappear { model.setRawSensors(false) }
    }
}
```

---

## 9. Entitlements, signing, distribution

### 9.1 Entitlements

`App/FanPilot.entitlements` — keep it essentially empty: **no** `com.apple.security.app-sandbox`. Hardened Runtime is enabled in Signing & Capabilities; IOKit SMC access needs no extra entitlement. The helper needs no entitlements file.

### 9.2 Personal build (your M3 Pro)

1. Sign both targets with **Apple Development** and the same Team (Xcode → Signing → Automatic). A Team ID is required because the XPC code-signing requirements check it; "Sign to Run Locally" (ad-hoc) will not work with the daemon setup.
2. Put your Team ID in `FP.teamID`, `FP.appRequirement`, `FP.helperRequirement`.
3. Product → Archive → Distribute → **Copy App**, move `FanPilot.app` to **/Applications**. Running from DerivedData works for quick tests, but the daemon registration is tied to the app's path, so use a stable location.
4. Launch, click **Install helper**, approve in **System Settings → General → Login Items & Extensions** ("Allow in the Background").
5. Enable **Launch at login** in Settings.

### 9.3 Public release (later)

- Developer ID Application certificate (paid Apple Developer Program).
- Archive → Distribute → **Developer ID** → Upload for notarization → staple.
- Ship as a DMG; optional auto-update via Sparkle 2 (the only third-party dependency you might add later).

---

## 10. Build order (milestones)

| # | Milestone | Done when |
|---|---|---|
| 1 | `smcdump` tool | Prints `FNum`, fan keys, and dozens of `T***` keys with sane values |
| 2 | Sensor validation | You confirmed CPU/GPU keys under load and adjusted `SensorCatalog` |
| 3 | Menu bar monitor | `MenuBarExtra` shows live CPU temp and RPM; Settings window opens |
| 4 | Helper skeleton | Daemon registers, approval works, `version()` round-trips over XPC |
| 5 | Manual fan write | Full Blast spins both fans to max; Automatic returns them to idle |
| 6 | Safety | Quit, `kill -9`, heartbeat timeout and SIGTERM all restore Auto |
| 7 | Curves | Balanced/Performance follow temperature smoothly without oscillation |
| 8 | Presets UI | Create, duplicate, edit, delete custom presets; persisted across launches |
| 9 | Login item | After reboot, app starts and re-applies the last preset |
| 10 | Polish | Units, display modes, wake handling, error messages |

---

## 11. Testing checklist

Load generation: `for i in $(seq 12); do yes > /dev/null & done` (stop with `killall yes`). For GPU load, use any Metal benchmark or a game.

- [ ] Automatic: `smcdump | grep Md` shows all `F{n}Md = 0`.
- [ ] Full Blast: both fans reach `F{n}Mx` within a few seconds.
- [ ] Balanced under CPU load: RPM rises with temperature, falls gradually after `killall yes`.
- [ ] Quit from the menu → fans return to Auto within ~2 s.
- [ ] `kill -9 <FanPilot pid>` → XPC invalidation resets to Auto immediately.
- [ ] Freeze simulation (pause app in debugger > 20 s) → heartbeat watchdog resets to Auto.
- [ ] `sudo launchctl kill SIGTERM system/com.abdulloh.fanpilot.helper` → Auto, helper exits cleanly.
- [ ] Sleep/wake with a custom preset active → preset re-applied after wake.
- [ ] Reboot with Launch at login on → last preset active without user action.
- [ ] Helper not installed → app runs in monitoring-only mode, no crashes.
- [ ] Lid closed / clamshell, on battery, while charging: no errors in logs.

---

## 12. Debugging and troubleshooting

**Logs** (both processes use `os.Logger`):

```bash
log stream --level debug --predicate 'subsystem BEGINSWITH "com.abdulloh.fanpilot"'
```

**Daemon status:**

```bash
sudo launchctl print system/com.abdulloh.fanpilot.helper
```

**Attach debugger to the helper:** Xcode → Debug → Attach to Process → `FanPilotHelper` (Xcode asks for admin rights).

| Symptom | Likely cause / fix |
|---|---|
| `register()` succeeds but status stays `requiresApproval` | Approve in System Settings → Login Items & Extensions |
| XPC connection invalidates instantly | Code-signing requirement mismatch: wrong Team ID or bundle ID in `FP` constants |
| Helper not found after rebuild | App moved or rebuilt at another path: Uninstall → Install again; keep the app in /Applications |
| Stale Background Items entries | `sfltool resetbtm`, then reboot |
| `F0Md` write always fails (result `0x84` etc.) | Unlock sequence changed in a new macOS build; check `smcdump` for `Ftst` existence; app falls back to monitoring-only |
| Fans pulse up/down | Increase smoothing (lower the 0.3 factor), lower `maxRampDownPerTick`, or flatten the curve |
| CPU temperature shows "–" | Sensor keys differ on your chip; check `smcdump --temps` and update `SensorCatalog`, or select **Hottest sensor** |

---

## 13. Safety rules (do not remove)

1. Never write a target below `F{n}Mn` or above `F{n}Mx`.
2. Any SMC error during a control tick that can't be recovered → all fans to Auto.
3. Sensors unreadable for 3 consecutive ticks → Auto.
4. Any sensor ≥ 100 °C → all fans to max, regardless of preset.
5. App disconnect, missed heartbeats, or SIGTERM → Auto.
6. Apple Silicon still thermally throttles on its own; fan control changes noise and temperature, it cannot disable the chip's protection. Don't market or rely on it as a way to "unlock" performance beyond what better cooling gives.

---

## 14. Possible extensions

- Per-fan overrides in the editor UI (the model already supports `perFan`).
- Global keyboard shortcut to cycle presets.
- Auto-switch rules: e.g. Full Blast when a specific app (Xcode build, a game) is frontmost, Automatic on battery.
- Small history sparkline (last 5 min) in the popover using Swift Charts.
- WidgetKit widget showing temperature and active preset.
