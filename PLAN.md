# App-triggered fan control with Apple Liquid Glass

## Summary

Build a lightweight native Swift menu-bar app for Apple Silicon MacBook Pros, initially validated on your M5 Pro.

Assign apps to Gaming, Performance, or custom temperature-to-RPM curves. Apply those curves while configured apps run and restore Apple’s automatic control afterward.

Use **Apple’s Liquid Glass design language**, with G-Helper informing the curve-editing functionality.

## Interface and visual design

- Target **macOS 26 or later** to use native Liquid Glass without a separate legacy appearance.
- Use standard SwiftUI/AppKit toolbars, controls, popovers, and sheets, which adopt the system appearance. Apply custom `glassEffect` sparingly and group related glass elements with `GlassEffectContainer`. Follow [Apple’s Liquid Glass guidance](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass).
- Place glass primarily in navigation and control surfaces. Keep graphs and numeric tables on stable, readable content backgrounds.
- Use system typography, SF Symbols, semantic colors, native window controls, rounded groups, and restrained accent color. Follow system light/dark appearance and accessibility preferences.
- Provide a compact menu-bar popover showing automatic/active/error status, triggering apps, active presets, and Pause, Settings, and Quit controls.
- Provide a resizable settings window with **Apps**, **Fan Curves**, and **General** navigation.
- In Fan Curves, show a preset picker, current temperature and per-fan RPM, fan selection, a large curve graph, and its editable numeric table.
- Honor Reduce Transparency, Reduce Motion, and increased contrast. Support keyboard editing and VoiceOver.
- Render live readings only while control is active; otherwise show “Apple Automatic.” Avoid decorative continuous animations.

## Curve editor and presets

- Plot temperature in °C horizontally and fan speed in RPM vertically, with draggable points and connecting lines.
- Allow adding/removing points and editing exact `{temperatureC, targetRPM}` pairs. Synchronize graph and table edits.
- Offer optional snapping to 1°C and 100 RPM. Show each fan’s supported RPM limits.
- Require at least two points, increasing temperatures, nondecreasing RPM, and maximum RPM reached at or below 85°C.
- Provide Apply, Cancel, and Restore Preset Defaults. Changes affect hardware only after Apply.
- Give each detected fan its own curve, labeled by hardware identity. **Copy to Other Fans** scales targets to each destination fan’s operating range.
- Generate these initial presets from detected fan limits:

| Temperature | Gaming | Performance |
|---|---:|---:|
| 40°C | Minimum | 20% of range |
| 60°C | 25% of range | 50% of range |
| 75°C | 60% of range | 80% of range |
| 85°C | Maximum | Maximum |

- Convert percentages using `minimumRPM + fraction × (maximumRPM − minimumRPM)` and display editable RPM values.
- Gaming balances noise and cooling; Performance ramps earlier. These initial curves require hardware validation and do not change CPU/GPU power settings.
- Persist versioned app rules, named per-fan presets, and hardware identity locally. Require curve review if hardware identity or fan limits change.

## Automation and hardware architecture

- Identify selected apps by bundle ID and track live instances by PID. Use launch/termination events and reconcile running apps at startup and wake.
- Background and minimized apps remain eligible. When multiple rules match, select the highest requested RPM independently for each fan.
- Separate lifecycle observation, curve evaluation, storage, and hardware access behind testable interfaces.
- Use a narrowly scoped privileged helper registered through `SMAppService`, accessed through authenticated XPC. Expose capabilities, control-session start/update, status, and restore-automatic operations; independently validate incoming curves.
- Make hardware validation the first milestone: verify sensors, fan limits, target writes, and automatic restoration on this Mac. Unsupported hardware stays in automatic mode.
- While active, sample the hottest validated CPU/GPU temperature once per second. Interpolate linearly, use endpoint values outside the curve, and clamp RPM to hardware limits.
- Raise targets immediately; require five consecutive lower-demand samples before lowering them. Skip unchanged writes.
- Restore automatic control on last-app exit, pause, quit, sleep, invalid readings, write failures, or serious/critical thermal pressure.
- Use a renewable five-second session lease to restore automatic control after app disconnection or loss of responsiveness. Restore automatic mode on helper startup and verify restoration attempts.
- Reconcile apps after wake before resuming. When inactive, stop sensor polling, control timers, and lease renewals; retain only event observation.
- Offer optional launch at login. Closing the settings window leaves automation running.

## Validation and delivery

- Unit-test interpolation, validation, per-fan scaling, simultaneous rules, and multiple instances of one app.
- Test graph/table synchronization, keyboard editing, snapping, Apply/Cancel, and default restoration.
- Validate Liquid Glass in light/dark appearance and accessibility modes, including graph readability and window resizing.
- Test startup, app launch/exit, pause, quit, sleep/wake, stale sensors, rejected writes, helper restart, and lease expiry.
- Verify actual fan response and restoration on the target Mac. Do not claim recovery from total system failure.
- Measure idle CPU and wakeups, targeting effectively zero sustained idle CPU and no periodic hardware polling.
- Deliver a personal-use arm64 app first. Intel support, launcher subprocess matching, public distribution, and unrelated G-Helper hardware controls remain deferred.
