#!/system/bin/sh
#
# Copyright (C) 2026 drybrine
# Licensed under the Apache License, Version 2.0 (see LICENSE)
#
# Makes sure `encored` is running. Two modes:
#
#   --once   (default) ensure it is up, then EXIT. No resident process.
#   --loop   stay resident and restart it whenever it dies.
#
# The default is --once: a module should not leave a background process behind
# just to babysit another one. What that costs: a soft reboot restarts the
# framework without running any module script, so encored dies and nothing
# brings it back - run `encore_transsion start` (or the manager Action button)
# once afterwards. A full reboot is fully automatic.
#
# --loop exists for people who soft-reboot often and prefer the convenience over
# having a process around.
#
# Why: the daemon is started by service.sh, which runs once at boot. A *soft*
# reboot restarts the framework but re-runs no module script, so the daemon
# disappears and the WebUI reports "Service inactive" while everything else
# (root, the USF bind mount) survives. Nothing in a module can hook a soft
# reboot, so instead of trying, this watchdog stays resident and puts the
# daemon back within one poll.
#
# It also covers the case where encored exits on its own (it returns
# EXIT_FAILURE when the gamelist is missing, or when MODPATH/update exists
# after a module update).
#
# Stops itself when the module is disabled or removed, so it can never fight a
# deliberate shutdown.

MODDIR=${MODDIR:-/data/adb/modules/encore}
MODULE_CONFIG=${ENCORE_CONFIG:-/data/adb/.config/encore}
BIN="$MODDIR/system/bin"
INTERVAL=${ENCORE_WATCHDOG_INTERVAL:-10}
# Once the daemon is confirmed healthy, poll less often. A soft reboot is a
# rare event; 30s to notice it is fine, and it keeps the device out of the way
# while it idles (notification delivery is the thing users feel).
IDLE_INTERVAL=${ENCORE_WATCHDOG_IDLE_INTERVAL:-30}
PIDFILE="$MODULE_CONFIG/.daemon_watchdog.pid"
# Filesystem root for hardware detection (the host suite overrides this).
SROOT=${ENCORE_SYSROOT:-}
LOG="$MODULE_CONFIG/daemon_watchdog.log"

log() {
	mkdir -p "$MODULE_CONFIG" 2>/dev/null
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

MODE="once"
case "${1:-}" in
--loop) MODE="loop" ;;
--once | "") MODE="once" ;;
*)
	printf 'usage: %s [--once|--loop]\n' "$0" >&2
	exit 2
	;;
esac

# Single instance - only meaningful in loop mode. The pid file is only trusted
# after its cmdline is checked: a recycled PID must never make us think a
# watchdog is already running.
if [ "$MODE" = "loop" ] && [ -r "$PIDFILE" ]; then
	old=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$old" ] && [ -d "/proc/$old" ]; then
		case "$(tr '\0' ' ' <"/proc/$old/cmdline" 2>/dev/null)" in
		*daemon_watch*) exit 0 ;;
		esac
	fi
fi
if [ "$MODE" = "loop" ]; then
	mkdir -p "$MODULE_CONFIG" 2>/dev/null
	printf '%s\n' "$$" >"$PIDFILE"
fi

cleanup() { [ "$MODE" = "loop" ] && rm -f "$PIDFILE" 2>/dev/null; return 0; }
# A TERM must actually end the loop - a trap that only cleans up would make
# the watchdog unkillable (and `timeout` would never return).
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

# Trim our own log so a long-running watchdog cannot fill /data.
trim() {
	[ -f "$LOG" ] || return 0
	size=$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')
	[ -n "$size" ] && [ "$size" -gt 65536 ] && : >"$LOG"
}

# True when encored is running.
#
# This runs every poll, forever, INCLUDING while the screen is off and the
# device wants to idle - so it must not fork per process. Scanning /proc/PID/
# cmdline costs one `tr` per process: ~280 on a PC, several hundred on a phone,
# i.e. millions of forks a day, all competing with FCM wakeups and idle entry.
# `pidof` answers the same question with a single call.
#
# The /proc scan is kept only as a fallback for builds without pidof.
daemon_running() {
	if command -v pidof >/dev/null 2>&1; then
		pidof encored >/dev/null 2>&1 && return 0
		return 1
	fi
	for d in /proc/[0-9]*; do
		[ -r "$d/cmdline" ] || continue
		c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)
		case "$c" in
		encored | encored\ * | */encored | */encored\ *) return 0 ;;
		esac
	done
	return 1
}

# ---------------------------------------------------------------------------
# Preconditions the daemon checks itself, repaired here.
#
# encored exits before writing a single log line when /data/adb/modules/<id>/update
# exists ("Please reboot your device to complete module update"), which is why a
# broken install shows an EMPTY encore.log and nothing else. A marker created
# BEFORE the current boot is stale: the update was already merged, the file was
# simply never cleaned up.
# ---------------------------------------------------------------------------

boot_epoch() {
	# now - uptime = the moment this kernel booted
	up=$(cut -d. -f1 /proc/uptime 2>/dev/null)
	case "$up" in ''|*[!0-9]*) echo 0; return ;; esac
	echo $(($(date +%s) - up))
}

# Grace period after boot_completed before a marker created DURING this boot is
# treated as stuck. The manager creates it while merging an update and is
# expected to remove it; if it does not, the daemon would never run again.
UPDATE_GRACE=${ENCORE_UPDATE_GRACE:-90}
UPDATE_SEEN_AT=""
# Set while a genuinely pending update marker is honoured; the loop must not
# start the daemon then (it would exit immediately anyway).
UPDATE_PENDING=""

clear_stale_update_marker() {
	UPDATE_PENDING=""
	if [ ! -e "$MODDIR/update" ]; then
		UPDATE_SEEN_AT=""
		return 0
	fi
	# Only pay for stat/boot_epoch when a marker is actually there (the common
	# case is "no marker": zero forks).
	bt=$(boot_epoch)
	mt=$(stat -c %Y "$MODDIR/update" 2>/dev/null)
	case "$mt" in ''|*[!0-9]*) mt=0 ;; esac

	if [ "$bt" -gt 0 ] && [ "$mt" -gt 0 ] && [ "$mt" -lt "$bt" ]; then
		# created before this boot -> the update already merged, nobody cleaned up
		rm -f "$MODDIR/update" 2>/dev/null
		log "removed a stale update marker from a previous boot ($MODDIR/update)"
		return 0
	fi

	# Created during this boot: give the manager time to finish, then clear it.
	if [ -z "$(getprop sys.boot_completed 2>/dev/null)" ]; then
		return 0
	fi
	if [ -z "$UPDATE_SEEN_AT" ]; then
		UPDATE_SEEN_AT=$(date +%s)
		UPDATE_PENDING=1
		log "pending module update: $MODDIR/update exists; waiting up to ${UPDATE_GRACE}s for the manager to clear it"
		return 0
	fi
	now=$(date +%s)
	if [ $((now - UPDATE_SEEN_AT)) -ge "$UPDATE_GRACE" ]; then
		rm -f "$MODDIR/update" 2>/dev/null
		UPDATE_SEEN_AT=""
		log "removed an update marker that outlived the ${UPDATE_GRACE}s grace period ($MODDIR/update)"
		return 0
	fi
	UPDATE_PENDING=1
}

# soc_recognition drives which tweaks run; 0 makes Encore skip most of them
# ("Unknown SoC"). The installer writes it once, so a failed detection at
# install time sticks forever. Re-detect cheaply.
repair_soc() {
	# read builtin, not $(cat ...): this runs every poll, including while the
	# device is trying to idle.
	cur=""
	[ -r "$MODULE_CONFIG/soc_recognition" ] && read -r cur <"$MODULE_CONFIG/soc_recognition"
	case "$cur" in 1|2|3|4|5|6|7|8) return 0 ;; esac

	# SROOT exists so the host suite can point this at a fake tree.
	soc=0
	[ -d "$SROOT/sys/class/kgsl/kgsl-3d0/devfreq" ] && soc=2
	[ "$soc" = 0 ] && [ -d "$SROOT/sys/devices/platform/kgsl-2d0.0/kgsl" ] && soc=2
	[ "$soc" = 0 ] && [ -d "$SROOT/sys/kernel/ged/hal" ] && soc=1
	[ "$soc" = 0 ] && [ -d "$SROOT/sys/kernel/tegra_gpu" ] && soc=6
	if [ "$soc" = 0 ]; then
		plat=$(getprop ro.board.platform 2>/dev/null)
		case "$plat" in
		mt* | MT*) soc=1 ;;
		sm* | qcom* | SM* | QCOM*) soc=2 ;;
		exynos* | universal* | s5e*) soc=3 ;;
		ums* | sp* | SC*) soc=4 ;;
		gs* | tensor*) soc=5 ;;
		kirin*) soc=7 ;;
		esac
	fi
	if [ "$soc" != 0 ]; then
		mkdir -p "$MODULE_CONFIG" 2>/dev/null
		printf '%s\n' "$soc" >"$MODULE_CONFIG/soc_recognition"
		log "soc_recognition was '${cur:-missing}'; detected SoC code $soc and repaired it"
	fi
}

# ---------------------------------------------------------------------------
# One pass: clear what blocks encored, then start it if it is down.
# Returns 0 when the daemon is up afterwards.
# ---------------------------------------------------------------------------
pass_once() {
	[ -d "$MODDIR" ] || return 1          # module removed
	[ -e "$MODDIR/disable" ] && return 1  # module disabled (file or dir)
	[ -x "$BIN/encored" ] || return 1
	# encored needs the framework: never start it before boot_completed.
	[ -n "$(getprop sys.boot_completed 2>/dev/null)" ] || return 1

	clear_stale_update_marker
	repair_soc
	# A genuinely pending update blocks encored by design; nothing to do.
	[ -n "$UPDATE_PENDING" ] && return 1

	if daemon_running; then
		return 0
	fi

	# Missing gamelist is fatal for encored; regenerate it if it vanished.
	if [ ! -f "$MODULE_CONFIG/gamelist.json" ] && [ -x "$BIN/encored" ]; then
		"$BIN/encored" setup_gamelist "$MODULE_CONFIG/gamelist.json" >/dev/null 2>&1
	fi
	log "encored not running; starting it"
	"$BIN/encored" daemon >>"$MODULE_CONFIG/encore.log" 2>&1
	sleep 3
	if daemon_running; then
		log "encored started"
		return 0
	fi
	log "WARN: encored exited immediately (see encore.log)"
	return 1
}

# Wait for boot_completed, bounded: this may run from post-fs-data, before the
# framework is up. Returns 0 once booted, 1 on timeout.
wait_boot() {
	limit=${1:-180}
	i=0
	while [ -z "$(getprop sys.boot_completed 2>/dev/null)" ]; do
		[ "$i" -ge "$limit" ] && return 1
		sleep 5
		i=$((i + 5))
	done
	return 0
}

if [ "$MODE" = "once" ]; then
	# The common case: start it, get out of the way, leave no process behind.
	if ! wait_boot 180; then
		log "boot_completed did not arrive within 180s; not starting encored"
		cleanup
		exit 1
	fi
	pass_once
	rc=$?
	trim
	cleanup
	exit $rc
fi

# --loop: resident mode, opt-in.
while :; do
	pass_once
	# Poll slowly while everything is healthy, quickly while recovering.
	if [ -n "$UPDATE_PENDING" ]; then
		sleep "$INTERVAL"
	elif daemon_running; then
		sleep "$IDLE_INTERVAL"
	else
		sleep "$INTERVAL"
	fi
done

cleanup
exit 0
