# Changelog

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
