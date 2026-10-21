#!/system/bin/sh
#
# Copyright (C) 2026 drybrine
# Licensed under the Apache License, Version 2.0 (see LICENSE)
#
# Two jobs, both before the framework is up:
#   1. Mount the USF-unlocked thermal config, so com.transsion.usf reads the
#      patched file on its FIRST config read and never applies the skin
#      temperature CPU cap.
#   2. Start the daemon watchdog. It waits for sys.boot_completed itself, then
#      starts encored and keeps it alive - which is what makes the tweaks come
#      up without a manual command.
#
# This stage does not run under late-load root (GhostLock) - service.sh covers
# that case.

MODDIR=${0%/*}
[ -f "$MODDIR/disable" ] && exit 0

# 1. Transsion USF CPU cap unlock
if [ -f "$MODDIR/system/bin/encore_transsion" ]; then
	export MODDIR
	"$MODDIR/system/bin/encore_transsion" boot \
		>>"$MODDIR/transsion_boot.log" 2>&1
fi

# 2. Keep encored alive (survives a soft reboot, where no module script runs)
if [ -f "$MODDIR/system/bin/encore_daemon_watch" ]; then
	export MODDIR
	# setsid detaches it from this script's process group, so it is not torn
	# down with the boot stage.
	if command -v setsid >/dev/null 2>&1; then
		setsid "$MODDIR/system/bin/encore_daemon_watch" >/dev/null 2>&1 &
	else
		nohup "$MODDIR/system/bin/encore_daemon_watch" >/dev/null 2>&1 &
	fi
fi

exit 0
