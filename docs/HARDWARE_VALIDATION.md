# Hardware commissioning

No M5 Pro sensor or fan-write behavior is assumed to be validated. The app cannot enable manual control based on a successful read-only discovery alone.

## Read-only discovery

From the project directory, in a normal Terminal session:

```sh
"dist/Auto Fan Control.app/Contents/MacOS/fanctl" doctor
```

If macOS requires privileged SMC access, run the same read-only command with `sudo`. It reports the model, each fan’s actual speed and limits, mode-key availability, and readable temperature candidates. It does not write fan keys or save a validation record. The diagnostic does not print the machine UUID.

Record the Mac model, macOS version, fan limits, and CPU/GPU sensor mapping in your own hardware notes. Verify the mapping against a reliable source for that exact SoC and observe responses under separate CPU/GPU loads. Do not classify a sensor from its plausible-looking temperature alone. Include all verified CPU/GPU sensors whose hottest value should govern cooling. Do not enable a profile if this mapping is uncertain.

## Explicit bounded response test

Quit other fan-control tools. Unregister this app’s helper first using General; the commissioning CLI and helper use the same exclusive hardware lock.

After identifying the sensor keys, substitute the verified comma-separated keys below:

```sh
sudo "dist/Auto Fan Control.app/Contents/MacOS/fanctl" validate --cpu CPU_KEYS --gpu GPU_KEYS
```

This command changes fan control. It:

1. Requires root and distinct, nonempty CPU/GPU sensor lists.
2. Checks fan limits and automatic mode before starting.
3. Starts a separate watchdog process. Missing heartbeats for five seconds, parent exit, or the 30-second overall deadline causes an automatic-restoration attempt.
4. Reads all supplied sensors, then requests maximum RPM for every fan.
5. Waits up to 20 seconds for actual RPM to reach at least 90% of each maximum, checking sensor readings and thermal pressure along the way.
6. Restores and verifies automatic mode, waits one second, and verifies again. The watchdog also verifies restoration before the parent saves the record.
7. Writes a root-owned validation record only if all those checks pass.

Do not suspend or kill the watchdog. If restoration cannot be verified, the CLI reports an error and does not grant validation. The emergency restoration command is:

```sh
sudo "dist/Auto Fan Control.app/Contents/MacOS/fanctl" restore
```

This command also acquires the exclusive hardware lock. When the helper is running, use the app’s Pause or Unregister controls first. Never remove a lock file to bypass a live process.

A passed commissioning run confirms that the supplied keys are readable and that fan response/restoration work at that moment. Correct CPU/GPU sensor identity still depends on the verified mapping supplied by the operator. It does not establish behavior across every load, firmware change, or system failure.

## End-to-end acceptance on the actual Mac

After registering the signed helper and reviewing curves:

- Launch a configured app and observe actual RPM converge at low, medium, and maximum demands.
- Launch a second configured app with a stronger curve; confirm independent per-fan maximum selection.
- Keep two instances of a configured bundle running; terminate one, then the other.
- Check Pause, Resume, last-app exit, Quit, sleep, wake, and helper restart. Confirm automatic mode from a separate read-only diagnostic after restoration.
- Verify the lease restores fans when the app is stopped or disconnected. Automatic restoration depends on the helper still being runnable; a helper crash depends on launchd restarting it.
- Test failures with the simulated backend first. Do not deliberately corrupt real thermal sensors or force critical pressure just to trigger a failure case.
- Measure idle CPU and wakeups in Activity Monitor or Instruments for at least one minute with no matching apps, and again while active. The inactive app/helper should have no periodic control or sensor timers.

Repeat commissioning after an OS version, fan-limit, or hardware identity change. Before rebuilding or moving an installed helper, unregister it so launchd does not retain an obsolete bundle registration.
