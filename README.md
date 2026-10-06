# MacFanPilot

A small, native menu bar app for Apple Silicon Macs. It shows CPU and GPU temperature and fan
speed, and lets you choose how the fans behave: leave them to macOS, follow a temperature curve,
or hold a fixed speed.

- **Offline.** No account, no network requests, no analytics. Nothing leaves your Mac.
- **Native.** SwiftUI, no third-party dependencies, under 1 MB to download.
- **Apple Silicon only**, macOS 14 or later. Lives in the menu bar, with no Dock icon.

## Status

Version 1.0. Developed and tested on an M3 Pro MacBook Pro running macOS 26. Other Apple Silicon
Macs are expected to work, because sensors are discovered at runtime rather than read from a
per-model table, but they have not been tested. A Mac without fans (MacBook Air) shows
temperatures only.

Fan control depends on undocumented behaviour of Apple's System Management Controller, which any
macOS update can change. When control is refused, the app says so and keeps working as a monitor.

## Features

- **Menu bar readout**: icon only (default), CPU temperature, fan speed, or both.
- **Presets**, switched in one click from the popover:

  | Preset | Behaviour |
  |---|---|
  | Automatic | macOS controls the fans |
  | Balanced | Curve from 50 °C to 92 °C |
  | Performance | Steeper curve from 40 °C to 85 °C |
  | Full Blast | Maximum speed |

- **Custom presets**: a fixed speed in rpm, or a curve of 2 to 8 points that follows the hottest
  CPU core, the CPU average, the GPU, or the hottest sensor overall.
- **Sensors tab** listing every temperature key the Mac exposes.
- **Launch at login**, restoring the last preset. Celsius or Fahrenheit.

## Installing

1. Open `MacFanPilot-1.0.dmg` and drag **MacFanPilot** to **Applications**.
2. Open it from Applications. The build is not notarized, so macOS says it cannot verify the app.
   Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway**.
3. Click the fan icon in the menu bar. Temperatures and fan speeds work straight away.
4. To control the fans, click **Install helper to control fans…** and switch MacFanPilot on in
   **System Settings → General → Login Items & Extensions**.

If step 2 does not offer **Open Anyway**, this does the same thing:

```sh
xattr -dr com.apple.quarantine /Applications/MacFanPilot.app
```

Quit any other fan utility (Macs Fan Control, TG Pro, …) first. Two apps driving the same fans
fight each other, and MacFanPilot warns when it sees one.

### Uninstalling

Open **Settings… → General → Fan control helper → Uninstall**, quit the app and delete it from
Applications. To remove its data as well:

```sh
rm -rf ~/Library/Application\ Support/MacFanPilot
defaults delete uz.stiv.macfanpilot
```

## Safety

The fans are driven by a small helper that runs as root, and that helper, not the app, is the
safety net. It hands the fans back to macOS when:

- you choose Automatic or quit the app;
- the app crashes, is killed, or stops responding for 20 seconds;
- the Mac shuts down or restarts;
- temperatures cannot be read for three seconds in a row;
- macOS keeps rejecting fan commands.

After a sleep longer than 20 seconds the fans also go back to macOS on wake, and the app then
re-applies the preset.

It also never asks for a speed outside the range the fan reports, and it forces every fan to
maximum while any CPU or GPU sensor is at 100 °C or above (until it falls to 95 °C), whatever the
preset says.

Fan control changes noise and temperature. It does not disable the chip's own thermal
protection, and it is not a way to get more performance than better cooling gives.

These paths are implemented but only partly exercised so far. The manual checklist is in
[§11 of the build guide](FanPilot-Build-Guide.md#11-testing-checklist); run it on your own
hardware before relying on a custom preset.

## Building

You need Xcode 16 or later and a signing certificate from an Apple Developer team.

```sh
scripts/build-dmg.sh        # → dist/MacFanPilot-1.0.dmg
```

The script builds the Release configuration, re-signs the app and its helper with a secure
timestamp, checks the signatures, and packs the DMG. It signs with a **Developer ID Application**
certificate if the team has one in the keychain and with **Apple Development** otherwise. With a
Developer ID certificate it can also notarize:

```sh
xcrun notarytool store-credentials macfanpilot    # once
NOTARY_PROFILE=macfanpilot scripts/build-dmg.sh
```

To work on the app, open `MacFanPilot.xcodeproj` and run the **MacFanPilot** scheme. Monitoring
works from anywhere. The helper is registered against the app's location, so to test fan control
copy the built app to `/Applications` and run it from there.

### Building under your own team

The app and the helper each verify the other's code signature, including the team ID, before
talking over XPC. Ad-hoc signing ("Sign to Run Locally") therefore cannot control fans. To build
under a different team, change the team ID and bundle identifiers in all of these:

- `Shared/Constants.swift`
- the build settings in `MacFanPilot.xcodeproj` (`DEVELOPMENT_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER`)
- `LaunchDaemons/uz.stiv.macfanpilot.helper.plist`, including its file name
- `scripts/build-dmg.sh`

### smcdump

The **smcdump** scheme builds a command-line tool that prints every SMC key the Mac exposes.
Reading needs no privileges.

```sh
smcdump --temps        # temperature keys only
smcdump | grep '^F'    # fan keys
```

## How it works

```
MacFanPilot.app (you)                           MacFanPilotHelper (root, launchd)
  menu bar UI, presets, settings                   control loop, once a second
  reads sensors for display        ── XPC ──▶      reads sensors, writes fan targets
  sends the chosen preset                          watchdog, emergency override
  heartbeat every 5 s              ◀── status ──   hands fans back on any failure
```

- Temperatures and fans belong to the **SMC**, reached through IOKit. Reading is open to any
  process; writing needs root, which is the only reason the helper exists.
- The helper is a launch daemon inside the app bundle, registered with `SMAppService`. It starts
  when the app connects, exits ten seconds after the app lets go, and is restarted by launchd
  after a crash so it can release the fans.
- The app sends a whole preset and the helper evaluates it, so a stalled UI never leaves the
  fans in a bad state.
- On M3 and newer chips macOS refuses manual mode until an unlock flag is set, and then needs a
  few seconds to let go. The helper handles that and re-asserts its target on every tick.
- CPU sensors are the `Tp**` and `Te**` SMC families and GPU sensors the `Tg**` family. Only the
  hottest few are polled each second, with a full pass every fifth tick, because each SMC read
  costs about 0.15 ms.

## Project layout

```
App/            SwiftUI app: menu bar popover, settings, preset store, helper client
Helper/         privileged helper: XPC service and the fan control loop
Shared/         compiled into every target: SMC access, sensor catalog, models, XPC protocol
LaunchDaemons/  launchd plist copied into the app bundle
Tools/smcdump/  SMC key dumper
scripts/        build-dmg.sh, make-icon.swift
```

[FanPilot-Build-Guide.md](FanPilot-Build-Guide.md) is the specification the app was built from.
It predates the final name and uses placeholder identifiers. The code departs from it where
testing on real hardware showed a problem: sensor discovery, the "hottest sensor" group, polling
cost, the Settings window, and several helper safety paths.

## Troubleshooting

| Symptom | What to do |
|---|---|
| "Allow MacFanPilot in Login Items" does not go away | Switch MacFanPilot on in System Settings → General → Login Items & Extensions |
| "Move MacFanPilot to the Applications folder" | The helper cannot be installed while the app runs from the DMG. Move the app to Applications and reopen it |
| "Another app is controlling the fans" | Quit the other fan utility |
| A preset switches itself back to Automatic | The helper gave up control. The popover shows the reason |
| Fan control stopped working after moving or replacing the app | Settings → General → Uninstall, then Install again |
| CPU temperature shows "–" | No sensor was recognised on this chip. Check the Sensors tab and `smcdump --temps` |

Both processes log through `os.Logger`:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem BEGINSWITH "uz.stiv.macfanpilot"'
```
