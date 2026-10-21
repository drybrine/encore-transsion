#
# Copyright (C) 2024-2026 Rem01Gaming
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

# Stop the watchdog first, or it would restart the daemon we are removing.
if [ -f /data/adb/.config/encore/.daemon_watchdog.pid ]; then
	wpid=$(cat /data/adb/.config/encore/.daemon_watchdog.pid 2>/dev/null)
	if [ -n "$wpid" ] && [ -d "/proc/$wpid" ]; then
		case "$(tr -d '\0' <"/proc/$wpid/cmdline" 2>/dev/null)" in
		*daemon_watch*) kill "$wpid" 2>/dev/null ;;
		esac
	fi
fi

# Put the stock USF config back before the module files disappear.
MODDIR=${0%/*}
if [ -x "$MODDIR/system/bin/encore_transsion" ]; then
	export MODDIR
	"$MODDIR/system/bin/encore_transsion" restore >/dev/null 2>&1
fi

rm -rf /data/adb/.config/encore
rm -f /data/adb/service.d/.encore_cleanup.sh

need_gone="encored encore_profiler encore_utility encore_log encore_transsion encore_daemon_watch"
manager_paths="/data/adb/ap/bin /data/adb/ksu/bin"

for dir in $manager_paths; do
	[ -d "$dir" ] && {
		for bin in $need_gone; do
			rm "$dir/$bin"
		done
	}
done
