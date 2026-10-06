# Testing MacFanPilot

Two layers: unit tests that run anywhere, and a manual checklist that needs a real Mac with fans,
because nothing short of the hardware proves that macOS accepts the fan commands.

## Unit tests

```sh
xcodebuild test -project MacFanPilot.xcodeproj -scheme MacFanPilot -destination 'platform=macOS,arch=arm64'
```

or ⌘U in Xcode. The test bundle compiles the sources itself and is signed to run locally, so it
needs no signing certificate and never talks to the installed helper.

| File | What it covers |
|---|---|
| `Tests/FanControllerTests.swift` | The helper's control loop against a fake SMC: clamping, ramping, the emergency override, the watchdog, sensor and write failures, the M3 unlock sequence, handing fans back, the stale-marker recovery, per-fan modes |
| `Tests/SensorTests.swift` | Sensor discovery, the fallback key lists, hot-set polling |
| `Tests/PresetStoreTests.swift` | Reading 1.0 files, the versioned format, backups of files that can't be read, delayed saves, import and export |
| `Tests/AppModelTests.swift` | Keeping the chosen preset through failures, retries, notifications, the battery rule, Focus filters, history |
| `Tests/ModelTests.swift` | Curves, preset sanitizing and decoding, SMC value coding, temperature units |
| `Tests/ViewSmokeTests.swift` | Lays out the popover, settings and preset editor with made-up readings |

`ViewSmokeTests` also writes a PNG of each view when `SNAPSHOT_DIR` is set, which is the quickest
way to look at a UI change in every state:

```sh
TEST_RUNNER_SNAPSHOT_DIR=/tmp/shots xcodebuild test -project MacFanPilot.xcodeproj -scheme MacFanPilot \
    -destination 'platform=macOS,arch=arm64' -only-testing:MacFanPilotTests/ViewSmokeTests
```

The tests do not cover the XPC connection, `SMAppService` registration, notifications, App Intents
or anything that needs the real SMC. That is what the checklist is for.

## Manual checklist

Run it from `/Applications` (the helper is registered against the app's location) with every
other fan utility quit. Watch the logs in a second terminal:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem BEGINSWITH "uz.stiv.macfanpilot"'
```

Load: `for i in $(seq 12); do yes > /dev/null & done`, stopped with `killall yes`. For GPU load
use any Metal benchmark or a game. `smcdump | grep -E '^(F[0-9]Md|Ftst)'` shows who holds the fans.

### Fan control

- [ ] Automatic: every `F{n}Md` is `0`, `Ftst` is `0`.
- [ ] Full Blast: both fans reach `F{n}Mx` within a few seconds.
- [ ] Balanced under CPU load: rpm rises with temperature and falls gradually after `killall yes`.
- [ ] A fixed-speed preset holds its rpm; the typed value is clamped to the fan's range.
- [ ] A preset with one fan overridden: each fan follows its own mode. With one fan on Automatic
      beside a held one (M3 and later), that fan follows the Balanced curve instead of stalling.
- [ ] Editing the active preset's curve applies within a second; renaming it does not restart
      control (no dip in fan speed).

### Handing the fans back

- [ ] Quit from the menu → fans on Auto within about 2 s, helper gone after 10 s.
- [ ] `kill -9 <MacFanPilot pid>` → Auto at once.
- [ ] Pause the app in a debugger for more than 20 s → the watchdog resets to Auto; on resume the
      preset is re-applied.
- [ ] `sudo launchctl kill SIGTERM system/uz.stiv.macfanpilot.helper` → Auto, helper exits.
- [ ] `sudo kill -9 <helper pid>` while controlling → launchd restarts the helper, which finds
      `/var/run/uz.stiv.macfanpilot.helper.active` and releases the fans; the app re-applies.
- [ ] Sleep and wake with a custom preset active → re-applied after wake.
- [ ] Restart with Launch at login on → last preset active without any action.

### Failure handling

- [ ] Helper not installed → monitoring only, the chosen preset stays ticked (dimmed) and the
      popover offers to install.
- [ ] Start another fan utility → "Another app is controlling the fans".
- [ ] Replace the app in `/Applications` with a newer build while a preset is selected → control
      resumes on launch without Uninstall / Install. The log shows whether the helper had to be
      registered again.
- [ ] Emergency override: hold the fans at a low fixed speed and load the CPU until a sensor
      reaches 100 °C. Every fan goes to maximum, the menu bar icon becomes a thermometer, one
      "Fans at maximum" banner appears, and the preset resumes once the sensor is back at 95 °C.
- [ ] The "Fan control stopped" banner and the warning-triangle icon can't be provoked on demand
      on healthy hardware (they follow sensors or fan writes failing). `AppModelTests` covers the
      logic; check the banner itself whenever a Mac does hit that state.

### Rules and integrations

- [ ] "Use Automatic on battery": unplug → Automatic with the battery notice, preset still
      ticked; plug in → preset back.
- [ ] Shortcuts: "Set Fan Preset" lists every preset and switches to it, also when the app was
      not running.
- [ ] A Focus with the "Set Fan Preset" filter switches when the Focus comes on and back when it
      goes off. Picking another preset during the Focus is not undone.
- [ ] Import a file exported on another Mac → presets appear as new copies. A 1.0 `presets.json`
      imports too.
- [ ] Copy Diagnostics → the clipboard holds versions, the Mac model, fan ranges and sensor
      families, and nothing personal.

### Housekeeping

- [ ] Popover closed with the menu bar on "Icon only": the app's energy impact in Activity
      Monitor drops (sensors are polled every 10 s instead of every 1–5 s).
- [ ] Lid closed in clamshell mode, on battery, and while charging: no errors in the logs.

## Safety rules

These hold whatever else changes. Rules 1 to 4, the watchdog in rule 5 and the release check in
rule 6 have tests in `FanControllerTests`; keep it that way. The disconnect, SIGTERM and exit
handling around them lives in `HelperService.swift` and `main.swift` and is only covered by the
checklist above.

1. Never write a target below `F{n}Mn` or above `F{n}Mx`.
2. Sensors unreadable for 3 ticks in a row → all fans to Auto.
3. Fan writes rejected 3 ticks in a row → all fans to Auto.
4. Any CPU or GPU sensor at 100 °C or above → every fan to maximum until it is back at 95 °C,
   whatever the preset says.
5. App disconnected, heartbeats missing for 20 s, or SIGTERM → all fans to Auto.
6. The helper never exits cleanly while a fan is still in manual mode. If a fan can't be handed
   back it stays alive and keeps trying, and the marker file stays in place so that a relaunch
   knows.
7. Apple Silicon still throttles on its own. Fan control changes noise and temperature; it cannot
   disable the chip's protection, and must not be presented as a way to get more performance than
   better cooling gives.
