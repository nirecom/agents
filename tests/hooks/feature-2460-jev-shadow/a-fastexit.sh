#!/usr/bin/env bash
# Tests: hooks/jev-shadow-pre.js, hooks/jev-shadow-post.js, hooks/lib/jev/broker.js
# Tags: TL2, hooks, jev, fast-exit, fail-safe-off, stdin-diagnostic, fail-open, secrets, scope:issue-specific, pwsh-not-required

# Every Agent/Task dispatch spawns both hooks, so the common path must be a silent no-op:
# exit 0, no stdout, nothing sent to Jev, no pending state. JEV is fail-safe OFF -- only a
# case-insensitive "on" enables it, and a .env load failure counts as off.
# Unreadable, empty, non-JSON or non-object stdin is fail-open too: exit 0 and no stdout,
# with exactly one stderr line when JEV is on and none at all when it is off.

# TL3 gap (what this test does NOT catch): whether Claude Code actually spawns these hooks
# for a live Agent dispatch; tests/hooks/TL3-hook-agent-jev-shadow.sh covers that.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
mock_start

SID="jev2460-a-sid"
# fast_exit_case <name> <target> <payload flags...> -- [VAR=value ...]: pre + post, expect a no-op.
fast_exit_case() {
  local name="$1" target="$2" tid="toolu_a_$1"
  shift 2
  local -a pflags=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do pflags+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  fx_new "a-$name"
  mock_mode '{}'
  mkpayload "$FX/io/pre.json" pre "$SID" "$tid" "${pflags[@]+"${pflags[@]}"}"
  mkpayload "$FX/io/post.json" post "$SID" "$tid" "${pflags[@]+"${pflags[@]}"}"
  run_hook pre "$FX/io/pre.json" "$@"; local pre_rc=$HOOK_RC pre_out; pre_out="$(cat "$OUT")"
  run_hook post "$FX/io/post.json" "$@"; local post_rc=$HOOK_RC post_out; post_out="$(cat "$OUT")"
  check "$name: pre rc/stdout, post rc/stdout, Jev requests, pending, log" \
    "0||0||0|0|nolog" \
    "$pre_rc|$pre_out|$post_rc|$post_out|$(mock_total)|$(pending_count)|$([ -e "$LOG" ] && echo log || echo nolog)"
}

echo "=== JEV flag values that must stay off ==="
case_begin "a-jev-unset" "hooks/jev-shadow-pre.js"
fast_exit_case jev-unset hooks/jev-shadow-pre.js -- JEV=__unset__
case_end
case_begin "a-jev-off" "hooks/jev-shadow-pre.js"
fast_exit_case jev-off hooks/jev-shadow-pre.js -- JEV=off
case_end
case_begin "a-jev-upper-off" "hooks/jev-shadow-pre.js"
fast_exit_case jev-upper-off hooks/jev-shadow-pre.js -- JEV=OFF
case_end
case_begin "a-jev-garbage" "hooks/jev-shadow-pre.js"
fast_exit_case jev-garbage hooks/jev-shadow-pre.js -- JEV=garbage
case_end
case_begin "a-jev-on-with-suffix" "hooks/jev-shadow-pre.js"
fast_exit_case jev-on-with-suffix hooks/jev-shadow-pre.js -- JEV=onx
case_end

echo "=== dispatches that are not the complexity-judge boundary ==="
case_begin "a-other-subagent" "hooks/jev-shadow-post.js"
fast_exit_case other-subagent hooks/jev-shadow-post.js --subagent Explore --
case_end
case_begin "a-subagent-turn-agent-id" "hooks/jev-shadow-post.js"
fast_exit_case subagent-turn hooks/jev-shadow-post.js --agent-id agent-2460-inner --
case_end
case_begin "a-tool-bash" "hooks/jev-shadow-post.js"
fast_exit_case tool-bash hooks/jev-shadow-post.js --tool Bash --
case_end

echo "=== a .env load failure is off, not on ==="
# The global .env is a directory, so load-env reports loadFailed; JEV is not exported.
case_begin "a-env-load-failure-is-off" "hooks/lib/jev/broker.js"
fx_new a-envfail-probe
mkdir -p "$FX/cfg/.env"
ENVFAIL_CFG="$AGENTS_MAIN_ROOT"
fast_exit_case env-load-failure hooks/lib/jev/broker.js -- JEV=__unset__ "AGENTS_MAIN_ROOT=$ENVFAIL_CFG"
case_end

echo "=== positive controls: the same fixtures DO reach Jev when enabled ==="
# Without these, every no-op row above would also pass against a hook that never calls Jev.
case_begin "a-control-process-jev-on" "hooks/jev-shadow-pre.js"
fx_new a-control-on
mock_mode '{}'
mkpayload "$FX/io/pre.json" pre "$SID" toolu_a_control_on
run_hook pre "$FX/io/pre.json" JEV=On
check "control: JEV=On (mixed case) exits 0 with empty stdout" "0|" "$HOOK_RC|$(cat "$OUT")"
check "control: JEV=On sends exactly one systemone query" "1" "$(mock_count systemone)"
check "control: JEV=On leaves one pending file for the post hook" "1" "$(pending_count)"
case_end
case_begin "a-control-global-env-on" "hooks/lib/jev/broker.js"
fx_new a-control-global
mock_mode '{}'
printf 'JEV=on\n' > "$FX/cfg/.env"
mkpayload "$FX/io/pre.json" pre "$SID" toolu_a_control_global
run_hook pre "$FX/io/pre.json" JEV=__unset__
check "control: JEV=on in the global .env (not exported) reaches Jev" "1" "$(mock_count systemone)"
case_end

skip_effect() { if [[ "$1" == pre ]]; then echo "shadow query skipped"; else echo "decision record not written"; fi; }
stderr_lines() { wc -l < "$ERR" | tr -d ' '; }
side_effects() { echo "$(mock_total)|$(pending_count)|$([[ -e "$LOG" ]] && echo log || echo nolog)"; }
# bad_stdin_case <name> <body> <error name>: both hooks on one bad stdin, JEV on / off / unset.
# The expected line is built here from the body's own byte count, never read back from the hook.
bad_stdin_case() {
  local name="$1" body="$2" errname="$3" detail="0 bytes, empty" kind flag
  fx_new "a-$name"
  mock_mode '{}'
  printf '%s' "$body" > "$FX/io/bad.txt"
  [[ -z "$body" ]] || detail="$(wc -c < "$FX/io/bad.txt" | tr -d ' ') bytes, $errname"
  for kind in pre post; do
    run_hook "$kind" "$FX/io/bad.txt" JEV=on
    check "$name/$kind JEV=on: rc, stdout, stderr line count, the line" \
      "0||1|[jev-shadow-$kind] stdin json-invalid ($detail): $(skip_effect "$kind") (fail-open)" \
      "$HOOK_RC|$(cat "$OUT")|$(stderr_lines)|$(cat "$ERR")"
    for flag in off __unset__; do
      run_hook "$kind" "$FX/io/bad.txt" "JEV=$flag"
      check "$name/$kind JEV=$flag: rc, stdout and stderr all empty" "0||" "$HOOK_RC|$(cat "$OUT")|$(cat "$ERR")"
    done
  done
  check "$name: Jev requests, pending, log" "0|0|nolog" "$(side_effects)"
}
# Does a write-only fd 0 make a plain read throw here? Asked of node, not of the hook.
wronly_stdin_probe() {
  ( exec 0> "$1"; bash "$RWT" 30 node -e 'try { require("fs").readSync(0, Buffer.alloc(1), 0, 1, null); console.log("readable"); } catch (e) { console.log(String(e.code)); }' ) 2>/dev/null
}

echo "=== bad stdin: one diagnostic line with JEV on, total silence with JEV off ==="
case_begin "a-stdin-empty-diagnostic" "hooks/jev-shadow-pre.js"
bad_stdin_case stdin-empty "" ""
case_end
case_begin "a-stdin-non-json-diagnostic" "hooks/jev-shadow-pre.js"
bad_stdin_case stdin-non-json "not json" SyntaxError
case_end
case_begin "a-stdin-non-object-json-diagnostic" "hooks/jev-shadow-post.js"
bad_stdin_case stdin-array '[]' TypeError
bad_stdin_case stdin-string '"str"' TypeError
bad_stdin_case stdin-null 'null' TypeError
bad_stdin_case stdin-number '42' TypeError
case_end

# Without this, the silent rows above would also pass against hooks that never write stderr
# and the one-line rows against hooks that always do.
case_begin "a-stdin-control-readable-payload-silent" "hooks/jev-shadow-post.js"
fx_new a-stdin-control
mock_mode '{}'
printf '%s' '{"tool_name":"Bash"}' > "$FX/io/ok.json"
for kind in pre post; do
  run_hook "$kind" "$FX/io/ok.json" JEV=on
  check "control/$kind: readable non-matching payload with JEV=on is silent" "0||" "$HOOK_RC|$(cat "$OUT")|$(cat "$ERR")"
done
case_end

case_begin "a-stdin-read-error-diagnostic" "hooks/jev-shadow-pre.js"
fx_new a-stdin-read-error
mock_mode '{}'
READ_CODE="$(wronly_stdin_probe "$FX/io/probe.txt")"
if [[ "$READ_CODE" =~ ^E[A-Z]+$ && "$READ_CODE" != EOF && "$READ_CODE" != EAGAIN && "$READ_CODE" != EINTR ]]; then
  for kind in pre post; do
    HOOK_STDIN=wronly run_hook "$kind" "$FX/io/unreadable.txt" JEV=on
    check "read-error/$kind JEV=on: rc, stdout, stderr line count, the line" \
      "0||1|[jev-shadow-$kind] stdin read-error ($READ_CODE): $(skip_effect "$kind") (fail-open)" \
      "$HOOK_RC|$(cat "$OUT")|$(stderr_lines)|$(cat "$ERR")"
    for flag in off __unset__; do
      HOOK_STDIN=wronly run_hook "$kind" "$FX/io/unreadable.txt" "JEV=$flag"
      check "read-error/$kind JEV=$flag: rc, stdout and stderr all empty" "0||" "$HOOK_RC|$(cat "$OUT")|$(cat "$ERR")"
    done
  done
  check "read-error: Jev requests, pending, log" "0|0|nolog" "$(side_effects)"
else
  skip "read-error: a write-only fd 0 does not fail a read on this platform (probe: ${READ_CODE:-none})"
fi
case_end

echo "=== the diagnostic carries neither the stdin body nor the API key ==="
case_begin "a-stdin-diagnostic-no-body-no-key" "hooks/jev-shadow-post.js"
fx_new a-stdin-leak
mock_mode '{}'
BODY_SENTINEL="JEV-STDIN-BODY-SENTINEL-2460"
printf '%s' "not json $BODY_SENTINEL" > "$FX/io/bad.txt"
: > "$FX/io/out-all.txt"
for kind in pre post; do
  run_hook "$kind" "$FX/io/bad.txt" JEV=on "TYPESAFE_API_KEY=$SENTINEL_KEY"
  cat "$OUT" >> "$FX/io/out-all.txt"
done
check "leak: the body sentinel really was on stdin" "present" "$(grep_absent "$BODY_SENTINEL" "$FX/io/bad.txt")"
check "leak: both hooks did emit their diagnostic line" "2|2" \
  "$(wc -l < "$ERR_ALL" | tr -d ' ')|$(grep -cF 'stdin json-invalid' "$ERR_ALL")"
check "leak: stdin body absent from stderr, stdout and state" "absent" \
  "$(grep_absent "$BODY_SENTINEL" "$ERR_ALL" "$FX/io/out-all.txt" "$FX/state")"
check "leak: API key absent from stderr, stdout and state" "absent" \
  "$(grep_absent "$SENTINEL_KEY" "$ERR_ALL" "$FX/io/out-all.txt" "$FX/state")"
case_end

finish
