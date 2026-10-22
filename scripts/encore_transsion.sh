#!/system/bin/sh
#
# Copyright (C) 2026 drybrine
# Portions Copyright (C) 2024-2026 Rem01Gaming (Encore Tweaks, Apache-2.0)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# encore_transsion — remove the Transsion (Infinix / Tecno / itel) skin-thermal
# CPU cluster cap so Encore's own clock tweaks are not clamped underneath it.
#
# Why this exists: on XOS devices `com.transsion.usf` caps the CPU clusters from
# a *virtual skin temperature*, long before the SoC is hot. Encore can pin
# governors and frequencies all it likes - USF re-clamps them through MediaTek
# PowerHAL within a second. This script removes ONLY that cap, by zeroing the
# cpu/clusterCpu* attributes of every <temp_config> row in USF's own config
# (its documented "no CPU limit" encoding) and bind-mounting the result. The
# file on the partition is never modified, and everything else in it - skin TJ
# targets, brightness, charging, GPU, FPS - stays byte-identical.
#
# Commands:
#   status              show mount state + live ceilings
#   apply [--mount-only] mount the patched config (and restart USF unless
#                       --mount-only, which is for boot/install where USF has
#                       not read its config yet)
#   restore             unmount and let USF reload the stock config
#   enable | disable    persist the preference (survives reboot)
#   install             installer entry point (detect + apply mount-only)
#
# The preference lives in $MODULE_CONFIG/transsion_unlock ("1"/"0").

MODULE_ID="encore"   # must match the prebuilt encored binary's hardcoded MODPATH
MODULE_CONFIG=${TRANS_SION_CONFIG:-/data/adb/.config/encore}
PREF="$MODULE_CONFIG/transsion_unlock"

# Resolve our own directory: this script is installed as system/bin/encore_transsion
# inside the module, and is also callable through the manager's bin symlink.
case "$0" in
*/*) SELF_DIR=$(dirname "$0") ;;
*) SELF_DIR="/data/adb/modules/$MODULE_ID/system/bin" ;;
esac
[ -d "$SELF_DIR" ] || SELF_DIR="/data/adb/modules/$MODULE_ID/system/bin"

MODDIR=${MODDIR:-/data/adb/modules/$MODULE_ID}
BACKUP_DIR="$MODDIR/transsion/backup"
PATCHED_DIR="$MODDIR/transsion/patched"
BACKUP="$BACKUP_DIR/tran_thermal.xml"
PATCHED="$PATCHED_DIR/tran_thermal.xml"
LOG="$MODULE_CONFIG/transsion.log"

PATCH_AWK="$SELF_DIR/transsion_patch_xml.awk"
VERIFY_AWK="$SELF_DIR/transsion_verify_xml.awk"

XML_TR_PRODUCT=/tr_product/etc/vconfig/tranusf/config/thermal/tran_thermal.xml
XML_SYSTEM_EXT=/system_ext/etc/vconfig/tranusf/config/thermal/tran_thermal.xml

SRC=""
[ -f "$XML_TR_PRODUCT" ] && SRC="$XML_TR_PRODUCT"
[ -z "$SRC" ] && [ -f "$XML_SYSTEM_EXT" ] && SRC="$XML_SYSTEM_EXT"
# Test hook: the host suite points this at a fixture (there is no USF on a PC).
[ -n "${TRANS_SION_SRC:-}" ] && SRC="$TRANS_SION_SRC"

KSU_BB=/data/adb/ksu/bin/busybox
[ -x "$KSU_BB" ] || KSU_BB=""

ui() { printf '%s\n' "$*"; }

log() {
	mkdir -p "$MODULE_CONFIG" 2>/dev/null
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
	ui "$*"
}

trim_log() {
	[ -f "$LOG" ] || return 0
	size=$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')
	[ -n "$size" ] && [ "$size" -gt 102400 ] && : >"$LOG"
}

run_awk() {
	if [ -n "$KSU_BB" ]; then "$KSU_BB" awk "$@"; else awk "$@"; fi
}

do_mount() {
	if [ -n "$KSU_BB" ]; then "$KSU_BB" mount "$@"; else mount "$@"; fi
}

do_umount() {
	if [ -n "$KSU_BB" ]; then "$KSU_BB" umount "$@"; else umount "$@"; fi
}

RF=""
rd() {
	RF=""
	[ -r "$1" ] || return 1
	read -r RF <"$1" 2>/dev/null
	return 0
}

is_mounted() { cut -d' ' -f2 /proc/mounts 2>/dev/null | grep -qxF "$1"; }

# PIDs whose cmdline is exactly the USF package (no wildcard matching).
usf_pids() {
	for d in /proc/[0-9]*; do
		[ -r "$d/cmdline" ] || continue
		c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
		case "$c" in
		com.transsion.usf | com.transsion.usf\ *) printf '%s\n' "${d#/proc/}" ;;
		esac
	done
}

pref_enabled() {
	rd "$PREF" || return 1
	[ "$RF" = "1" ]
}

set_pref() {
	mkdir -p "$MODULE_CONFIG" 2>/dev/null
	printf '%s\n' "$1" >"$PREF"
}

print_freqs() {
	for d in /sys/devices/system/cpu/cpufreq/policy*; do
		[ -r "$d/scaling_max_freq" ] || continue
		rd "$d/scaling_max_freq" || continue
		_mx=$RF
		_hw="?"
		rd "$d/cpuinfo_max_freq" && _hw=$RF
		ui "  ${d##*/}: max=$_mx hw=$_hw"
	done
}

# Serialize apply/restore: a boot-time auto-apply racing a manual toggle must
# not stack two identical bind mounts.
LOCK="$MODDIR/.transsion.lock"
lock_acquire() {
	# The module directory must exist before the lock can: on a fresh install
	# MODDIR may still be the staging path.
	mkdir -p "$MODDIR" 2>/dev/null
	n=0
	while [ "$n" -lt 15 ]; do
		mkdir "$LOCK" 2>/dev/null && return 0
		sleep 1
		n=$((n + 1))
	done
	return 1
}
lock_release() { rmdir "$LOCK" 2>/dev/null; }

restart_usf() {
	pids=$(usf_pids | tr '\n' ' ')
	old=$(usf_pids | head -n 1)
	if [ -z "$old" ]; then
		log "USF is not running; nothing to restart"
		return 0
	fi
	for p in $pids; do
		# Re-read cmdline immediately before the kill: a PID can be recycled
		# between the scan and here.
		c=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null) || continue
		case "$c" in
		com.transsion.usf | com.transsion.usf\ *) kill -9 "$p" 2>/dev/null ;;
		esac
	done
	i=0
	while [ "$i" -lt 30 ]; do
		new=$(usf_pids | head -n 1)
		if [ -n "$new" ] && [ "$new" != "$old" ]; then
			log "USF restarted (pid $new)"
			return 0
		fi
		sleep 1
		i=$((i + 1))
	done
	log "WARN: USF did not restart within 30s (it is persistent and should return on its own)"
	return 1
}

engine_state() {
	if command -v timeout >/dev/null 2>&1; then
		timeout 6 dumpsys activity service com.transsion.usf.UsfMainService -thermal thermal_engine state 2>/dev/null
	else
		dumpsys activity service com.transsion.usf.UsfMainService -thermal thermal_engine state 2>/dev/null
	fi
}

apply_locked() { # apply_locked [--mount-only]
	trim_log
	if [ -z "$SRC" ]; then
		log "ERROR: tran_thermal.xml not found (this is not a Transsion XOS build)"
		return 1
	fi
	if is_mounted "$SRC"; then
		log "Already applied: the patched config is mounted over $SRC"
		return 0
	fi
	grep -q temp_config "$SRC" 2>/dev/null || {
		log "ERROR: $SRC has no temp_config element; nothing changed"
		return 1
	}
	[ -f "$PATCH_AWK" ] && [ -f "$VERIFY_AWK" ] || {
		log "ERROR: XML patcher missing ($PATCH_AWK)"
		return 1
	}

	mkdir -p "$BACKUP_DIR" "$PATCHED_DIR" || return 1
	cp -f "$SRC" "$BACKUP" || {
		log "ERROR: backup copy failed"
		return 1
	}

	run_awk -f "$PATCH_AWK" "$SRC" >"$PATCHED.tmp" 2>/dev/null || {
		rm -f "$PATCHED.tmp"
		log "ERROR: XML patch failed; nothing changed"
		return 1
	}
	run_awk -f "$VERIFY_AWK" "$PATCHED.tmp" 2>/dev/null || {
		rm -f "$PATCHED.tmp"
		log "ERROR: patched XML failed verification; nothing changed"
		return 1
	}
	n_orig=$(grep -o '<temp_config' "$SRC" | wc -l | tr -d ' ')
	n_new=$(grep -o '<temp_config' "$PATCHED.tmp" | wc -l | tr -d ' ')
	if [ "$n_orig" != "$n_new" ] || [ "$n_orig" -eq 0 ]; then
		rm -f "$PATCHED.tmp"
		log "ERROR: temp_config count mismatch ($n_orig -> $n_new); nothing changed"
		return 1
	fi
	mv -f "$PATCHED.tmp" "$PATCHED" || return 1

	# Match owner/mode/SELinux label of the original, or USF may be denied reads.
	owner=$(stat -c '%u:%g' "$SRC" 2>/dev/null)
	mode=$(stat -c '%a' "$SRC" 2>/dev/null)
	label=$(stat -c '%C' "$SRC" 2>/dev/null)
	[ -n "$owner" ] && chown "$owner" "$PATCHED" 2>/dev/null
	[ -n "$mode" ] && chmod "$mode" "$PATCHED" 2>/dev/null
	[ -z "$mode" ] && chmod 644 "$PATCHED" 2>/dev/null
	if [ -n "$label" ]; then
		chcon "$label" "$PATCHED" 2>/dev/null || log "WARN: chcon '$label' failed (SELinux may block USF reads)"
	fi

	do_mount -o bind "$PATCHED" "$SRC" 2>/dev/null ||
		do_mount --bind "$PATCHED" "$SRC" 2>/dev/null || {
		log "ERROR: bind mount failed; nothing changed"
		return 1
	}
	do_mount -o remount,bind,ro "$SRC" 2>/dev/null || log "WARN: could not remount the bind read-only"

	if [ "$1" = "--mount-only" ]; then
		log "Mounted (mount-only): USF will read the patched config on its next start"
		return 0
	fi

	log "Patched config mounted; restarting USF to reload it"
	restart_usf

	i=0
	ok=0
	while [ "$i" -lt 45 ]; do
		c=$(engine_state | sed -n 's/.*clusterCpu0=\([0-9][0-9]*\).*/\1/p' | head -n 1)
		if [ -n "$c" ] && [ "$c" -eq 0 ]; then
			ok=1
			break
		fi
		sleep 1
		i=$((i + 1))
	done
	if [ "$ok" -eq 1 ]; then
		log "APPLIED: USF CPU thermal cap disabled (active config clusterCpu0=0)"
	else
		log "APPLIED (mounted + USF restarted) but the engine state was not confirmed within 45s"
	fi
	print_freqs
}

restore_locked() {
	trim_log
	if [ -z "$SRC" ]; then
		ui "ERROR: tran_thermal.xml not found"
		return 1
	fi
	if ! is_mounted "$SRC"; then
		log "Not applied (no bind mount active); stock behavior already in place"
		return 0
	fi
	do_umount "$SRC" 2>/dev/null || do_umount -l "$SRC" 2>/dev/null || {
		log "ERROR: umount failed; retry, or reboot (mounts do not survive a reboot)"
		return 1
	}
	log "Bind mount removed; restarting USF to reload the stock config"
	restart_usf
	print_freqs
}

do_apply() {
	lock_acquire || {
		log "ERROR: another apply/restore is already running"
		return 1
	}
	apply_locked "$@"
	rc=$?
	lock_release
	return $rc
}

do_restore() {
	lock_acquire || {
		log "ERROR: another apply/restore is already running"
		return 1
	}
	restore_locked
	rc=$?
	lock_release
	return $rc
}

do_status() {
	ui "encore-transsion"
	if [ -z "$SRC" ]; then
		ui "device      : not a Transsion XOS build (no tran_thermal.xml)"
		ui "state       : nothing to do"
		return 0
	fi
	ui "config      : $SRC"
	if is_mounted "$SRC"; then
		ui "usf cap     : DISABLED (patched config mounted)"
	else
		ui "usf cap     : stock (USF clamps CPU from skin temperature)"
	fi
	if pref_enabled; then
		ui "preference  : enabled"
	else
		ui "preference  : disabled"
	fi
	pids=$(usf_pids | tr '\n' ' ')
	ui "usf pid(s)  : ${pids:-not running}"
	c=$(engine_state | sed -n 's/.*clusterCpu0=\([0-9][0-9]*\).*/\1/p' | head -n 1)
	t=$(engine_state | sed -n 's/.*tempLevel=\([0-9][0-9]*\).*/\1/p' | head -n 1)
	ui "engine      : clusterCpu0=${c:-unknown} tempLevel=${t:-unknown}"
	ui "cpufreq caps (max vs hardware max):"
	print_freqs
}

do_enable() {
	set_pref 1
	ui "preference  : enabled"
	do_apply
}

do_disable() {
	set_pref 0
	do_restore
}

# Boot/late-load entry point: honours the persisted preference.
#   boot            mount only (post-fs-data: USF has not read its config yet)
#   boot --restart  mount and reload USF (service.sh / late-load, where USF is
#                   already running with the stock config)
do_boot() {
	[ -n "$SRC" ] || return 0
	pref_enabled || return 0
	if is_mounted "$SRC"; then
		return 0
	fi
	if [ "$1" = "--restart" ]; then
		apply_locked
	else
		apply_locked --mount-only
	fi
}

# One command that answers "why is the daemon not running". Every precondition
# encored checks is printed with its verdict, so a silent failure (encored
# exits without logging when the update marker is present) is visible.
do_doctor() {
	MD=${MODDIR:-/data/adb/modules/encore}
	CFG=$MODULE_CONFIG
	ui "encore-transsion doctor"
	ui "module dir  : $MD"
	ui ""

	ui "[daemon]"
	found=0
	for d in /proc/[0-9]*; do
		[ -r "$d/cmdline" ] || continue
		c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)
		case "$c" in
		encored | encored\ * | */encored | */encored\ *)
			ui "  encored      : running (pid ${d#/proc/})"
			found=1
			;;
		esac
	done
	[ "$found" = 0 ] && ui "  encored      : NOT running"

	wpid=""
	rd "$CFG/.daemon_watchdog.pid" && wpid=$RF
	if [ -n "$wpid" ] && [ -d "/proc/$wpid" ]; then
		ui "  watchdog     : running (pid $wpid)"
	else
		ui "  watchdog     : NOT running"
	fi
	ui "  boot done    : $(getprop sys.boot_completed 2>/dev/null | head -n 1)"
	ui ""

	ui "[preconditions encored checks]"
	if [ -e "$MD/update" ]; then
		ui "  update marker: PRESENT ($MD/update) <- encored exits immediately"
		ui "                 (created before this boot = stale; the watchdog removes it)"
	else
		ui "  update marker: absent (ok)"
	fi
	if [ -f "$CFG/gamelist.json" ]; then
		ui "  gamelist.json: present"
	else
		ui "  gamelist.json: MISSING <- encored exits"
	fi
	if [ -f "$CFG/device_mitigation.json" ]; then
		ui "  mitigation   : present"
	else
		ui "  mitigation   : MISSING <- encored exits"
	fi
	soc=""
	rd "$CFG/soc_recognition" && soc=$RF
	ui "  soc code     : ${soc:-missing}  (1=MTK 2=QCOM 3=Exynos; 0/missing = most tweaks skipped)"
	ui ""

	ui "[logs]"
	for f in encore.log daemon_watchdog.log; do
		if [ -f "$CFG/$f" ]; then
			ui "  $f: $(wc -l <"$CFG/$f" 2>/dev/null | tr -d ' ') line(s), last:"
			tail -n 5 "$CFG/$f" 2>/dev/null | sed 's/^/    /'
		else
			ui "  $f: absent"
		fi
	done
	ui ""

	ui "[usf cpu cap]"
	do_status | sed 's/^/  /'
}

do_install() {
	# Installer entry point: mount only, no USF restart (the user reboots after
	# installing, and USF reads its config during that boot).
	if [ -z "$SRC" ]; then
		ui "- Not a Transsion device: USF CPU cap unlock skipped"
		return 0
	fi
	set_pref 1
	ui "- Transsion USF detected: disabling the skin-thermal CPU cap"
	apply_locked --mount-only
}

case "${1:-status}" in
status) do_status ;;
apply)
	shift
	do_apply "$@"
	;;
restore) do_restore ;;
enable) do_enable ;;
disable) do_disable ;;
install) do_install ;;
doctor) do_doctor ;;
boot)
	shift
	do_boot "$@"
	;;
*)
	ui "usage: $0 {status|apply [--mount-only]|restore|enable|disable|install|boot [--restart]|doctor}"
	exit 2
	;;
esac
