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
  FAKE_PIDFILE="$TMP/daemon.pid" \
    sh "$WATCH" >/dev/null 2>&1 &
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
  ENCORE_WATCHDOG_INTERVAL=1 FAKE_PIDFILE="$TMP/daemon.pid" \
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

t_starts_daemon
t_waits_for_boot
t_no_double_start
t_respects_disable
t_stops_when_module_gone
t_single_instance
t_replaces_stale_pidfile

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
