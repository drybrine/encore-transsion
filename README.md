> **This is a fork: `encore-transsion`.** It is [Encore Tweaks](https://github.com/Rem01Gaming/encore) by Rem01Gaming, with one addition for Infinix / Tecno / itel devices.
>
> On Transsion XOS, `com.transsion.usf` caps the CPU clusters from a *virtual skin temperature* — on an Infinix Note 60 that is 1.8 / 2.2 GHz instead of 2.0 / 2.6 GHz at a 41 °C skin reading, and it re-clamps within a second even when you write the ceiling by hand. That clamp sits **underneath** Encore's own tweaks, so profiles could never reach the hardware maximum.
>
> This fork ships two ways to remove that cap, and leaves the rest of Encore untouched: **method `all`** (default) turns `com.transsion.usf` off entirely, **method `cpu`** patches only the CPU columns of its thermal config. See [Transsion CPU unlock](#transsion-cpu-unlock) below.
>
> Everything else here is upstream. Report upstream bugs upstream.

<p align="center"><a href="https://encore.rem01gaming.dev" target="_blank"><img src="https://encore.rem01gaming.dev/logo.webp" width="200" alt="Encore Tweaks Logo"></a></p>

<p align="center">
<a href="https://t.me/rem01schannel"><img src="https://img.shields.io/badge/Follow-Telegram-white.svg?style=for-the-badge&logo=telegram&logoColor=white&labelColor=222" alt="Join Our Telegram Channel"></a>
<a href="https://encore.rem01gaming.dev/download"><img src="https://img.shields.io/github/downloads/rem01gaming/encore/total?style=for-the-badge&logoColor=white&labelColor=222" alt="Total Downloads"></a>
<a href="https://github.com/Rem01Gaming/encore/releases"><img src="https://img.shields.io/github/v/release/rem01gaming/encore?label=Release&style=for-the-badge&logo=github&logoColor=white&labelColor=222" alt="Latest Stable Version"></a>
<a href="https://encore.rem01gaming.dev"><img src="https://img.shields.io/badge/Apache-white?style=for-the-badge&logo=andela&logoColor=white&label=License&labelColor=222" alt="License"></a>
</p>

## About Encore Tweaks

**Encore Tweaks** is a dynamic Magisk module designed to maximize your device's gaming performance while intelligently preserving battery life during everyday use. Perfect for gamers who demand smooth gameplay without compromising daily usability!

More info about this project on [Official Encore Tweaks website](https://encore.rem01gaming.dev/)

## Transsion CPU unlock

Transsion Holdings builds XOS for Infinix, Tecno and itel. Its skin-thermal
engine (`com.transsion.usf`) applies a CPU cluster cap derived from a *virtual
skin temperature*:

| Skin temp | little / big (stock) |
|---|---|
| ≤ 36 °C | 2.0 / 2.6 GHz (hardware max) |
| 39–40 °C | 1.9 / 2.3 GHz |
| 41–42 °C | 1.8 / 2.2 GHz |
| 43–44 °C | 1.7 / 2.1 GHz |
| ≥ 45 °C | 1.6 / 2.0 GHz |

Because USF applies that cap through MediaTek PowerHAL, writing
`scaling_max_freq` by hand is undone in under a second — Encore's governors and
frequency pinning were fighting a limiter that wins.

This fork removes the cap with one of two methods. **The default is `all`.**

| Method | What it removes | What else stops working |
|---|---|---|
| `all` (default) | USF itself: the package is disabled, so no `TranThermalEngine` method runs | GPU throttle, brightness/HBM, refresh rate, FPS, media-volume reduction, wifi/bt policy, PowerHAL locks, core isolation, torch — all unmanaged |
| `cpu` | Only the CPU ceiling, from USF's own config | nothing else |

Either way every kernel thermal zone, trip point and junction protection stays
stock: the device still throttles at the kernel trip points. It **can run
hotter** under sustained load; watch your temperatures.

### Method `all` — turn USF off (default)

Same code path as [`usf-off`](https://github.com/drybrine/usf-off):
`pm disable-user --user 0 com.transsion.usf`, then a kill by exact cmdline
match. It runs only after `sys.boot_completed` — disabling a persistent system
app before the framework is up can restart the boot sequence — so on each boot
USF applies its policy for the first few seconds and then stops. `restore`
re-enables the package.

On some XOS builds a supervisor (not init) restarts `com.transsion.usf` after the
kill, so the disable flag alone removes nothing — the new process re-applies
every policy from its config. The script detects that, names the respawned pid
and its parent, and falls back to mounting the CPU-unlocked config so the
respawn cannot re-cap the CPU; it then reports the state as **degraded**: the CPU
cap is neutralised, the other USF methods (GPU, brightness, refresh, fps, volume)
are not. On such a build `method cpu` is the honest choice — same CPU result,
without the pretence that USF is off.

### Method `cpu` — patch the config

1. Copies USF's own `tran_thermal.xml` and zeroes **only** the `cpu` /
   `clusterCpu0` / `clusterCpu1` / `clusterCpu2` attributes of every
   `<temp_config>` row. An all-zero row is USF's own "no CPU limit" encoding:
   its `applyCpuLimit()` releases the PowerHAL thermal handle for such a row.
2. Bind-mounts the patched copy over the original path. **The file on the
   partition is never modified** — `restore` (or a reboot) brings stock back.
3. `post-fs-data.sh` mounts it before USF starts, so USF reads the patched file
   on its first config read. Under late-load root (GhostLock) that stage does
   not run, so `service.sh` mounts and reloads USF instead.

Everything else in that config — skin TJ targets, brightness/HBM, charging,
GPU, FPS — stays byte-identical.

### Starting the daemon after a soft reboot

The module starts `encored` once at boot and exits — no background process. A
soft reboot runs no module script, so the daemon dies with the framework:

```sh
su -c '/data/adb/modules/encore/system/bin/encore_transsion start'
```

A full reboot is automatic. If you soft-reboot often and want it handled for
you, run the watchdog in resident mode instead
(`encore_daemon_watch --loop`).

### Controlling it

There is no WebUI change in this fork — the WebUI is upstream, untouched. The
unlock is on by default and controlled from a shell:

```sh
su -c '/data/adb/modules/encore-transsion/system/bin/encore_transsion status'
su -c '/data/adb/modules/encore-transsion/system/bin/encore_transsion disable'
su -c '/data/adb/modules/encore-transsion/system/bin/encore_transsion enable'
```

`status` prints the active method, the package/mount state and every cpufreq
ceiling against its hardware maximum — so you can see the cap is gone rather
than trust it.

Switch method (the old one is undone first: unmount or re-enable, never both at
once):

```sh
su -c '/data/adb/modules/encore/system/bin/encore_transsion method cpu'
su -c '/data/adb/modules/encore/system/bin/encore_transsion method all'
```

The preference and the method are persisted, so a reboot keeps whichever state
you picked. On a device without USF the script reports that it does not apply
and does nothing.

Do **not** run this alongside `usf-unlock` or `usf-cpu-unlock`: they bind-mount
a patched copy over the same path, and whichever mounts first wins. Pick one.

## Supported Root Managers

- [APatch](https://github.com/bmax121/APatch)
- [KernelSU](https://github.com/tiann/KernelSU)
- [Magisk](https://github.com/topjohnwu/Magisk)  <sup>([no WebUI](https://github.com/topjohnwu/Magisk/issues/8609#event-15568590949)👀)</sup>

### Also Supported on

- [KsuWebUI](https://github.com/5ec1cff/KsuWebUIStandalone)   <sup>🌐</sup>
- [WebUI-X](https://github.com/MMRLApp/WebUI-X-Portable)   <sup>🌐</sup>
- [MMRL](https://github.com/MMRLApp/MMRL)

## Resources

- [FAQ](https://encore.rem01gaming.dev/guide/faq.html) - Common questions answered
- [Configuration Guide](https://encore.rem01gaming.dev/guide/webui-and-configuration.html) - How to configure the WebUI
- [Download](https://encore.rem01gaming.dev/download) - Get the latest version

## Community & Support

- [Telegram Channel](https://t.me/rem01schannel) - Stay updated with announcements
- [Report Issues](https://github.com/rem01gaming/encore/issues) - Found a bug? Let us know!
- [Contribute](https://github.com/rem01gaming/encore/pulls) - Submit improvements via PR

## Translation

Interested in translating Encore Tweaks? We use Weblate to crowdsource translations, allowing the community to collaborate on making the project accessible in multiple languages. Visit our translation project [here](https://hosted.weblate.org/projects/encore-tweaks/) and help us reach more users worldwide!

<a href="https://hosted.weblate.org/projects/encore-tweaks/"><img src="https://hosted.weblate.org/widget/encore-tweaks/webui/horizontal-auto.svg" alt="Weblate translation status"></a>

## License

Encore Tweaks is open-sourced software licensed under the [Apache-2.0 license](https://www.apache.org/licenses/LICENSE-2.0).
