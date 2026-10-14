# Auto Fan Control

A native, personal-use menu-bar app for Apple Silicon Macs running macOS 26+. Built from [PLAN.md](PLAN.md) with SwiftUI, AppKit, IOKit, authenticated XPC, and SMAppService. No third-party dependencies.

Assign apps to Gaming, Performance, or named custom curves. While matching apps run, each fan uses the highest requested RPM. Closing Settings leaves the menu-bar app running.

## Build and run

Requires Xcode 26+ with its command-line tools selected.

```sh
./Scripts/test.sh
./Scripts/build.sh
open "dist/Auto Fan Control.app"
```

The build script produces an arm64 `.app` containing the app, helper, commissioning CLI, and launch-daemon property list. Open `Package.swift` in Xcode to work on the sources. Use the packaging script to run the complete app bundle; a bare SwiftPM executable does not contain the service-registration resources.

For the curve editor without touching hardware:

```sh
open "dist/Auto Fan Control.app" --args --preview
```

Quit any existing instance first. Preview uses clearly labeled illustrative fan limits and a temporary configuration; it cannot connect to the helper or control fans.

By default the build is ad-hoc signed. The interface works, but the helper deliberately refuses ad-hoc clients. For hardware operation, build all components with the same Apple-issued development or Developer ID identity:

```sh
SIGNING_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build.sh
```

The identity must already exist in your keychain. The helper and app enforce reciprocal signing requirements using their bundle identifiers and the same signing team. There is no unsigned fallback. This project does not install certificates or register a daemon during its build.

## First hardware setup

1. Build with your signing identity and place the app at its intended permanent location before registering the service.
2. Run the read-only `fanctl doctor` command described in [hardware validation](docs/HARDWARE_VALIDATION.md). Identify and verify the actual CPU and GPU temperature keys for the target machine. Candidate key names alone are not proof of sensor identity.
3. With the helper unregistered, perform the bounded, root-only commissioning test. It checks sensor readability, actual fan response at maximum RPM, and return to automatic mode. A separate watchdog restores automatic mode on loss of commissioning heartbeats. A successful run writes a root-owned validation record.
4. Open **General → Register Helper** and approve the daemon in macOS **Login Items & Extensions** if requested. Select **Connect / Refresh**.
5. Review every fan’s curve and reported limits. In General, select **I’ve Reviewed All Curves**.
6. In Apps, choose **Add Apps…**, assign presets, and run a configured app.

Registration and commissioning are explicit setup steps. Unsupported hardware stays out of manual control. This implementation does not use SMC diagnostic/unlock keys to override the system thermal manager.

## Behavior

- Gaming and Performance presets are generated from each fan’s detected minimum/maximum RPM.
- Graph and numeric fields edit the same draft. Drag points, focus a graph point and use arrow keys, or enter exact values. Snapping applies to dragging; numeric fields retain exact values.
- **Apply** validates and saves the draft. **Cancel** restores the last saved version. Switching presets with an unapplied draft asks whether to discard it. Leaving the Fan Curves page discards its unapplied draft.
- **Duplicate** creates a named custom preset. **Copy to Other Fans** scales RPM over the destination fan’s range. Default restoration uses the preset’s factory curve; custom presets use Gaming as the reset baseline.
- Curves require 2–32 points, strictly increasing temperatures, nondecreasing RPM within hardware limits, and maximum RPM at or below 85°C.
- Background/minimized apps remain eligible. Multiple live PIDs of a bundle ID count as one rule; stopping one instance does not clear another.
- The helper reads the hottest validated CPU/GPU sensor once per second while active, raises demand immediately, and requires five consecutive lower-demand samples to reduce RPM. Unchanged targets are not rewritten.
- Last-app exit, Pause, Quit, sleep, elevated thermal pressure, invalid readings, failed writes, disconnect, or lease expiry requests verified automatic restoration. Failures to verify restoration are surfaced rather than labeled successful.
- The helper independently observes system sleep and thermal pressure. It cancels its control timer when inactive. The app cancels lease renewals and only observes lifecycle events while inactive.
- Hardware identity or fan-limit changes invalidate curve review. An OS version change also invalidates commissioning. Existing matching fan curves are rescaled to new ranges for review.
- Launch at login is optional. Presets do not change CPU/GPU power settings.

## Files and architecture

| Location | Responsibility |
| --- | --- |
| `Sources/FanCore` | Value models, validation, interpolation, draft editor, PID matching, atomic versioned storage, testable control engine |
| `Sources/AutoFanControl` | SwiftUI settings and popover, app observation, helper client, service registration |
| `Sources/FanIPC` | Narrow XPC protocol, bounded JSON messages, reciprocal code-signing requirements |
| `Sources/FanHelper` | Serialized hardware ownership, independent validation, sampling timer, session lease, IOKit sleep notifications |
| `Sources/FanHardware` | Typed SMC access, hardware discovery, commissioning, restoration verification |
| `Sources/CSMC` | Small private transport for the AppleSMC user-client ABI |
| `Sources/fanctl` | Read-only discovery, explicit root-only validation and restore commands |
| `Tests/FanCoreTests` | Core behavior and failure-path tests with simulated hardware |

User configuration: `~/Library/Application Support/AutoFanControl/configuration.json` (schema version 1). Hardware validation: `/Library/Application Support/AutoFanControl/hardware-validation.json`. Corrupt or unknown-version settings are preserved and prevent automation; back up the file before replacing it to reset settings.

## Validation status

See [the validation report](docs/VALIDATION.md) for checks performed and outstanding hardware/UI work. This build has **not** been validated for fan control on the target M5 Pro. Neither total system failure nor a hung/crashed kernel/SMC can be recovered by a userspace lease.

The implementation follows Apple's [Liquid Glass guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass), [GlassEffectContainer API](https://developer.apple.com/documentation/swiftui/glasseffectcontainer), and [SMAppService model](https://developer.apple.com/documentation/servicemanagement/smappservice). The SMC user-client interface is undocumented; its wire layout and key names are discoverable in existing [SMC tooling](https://github.com/hholtmann/smcFanControl/blob/master/smc-command/smc.h). Hardware-specific semantics must be commissioned locally.
