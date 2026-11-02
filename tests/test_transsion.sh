#!/bin/sh
# Host-side tests for scripts/encore_transsion.sh.
#
# The mount/restart paths need root and a real USF, so they are not exercised
# here (they are the same code paths proven in usf-cpu-unlock). What IS tested
# is everything that can silently go wrong on a PC:
#   - detection (Transsion vs not) and the messages users see
#   - the persisted preference and that boot/install honour it
#   - the XML patch pipeline against the same fixtures as the parent module
#   - graceful failure: no config, no patcher, unknown command
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BIN=$ROOT/scripts/encore_transsion.sh
FIX=$ROOT/tests/fixtures
TMP=$(mktemp -d) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s: %s\n' "$1" "$2"; }

run() { # run <args...> with an isolated config dir and no USF present
  TRANS_SION_CONFIG="$TMP/cfg" TRANS_SION_SRC="${TSRC:-}" \
    sh "$BIN" "$@" 2>&1
}

# Method all talks to the package manager and waits for the framework. Both are
# faked so the whole disable/enable path can be exercised on a PC.
FAKE_PKG=com.transsion.usf
setup_fakes() {
  mkdir -p "$TMP/fakebin"
  cat > "$TMP/fakebin/pm" <<'SH'
#!/bin/sh
echo "$*" >> "$FAKE_PM_LOG"
st=""
[ -f "$FAKE_PM_STATE" ] && st=$(cat "$FAKE_PM_STATE")
inst="${FAKE_PM_INSTALLED:-1}"
case "$1" in
list)
  [ "$inst" = 1 ] || exit 0
  case "$3" in
  -d) [ "$st" = disabled ] && echo "package:$FAKE_PM_PKG" ;;
  *) echo "package:$FAKE_PM_PKG" ;;
  esac
  ;;
disable-user|disable)
  [ "${FAKE_PM_REFUSE:-0}" = 1 ] && { echo "Error: not allowed" >&2; exit 1; }
  echo disabled > "$FAKE_PM_STATE"
  ;;
enable)
  echo enabled > "$FAKE_PM_STATE"
  ;;
esac
exit 0
SH
  cat > "$TMP/fakebin/getprop" <<'SH'
#!/bin/sh
case "$1" in sys.boot_completed) echo 1 ;; esac
SH
  chmod +x "$TMP/fakebin/pm" "$TMP/fakebin/getprop"
}

runp() { # run <args...> with the fake pm/getprop on PATH, no waiting
  PATH="$TMP/fakebin:$PATH" TRANS_SION_CONFIG="$TMP/cfg" TRANS_SION_SRC="${TSRC:-}" \
    MODDIR="$TMP/mod" TRANS_SION_SETTLE=0 TRANS_SION_BOOT_WAIT=0 \
    FAKE_PM_PKG="$FAKE_PKG" FAKE_PM_STATE="$TMP/pmstate" FAKE_PM_LOG="$TMP/pm.log" \
    FAKE_PM_INSTALLED="${FAKE_PM_INSTALLED:-1}" FAKE_PM_REFUSE="${FAKE_PM_REFUSE:-0}" \
    sh "$BIN" "$@" 2>&1
}

reset_all() { # fresh config, no pm state, preference enabled, method default
  rm -rf "$TMP/cfg" "$TMP/mod" "$TMP/pm.log" "$TMP/pmstate"
  mkdir -p "$TMP/cfg"
  printf '1\n' > "$TMP/cfg/transsion_unlock"
}

set_method() {
  mkdir -p "$TMP/cfg"
  printf '%s\n' "$1" > "$TMP/cfg/transsion_method"
}

t_usage() {
  out=$(run bogus); rc=$?
  [ "$rc" -eq 2 ] || { bad usage "exit $rc, expected 2"; return; }
  echo "$out" | grep -q 'usage:' || { bad usage "no usage text"; return; }
  ok usage
}

t_not_transsion() {
  # No override and no real config on the host: must report and exit cleanly.
  out=$(TRANS_SION_CONFIG="$TMP/cfg" sh "$BIN" status 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { bad no-transsion "exit $rc"; return; }
  echo "$out" | grep -q 'usf app     : absent' || { bad no-transsion "got: $out"; return; }
  echo "$out" | grep -q 'nothing to unlock' || { bad no-transsion "no explanation: $out"; return; }
  ok no-transsion
}

t_install_skips_cleanly() {
  out=$(TRANS_SION_CONFIG="$TMP/cfg" sh "$BIN" install 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { bad install-skip "exit $rc"; return; }
  echo "$out" | grep -q 'nothing to unlock' || { bad install-skip "got: $out"; return; }
  # it must not have created a preference for a device it cannot help
  [ -f "$TMP/cfg/transsion_unlock" ] && { bad install-skip "preference written anyway"; return; }
  ok install-skip
}

t_status_with_config() {
  rm -rf "$TMP/cfg"; set_method cpu
  TSRC="$FIX/pretty.xml" run status > "$TMP/out" 2>&1
  grep -q 'usf cap     : stock' "$TMP/out" || { bad status "no stock line: $(cat "$TMP/out")"; return; }
  grep -q 'preference  : disabled' "$TMP/out" || { bad status "preference default wrong"; return; }
  grep -q 'cpufreq caps' "$TMP/out" || { bad status "no ceilings section"; return; }
  ok status
}

t_preference() {
  rm -rf "$TMP/cfg"
  TSRC="$FIX/pretty.xml" run enable >/dev/null 2>&1
  [ "$(cat "$TMP/cfg/transsion_unlock" 2>/dev/null)" = "1" ] \
    || { bad pref "enable did not persist"; return; }
  TSRC="$FIX/pretty.xml" run disable >/dev/null 2>&1
  [ "$(cat "$TMP/cfg/transsion_unlock" 2>/dev/null)" = "0" ] \
    || { bad pref "disable did not persist"; return; }
  ok preference
}

t_boot_honours_preference() {
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  printf '0\n' > "$TMP/cfg/transsion_unlock"
  out=$(TSRC="$FIX/pretty.xml" run boot 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { bad boot-pref "exit $rc"; return; }
  # disabled -> must not attempt anything (no log line about mounting)
  echo "$out" | grep -qi 'mount' && { bad boot-pref "tried to mount while disabled: $out"; return; }
  ok boot-pref
}

t_patch_pipeline() {
  # Same fixtures the parent module uses: the patched output must verify and
  # keep every <temp_config> row.
  for fx in pretty minified partial; do
    awk -f "$ROOT/scripts/transsion_patch_xml.awk" "$FIX/$fx.xml" > "$TMP/$fx.out" 2>"$TMP/$fx.err" \
      || { bad "patch-$fx" "patcher failed: $(cat "$TMP/$fx.err")"; return; }
    awk -f "$ROOT/scripts/transsion_verify_xml.awk" "$TMP/$fx.out" 2>>"$TMP/$fx.err" \
      || { bad "patch-$fx" "verifier rejected output"; return; }
    a=$(grep -o '<temp_config' "$FIX/$fx.xml" | wc -l | tr -d ' ')
    b=$(grep -o '<temp_config' "$TMP/$fx.out" | wc -l | tr -d ' ')
    [ "$a" = "$b" ] || { bad "patch-$fx" "temp_config count $a -> $b"; return; }
    grep -q 'clusterCpu0="[1-9]' "$TMP/$fx.out" && { bad "patch-$fx" "clusterCpu0 not zeroed"; return; }
  done
  ok patch-pipeline
}

t_scene_blocks_too() {
  # USF picks a config per "scene": screen-off, multi-window, an app scene, game
  # mode, else defaultScene. Every one of those blocks carries its own CPU cap,
  # so the patch must zero all of them - not just the default one. Otherwise an
  # app that maps to a scene would stay capped.
  cat > "$TMP/scene.xml" <<'XML'
<thermalEngineConfig><thermalPolicyConfig>
  <default enable="true"><common_config>
    <temp_config tempLevel="41" cpu="0" clusterCpu0="1800000" clusterCpu1="2200000"/>
  </common_config></default>
  <scene sceneName="scene_social">
    <temp_config tempLevel="41" cpu="0" clusterCpu0="1500000" clusterCpu1="1800000"/>
  </scene>
  <scene sceneName="scene_game_144">
    <temp_config tempLevel="41" cpu="0" clusterCpu0="2000000" clusterCpu1="2600000"/>
  </scene>
</thermalPolicyConfig></thermalEngineConfig>
XML
  awk -f "$ROOT/scripts/transsion_patch_xml.awk" "$TMP/scene.xml" > "$TMP/scene.out" 2>"$TMP/scene.err" \
    || { bad scenes "patcher failed: $(cat "$TMP/scene.err")"; return; }
  awk -f "$ROOT/scripts/transsion_verify_xml.awk" "$TMP/scene.out" 2>>"$TMP/scene.err" \
    || { bad scenes "verifier rejected the output"; return; }
  n=$(grep -o 'clusterCpu0="0"' "$TMP/scene.out" | wc -l | tr -d ' ')
  [ "$n" = "3" ] || { bad scenes "$n of 3 scene/default blocks zeroed"; return; }
  grep -q 'clusterCpu[01]="[1-9]' "$TMP/scene.out" \
    && { bad scenes "a capped block survived: $(cat "$TMP/scene.out")"; return; }
  ok scenes
}

t_extra_clusters() {
  # A 4-cluster device (or a future schema) must be unlocked fully, not
  # partially: clusterCpu3+ has to be zeroed too.
  printf '<root><temp_config tempLevel="41" cpu="0" clusterCpu0="1800000" clusterCpu1="2200000" clusterCpu2="0" clusterCpu3="2000000" clusterCpu4="1900000"/></root>\n' > "$TMP/multi.xml"
  awk -f "$ROOT/scripts/transsion_patch_xml.awk" "$TMP/multi.xml" > "$TMP/multi.out" 2>"$TMP/multi.err" \
    || { bad extra-clusters "patcher failed: $(cat "$TMP/multi.err")"; return; }
  awk -f "$ROOT/scripts/transsion_verify_xml.awk" "$TMP/multi.out" 2>>"$TMP/multi.err" \
    || { bad extra-clusters "verifier rejected the output"; return; }
  for i in 0 1 2 3 4; do
    grep -q "clusterCpu$i=\"0\"" "$TMP/multi.out" \
      || { bad extra-clusters "clusterCpu$i not zeroed: $(cat "$TMP/multi.out")"; return; }
  done
  ok extra-clusters
}

t_verifier_catches_leftover_cluster() {
  # The verifier is the last gate before a mount; it must reject an output that
  # still caps a cluster, whatever its index.
  printf '<root><temp_config tempLevel="41" cpu="0" clusterCpu0="0" clusterCpu5="2000000"/></root>\n' > "$TMP/leftover.xml"
  awk -f "$ROOT/scripts/transsion_verify_xml.awk" "$TMP/leftover.xml" 2>/dev/null \
    && { bad verify-leftover "verifier accepted a capped clusterCpu5"; return; }
  ok verify-leftover-cluster
}

t_patch_fails_closed() {
  # A file with no temp_config must be rejected, not silently accepted.
  printf '<root><other/></root>\n' > "$TMP/empty.xml"
  awk -f "$ROOT/scripts/transsion_patch_xml.awk" "$TMP/empty.xml" >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || { bad fail-closed "patcher accepted a file without temp_config"; return; }
  ok fail-closed
}

t_rom_detection() {
  # USF only ships on Transsion's own builds. Naming the ROM is the difference
  # between "unsupported device" and "you are on a custom ROM".
  for pair in "Infinix/X6879:16/x:user|XOS" "TECNO/CK8n:14/x:user|HiOS" \
              "itel/S666LN:13/x:user|itelOS" "LineageOS/lineage_x:16/x:user|custom ROM"; do
    fp=${pair%%|*}; want=${pair##*|}
    got=$(sh -c 'getprop() { case "$1" in ro.build.fingerprint) echo "'"$fp"'" ;; esac; }; '"$(sed -n '/^rom_name()/,/^}/p' "$ROOT/scripts/encore_transsion.sh")"'; rom_name' 2>&1)
    case "$got" in
    "$want"*) : ;;
    *) bad "rom-$want" "fingerprint '$fp' -> '$got', want '$want'"; return ;;
    esac
  done
  ok rom-detection
}

t_no_usf_is_noop() {
  # Stock -> custom ROM: the preference is still "enabled" but USF is gone.
  # boot must do nothing at all (no mount, no lock, no error).
  rm -rf "$TMP/cfg"; mkdir -p "$TMP/cfg"
  printf '1\n' > "$TMP/cfg/transsion_unlock"
  out=$(TRANS_SION_CONFIG="$TMP/cfg" MODDIR="$TMP/modfb" \
        TRANS_SION_SRC="" sh "$BIN" boot 2>&1); rc=$?
  [ "$rc" -eq 0 ] || { bad no-usf "boot exited $rc"; return; }
  [ -d "$TMP/modfb" ] && { bad no-usf "boot created state for a device it cannot help"; return; }
  echo "$out" | grep -qi 'error' && { bad no-usf "boot errored: $out"; return; }
  # and status must explain why, not just say "unknown"
  out=$(TRANS_SION_CONFIG="$TMP/cfg" MODDIR="$TMP/modfb" sh "$BIN" status 2>&1)
  echo "$out" | grep -q 'nothing to unlock' || { bad no-usf "status does not explain: $out"; return; }
  ok no-usf-noop
}

t_profiler_soc_fallback() {
  # A missing soc_recognition must not silently disable every SoC tweak.
  # The profiler is upstream's; this asserts the fallback we added.
  grep -q 'Transsion ships MediaTek' "$ROOT/scripts/encore_profiler.sh" \
    || { bad profiler-soc "no fallback in the profiler"; return; }
  # and it must not read the file in a way that errors when absent
  grep -q 'SOC=$(<' "$ROOT/scripts/encore_profiler.sh" \
    && { bad profiler-soc "still uses the erroring \$(<file) form"; return; }
  # GPU OPP tables are not exposed on every MediaTek device; reading them
  # unguarded leaks awk's fatal error into the daemon log.
  grep -q 'gpufreq_opp_dump |' "$ROOT/scripts/encore_profiler.sh" \
    && { bad profiler-soc "unguarded gpufreq_opp_dump read"; return; }
  ok profiler-soc
}

t_apply_without_patcher() {
  # If the awk files are missing the script must refuse, not mount garbage.
  mkdir -p "$TMP/fakebin"; set_method cpu
  cp "$BIN" "$TMP/fakebin/encore_transsion"
  out=$(TRANS_SION_CONFIG="$TMP/cfg" TRANS_SION_SRC="$FIX/pretty.xml" \
        MODDIR="$TMP/mod" sh "$TMP/fakebin/encore_transsion" apply --mount-only 2>&1)
  echo "$out" | grep -q 'patcher missing' || { bad no-patcher "got: $out"; return; }
  ok no-patcher
}

# --- method all (the usf-off path) ------------------------------------------

t_method_default_is_all() {
  rm -rf "$TMP/cfg"
  out=$(run status 2>&1)
  echo "$out" | grep -q 'method      : all' || { bad method-default "got: $out"; return; }
  ok method-default
}

t_method_switch_persists() {
  reset_all
  setup_fakes
  runp method cpu >/dev/null 2>&1
  [ "$(cat "$TMP/cfg/transsion_method" 2>/dev/null)" = cpu ] \
    || { bad method-switch "cpu not persisted"; return; }
  [ "$(cat "$TMP/cfg/transsion_unlock" 2>/dev/null)" = 1 ] \
    || { bad method-switch "preference not re-enabled"; return; }
  out=$(runp method)
  echo "$out" | grep -q 'method: cpu' || { bad method-switch "shows wrong method: $out"; return; }
  ok method-switch
}

t_all_disables_package() {
  reset_all
  setup_fakes
  out=$(runp apply 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { bad all-apply "exit $rc: $out"; return; }
  [ "$(cat "$TMP/pmstate" 2>/dev/null)" = disabled ] \
    || { bad all-apply "package not disabled: $out"; return; }
  grep -q 'disable-user --user 0 com.transsion.usf' "$TMP/pm.log" \
    || { bad all-apply "pm disable-user not called: $(cat "$TMP/pm.log")"; return; }
  echo "$out" | grep -q 'APPLIED (method all)' || { bad all-apply "no applied line: $out"; return; }
  ok all-apply
}

t_all_is_idempotent() {
  reset_all
  setup_fakes
  runp apply >/dev/null 2>&1
  : > "$TMP/pm.log"
  out=$(runp apply 2>&1)
  echo "$out" | grep -q 'already off' || { bad all-idempotent "got: $out"; return; }
  grep -q 'disable-user' "$TMP/pm.log" && { bad all-idempotent "disabled twice"; return; }
  ok all-idempotent
}

t_all_reports_pm_refusal() {
  reset_all
  setup_fakes
  out=$(FAKE_PM_REFUSE=1 runp apply 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || { bad all-refusal "exit 0 on a refused disable"; return; }
  echo "$out" | grep -q 'ERROR' || { bad all-refusal "failure swallowed: $out"; return; }
  ok all-refusal
}

t_all_boot_defers_to_service() {
  reset_all
  setup_fakes
  out=$(runp boot 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { bad all-boot-defer "exit $rc: $out"; return; }
  if [ -f "$TMP/pm.log" ]; then
    grep -q 'disable' "$TMP/pm.log" && { bad all-boot-defer "disabled at post-fs-data"; return; }
  fi
  echo "$out" | grep -q 'deferred to service.sh' || { bad all-boot-defer "no deferral note: $out"; return; }
  ok all-boot-defer
}

t_all_boot_restart_applies() {
  reset_all
  setup_fakes
  runp boot --restart >/dev/null 2>&1
  [ "$(cat "$TMP/pmstate" 2>/dev/null)" = disabled ] \
    || { bad all-boot-restart "not disabled at the service.sh stage"; return; }
  ok all-boot-restart
}

t_all_restore_reenables() {
  reset_all
  setup_fakes
  runp apply >/dev/null 2>&1
  out=$(runp restore 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { bad all-restore "exit $rc: $out"; return; }
  [ "$(cat "$TMP/pmstate" 2>/dev/null)" = enabled ] || { bad all-restore "still disabled"; return; }
  ok all-restore
}

t_all_no_usf_is_noop() {
  reset_all
  setup_fakes
  out=$(FAKE_PM_INSTALLED=0 runp apply 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || { bad all-no-usf "exit $rc: $out"; return; }
  echo "$out" | grep -q 'nothing to turn off' || { bad all-no-usf "got: $out"; return; }
  if [ -f "$TMP/pm.log" ]; then
    grep -q 'disable' "$TMP/pm.log" && { bad all-no-usf "tried to disable a missing package"; return; }
  fi
  ok all-no-usf
}

t_switch_all_to_cpu_reenables_first() {
  reset_all
  setup_fakes
  runp apply >/dev/null 2>&1
  : > "$TMP/pm.log"
  runp method cpu >/dev/null 2>&1
  grep -q 'enable com.transsion.usf' "$TMP/pm.log" \
    || { bad switch-cpu "package not re-enabled: $(cat "$TMP/pm.log")"; return; }
  [ "$(cat "$TMP/cfg/transsion_method")" = cpu ] || { bad switch-cpu "method not persisted"; return; }
  ok switch-all-to-cpu
}

t_usage_lists_method() {
  out=$(run bogus 2>&1)
  echo "$out" | grep -q 'method \[cpu|all\]' || { bad usage-method "got: $out"; return; }
  ok usage-method
}

t_usage
t_not_transsion
t_install_skips_cleanly
t_status_with_config
t_preference
t_boot_honours_preference
t_patch_pipeline
t_scene_blocks_too
t_extra_clusters
t_verifier_catches_leftover_cluster
t_patch_fails_closed
t_rom_detection
t_no_usf_is_noop
t_profiler_soc_fallback
t_apply_without_patcher
t_method_default_is_all
t_method_switch_persists
t_all_disables_package
t_all_is_idempotent
t_all_reports_pm_refusal
t_all_boot_defers_to_service
t_all_boot_restart_applies
t_all_restore_reenables
t_all_no_usf_is_noop
t_switch_all_to_cpu_reenables_first
t_usage_lists_method

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
