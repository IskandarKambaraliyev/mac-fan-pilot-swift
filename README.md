# MacFanPilot

A small, native menu bar app for Apple Silicon Macs. It shows CPU and GPU temperature and fan
speed, and lets you choose how the fans behave: leave them to macOS, follow a temperature curve,
or hold a fixed speed.

- **Offline.** No account, no network requests, no analytics. Nothing leaves your Mac.
- **Native.** SwiftUI, no third-party dependencies, about 1 MB to download.
- **Apple Silicon only**, macOS 14 or later. Lives in the menu bar, with no Dock icon.

## Status

Version 1.1.0. Developed and tested on an M3 Pro MacBook Pro running macOS 26. Other Apple Silicon
Macs are expected to work, because sensors are discovered at runtime rather than read from a
per-model table, but they have not been tested. A Mac without fans (MacBook Air) shows
temperatures only.

Fan control depends on undocumented behaviour of Apple's System Management Controller, which any
macOS update can change. When control is refused, the app says so and keeps working as a monitor.

## Features

- **Menu bar readout**: icon only (default), CPU temperature, fan speed, or both. The icon is
  outlined while macOS has the fans, filled while a preset is running, a thermometer during the
  emergency override, and a warning triangle when a preset could not be kept running.
- **Popover** with CPU and GPU temperature, their last five minutes as a small chart, and each
  fan's speed.
- **Presets**, switched in one click from the popover:

  | Preset | Behaviour |
  |---|---|
  | Automatic | macOS controls the fans |
  | Balanced | Curve from 50 °C to 92 °C |
  | Performance | Steeper curve from 40 °C to 85 °C |
  | Full Blast | Maximum speed |

- **Custom presets**: a fixed speed in rpm, or a curve of 2 to 8 points that follows the hottest
  CPU core, the CPU average, the GPU, or the hottest sensor overall. On a Mac with two fans each
  fan can have its own mode. Presets can be exported to a file and imported on another Mac.
- **Automatic on battery** (optional): the selected preset is set aside while the Mac runs on
  battery and comes back when power is connected.
- **Shortcuts and Focus**: a "Set Fan Preset" action for the Shortcuts app, which also makes
  presets available to keyboard shortcuts and automations, and the same as a Focus filter that
  switches preset while a Focus is on.
- **Notifications** (optional) when fan control stops or the emergency override takes over.
- **Sensors tab** listing every temperature key the Mac exposes, named where the meaning is known.
- **Launch at login**, restoring the last preset. Celsius or Fahrenheit.
- **Copy Diagnostics** in Settings: versions, the Mac model, fan ranges and sensor families as
  text, for bug reports from Macs this has not been tested on.

## Installing

1. Open `MacFanPilot-1.1.0.dmg` and drag **MacFanPilot** to **Applications**.
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

If macOS refuses to take a fan back, the helper stays alive and keeps trying instead of exiting
with the fan stuck at its last speed.

When a preset can't be applied or the helper gives the fans back, your choice of preset is kept:
the app tries again after 5, 20 and 60 seconds, then shows the reason and waits for the next
wake, relaunch or click.

It also never asks for a speed outside the range the fan reports, and it forces every fan to
maximum while any CPU or GPU sensor is at 100 °C or above (until it falls to 95 °C), whatever the
preset says.

Fan control changes noise and temperature. It does not disable the chip's own thermal
protection, and it is not a way to get more performance than better cooling gives.

The control loop behind these rules is unit-tested against a simulated SMC, but only real
hardware shows whether macOS accepts the commands, and not every path has been exercised there.
The manual checklist is in [docs/Testing.md](docs/Testing.md); run it on your own hardware before
relying on a custom preset.

## Building

You need Xcode 16 or later and a signing certificate from an Apple Developer team.

```sh
scripts/build-dmg.sh        # → dist/MacFanPilot-1.1.0.dmg
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

### Tests

```sh
xcodebuild test -project MacFanPilot.xcodeproj -scheme MacFanPilot -destination 'platform=macOS,arch=arm64'
```

The tests need no signing certificate and never touch the real fans: the helper's control loop
runs against a simulated SMC. [docs/Testing.md](docs/Testing.md) lists what they cover and has
the manual checklist for what they can't.

### Building under your own team

The app and the helper each verify the other's code signature, including the team ID, before
talking over XPC. Ad-hoc signing ("Sign to Run Locally") therefore cannot control fans. To build
under a different team, change the team ID and the bundle identifier at the top of
`Config/Identity.xcconfig`. The build settings, the launchd plist, the code and
`scripts/build-dmg.sh` all take them from there.

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
- On every new connection the app asks the helper for its version. If launchd can't start the
  helper, or starts a copy from another build (which is what moving or replacing the app can
  leave behind), the app registers it again by itself, as long as it runs from an Applications
  folder.
- On M3 and newer chips macOS refuses manual mode until an unlock flag is set, and then needs a
  few seconds to let go. The helper handles that and re-asserts its target on every tick.
- CPU sensors are the `Tp**` and `Te**` SMC families and GPU sensors the `Tg**` family. Only the
  hottest few are polled each second, with a full pass every fifth tick, because each SMC read
  costs about 0.15 ms.
- The app reads sensors at the chosen refresh rate only while a readout is on screen (the
  popover, the settings window, or a menu bar readout other than the icon). Otherwise it reads
  every 10 seconds, which is enough for the history chart.

## Project layout

```
App/            SwiftUI app: menu bar popover, settings, preset store, helper client, App Intents
Helper/         privileged helper: XPC service and the fan control loop
Shared/         compiled into every target: SMC access, sensor catalog, models, XPC protocol
Tests/          unit tests; they compile the sources above directly
Config/         Identity.xcconfig (team and bundle identifiers) and the Info.plist that carries them
LaunchDaemons/  template of the launchd plist; the build fills in the identifiers
Tools/smcdump/  SMC key dumper
scripts/        build-dmg.sh, make-icon.swift
docs/           Testing.md, and the archived original specification
```

[docs/archive/FanPilot-Build-Guide.md](docs/archive/FanPilot-Build-Guide.md) is the specification
the app was first built from. It predates the final name, uses placeholder identifiers, and its
code no longer matches the source; it is kept for its account of how fan control works on Apple
Silicon.

## Troubleshooting

| Symptom | What to do |
|---|---|
| "Allow MacFanPilot in Login Items" does not go away | Switch MacFanPilot on in System Settings → General → Login Items & Extensions |
| "Move MacFanPilot to the Applications folder" | The helper cannot be installed while the app runs from the DMG. Move the app to Applications and reopen it |
| "Another app is controlling the fans" | Quit the other fan utility |
| The selected preset has a grey tick and the menu bar shows a warning triangle | The preset could not be kept running. The popover shows the reason; the app retries by itself, and choosing the preset again retries at once |
| "On battery, so the fans are on Automatic" | Settings → General → Use Automatic on battery is on. The preset returns when power is connected |
| Fan control stopped working after moving or replacing the app | The app registers the helper again by itself when it runs from Applications. If that did not help: Settings → General → Uninstall, then Install again |
| Custom presets are missing after an update or a damaged file | A file the app could not read is kept as `presets.backup-….json` in `~/Library/Application Support/MacFanPilot` before it is replaced |
| CPU temperature shows "–" | No sensor was recognised on this chip. Check the Sensors tab and `smcdump --temps` |

Both processes log through `os.Logger`:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem BEGINSWITH "uz.stiv.macfanpilot"'
```

## License

[MIT](LICENSE).
