#!/usr/bin/env bash
# tests/bin/feature-2501-registry-plain-exec.sh
# Tests: bin/lib/test-language-registry-plain.sh
# Tags: TL2, bin, test-language-registry, launch, fallback, unsupported, scope:issue-specific
# tlr_exec_plain (#2501), the no-launcher fallback: it launches only a supported `file` entry whose
# argv is exactly `bash {path}` with no launch.requires and no launch.wrapper. Another supported shape
# is rc 2 / FAIL with one `not run:` line in <out>; a file no supported entry matches is rc 78 /
# UNSUPPORTED. Neither is launched. The fixture table is loaded with tlr_load <table>; the accepted
# shape is the control that makes each reject meaningful.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available (the test language registry loader needs it)"
  exit 77
fi

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT
harness_isolate "$TMPBASE/iso"

PLAIN_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/test-language-registry-plain.sh"
FX_TABLE="$TMPBASE/plain-table.json"
T="$TMPBASE/t"
mkdir -p "$T"

# One entry per launch shape; the wrapper must exist in this checkout for the table to validate.
cat >"$FX_TABLE" <<'EOF'
{
 "schema": 1,
 "headerMaxLines": 10,
 "entries": [
  { "id": "fx-ok", "status": "supported", "patterns": ["*.fxok"], "selfIdentifying": true,
    "launch": { "unit": "file", "requires": null, "command": ["bash", "{path}"], "timeoutSeconds": null },
    "diagnostics": { "nameLabel": ".fxok" } },
  { "id": "fx-to", "status": "supported", "patterns": ["*.fxto"], "selfIdentifying": true,
    "launch": { "unit": "file", "requires": null, "command": ["bash", "{path}"], "timeoutSeconds": 1 },
    "diagnostics": { "nameLabel": ".fxto" } },
  { "id": "fx-sh", "status": "supported", "patterns": ["*.fxsh"], "selfIdentifying": true,
    "launch": { "unit": "file", "requires": null, "command": ["sh", "{path}"] },
    "diagnostics": { "nameLabel": ".fxsh" } },
  { "id": "fx-xarg", "status": "supported", "patterns": ["*.fxxarg"], "selfIdentifying": true,
    "launch": { "unit": "file", "requires": null, "command": ["bash", "-e", "{path}"] },
    "diagnostics": { "nameLabel": ".fxxarg" } },
  { "id": "fx-native", "status": "supported", "patterns": ["*.fxnat"], "selfIdentifying": true,
    "launch": { "unit": "file", "requires": null, "command": ["bash", "{nativePath}"] },
    "diagnostics": { "nameLabel": ".fxnat" } },
  { "id": "fx-req", "status": "supported", "patterns": ["*.fxreq"], "selfIdentifying": true,
    "launch": { "unit": "file", "requires": "bash", "command": ["bash", "{path}"] },
    "diagnostics": { "nameLabel": ".fxreq" } },
  { "id": "fx-wrap", "status": "supported", "patterns": ["*.fxwrp"], "selfIdentifying": true,
    "launch": { "unit": "file", "requires": null, "command": ["bash", "{path}"], "wrapper": "bin/lib/test-wrappers/node.js" },
    "diagnostics": { "nameLabel": ".fxwrp" } },
  { "id": "fx-suite", "status": "supported", "patterns": ["*.fxste"], "selfIdentifying": true,
    "launch": { "unit": "suite", "requires": null, "command": ["bash", "run.sh"], "suiteRootMarker": "fx.root" },
    "diagnostics": { "nameLabel": ".fxste" } },
  { "id": "fx-prep", "status": "supported", "patterns": ["*.fxprp"], "selfIdentifying": true,
    "launch": { "unit": "file", "requires": null, "prepare": ["bash", "-c", ": >\"$0.prepared\"", "{path}"], "command": ["bash", "{path}"] },
    "diagnostics": { "nameLabel": ".fxprp" } },
  { "id": "fx-rec", "status": "recognized-only", "patterns": ["*.fxrec"], "selfIdentifying": true,
    "launch": null, "diagnostics": {} }
 ]
}
EOF

# pe.sh <agents> <table> (<file> <out> <err>)... — tlr_exec_plain on each triple in one shell;
# one "rc=N launched=V state=S" line per call (97: loader missing, 96: table not loadable).
cat >"$TMPBASE/pe.sh" <<'EOF'
. "$1/bin/lib/test-language-registry.sh" || exit 97
tlr_load "$2" || exit 96
shift 2
while [ "$#" -ge 3 ]; do
  unset RUN_ALL_EXEC_LAUNCHED RUN_ALL_EXEC_STATE
  tlr_exec_plain "$1" "$2" "$3"
  rc=$?
  printf 'rc=%s launched=%s state=%s\n' "$rc" "${RUN_ALL_EXEC_LAUNCHED-unset}" "${RUN_ALL_EXEC_STATE-unset}"
  shift 3
done
EOF

# pe <tag>... — tlr_exec_plain on $T/<tag> (out/err beside it); the result lines joined by " | ".
pe() {
  local args=() tag
  for tag in "$@"; do args+=("$T/$tag" "$T/$tag.out" "$T/$tag.err"); done
  run_with_timeout 120 bash "$TMPBASE/pe.sh" "$SCRIPT_CHECKOUT_ROOT" "$(np "$FX_TABLE")" "${args[@]}" 2>>"$TMPBASE/pe.stderr" |
    awk 'BEGIN { s = "" } { s = s (NR > 1 ? " | " : "") $0 } END { printf "%s", s }'
}

# Every fixture records that it ran; a rejected one must never leave the marker.
for tag in ok.fxok t.fxsh t.fxxarg t.fxnat t.fxreq t.fxwrp t.fxste t.fxprp t.fxrec t.zzz; do
  printf '%s\n' ': >"$0.ran"' 'echo to-out' 'echo to-err >&2' 'exit 5' >"$T/$tag"
done

# check_not_launched <tag> <language> <result> <out-prefix> — not launched, with that result line; one
# exact <out> line; <err> and the ran-marker never written.
check_not_launched() {
  local tag="$1" id="$2"
  assert_eq "$tag: $(pe "$tag")" "$tag: $3"
  assert_eq "$tag out: $(cat "$T/$tag.out" 2>/dev/null || printf '<absent>')" \
    "$tag out: $4: $T/$tag (language: $id; launcher library not found)"
  if [ -e "$T/$tag.ran" ]; then fail "$tag: not launched" "the fixture ran"; else pass "$tag: not launched"; fi
  if [ -e "$T/$tag.err" ]; then fail "$tag: no err file" "$(cat "$T/$tag.err")"; else pass "$tag: no err file"; fi
}
# A supported entry the fallback cannot launch is a FAIL: a run must not pass over a test it was meant to run.
check_fail() { check_not_launched "$1" "$2" "rc=2 launched=0 state=FAIL" "not run"; }
# A file no supported entry matches was never meant to run: UNSUPPORTED, which a run ignores.
check_reject() { check_not_launched "$1" "$2" "rc=78 launched=0 state=UNSUPPORTED" "UNSUPPORTED"; }

case_begin "plain-lib-present" "bin/lib/test-language-registry-plain.sh"
if [ -f "$PLAIN_LIB" ]; then
  pass "present: bin/lib/test-language-registry-plain.sh"
else
  fail "present: bin/lib/test-language-registry-plain.sh" "missing — every case below fails too"
fi
case_end

case_begin "plain-accepts-bare-bash-path" "bin/lib/test-language-registry-plain.sh"
# Control: the one accepted shape runs, passes the rc through and keeps the streams apart.
assert_eq "ok: $(pe ok.fxok)" "ok: rc=5 launched=1 state=FAIL"
if [ -e "$T/ok.fxok.ran" ]; then pass "ok: launched"; else fail "ok: launched" "no ran marker"; fi
assert_eq "ok out: $(cat "$T/ok.fxok.out" 2>/dev/null || printf '<absent>')" "ok out: to-out"
assert_eq "ok err: $(cat "$T/ok.fxok.err" 2>/dev/null || printf '<absent>')" "ok err: to-err"
case_end

case_begin "plain-exit-states-and-no-timer" "bin/lib/test-language-registry-plain.sh"
# D8-2 state table: 0 -> PASS, 77 -> SKIP (rc kept), other -> FAIL (the control above). The fallback
# has no timer, so an entry's timeoutSeconds is not applied: a 1s entry sleeping 3s still passes.
printf '%s\n' 'exit 0' >"$T/zero.fxok"
printf '%s\n' 'exit 77' >"$T/skip.fxok"
printf '%s\n' 'sleep 3' 'exit 0' >"$T/slow.fxto"
assert_eq "states: $(pe zero.fxok skip.fxok slow.fxto)" "states: rc=0 launched=1 state=PASS | rc=77 launched=1 state=SKIP | rc=0 launched=1 state=PASS"
case_end

case_begin "plain-rejects-other-argv" "bin/lib/test-language-registry-plain.sh"
# Another interpreter, an extra argv element, another path placeholder: supported, so FAIL.
check_fail t.fxsh fx-sh
check_fail t.fxxarg fx-xarg
check_fail t.fxnat fx-native
case_end

case_begin "plain-rejects-requires-wrapper-suite" "bin/lib/test-language-registry-plain.sh"
# A bare `bash {path}` argv is still refused once the entry needs a tool, a wrapper, or a suite root.
check_fail t.fxreq fx-req
check_fail t.fxwrp fx-wrap
check_fail t.fxste fx-suite
# The fallback has no prepare step, so an entry that declares one is refused rather than half-run.
check_fail t.fxprp fx-prep
if [ -e "$T/t.fxprp.prepared" ]; then fail "t.fxprp: prepare not run" "prepare ran"; else pass "t.fxprp: prepare not run"; fi
case_end

case_begin "plain-rejects-unlaunchable-names" "bin/lib/test-language-registry-plain.sh"
# A recognized-only entry is named; a file no entry matches is "unknown".
check_reject t.fxrec fx-rec
check_reject t.zzz unknown
case_end

case_begin "plain-reject-resets-state-after-launch" "bin/lib/test-language-registry-plain.sh"
# In one shell: a launched run, then two not-launched ones — no LAUNCHED / STATE leaks into either.
rm -f "$T"/*.ran "$T"/*.out "$T"/*.err
assert_eq "sequence: $(pe ok.fxok t.zzz t.fxsh)" "sequence: rc=5 launched=1 state=FAIL | rc=78 launched=0 state=UNSUPPORTED | rc=2 launched=0 state=FAIL"
case_end

case_begin "plain-dash-leading-relative-path-is-a-file" "bin/lib/test-language-registry-plain.sh"
# Security round: a relative path that begins with '-' is launched as a file, never read as an option.
mkdir -p "$T/dash"
printf '%s\n' 'echo dash-ran' >"$T/dash/-d.fxok"
dash_line="$(cd "$T/dash" && run_with_timeout 120 bash "$TMPBASE/pe.sh" "$SCRIPT_CHECKOUT_ROOT" "$(np "$FX_TABLE")" "-d.fxok" d.out d.err 2>>"$TMPBASE/pe.stderr")"
assert_eq "dash: $dash_line" "dash: rc=0 launched=1 state=PASS"
assert_eq "dash out: $(cat "$T/dash/d.out" 2>/dev/null || printf '<absent>')" "dash out: dash-ran"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
