# Changelog

## v5.2.2-transsion.5

Makes the "does this device apply?" answer explicit, and documents the boundary.

- **ROM is named, not guessed at.** `status` / `doctor` / `install` now report
  `XOS (Infinix)`, `HiOS (Tecno)`, `itelOS (itel)` or `custom ROM (AOSP-based)`
  from `ro.build.fingerprint` / `ro.build.display.id`.
- **Two different failures are no longer the same message.** A build with no
  USF config is now distinguished from a Transsion build whose config is
  missing: the first says "nothing to unlock — USF only ships on XOS / HiOS /
  itelOS", the second says "USF is installed but its thermal config was not
  found (unexpected layout — please report it)".
- **The fallback is a verified no-op.** On a custom ROM there is no USF, so the
  preference stays enabled but `boot` does nothing: no mount, no lock file, no
  error. The rest of Encore runs exactly as upstream — and on a custom ROM there
  is no USF clamp to fight anyway, which is why the unlock is not needed there.

### Scope
This unlock is for **stock Transsion builds** — XOS (Infinix), HiOS (Tecno),
itelOS (itel). On any other ROM it is inert by design; Encore's own tweaks are
what run, unmodified.


## v5.2.2-transsion.4

Portability pass: make the unlock work on other Transsion devices, not just the
one it was built on.

- **Clusters above 2 are no longer skipped.** The patcher only zeroed
  `clusterCpu0` / `1` / `2`. A device with a fourth cluster would have been
  unlocked *partially* — the cap would stay on the extra cluster and the unlock
  would look broken. It now handles `clusterCpu0`..`clusterCpu7`, and the
  verifier rejects any output that still caps a cluster at any index.
- **Unrecognised cluster attributes are reported, not ignored.** If a config
  uses an index above 7, the patcher prints a warning instead of silently
  producing a half-unlocked file.
- **`soc_recognition` fallback in the profiler.** The file was read with
  `SOC=$(<file)`, which fails when the file is missing and leaves `SOC` empty —
  that silently disables *every* SoC-specific tweak, which is what "Unknown
  SoC" looked like. It now falls back to `ro.board.platform`, then to MediaTek.
- **GPU OPP reads are guarded.** `/proc/gpufreq/gpufreq_opp_dump` is not exposed
  on every MediaTek device, and reading it unguarded leaked `awk: fatal:` into
  the daemon log.

### Compatibility notes
The unlock is generic in the ways that matter: it keys off USF's own element
and attribute names, not temperature values, so a different device with a
different throttle ladder works unchanged. What still varies per device:

| Aspect | Handled how |
|---|---|
| Config path | tries `/tr_product/...` then `/system_ext/...` |
| Throttle ladder (temps, freqs) | irrelevant — only the cap attributes are touched |
| Number of CPU clusters | `clusterCpu0..7` |
| Different attribute names | not patched (safe, but no effect) — the verifier still passes |
| USF absent entirely | install reports it and does nothing |

If a device uses a different schema the module leaves it alone rather than
guessing.


## v5.2.2-transsion.3

Diagnosed from a bug report whose `encore.log` contained **only the export
header** — no daemon lines at all.

### Why the log was empty
`encored` has three preconditions, and exactly one of them exits **without
logging**:

```c
if (access(MODULE_UPDATE, F_OK) == 0) {      // /data/adb/modules/<id>/update
    notify("Please reboot your device to complete module update.");
    return EXIT_FAILURE;                      // no LOGC -> empty log
}
```

The gamelist and device-mitigation failures all call `LOGC`, so they would have
left lines behind. An empty log therefore means the **update marker** was
present. The watchdog now handles it:

- A marker created **before** this boot is stale (the update already merged,
  nothing cleaned up) → removed, daemon starts.
- A marker created **during** this boot is honoured for a 90 s grace period
  (`ENCORE_UPDATE_GRACE`), then removed so a manager that forgets to clean up
  cannot keep the daemon dead forever.

### Also fixed
- **"Unknown SoC"**: `soc_recognition` was `0`, which makes Encore skip most of
  its tweaks. The installer writes that value once, so a failed detection at
  install time sticks forever. The watchdog re-detects it (`/sys` markers, then
  `ro.board.platform`) and repairs the file.
- **New `doctor` command** — prints the daemon state, every precondition
  encored checks, the soc code, the tails of both logs, and the USF cap state,
  so a silent failure is visible in one command:

```sh
su -c '/data/adb/modules/encore/system/bin/encore_transsion doctor'
```

### Tests
`tests/test_daemon_watch.sh` is now 11 host tests: start, boot gate, stale
marker, pending marker, grace expiry, SoC repair (three sysfs shapes plus "leave
a valid code alone"), no double start, disable (file and dir), self-exit on
module removal, single instance, stale pidfile.


## v5.2.2-transsion.2

Fixes the daemon not coming back after a soft reboot, and the module id that
the prebuilt binary requires.

### Fixed
- **`encored` never started.** The prebuilt daemon has its module path compiled
  in (`/data/adb/modules/encore`), and it loads
  `MODPATH/binder_resolver.apk` during init. With a fork id of
  `encore-transsion` that file was not where the binary looks, so the daemon
  exited immediately and the WebUI reported "Service inactive". The module id
  is now `encore` again — the fork lives in the repo name, not in the id.
  Installing this over upstream Encore is a normal in-place upgrade.
- **Nothing restarted the daemon after a soft reboot.** A soft reboot restarts
  the framework but re-runs no module script, so the daemon died while root
  and the USF bind mount survived. New `encore_daemon_watch` stays resident,
  starts `encored` once `sys.boot_completed` is set, and restarts it within one
  poll if it ever exits — soft reboot, crash, or a failed gamelist load. It
  stops itself when the module is disabled or removed.
- The watchdog is started from `post-fs-data.sh` (permanent root) and from
  `service.sh` (late-load / GhostLock), so both paths get it.

### Note
The USF unlock itself was already working: `clusterCpu0=0` with
`policy0 2.0/2.0` and `policy4 2.6/2.6` on an Infinix Note 60 at
`tempLevel=43` — a skin band whose stock caps are 1.7 / 2.1 GHz.


## v5.2.2-transsion.1

First build of the Transsion fork. Upstream Encore Tweaks 5.2.2, unchanged,
plus a fix for the CPU clamp that defeated it on Infinix / Tecno / itel.

### Added
- **USF skin-thermal CPU cap removed.** On XOS, `com.transsion.usf` lowers the
  CPU cluster ceilings from a *virtual skin temperature* (1.8 / 2.2 GHz instead
  of 2.0 / 2.6 GHz on an Infinix Note 60 at a 41 °C skin reading) and re-clamps
  them through MediaTek PowerHAL within a second. Encore's governor and
  frequency tweaks were being clamped underneath it, so profiles could not
  reach the hardware maximum. The fork zeroes only the `cpu` / `clusterCpu0` /
  `clusterCpu1` / `clusterCpu2` attributes of every `<temp_config>` row in
  USF's own `tran_thermal.xml` — its own "no CPU limit" encoding — and
  bind-mounts the patched copy. The file on the partition is never modified.
- Mounted by `post-fs-data.sh` before USF starts on permanent root; by
  `service.sh` (mount + reload) under late-load root such as GhostLock, where
  that stage never runs; at install time by `customize.sh` so
  install → reboot is enough.
- `restore` on disable/uninstall, so a removed or disabled module leaves stock
  thermal behaviour behind.
- CLI: `encore_transsion status | apply | restore | enable | disable`.
  The preference is persisted across reboots.

### Unchanged from upstream
- The WebUI. No page, menu entry or string was added; the only WebUI edits are
  the two hardcoded `/data/adb/modules/encore` paths updated to the fork's
  module id.
- Every Encore tweak, profile, gamelist behaviour and daemon.
- Kernel thermal zones, trip points, junction protection, skin TJ targets,
  charging, GPU and brightness policy.

### Safety
- The XML rewrite is fail-closed: an unexpected shape aborts without touching
  anything, and a separate verifier plus a `<temp_config>` count check gates
  the mount.
- USF is only signalled after re-reading its `/proc/PID/cmdline`, so a recycled
  PID is never killed.
- `apply`/`restore` are serialized with a lockfile.
- The device can run hotter under sustained load. Watch your temperatures.
