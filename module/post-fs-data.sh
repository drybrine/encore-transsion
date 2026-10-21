#!/system/bin/sh
#
# Copyright (C) 2026 drybrine
# Licensed under the Apache License, Version 2.0 (see LICENSE)
#
# Mount the USF-unlocked thermal config BEFORE com.transsion.usf starts, so it
# reads the patched file on its first config read and never applies the skin
# temperature CPU cap. This stage does not run under late-load (GhostLock) -
# service.sh covers that case by mounting and reloading USF afterwards.

MODDIR=${0%/*}

[ -f "$MODDIR/disable" ] && exit 0
[ -f "$MODDIR/system/bin/encore_transsion" ] || exit 0

# MODDIR is inherited: the script defaults to /data/adb/modules/encore-transsion,
# which is exactly where this file lives once installed.
export MODDIR
"$MODDIR/system/bin/encore_transsion" boot >>"$MODDIR/transsion_boot.log" 2>&1

exit 0
