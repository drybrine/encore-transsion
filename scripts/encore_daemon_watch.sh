#!/system/bin/sh
#
# Copyright (C) 2026 drybrine
# Licensed under the Apache License, Version 2.0 (see LICENSE)
#
# Keeps `encored` alive.
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
PIDFILE="$MODULE_CONFIG/.daemon_watchdog.pid"
# Filesystem root for hardware detection (the host suite overrides this).
SROOT=${ENCORE_SYSROOT:-}
LOG="$MODULE_CONFIG/daemon_watchdog.log"

log() {
	mkdir -p "$MODULE_CONFIG" 2>/dev/null
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

# Single instance. The pid file is only trusted after its cmdline is checked:
# a recycled PID must never make us think a watchdog is already running.
if [ -r "$PIDFILE" ]; then
	old=$(cat "$PIDFILE" 2>/dev/null)
	if [ -n "$old" ] && [ -d "/proc/$old" ]; then
		case "$(tr '\0' ' ' <"/proc/$old/cmdline" 2>/dev/null)" in
		*daemon_watch*) exit 0 ;;
		esac
	fi
fi
mkdir -p "$MODULE_CONFIG" 2>/dev/null
printf '%s\n' "$$" >"$PIDFILE"

cleanup() { rm -f "$PIDFILE" 2>/dev/null; }
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

# True when encored is running. argv is NUL-separated, so the NULs become
# spaces - which leaves a TRAILING space, hence the " *" patterns.
daemon_running() {
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
	cur=$(cat "$MODULE_CONFIG/soc_recognition" 2>/dev/null)
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

while :; do
	# Stop conditions, checked every poll so a disable takes effect quickly.
	[ -d "$MODDIR" ] || break          # module removed
	[ -e "$MODDIR/disable" ] && break  # module disabled (file or dir)
	[ -x "$BIN/encored" ] || break

	# encored refuses to run until boot completed (it needs the framework).
	if [ -z "$(getprop sys.boot_completed 2>/dev/null)" ]; then
		sleep 5
		continue
	fi

	clear_stale_update_marker
	repair_soc

	if [ -n "$UPDATE_PENDING" ]; then
		sleep "$INTERVAL"
		continue
	fi

	if ! daemon_running; then
		# Missing gamelist is fatal for encored; regenerate it if it vanished.
		if [ ! -f "$MODULE_CONFIG/gamelist.json" ] && [ -x "$BIN/encored" ]; then
			"$BIN/encored" setup_gamelist "$MODULE_CONFIG/gamelist.json" >/dev/null 2>&1
		fi
		log "encored not running; starting it"
		"$BIN/encored" daemon >>"$MODULE_CONFIG/encore.log" 2>&1
		sleep 3
		if daemon_running; then
			log "encored started"
		else
			log "WARN: encored exited immediately (see encore.log)"
		fi
		trim
	fi

	sleep "$INTERVAL"
done

cleanup
exit 0
