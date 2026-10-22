#!/bin/sh
# Host-side tests for scripts/encore_daemon_watch.sh.
#
# The watchdog exists because a soft reboot re-runs no module script: encored
# dies with the framework and the WebUI reports "Service inactive" while root
# and the USF mount survive. These tests drive it with a fake encored and a
# fake getprop, so the decision logic is exercised without a phone.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WATCH=$ROOT/scripts/encore_daemon_watch.sh
TMP=$(mktemp -d) || exit 1
cleanup_all() {
  # A leftover fake encored makes daemon_running() true in the NEXT test,
  # which looks like a watchdog bug but is test pollution.
  stop_fake_daemon
  rm -rf "$TMP"
}
trap cleanup_all EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

# --- fixtures: a module dir, a fake encored, a fake getprop -------------------
setup() { # setup <boot_completed 0|1>
  # start from a clean slate: a surviving fake daemon from a previous test
  # would make the watchdog correctly think encored is already running
  stop_fake_daemon
  rm -rf "$TMP/mod" "$TMP/cfg" "$TMP/bin"
  mkdir -p "$TMP/mod/system/bin" "$TMP/cfg" "$TMP/bin"

  # fake encored: "daemon" writes a pidfile and sleeps (like the real one,
  # which daemonizes itself)
  # The real encored daemonizes (daemon(0,0)): the parent exits immediately and
  # the child keeps running with an argv that still contains "encored". The
  # fake must do the same, or the watchdog would block forever on the start
  # call instead of polling.
  cat > "$TMP/mod/system/bin/encored" <<'EOF'
#!/bin/sh
case "$1" in
daemon)
  ( trap '' HUP; exec "$0" __run ) &
  printf '%s\n' "$!" > "$FAKE_PIDFILE"
  exit 0
  ;;
__run)
  while :; do sleep 1; done
  ;;
setup_gamelist)
  printf '{}\n' > "$2"
  ;;
esac
EOF
  chmod +x "$TMP/mod/system/bin/encored"

  # fake pidof: the fixture daemon is a shell script (comm = "sh"), which the
  # real pidof would not match. Honour pidof's contract instead - exit 0 with
  # the pid while the fake daemon is alive.
  cat > "$TMP/bin/pidof" <<'EOF'
#!/bin/sh
[ -f "$FAKE_PIDFILE" ] || exit 1
p=$(cat "$FAKE_PIDFILE" 2>/dev/null)
[ -n "$p" ] && [ -d "/proc/$p" ] || exit 1
echo "$p"
exit 0
EOF
  chmod +x "$TMP/bin/pidof"

  # fake getprop: the boot value is baked in, so nothing has to be exported
  {
    printf '#!/bin/sh\n'
    printf 'case "$1" in\n'
    if [ "$1" = "1" ]; then
      printf '  sys.boot_completed) echo 1 ;;\n'
    fi
    printf 'esac\n'
  } > "$TMP/bin/getprop"
  chmod +x "$TMP/bin/getprop"
}

# run the watchdog for a bounded time and return its log
run_watch() { # run_watch <boot:0|1> <seconds>
  # <boot> was already baked into the getprop fake by setup().
  # Bound by PID, never by pkill -f: a pattern match can hit the shell that is
  # running the suite itself, and it hides cross-test pollution instead of
  # preventing it.
  : > "$TMP/cfg/daemon_watchdog.log"
  PATH="$TMP/bin:$PATH" \
  MODDIR="$TMP/mod" \
  ENCORE_CONFIG="$TMP/cfg" \
  ENCORE_WATCHDOG_INTERVAL=1 \
  ENCORE_WATCHDOG_IDLE_INTERVAL=1 \
  ENCORE_UPDATE_GRACE="${ENCORE_UPDATE_GRACE:-90}" \
  ENCORE_SYSROOT="$TMP/root" \
  FAKE_PIDFILE="$TMP/daemon.pid" \
    sh "$WATCH" --loop >/dev/null 2>&1 &
  wpid=$!
  sleep "$2"
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  stop_fake_daemon
  cat "$TMP/cfg/daemon_watchdog.log" 2>/dev/null
}

stop_fake_daemon() {
  [ -f "$TMP/daemon.pid" ] || return 0
  dpid=$(cat "$TMP/daemon.pid" 2>/dev/null)
  if [ -n "$dpid" ] && [ -d "/proc/$dpid" ]; then
    kill "$dpid" 2>/dev/null
    sleep 0.2
  fi
  rm -f "$TMP/daemon.pid"
}

t_once_mode_exits() {
  # The default must be one-shot: start the daemon, then exit. A module should
  # not leave a background process behind just to babysit another one.
  setup 1
  : > "$TMP/cfg/daemon_watchdog.log"
  PATH="$TMP/bin:$PATH" MODDIR="$TMP/mod" ENCORE_CONFIG="$TMP/cfg" \
  ENCORE_WATCHDOG_INTERVAL=1 ENCORE_WATCHDOG_IDLE_INTERVAL=1 \
  FAKE_PIDFILE="$TMP/daemon.pid" \
    timeout 30 sh "$WATCH" --once >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { bad once "exit $rc"; return; }
  [ -f "$TMP/cfg/.daemon_watchdog.pid" ] && { bad once "left a pidfile behind"; return; }
  out=$(cat "$TMP/cfg/daemon_watchdog.log" 2>/dev/null)
  echo "$out" | grep -q 'encored started' || { bad once "daemon not started: $out"; return; }
  stop_fake_daemon
  ok once-exits
}

t_once_is_default() {
  # no argument == --once, and the script must terminate on its own
  setup 1
  PATH="$TMP/bin:$PATH" MODDIR="$TMP/mod" ENCORE_CONFIG="$TMP/cfg" \
  FAKE_PIDFILE="$TMP/daemon.pid" \
    timeout 30 sh "$WATCH" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || { bad once-default "exit $rc (did not terminate?)"; return; }
  stop_fake_daemon
  ok once-default
}

t_loop_mode_still_available() {
  # opt-in resident mode must still work for people who want it
  setup 1
  PATH="$TMP/bin:$PATH" MODDIR="$TMP/mod" ENCORE_CONFIG="$TMP/cfg" \
  ENCORE_WATCHDOG_INTERVAL=1 ENCORE_WATCHDOG_IDLE_INTERVAL=1 \
  FAKE_PIDFILE="$TMP/daemon.pid" \
    sh "$WATCH" --loop >/dev/null 2>&1 &
  wpid=$!
  sleep 2
  [ -d "/proc/$wpid" ] || { bad loop "loop mode exited immediately"; return; }
  [ -f "$TMP/cfg/.daemon_watchdog.pid" ] || { bad loop "no pidfile in loop mode"; return; }
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  stop_fake_daemon
  ok loop-mode
}

t_uses_pidof() {
  # A /proc sweep costs one fork per process per poll - millions a day on a
  # phone, all of it while the device is trying to idle (users feel that as
  # delayed notifications). pidof must be the primary check.
  grep -q 'pidof encored' "$WATCH" || { bad uses-pidof "watchdog does not use pidof"; return; }
  # the sweep may only exist as a fallback
  line_pidof=$(grep -n 'pidof encored' "$WATCH" | head -n 1 | cut -d: -f1)
  line_sweep=$(grep -n 'for d in /proc/\[0-9\]\*' "$WATCH" | head -n 1 | cut -d: -f1)
  [ -n "$line_pidof" ] && [ -n "$line_sweep" ] || { bad uses-pidof "missing either path"; return; }
  [ "$line_pidof" -lt "$line_sweep" ] \
    || { bad uses-pidof "the /proc sweep still runs first"; return; }
  ok uses-pidof
}

t_starts_daemon() {
  setup 1
  out=$(run_watch 1 5)
  echo "$out" | grep -q 'starting it' || { bad start "no start attempt: $out"; return; }
  echo "$out" | grep -q 'encored started' || { bad start "daemon not confirmed: $out"; return; }
  ok start
}

t_waits_for_boot() {
  setup 0
  out=$(run_watch 0 3)
  echo "$out" | grep -q 'starting it' && { bad boot-wait "started before boot_completed"; return; }
  ok boot-wait
}

t_no_double_start() {
  setup 1
  out=$(run_watch 1 6)
  n=$(echo "$out" | grep -c 'starting it')
  [ "$n" -eq 1 ] || { bad no-double "started $n times, expected 1"; return; }
  ok no-double
}

t_respects_disable() {
  # managers drop a FILE named "disable" next to module.prop; a directory of
  # the same name must work too
  for kind in file dir; do
    setup 1
    if [ "$kind" = "file" ]; then
      : > "$TMP/mod/disable"
    else
      mkdir -p "$TMP/mod/disable"
    fi
    out=$(run_watch 1 4)
    echo "$out" | grep -q 'starting it' && { bad "disable-$kind" "started while module disabled"; return; }
  done
  ok disable
}

t_stops_when_module_gone() {
  # The watchdog must exit on its own when the module directory disappears -
  # otherwise it keeps running (and logging) after an uninstall.
  setup 1
  PATH="$TMP/bin:$PATH" MODDIR="$TMP/mod" ENCORE_CONFIG="$TMP/cfg" \
  ENCORE_WATCHDOG_INTERVAL=1 ENCORE_WATCHDOG_IDLE_INTERVAL=1 \
  FAKE_PIDFILE="$TMP/daemon.pid" \
    sh "$WATCH" >/dev/null 2>&1 &
  wpid=$!

  sleep 2
  rm -rf "$TMP/mod"

  # poll for a self-exit, up to 8s
  i=0
  while [ "$i" -lt 80 ]; do
    [ -d "/proc/$wpid" ] || break
    sleep 0.1
    i=$((i + 1))
  done

  if [ -d "/proc/$wpid" ]; then
    kill "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    stop_fake_daemon
    bad module-gone "watchdog did not exit when the module vanished"
    return
  fi
  wait "$wpid" 2>/dev/null
  stop_fake_daemon
  ok module-gone
}

t_single_instance() {
  setup 1
  # a second instance must exit immediately because the pidfile is live
  PATH="$TMP/bin:$PATH" MODDIR="$TMP/mod" ENCORE_CONFIG="$TMP/cfg" \
    FAKE_PIDFILE="$TMP/daemon.pid" sh "$WATCH" >/dev/null 2>&1 &
  first=$!
  sleep 1.5
  PATH="$TMP/bin:$PATH" MODDIR="$TMP/mod" ENCORE_CONFIG="$TMP/cfg" \
    FAKE_PIDFILE="$TMP/daemon.pid" timeout 3 sh "$WATCH" >/dev/null 2>&1
  rc=$?
  kill "$first" 2>/dev/null
  wait "$first" 2>/dev/null
  stop_fake_daemon
  [ "$rc" -eq 0 ] || { bad single "second instance exited $rc"; return; }
  ok single
}

t_replaces_stale_pidfile() {
  setup 1
  # a pid that exists but is NOT a watchdog must not block startup
  printf '%s\n' 1 > "$TMP/cfg/.daemon_watchdog.pid"
  out=$(run_watch 1 5)
  echo "$out" | grep -q 'encored started' || { bad stale-pid "blocked by a stale pidfile: $out"; return; }
  ok stale-pid
}

t_clears_stale_update_marker() {
  # encored exits WITHOUT logging when <module>/update exists. A marker older
  # than the current boot is stale (the update already merged) and must be
  # removed, or the daemon never runs again.
  setup 1
  : > "$TMP/mod/update"
  # backdate it well before this boot
  touch -d "2020-01-01 00:00:00" "$TMP/mod/update" 2>/dev/null || touch -t 202001010000 "$TMP/mod/update"
  out=$(run_watch 1 4)
  [ -e "$TMP/mod/update" ] && { bad stale-marker "marker survived: $out"; return; }
  echo "$out" | grep -q 'stale update marker' || { bad stale-marker "not logged: $out"; return; }
  echo "$out" | grep -q 'encored started' || { bad stale-marker "daemon did not start after cleanup: $out"; return; }
  ok stale-marker
}

t_keeps_fresh_update_marker() {
  # a marker created AFTER this boot means an update really is pending: honour
  # it during the grace period instead of deleting it immediately
  setup 1
  : > "$TMP/mod/update"      # mtime = now, i.e. newer than the boot
  out=$(ENCORE_UPDATE_GRACE=600 run_watch 1 4)
  [ -e "$TMP/mod/update" ] || { bad fresh-marker "removed a pending-update marker"; return; }
  echo "$out" | grep -q 'pending module update' || { bad fresh-marker "not logged: $out"; return; }
  echo "$out" | grep -q 'encored started' && { bad fresh-marker "started despite a pending update"; return; }
  ok fresh-marker
}

t_update_marker_grace_expires() {
  # ... but a marker that outlives the grace period is stuck, and the daemon
  # must not stay dead forever because a manager forgot to clean up
  setup 1
  : > "$TMP/mod/update"
  out=$(ENCORE_UPDATE_GRACE=1 run_watch 1 5)
  [ -e "$TMP/mod/update" ] && { bad grace "stuck marker never cleared: $out"; return; }
  echo "$out" | grep -q 'grace period' || { bad grace "not logged: $out"; return; }
  echo "$out" | grep -q 'encored started' || { bad grace "daemon did not start: $out"; return; }
  ok grace
}

t_repairs_soc() {
  # soc_recognition 0 makes Encore skip most tweaks ("Unknown SoC"). The
  # installer writes it once, so a failed detection at install time sticks.
  # Each case: fake sysfs tree + expected code.
  for case in "mtk:1" "qcom:2" "unknown:0"; do
    want=${case##*:}; kind=${case%%:*}
    setup 1
    rm -rf "$TMP/root"
    case "$kind" in
    mtk)   mkdir -p "$TMP/root/sys/kernel/ged/hal" ;;
    qcom)  mkdir -p "$TMP/root/sys/class/kgsl/kgsl-3d0/devfreq" ;;
    esac
    printf '0\n' > "$TMP/cfg/soc_recognition"

    PATH="$TMP/bin:$PATH" MODDIR="$TMP/mod" ENCORE_CONFIG="$TMP/cfg" \
    ENCORE_SYSROOT="$TMP/root" ENCORE_WATCHDOG_INTERVAL=1 \
    ENCORE_WATCHDOG_IDLE_INTERVAL=1 \
    FAKE_PIDFILE="$TMP/daemon.pid" \
      sh "$WATCH" >/dev/null 2>&1 &
    wpid=$!
    sleep 2
    kill "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null
    stop_fake_daemon

    got=$(cat "$TMP/cfg/soc_recognition" 2>/dev/null)
    [ "$got" = "$want" ] || { bad "soc-$kind" "got '$got', want '$want'"; return; }
  done

  # a valid code must be left alone
  setup 1
  printf '1\n' > "$TMP/cfg/soc_recognition"
  PATH="$TMP/bin:$PATH" MODDIR="$TMP/mod" ENCORE_CONFIG="$TMP/cfg" \
  ENCORE_SYSROOT="$TMP/root" ENCORE_WATCHDOG_INTERVAL=1 \
  ENCORE_WATCHDOG_IDLE_INTERVAL=1 FAKE_PIDFILE="$TMP/daemon.pid" \
    sh "$WATCH" >/dev/null 2>&1 &
  wpid=$!
  sleep 2
  kill "$wpid" 2>/dev/null
  wait "$wpid" 2>/dev/null
  stop_fake_daemon
  [ "$(cat "$TMP/cfg/soc_recognition")" = "1" ] || { bad soc-keep "overwrote a valid code"; return; }
  ok soc-repair
}

t_uses_pidof
t_once_mode_exits
t_once_is_default
t_loop_mode_still_available
t_starts_daemon
t_waits_for_boot
t_clears_stale_update_marker
t_keeps_fresh_update_marker
t_update_marker_grace_expires
t_repairs_soc
t_no_double_start
t_respects_disable
t_stops_when_module_gone
t_single_instance
t_replaces_stale_pidfile

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
