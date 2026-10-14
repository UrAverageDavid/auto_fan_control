# Implementation validation — 2026-10-15

Environment: arm64, macOS 27.0.1, Xcode 27.0, Swift 6.4. Deployment target: macOS 26.0. No third-party dependencies.

## Completed

- Compiled the native SwiftUI app, XPC helper, SMC transport, and commissioning CLI.
- Packaged an arm64 app bundle with the helper and SMAppService daemon property list.
- Verified the bundle with `codesign --verify --deep --strict` and checked its Info.plist with `plutil`.
- Ran automated XCTest cases for interpolation/endpoints, curve constraints, percentage defaults, per-fan scaling, multi-app demands, multiple PIDs, disabled rules, startup/wake reconciliation model, draft edits, snapping, keyboard-step model operations, Apply/Cancel/defaults, add/remove/copy, storage round trips/version rejection, hysteresis, unchanged writes, lease expiry, late renewals, idle no-polling behavior, sensor failures/staleness, write rejection, thermal pressure, restoration failure reporting, unsupported/changed hardware, and stop/startup paths.
- Attempted read-only SMC discovery. `IOServiceOpen` returned `-536870174` (access denied in this execution environment). No fan writes or commissioning were attempted.
- Checked the release executable is arm64 and present in the signed bundle.

## Not yet verified

- Actual M5 Pro CPU/GPU sensor identities, supported mode/target keys, actual fan response, or restoration on this hardware.
- Signed XPC communication, SMAppService registration/approval, launch-at-login, or live daemon sleep/wake behavior. The keychain reports zero valid code-signing identities, so the delivered bundle is ad-hoc signed and the privileged path is intentionally disabled.
- Rendered UI, pointer interaction, actual VoiceOver behavior, light/dark appearance, accessibility display modes, and resizing. Launch Services rejected the sandbox launch; direct execution aborted in AppKit's `_RegisterApplication` before the interface initialized. The computer-use service also timed out. Core editor behavior is tested, but those tests are not UI automation.
- Measured idle CPU/wakeups on the desktop session. Tests confirm no inactive sampling in the control engine; source wiring cancels active timers, but this is not a CPU measurement.

## Remaining acceptance checks

Perform the commissioning and end-to-end checks in [HARDWARE_VALIDATION.md](HARDWARE_VALIDATION.md). In the desktop session, launch with `--preview` to check the full editor without hardware:

1. Inspect Apps, Fan Curves, General, and the menu popover.
2. Resize from the 820×620 minimum to a large window. Check scrolling, numeric-field labels, graph ticks, and bottom actions.
3. Change a graph point, edit its numeric values, and verify both stay synchronized. Tab to a graph point and use arrow keys. Check VoiceOver point labels and adjustment actions.
4. Test Apply, Cancel, Restore Preset Defaults, Duplicate, custom naming/deletion, Copy to Other Fans, and switching presets with unsaved changes.
5. Inspect in light/dark, Reduce Transparency, Reduce Motion, and increased contrast. The graph uses a stable content background. Reduced transparency removes the custom glass surface. No continuous animations are used.
6. Check the unavailable-hardware and unconfirmed-restoration states. Preview must remain visibly labeled and must never enable hardware control.

The default Swift 6.4 build engine hit a sandbox denial during dSYM generation. The release script uses SwiftPM's native backend with debug information disabled to produce a verified bundle in this environment. The unit suite runs with the default build engine.
