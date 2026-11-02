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
#   status              show method, mount/package state + live ceilings
#   apply [--mount-only] cpu: mount the patched config (and restart USF unless
#                       --mount-only, which is for boot/install where USF has
#                       not read its config yet)
#                       all: disable the package and kill it (nothing else)
#   restore             cpu: unmount and let USF reload the stock config
#                       all: re-enable the package
#   enable | disable    persist the preference (survives reboot)
#   method [cpu|all]    show or switch the unlock method
#   install             installer entry point (detect + apply)
#
# The preference lives in $MODULE_CONFIG/transsion_unlock ("1"/"0"), the method
# in $MODULE_CONFIG/transsion_method ("all" when absent).
#
# METHOD all is the blunt one, and the default: it disables com.transsion.usf
# outright, so every TranThermalEngine method stops at once - CPU ceiling, GPU
# throttle, brightness/HBM, refresh rate, FPS, media volume, wifi/bt, PowerHAL,
# core isolation, torch. The kernel thermal driver is untouched and still
# throttles at its trip points. METHOD cpu is the surgical one: it only zeroes
# the cpu/clusterCpu* attributes in USF's own thermal config.

MODULE_ID="encore"   # must match the prebuilt encored binary's hardcoded MODPATH
MODULE_CONFIG=${TRANS_SION_CONFIG:-/data/adb/.config/encore}
PREF="$MODULE_CONFIG/transsion_unlock"
METHOD_PREF="$MODULE_CONFIG/transsion_method"
USF_PKG=${TRANS_SION_PKG:-com.transsion.usf}
# Boot gate and post-disable settle. Both are overridable so the host suite does
# not have to wait for a real boot.
BOOT_WAIT=${TRANS_SION_BOOT_WAIT:-120}
SETTLE=${TRANS_SION_SETTLE:-2}

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

# Name the ROM. USF only ships on Transsion's own builds - XOS (Infinix),
# HiOS (Tecno) and itelOS (itel) - so on an AOSP/LineageOS port of the same
# phone there is no USF and nothing to unlock. Saying which case applies is the
# difference between "your device is unsupported" and "you are on a custom ROM".
rom_name() {
	fp=$(getprop ro.build.fingerprint 2>/dev/null)
	disp=$(getprop ro.build.display.id 2>/dev/null)
	inc=$(getprop ro.build.version.incremental 2>/dev/null)
	all="$fp $disp $inc"

	case "$all" in
	*Infinix* | *XOS* | *xos*) printf 'XOS (Infinix)' ;;
	*TECNO* | *Tecno* | *HiOS* | *hios*) printf 'HiOS (Tecno)' ;;
	*itel* | *ItelOS*) printf 'itelOS (itel)' ;;
	*)
		# No Transsion marker: a custom ROM, or a Transsion device whose props
		# were replaced by the port.
		case "$all" in
		*AOSP* | *aosp* | *Lineage* | *lineage* | *Pixel* | *Evolution* | *crDroid*) printf 'custom ROM (AOSP-based)' ;;
		*) printf 'unknown' ;;
		esac
		;;
	esac
}

# Does the USF package exist on this build? Cheap check, no pm spawn unless the
# file-based check is inconclusive.
usf_installed() {
	for d in /proc/[0-9]*; do
		[ -r "$d/cmdline" ] || continue
		c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null)
		case "$c" in "$USF_PKG" | "$USF_PKG "\ *) return 0 ;; esac
	done
	for p in /system/app/*Usf* /system/priv-app/*Usf* /system_ext/app/*Usf* \
	         /system_ext/priv-app/*Usf* /product/app/*Usf* /product/priv-app/*Usf* \
	         /product/app/*TranUsf* /system_ext/app/*TranUsf*; do
		[ -e "$p" ] && return 0
	done
	return 1
}

# PIDs whose cmdline is exactly the USF package (no wildcard matching).
usf_pids() {
	for d in /proc/[0-9]*; do
		[ -r "$d/cmdline" ] || continue
		c=$(tr '\0' ' ' <"$d/cmdline" 2>/dev/null) || continue
		case "$c" in
		"$USF_PKG" | "$USF_PKG "\ *) printf '%s\n' "${d#/proc/}" ;;
		esac
	done
}

# --- package state (method all) ---------------------------------------------

pkg_installed() {
	pm list packages 2>/dev/null | sed 's/^package://' | grep -qxF "$USF_PKG"
}

pkg_disabled() {
	pm list packages -d 2>/dev/null | sed 's/^package://' | grep -qxF "$USF_PKG"
}

settle() {
	[ "$SETTLE" -gt 0 ] && sleep "$SETTLE"
	return 0
}

# The method decides what "unlock" means. Anything unreadable or unknown falls
# back to `all`: that is the documented default, and a corrupted preference must
# not silently downgrade the user to the partial unlock.
method() {
	if rd "$METHOD_PREF"; then
		case "$RF" in
		cpu) printf 'cpu' ;;
		all) printf 'all' ;;
		*) printf 'all' ;;
		esac
		return 0
	fi
	printf 'all'
}

# Wait for the framework. Disabling a persistent system app before
# sys.boot_completed can restart the boot sequence, so method all never acts
# earlier - not at install, not at post-fs-data.
wait_boot_completed() {
	command -v getprop >/dev/null 2>&1 || return 0
	[ -n "$(getprop sys.boot_completed 2>/dev/null)" ] && return 0
	i=0
	while [ "$i" -lt "$BOOT_WAIT" ]; do
		sleep 1
		[ -n "$(getprop sys.boot_completed 2>/dev/null)" ] && return 0
		i=$((i + 1))
	done
	log "ERROR: sys.boot_completed not set after ${BOOT_WAIT}s; USF left alone"
	return 1
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
		"$USF_PKG" | "$USF_PKG "\ *) kill -9 "$p" 2>/dev/null ;;
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

# --- method all: turn USF off outright --------------------------------------

# Same code path as usf-off: disable the package, then kill it by exact cmdline.
# Both halves matter - the disable stops the respawn, the kill stops the policy
# that is already in memory.
kill_usf() {
	pids=$(usf_pids | tr '\n' ' ')
	[ -n "$pids" ] || return 0
	for p in $pids; do
		# Re-read cmdline immediately before the kill: a PID can be recycled
		# between the scan and here.
		c=$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null) || continue
		case "$c" in
		"$USF_PKG" | "$USF_PKG "\ *) kill -9 "$p" 2>/dev/null ;;
		esac
	done
	i=0
	while [ "$i" -lt 15 ]; do
		[ -z "$(usf_pids)" ] && return 0
		sleep 1
		i=$((i + 1))
	done
	log "WARN: USF still has a live process after SIGKILL (it is persistent and may be respawned)"
	return 1
}

disable_usf_locked() {
	if ! pkg_installed; then
		log "$USF_PKG is not installed on this build; nothing to turn off"
		return 0
	fi
	if pkg_disabled; then
		log "already off: $USF_PKG is disabled"
	else
		if ! out=$(pm disable-user --user 0 "$USF_PKG" 2>&1); then
			log "disable-user failed ($out); trying plain disable"
			out=$(pm disable "$USF_PKG" 2>&1) || {
				log "ERROR: could not disable $USF_PKG: $out"
				return 1
			}
		fi
		settle
		if ! pkg_disabled; then
			log "ERROR: $USF_PKG still reports enabled after disable (the manager may be overriding it)"
			return 1
		fi
		log "package disabled: every TranThermalEngine method is off (cpu, gpu, brightness, hbm, refresh, fps, volume, wifi/bt, powerhal, isolate, torch)"
	fi

	kill_usf
	rc=$?
	# A persistent app can be respawned; give it a moment and check again.
	settle
	[ -n "$(usf_pids)" ] && log "WARN: USF respawned after being killed (persistent=true)"

	log "APPLIED (method all): USF is off; kernel thermal trip points still throttle"
	print_freqs
	return $rc
}

enable_usf_locked() {
	if ! pkg_installed; then
		log "$USF_PKG is not installed on this build; nothing to re-enable"
		return 0
	fi
	if ! pkg_disabled; then
		log "already on: $USF_PKG is enabled"
		return 0
	fi
	out=$(pm enable "$USF_PKG" 2>&1) || {
		log "ERROR: could not enable $USF_PKG: $out"
		return 1
	}
	settle
	if pkg_disabled; then
		log "ERROR: $USF_PKG still reports disabled after enable"
		return 1
	fi
	log "package enabled; its thermal policy applies again on its next start"
	return 0
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
		log "ERROR: tran_thermal.xml not found - ROM: $(rom_name); USF cap unlock does not apply here"
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
	if [ "$(method)" = all ]; then
		if ! wait_boot_completed; then
			lock_release
			return 1
		fi
		disable_usf_locked
	else
		apply_locked "$@"
	fi
	rc=$?
	lock_release
	return $rc
}

do_restore() {
	lock_acquire || {
		log "ERROR: another apply/restore is already running"
		return 1
	}
	if [ "$(method)" = all ]; then
		enable_usf_locked
	else
		restore_locked
	fi
	rc=$?
	lock_release
	return $rc
}

do_status() {
	m=$(method)
	ui "encore-transsion"
	ui "rom         : $(rom_name)"
	ui "method      : $m  (all = USF off entirely; cpu = patched thermal config)"
	if pref_enabled; then
		ui "preference  : enabled"
	else
		ui "preference  : disabled"
	fi

	if [ "$m" = all ]; then
		if ! pkg_installed; then
			ui "usf app     : absent"
			ui "state       : nothing to unlock - USF only ships on XOS / HiOS / itelOS"
			return 0
		fi
		ui "usf app     : $USF_PKG"
		if pkg_disabled; then
			ui "state       : OFF (package disabled - no TranThermalEngine method runs)"
		else
			ui "state       : ON (USF owns cpu, gpu, brightness, refresh, fps, volume)"
		fi
		pids=$(usf_pids | tr '\n' ' ')
		ui "usf pid(s)  : ${pids:-not running}"
		if [ -n "$SRC" ]; then
			if is_mounted "$SRC"; then
				ui "config mount: patched config mounted (left over from method cpu)"
			else
				ui "config mount: none (stock file)"
			fi
		fi
		ui "cpufreq caps (max vs hardware max):"
		print_freqs
		return 0
	fi

	if [ -z "$SRC" ]; then
		ui "usf config  : not present"
		if usf_installed; then
			ui "usf app     : present, but its thermal config is missing"
			ui "state       : cannot patch this build (unexpected layout)"
		else
			ui "usf app     : absent"
			ui "state       : nothing to unlock - USF only ships on XOS / HiOS / itelOS"
		fi
		return 0
	fi
	ui "config      : $SRC"
	if is_mounted "$SRC"; then
		ui "usf cap     : DISABLED (patched config mounted)"
	else
		ui "usf cap     : stock (USF clamps CPU from skin temperature)"
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

# Switch the unlock method, moving the device from the old state to the new one
# instead of leaving a bind mount and a disabled package behind at once.
do_method() {
	cur=$(method)
	new=${1:-}
	case "$new" in
	"")
		ui "method: $cur"
		return 0
		;;
	cpu | all) : ;;
	*)
		ui "usage: $0 method {cpu|all}"
		return 2
		;;
	esac
	if [ "$new" = "$cur" ]; then
		ui "method: already $new"
		return 0
	fi

	lock_acquire || {
		log "ERROR: another apply/restore is already running"
		return 1
	}

	# Undo the old method first: leaving the patched config mounted under
	# method all would hide the fact that the package is off, and leaving the
	# package off under method cpu would keep every other policy disabled.
	if [ "$cur" = all ]; then
		enable_usf_locked || {
			lock_release
			ui "ERROR: could not re-enable $USF_PKG; method unchanged"
			return 1
		}
	else
		restore_locked
	fi

	mkdir -p "$MODULE_CONFIG" 2>/dev/null
	printf '%s\n' "$new" >"$METHOD_PREF"
	set_pref 1

	if [ "$new" = all ]; then
		if wait_boot_completed; then
			disable_usf_locked
		else
			ui "framework not up; the boot hook will apply method all"
		fi
	else
		apply_locked
	fi
	rc=$?
	lock_release
	ui "method: $new"
	return $rc
}

# Boot/late-load entry point: honours the persisted preference.
#   boot            post-fs-data stage: cpu mounts the config, all defers
#   boot --restart  service.sh / late-load: the stage that may act for method all
do_boot() {
	pref_enabled || return 0

	if [ "$(method)" = all ]; then
		# Disabling a persistent system app before the framework is up can
		# restart the boot sequence, so post-fs-data does not do it. service.sh
		# passes --restart and runs after sys.boot_completed.
		if [ "$1" != "--restart" ]; then
			log "method all: deferred to service.sh (framework not up at this stage)"
			return 0
		fi
		if ! wait_boot_completed; then
			return 1
		fi
		lock_acquire || {
			log "ERROR: another apply/restore is already running"
			return 1
		}
		disable_usf_locked
		rc=$?
		lock_release
		return $rc
	fi

	[ -n "$SRC" ] || return 0
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
	ui "rom         : $(rom_name)"
	ui "method      : $(method)"
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

	ui "[usf]"
	do_status | sed 's/^/  /'
}

# Bring encored up without rebooting. This is the one command needed after a
# soft reboot (which runs no module script) - or after anything that killed the
# daemon.
do_start() {
	MD=${MODDIR:-/data/adb/modules/encore}
	W="$MD/system/bin/encore_daemon_watch"
	if [ ! -x "$W" ]; then
		ui "ERROR: $W not found"
		return 1
	fi
	MODDIR="$MD" "$W" --once
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ui "encored is running"
	else
		ui "encored is NOT running - run 'doctor' for the reason"
	fi
	return $rc
}

do_install() {
	if [ "$(method)" = all ]; then
		if ! pkg_installed; then
			ui "- ROM: $(rom_name)"
			ui "- No Transsion USF on this build: nothing to unlock"
			ui "  (USF only ships on XOS, HiOS and itelOS - not on custom ROMs)"
			return 0
		fi
		set_pref 1
		ui "- Transsion USF detected: turning it off (method all)"
		if ! wait_boot_completed; then
			ui "  - framework is not up yet; the boot hook will apply it"
			return 0
		fi
		# pm can be unreachable from the installer; that is not fatal, the
		# boot hook retries. Never abort the install over it.
		disable_usf_locked || ui "  - could not turn it off now; the boot hook will retry"
		return 0
	fi

	# Installer entry point for method cpu: mount only, no USF restart (the user
	# reboots after installing, and USF reads its config during that boot).
	if [ -z "$SRC" ]; then
		if usf_installed; then
			ui "- USF is installed but its thermal config was not found: unlock skipped"
			ui "  (unexpected layout - please report it)"
		else
			ui "- ROM: $(rom_name)"
			ui "- No Transsion USF on this build: the CPU cap unlock does not apply"
			ui "  (USF only ships on XOS, HiOS and itelOS - not on custom ROMs)"
		fi
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
method)
	shift
	do_method "$@"
	;;
install) do_install ;;
doctor) do_doctor ;;
start) do_start ;;
boot)
	shift
	do_boot "$@"
	;;
*)
	ui "usage: $0 {status|apply [--mount-only]|restore|enable|disable|method [cpu|all]|install|boot [--restart]|doctor|start}"
	exit 2
	;;
esac
