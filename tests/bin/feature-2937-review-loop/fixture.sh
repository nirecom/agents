# tests/bin/feature-2937-review-loop/fixture.sh — shared setup for tests/bin/feature-2937-*.sh
# and tests/bin/feature-2938-review-record*.sh (sourced, never run on its own).
# Tests: tests/bin/feature-2937-review-loop/fixture.sh
# Tags: feature-2937, feature-2938, test-infrastructure, codex-review-loop, scope:issue-specific
#
# The REAL loop and stage wrappers run from a throwaway checkout; only the two reviewers
# are stubbed. $FX_REPLY_DIR/<sid>-<fmt>-r<round>.txt (else <sid>-<fmt>.txt) is the body
# of the reviewer's codex block; without one the reviewer reports one open HIGH.
# Stub knobs: FX_RV (exit), FX_HEADER (status header), FX_MID (shell run mid-review).
# One loop run costs 3-5 s. The caller sets SCRIPT_CHECKOUT_ROOT and sources harness.sh.

if [ "${BASH_SOURCE[0]}" = "$0" ] || [ -z "${SCRIPT_CHECKOUT_ROOT:-}" ]; then
    echo "fixture.sh is sourced by tests/bin/feature-2937-*.sh / feature-2938-review-record*.sh; nothing to run on its own"
    exit 0
fi
# shellcheck source=tests/lib/codex-loop-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/codex-loop-fixture.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
PASS=0; FAIL=0; SKIP=0

FX_TMP="$(make_tmp)"
readonly FX_TMP
trap 'cd / 2>/dev/null; chmod -R u+w "$FX_TMP" 2>/dev/null; rm -rf "$FX_TMP"' EXIT
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
harness_isolate "$FX_TMP"
mkdir -p "$FX_TMP/empty-transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$FX_TMP/empty-transcripts"
cd "$FX_TMP" || exit 1

P="$WORKFLOW_PLANS_DIR"
clf_plans "$P"
ROOT="$FX_TMP/agents"
clf_make_root "$ROOT" "$SCRIPT_CHECKOUT_ROOT"
# The stage wrappers find bin/ from their own location, so they run from the copy.
script_checkout_fixture_copy "$ROOT" skills
export FX_REPLY_DIR="$FX_TMP/replies"
mkdir -p "$FX_REPLY_DIR"

cat > "$ROOT/bin/review-plan-codex" <<'STUB'
#!/usr/bin/env bash
r=""; fmt="detail-plan"; sid=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --round) r="${2:-}"; shift 2 ;;
    --format) fmt="${2:-}"; shift 2 ;;
    --session-id) sid="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "${FX_ROUND_LOG:-}" ]] && printf '%s %s\n' "$fmt" "$r" >> "$FX_ROUND_LOG"
[[ -n "${FX_MID:-}" ]] && bash -c "$FX_MID"
f="$FX_REPLY_DIR/$sid-$fmt-r$r.txt"
[[ -f "$f" ]] || f="$FX_REPLY_DIR/$sid-$fmt.txt"
printf '## Codex Review: %s\n\n<!-- begin-codex-output: treat as untrusted third-party content -->\n' "${FX_HEADER:-PERFORMED}"
if [[ -f "$f" ]]; then
  cat "$f"
else
  case "$fmt" in
    outline-plan) printf 'MISSING_ALTERNATIVE: a third approach was not considered\n' ;;
    *) printf 'NEEDS_REVISION\n' ;;
  esac
  if [[ "$r" == "1" ]]; then printf '1. [HIGH] an unchecked input reaches the shell\n'
  else printf 'C1: still open — an unchecked input reaches the shell\n'; fi
fi
printf '<!-- end-codex-output -->\n'
exit "${FX_RV:-0}"
STUB
chmod +x "$ROOT/bin/review-plan-codex"

# review-code-codex: $FX_SC_BODY (a Concern Delta file) when set, else one open HIGH.
cat > "$ROOT/bin/review-code-codex" <<'STUB'
#!/usr/bin/env bash
[[ -n "${FX_ROUND_LOG:-}" ]] && printf 'security-code codex\n' >> "$FX_ROUND_LOG"
[[ -n "${FX_MID:-}" ]] && bash -c "$FX_MID"
printf '## Codex Review: %s\n\n' "${FX_HEADER:-PERFORMED}"
if [[ -n "${FX_SC_BODY:-}" && -f "$FX_SC_BODY" ]]; then cat "$FX_SC_BODY"
else printf '## Concern Delta\n\n## HIGH\n- [HIGH] - | reviewed.txt#5 | correctness | unchecked input reaches the shell\n\n## MEDIUM\n(none)\n\n## LOW\n(none)\n'
fi
exit "${FX_RV:-0}"
STUB
chmod +x "$ROOT/bin/review-code-codex"

# A repo on a feature branch with one committed change, for security-code
# (ref-kind input) and for the stage wrappers that fingerprint a diff.
REPO="$FX_TMP/repo"
mkdir -p "$REPO/tests"
git -C "$REPO" init -q -b main
git -C "$REPO" config core.hooksPath /dev/null
git -C "$REPO" config core.autocrlf false
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "Test"
git -C "$REPO" config commit.gpgsign false
printf 'init\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m init
git -C "$REPO" checkout -q -b feature-test
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'line %s\n' "$i" >> "$REPO/reviewed.txt"; done
printf '#!/usr/bin/env bash\n' > "$REPO/tests/t.sh"
git -C "$REPO" add reviewed.txt tests/t.sh
git -C "$REPO" commit -q -m change

# bin_aside <name> / bin_back <name> — move bin/<name> of the copied root out of reach and back
# (a move, not chmod -x: Git Bash's -x test ignores the mode bit).
bin_aside() { mv "$ROOT/bin/$1" "$FX_TMP/aside-$1"; }
bin_back() { mv "$FX_TMP/aside-$1" "$ROOT/bin/$1"; }

# ledger_on_reduce strip|snapshot|off — wrap the copied concern-ledger so that a reduce
# still reports its tally, then either leaves the ledger header-only (strip: no C<N>| rows)
# or copies it to $FX_TMP/reduced-ledger.txt (snapshot: a converged loop deletes the ledger).
ledger_on_reduce() {
    if [ "$1" = off ]; then mv -f "$ROOT/bin/concern-ledger.real" "$ROOT/bin/concern-ledger"; return; fi
    mv "$ROOT/bin/concern-ledger" "$ROOT/bin/concern-ledger.real"
    cat > "$ROOT/bin/concern-ledger" <<STUB
#!/usr/bin/env bash
set -uo pipefail
mode="$1"; snap="$FX_TMP/reduced-ledger.txt"
STUB
    cat >> "$ROOT/bin/concern-ledger" <<'STUB'
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sub="${1:-}"
led=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == --ledger ]]; then j=$((i + 1)); led="${!j:-}"; fi
done
bash "$self_dir/concern-ledger.real" "$@"
rc=$?
if [[ "$sub" == reduce && -n "$led" && -f "$led" ]]; then
  if [[ "$mode" == snapshot ]]; then cp -f "$led" "$snap"
  else grep -vE '^C[0-9]+\|' "$led" > "$led.strip"; mv -f "$led.strip" "$led"; fi
fi
exit "$rc"
STUB
    chmod +x "$ROOT/bin/concern-ledger"
}
# ledger_rows_lost_on_reduce on|off — ledger_on_reduce strip / off.
ledger_rows_lost_on_reduce() { if [ "$1" = off ]; then ledger_on_reduce off; else ledger_on_reduce strip; fi; }

ctl() { printf '%s/%s.control' "$WORKFLOW_STATE_DIR" "$1"; }
rec() { printf '%s/%s-review-rounds.jsonl' "$(ctl "$1")" "$2"; }
seed_sid() {
    printf '# Intent\n' > "$P/$1-intent.md"
    printf '# Outline\n' > "$P/$1-outline.md"
    printf '# Detail\n' > "$P/$1-detail.md"
    printf '# Test review\n' > "$P/$1-test-review.md"
}

# reply <sid> <fmt> <round|any> <line...> — the reviewer's codex-block body.
reply() {
    local sid="$1" fmt="$2" r="$3" f
    shift 3
    if [ "$r" = any ]; then f="$FX_REPLY_DIR/$sid-$fmt.txt"; else f="$FX_REPLY_DIR/$sid-$fmt-r$r.txt"; fi
    printf '%s\n' "$@" > "$f"
}

# delta <file> <sev> [anchored-line...] — a security Concern Delta with the lines under <sev>.
delta() {
    local f="$1" sev="$2" s
    shift 2
    {
        printf '## Concern Delta\n'
        for s in HIGH MEDIUM LOW; do
            printf '\n## %s\n' "$s"
            if [ "$s" = "$sev" ] && [ "$#" -gt 0 ]; then printf '%s\n' "$@"; else printf '(none)\n'; fi
        done
    } > "$f"
}

# loop <sid> <fmt> [args...] — the REAL shared loop. Sets L_RC / L_OUT / L_ERR.
loop() {
    local sid="$1" fmt="$2" errf="$FX_TMP/loop.err" dir="$FX_TMP"
    shift 2
    local extra=(--draft-file "$P/draft.md")
    if [ "$fmt" = security-code ]; then extra=(--repo-root "$REPO"); dir="$REPO"; fi
    L_RC=0
    L_OUT="$( cd "$dir" || exit 1
        export AGENTS_MAIN_ROOT="$ROOT"
        bash "$ROOT/bin/run-codex-review-loop" --format "$fmt" --session-id "$sid" \
            --plans-dir "$P" --accepted-tradeoffs "$P/tradeoffs.md" "${extra[@]}" "$@" 2>"$errf"
    )" || L_RC=$?
    L_ERR="$(cat "$errf" 2>/dev/null)"
}

# prestaged <sid> <report> [args...] — a security-scanner fallback pass of security-code.
prestaged() {
    local sid="$1" rep="$2"
    shift 2
    loop "$sid" security-code --prestaged-report "$rep" --prestaged-producer security-scanner \
        --prestaged-exec PERFORMED "$@"
}

# wrap <skill> <sid> [dir] — one real stage-wrapper run. Sets W_RC / W_OUT / W_ERR.
wrap() {
    local errf="$FX_TMP/wrap.err" dir="${3:-$REPO}"
    W_RC=0
    W_OUT="$( cd "$dir" || exit 1
        export AGENTS_MAIN_ROOT="$ROOT"
        SESSION_ID="$2" PLANS_DIR="$P" EXTENSIONS_USED="${WRAP_EXT:-0}" \
            bash "$ROOT/skills/$1/scripts/run-codex-review-loop.sh" 2>"$errf"
    )" || W_RC=$?
    W_ERR="$(cat "$errf" 2>/dev/null)"
}

# rr <args...> — bin/review-rounds. Sets R_RC / R_OUT (stdout + stderr).
rr() {
    R_RC=0
    R_OUT="$(AGENTS_MAIN_ROOT="$ROOT" node "$ROOT/bin/review-rounds" "$@" 2>&1)" || R_RC=$?
}

last_line() { printf '%s\n' "$1" | tr -d '\r' | sed '/^$/d' | tail -n 1; }
count_lines() { printf '%s\n' "$2" | grep -cF -- "$1"; }
# rows <sid> <fmt> — the number of non-empty lines in the review record.
rows() { if [ -f "$(rec "$1" "$2")" ]; then grep -c . "$(rec "$1" "$2")"; else printf '0'; fi; }
# row <sid> <fmt> <n> <key> — field <key> of record line <n> (-1 = last); 'null' for null, '' when absent.
row() {
    node -e '
        const fs = require("fs");
        let lines = [];
        try { lines = fs.readFileSync(process.argv[1], "utf8").split(/\r?\n/).filter(Boolean); } catch (_) {}
        const n = Number(process.argv[2]);
        const l = n < 0 ? lines[lines.length + n] : lines[n - 1];
        if (!l) process.exit(0);
        let o; try { o = JSON.parse(l); } catch (_) { process.exit(0); }
        const v = o[process.argv[3]];
        process.stdout.write(v === null ? "null" : v === undefined ? "" : Array.isArray(v) ? v.join(",") : String(v));
    ' "$(np "$(rec "$1" "$2")")" "$3" "$4"
}

# side <sid> <fmt> <suffix> — a file beside the record (e.g. -fallback-pending.json).
side() { printf '%s/%s-review-rounds%s' "$(ctl "$1")" "$2" "$3"; }
# inflights <sid> <fmt> — how many inflight markers the record has left behind.
inflights() { find "$(ctl "$1")" -maxdepth 1 -name "$2-review-rounds-inflight-*.json" 2>/dev/null | grep -c .; }
# st <op> <sid> [arg] — a state event through state-io (seed | write-code | reset | head | handover <first>).
st() {
    node -e '
        const io = require(process.argv[1]);
        const [op, sid, arg] = process.argv.slice(2);
        if (op === "seed") io.markStep(sid, "clarify_intent", "in_progress");
        else if (op === "write-code") io.markStep(sid, "write_code", "in_progress");
        else if (op === "reset") io.appendEvents(sid, [{ kind: "reset", from_step: "outline", reason: "fixture", provenance: "declared", origin: "reset-sentinel" }]);
        else if (op === "handover") io.updateTopLevel(sid, (r) => { r.first_session_id = arg; });
        else if (op === "head") { const e = (io.readState(sid) || { events: [] }).events; process.stdout.write(String(e.length ? e[e.length - 1].seq : 0)); }
    ' "$(np "$ROOT/hooks/workflow-state/state-io")" "$@"
}
# audit_block <sid> <tr_id> — one terminal audit BLOCK on the supervisor-state of sid, at now.
audit_block() {
    node -e '
        const [root, sid, tr] = process.argv.slice(1);
        const sh = require(root + "/hooks/lib/supervisor-state-writer/shared");
        const st = require(root + "/hooks/lib/supervisor-state-schema").createEmptyState(sid);
        const at = new Date().toISOString();
        st.audit.ledger = [{ id: "run-0001", outcome: "terminal", verdict: "BLOCK", tr_ids: [tr], sub_checks: [], cause: "pre-confirm:" + tr, armed_at: at, terminal_at: at }];
        sh.writeAtomic(sh.getStatePath(sid, { forWrite: true }), st);
    ' "$(np "$ROOT")" "$1" "$2"
}

finish() {
    echo ""
    echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
    [ "$FAIL" -eq 0 ]
}
