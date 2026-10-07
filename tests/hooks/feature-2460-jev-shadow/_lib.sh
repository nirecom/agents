#!/usr/bin/env bash
# Tests: hooks/lib/jev/broker.js
# Tags: TL2, hooks, jev, shared-lib, scope:issue-specific, pwsh-not-required
# Shared scaffolding for the feature-2460-jev-shadow fragments: fixture isolation per
# rules/test/fixture-isolation.md, the mock Jev server, hook runners and record queries.
# Sourced by each fragment (idempotent); holds no cases of its own.

if [ -n "${_FEAT2460_JEV_LIB_SOURCED:-}" ]; then
  return 0
fi
_FEAT2460_JEV_LIB_SOURCED=1

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
. "$AGENTS_DIR/tests/lib/harness.sh"
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

LIBDIR="$AGENTS_DIR/tests/hooks/feature-2460-jev-shadow"
HELPERS="$(np "$LIBDIR/helpers.js")"
MOCK_JS="$(np "$LIBDIR/mock-jev-server.js")"
REPO_N="$(np "$AGENTS_DIR")"
PRE_HOOK="$REPO_N/hooks/jev-shadow-pre.js"
POST_HOOK="$REPO_N/hooks/jev-shadow-post.js"
ADAPTER_JS="$REPO_N/bin/workflow/lib/jev-complexity-adapter.js"
OVERRIDES_JS="$REPO_N/hooks/lib/jev/test-overrides.js"
PROVIDER_JS="$REPO_N/hooks/lib/jev/provider-core.js"
REGISTRY_JS="$REPO_N/hooks/lib/jev/registry.js"
RECORD_JS="$REPO_N/hooks/lib/jev/decision-record.js"
LOADENV_JS="$REPO_N/hooks/lib/load-env.js"
PARSER="$REPO_N/bin/workflow/normalize-judge-signals"
SENTINEL_KEY="jev-test-sentinel-key-2460"
ERRBODY_SENTINEL="JEV-ERRBODY-SENTINEL-2460"
SIGNAL_CSV="S1-multi-file,S1b-wide-change,S2-architecture,S3-security,S4-installer,S5-breaking,S6-long-plan"
LOCAL_ENV_NAME=".env"".local"

TMPROOT="$(make_tmp)"
MOCK_PID=""
_jev_cleanup() {
  if [ -n "$MOCK_PID" ]; then kill "$MOCK_PID" 2>/dev/null || true; fi
  rm -rf "$TMPROOT"
}
trap _jev_cleanup EXIT
# Top-level pin before the first function that runs a hook or bin (fx_new re-pins per fixture).
harness_isolate "$TMPROOT/iso"

check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
hq() { run_with_timeout 30 node "$HELPERS" "$@" 2>/dev/null; }

# fx_new <name>: fresh isolated fixture; exports the pinned dirs for child processes.
fx_new() {
  FX="$TMPROOT/fx-$1"
  mkdir -p "$FX/state" "$FX/wf" "$FX/plans" "$FX/cfg" "$FX/cwd" "$FX/transcripts" "$FX/io"
  harness_git_init "$FX/proj"
  export AGENTS_STATE_DIR; AGENTS_STATE_DIR="$(np "$FX/state")"
  export WORKFLOW_STATE_DIR; WORKFLOW_STATE_DIR="$(np "$FX/wf")"
  export WORKFLOW_PLANS_DIR; WORKFLOW_PLANS_DIR="$(np "$FX/plans")"
  export AGENTS_CONFIG_DIR; AGENTS_CONFIG_DIR="$(np "$FX/cfg")"
  export CLAUDE_PROJECT_DIR; CLAUDE_PROJECT_DIR="$(np "$FX/proj")"
  export CLAUDE_TRANSCRIPT_BASE_DIR; CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$FX/transcripts")"
  LOG="$FX/state/logs/jev-decisions.log"
  JEVDIR="$FX/state/jev"
  OUT="$FX/io/out.txt"; ERR="$FX/io/err.txt"; ERR_ALL="$FX/io/err-all.txt"
  : > "$ERR_ALL"
}

# mock_start: launch the mock once per fragment; MOCK_URL points at it.
mock_start() {
  MOCK_DIR="$TMPROOT/mock"; mkdir -p "$MOCK_DIR"
  MOCK_MODE="$MOCK_DIR/mode.json"; MOCK_REQ="$MOCK_DIR/requests.jsonl"; MOCK_SINK_REQ="$MOCK_DIR/sink-requests.jsonl"
  printf '{}' > "$MOCK_MODE"; : > "$MOCK_REQ"; : > "$MOCK_SINK_REQ"
  node "$MOCK_JS" "$(np "$MOCK_DIR/port")" "$(np "$MOCK_MODE")" "$(np "$MOCK_REQ")" "$(np "$MOCK_SINK_REQ")" &
  MOCK_PID=$!
  local i=0
  while [ ! -s "$MOCK_DIR/port" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if [ ! -s "$MOCK_DIR/port" ]; then echo "SKIP: mock Jev server did not start"; exit 77; fi
  MOCK_URL="http://127.0.0.1:$(cat "$MOCK_DIR/port")"
  _mock_counter_selfcheck
}
# One known GET /v1/models must count as models=1, systemone=0, total=1; a dead counter
# would turn every "0 requests" assertion false-green, so the fragment aborts instead.
_mock_counter_selfcheck() {
  local got
  run_with_timeout 30 node -e '
    require("http").get(process.argv[1] + "/v1/models", (r) => { r.resume(); })
      .on("error", () => process.exit(1));
  ' "$MOCK_URL" >/dev/null 2>&1
  got="$(mock_count models)|$(mock_count systemone)|$(mock_total)"
  check "mock counter self-check: one probe counts as models|systemone|total" "1|0|1" "$got"
  if [ "$got" != "1|0|1" ]; then echo "ABORT: mock request counter is not live"; exit 1; fi
  : > "$MOCK_REQ"
}
mock_mode() { printf '%s' "$1" > "$MOCK_MODE"; : > "$MOCK_REQ"; : > "$MOCK_SINK_REQ"; }
# mock_count <systemone|models>: requests the mock saw on that route (slash-less token).
mock_count() { hq mock-count "$(np "$MOCK_REQ")" "$1"; }
mock_total() { hq mock-q "$(np "$MOCK_REQ")" "reqs.length"; }
# sink_total: requests that reached the redirect target (0 when the client refused the redirect).
sink_total() { hq mock-q "$(np "$MOCK_SINK_REQ")" "reqs.length"; }

# mkpayload <file> <pre|post> <sid> <tid> [helpers.js payload flags]; LLM text via $LLM_TEXT.
mkpayload() { local f="$1"; shift; run_with_timeout 30 node "$HELPERS" payload "$(np "$f")" "$@"; }

# run_hook <pre|post> <payload> [VAR=value ...]: VAR=__unset__ drops a default.
# Defaults: JEV=on, the sentinel key, JEV_BASE_URL=$MOCK_URL. Sets HOOK_RC, $OUT, $ERR.
# HOOK_STDIN=wronly opens fd 0 write-only on <payload>, so the hook's stdin read fails.
run_hook() {
  local kind="$1" payload="$2" script kv name dropped=" "
  shift 2
  if [ "$kind" = pre ]; then script="$PRE_HOOK"; else script="$POST_HOOK"; fi
  # Later assignments win in env(1); __unset__ names are filtered out entirely.
  local -a all=("JEV=on" "TYPESAFE_API_KEY=$SENTINEL_KEY" "JEV_BASE_URL=${MOCK_URL:-http://127.0.0.1:1}" "$@") sets=()
  for kv in "$@"; do [ "${kv#*=}" = "__unset__" ] && dropped="$dropped${kv%%=*} "; done
  for kv in "${all[@]}"; do
    name="${kv%%=*}"
    case "$dropped" in *" $name "*) continue ;; esac
    sets+=("$kv")
  done
  (
    cd "$FX/cwd" || exit 97
    if [[ "${HOOK_STDIN:-}" == wronly ]]; then exec 0> "$payload"; else exec 0< "$payload"; fi
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDECODE \
      -u JEV -u TYPESAFE_API_KEY -u JEV_BASE_URL -u JEV_HTTP_TIMEOUT_MS -u JEV_PENDING_TTL_MS \
      "${sets[@]+"${sets[@]}"}" bash "$RWT" 60 node "$script" > "$OUT" 2> "$ERR"
  )
  HOOK_RC=$?
  cat "$ERR" >> "$ERR_ALL"
}

# pair <sid> <tid> [VAR=value ...]: pre then post for one dispatch; LLM text via $LLM_TEXT.
pair() {
  local sid="$1" tid="$2"
  shift 2
  mkpayload "$FX/io/pre-$tid.json" pre "$sid" "$tid"
  mkpayload "$FX/io/post-$tid.json" post "$sid" "$tid"
  run_hook pre "$FX/io/pre-$tid.json" "$@"
  PRE_RC=$HOOK_RC
  run_hook post "$FX/io/post-$tid.json" "$@"
}

# rq <tid> <expr>: evaluate <expr> against the single log record for <tid> (r) or all of them (recs).
rq() { hq q "$(np "$LOG")" "$1" "$2"; }
# stdout_state: "empty" when the last hook run wrote zero bytes to stdout, else
# "nonempty:<first bytes>". Shadow mode injects nothing into the conversation.
stdout_state() {
  if [ -s "$OUT" ]; then echo "nonempty:$(head -c 120 "$OUT" | tr -d '\r\n')"; else echo "empty"; fi
}
pending_count() { find "$JEVDIR" -path '*/pending/*' -type f 2>/dev/null | wc -l | tr -d ' '; }
# grep_absent <needle> <file...>: "absent" when no file contains the fixed string.
grep_absent() {
  local n="$1"; shift
  if grep -rqF -- "$n" "$@" 2>/dev/null; then echo "present"; else echo "absent"; fi
}

finish() {
  echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
  [ "$FAIL" -eq 0 ]
}
