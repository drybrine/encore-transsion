#!/system/bin/sh
#
# Copyright (C) 2026 drybrine
# Licensed under the Apache License, Version 2.0 (see LICENSE)
#
# Two jobs, both before the framework is up:
#   1. Mount the USF-unlocked thermal config, so com.transsion.usf reads the
#      patched file on its FIRST config read and never applies the skin
#      temperature CPU cap.
#   2. Start encored once (it waits for boot_completed itself, then exits).
#
# No resident process: this stage starts the daemon and leaves nothing behind.
# A soft reboot runs no module script, so after one, run
# `encore_transsion start` (or the Action button) to bring the daemon back.
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

# 2. Bring encored up once. Backgrounded only because it has to wait for
#    boot_completed and post-fs-data must not block the boot; it exits by itself.
if [ -f "$MODDIR/system/bin/encore_daemon_watch" ]; then
	export MODDIR
	if command -v setsid >/dev/null 2>&1; then
		setsid "$MODDIR/system/bin/encore_daemon_watch" --once >/dev/null 2>&1 &
	else
		nohup "$MODDIR/system/bin/encore_daemon_watch" --once >/dev/null 2>&1 &
	fi
fi

exit 0
