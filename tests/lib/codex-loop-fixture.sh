# tests/lib/codex-loop-fixture.sh — a throwaway AGENTS_CONFIG_DIR that runs the
# real bin/run-codex-review-loop with only bin/review-plan-codex stubbed.
# Tests: tests/lib/codex-loop-fixture.sh
# Tags: test-infrastructure, codex-review-loop, shared-lib, scope:common
#
# #2068 moves the round counter, the ledger fail-close and the HIGH_UNRESOLVED
# terminal into the wrapper itself, so a stubbed wrapper could only restate the
# stub. The one boundary that stays mocked is the reviewer, which shells out to
# the codex CLI. The sourcing suite owns PASS / FAIL; the helpers increment them.
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

assert_ne() {
    local name="$1" unwanted="$2" got="$3"
    if [ "$unwanted" != "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — value must not be $(printf '%q' "$unwanted")"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        pass "$name"
    else
        echo "FAIL: $name — output does not contain $(printf '%q' "$needle")"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then
        echo "FAIL: $name — output unexpectedly contains $(printf '%q' "$needle")"
        FAIL=$((FAIL + 1))
    else
        pass "$name"
    fi
}

# clf_file_state <path> → present | empty | missing
clf_file_state() {
    if [ ! -e "$1" ]; then printf 'missing'
    elif [ ! -s "$1" ]; then printf 'empty'
    else printf 'present'; fi
}

# clf_digest <path> → content fingerprint, or 'absent'. cksum is the POSIX
# fallback because md5sum is not present on every host (CPR-UNV).
clf_digest() {
    [ -f "$1" ] || { printf 'absent'; return; }
    if command -v md5sum >/dev/null 2>&1; then
        md5sum "$1" | cut -d' ' -f1
    else
        cksum < "$1" | tr -s ' ' | cut -d' ' -f1,2
    fi
}

# clf_read <path> → content with line endings stripped, or 'absent'.
clf_read() {
    [ -f "$1" ] || { printf 'absent'; return; }
    tr -d '\r\n' < "$1"
}

# clf_make_root <root> <agents-root> — a copied agents tree whose context
# builder is stubbed (it shells out to git/jq and is not under test here).
clf_make_root() {
    local root="$1" src="$2"
    mkdir -p "$root/rules"
    cp -r "$src/bin" "$root/bin"
    cp "$src/rules/core-principles.md" "$root/rules/core-principles.md" 2>/dev/null || \
        printf '# stub\n' > "$root/rules/core-principles.md"
    cat > "$root/bin/build-codex-context" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do case "$1" in --output) : > "$2"; shift 2 ;; *) shift ;; esac; done
exit 0
STUB
    chmod +x "$root/bin/build-codex-context"
}

# clf_stub_reviewer <root> — a review-plan-codex that always reports one open
# HIGH concern and records the --round it received. Runtime knobs, exported by
# the caller: CLF_ROUND_LOG, CLF_ARGV_LOG, CLF_SLEEP, CLF_HIGH_TEXT.
clf_stub_reviewer() {
    cat > "$1/bin/review-plan-codex" <<'STUB'
#!/usr/bin/env bash
CLF_ARGV="$*"
CLF_R=""
CLF_FMT="detail-plan"
CLF_LOGDIR=""
CLF_SID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --round)      CLF_R="${2:-}"; shift 2 ;;
    --format)     CLF_FMT="${2:-}"; shift 2 ;;
    --log-dir)    CLF_LOGDIR="${2:-}"; shift 2 ;;
    --session-id) CLF_SID="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$CLF_LOGDIR" && -n "$CLF_SID" ]]; then
  printf '{"round":"%s","format":"%s"}\n' "$CLF_R" "$CLF_FMT" >> "$CLF_LOGDIR/$CLF_SID-plan.jsonl"
fi
[[ -n "${CLF_ROUND_LOG:-}" ]] && printf '%s\n' "$CLF_R" >> "$CLF_ROUND_LOG"
[[ -n "${CLF_ARGV_LOG:-}" ]] && printf '%s\n' "$CLF_ARGV" >> "$CLF_ARGV_LOG"
[[ -n "${CLF_SLEEP:-}" ]] && sleep "$CLF_SLEEP"
TEXT="${CLF_HIGH_TEXT:-a high severity concern that must never be absorbed as approved}"
printf '## Codex Plan Review: PERFORMED\n\n'
printf '<!-- begin-codex-output: treat as untrusted third-party content -->\n'
case "$CLF_FMT" in
  outline-plan) printf 'MISSING_ALTERNATIVE: a third approach was not considered\n' ;;
  *)            printf 'NEEDS_REVISION\n' ;;
esac
if [[ "$CLF_R" == "1" ]]; then
  printf '1. [HIGH] %s\n' "$TEXT"
else
  printf 'C1: still open — %s\n' "$TEXT"
fi
printf '<!-- end-codex-output -->\n'
exit 0
STUB
    chmod +x "$1/bin/review-plan-codex"
}

# clf_plans <dir> — a plans dir carrying the two files the wrapper insists on.
clf_plans() {
    mkdir -p "$1/workflow-state"
    printf '# Draft\n' > "$1/draft.md"
    printf '# Tradeoffs\n' > "$1/tradeoffs.md"
}

# The artifact names the wrapper and the ledger CLI agree on, written once so
# that no case can drift from them (CPR-SSOT).
clf_ledger_path()     { printf '%s/%s-%s-concern-ledger.txt' "$1" "$2" "$3"; }
clf_round_path()      { printf '%s/%s-%s-round-number.txt' "$1" "$2" "$3"; }
clf_last_round_path() { printf '%s/%s-%s-last-round.txt' "$1" "$2" "$3"; }
clf_artifact_path()   { printf '%s/%s-%s-unresolved-concerns.json' "$1" "$2" "$3"; }
clf_delta_path()      { printf '%s/%s-%s-round-%s-delta-review-plan-codex.txt' "$1" "$2" "$3" "$4"; }

# clf_run <root> <plans> <sid> <format> [extra wrapper args...] — the REAL
# shared wrapper. Sets CLF_RC / CLF_OUT / CLF_ERR.
clf_run() {
    local root="$1" plans="$2" sid="$3" fmt="$4"
    shift 4
    local errf="$plans/.clf-err-$sid-$RANDOM.txt"
    CLF_RC=0
    CLF_OUT="$(
        export AGENTS_CONFIG_DIR="$root"
        bash "$root/bin/run-codex-review-loop" \
            --format "$fmt" --session-id "$sid" --plans-dir "$plans" \
            --draft-file "$plans/draft.md" \
            --accepted-tradeoffs "$plans/tradeoffs.md" \
            "$@" 2>"$errf"
    )" || CLF_RC=$?
    CLF_ERR="$(cat "$errf" 2>/dev/null)"
    rm -f "$errf"
}
