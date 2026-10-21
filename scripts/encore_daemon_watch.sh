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
