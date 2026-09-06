#!/usr/bin/env bash
# tests/feature-2223-dotenv-multiline.sh
# Tests: hooks/lib/load-env.js, hooks/lib/load-env.sh
# Tags: scope:issue-specific, TL1, load-env, dotenv, parser, pwsh-not-required
# RED for issue #2223 — parseEnv() multi-line quoted value grammar.
# Table encoding: input column uses @NL@ / @CR@ for a real LF / CR so a case fits
# one row (every backslash stays literal); want column is JSON.stringify() of the
# expected value, or __ABSENT__ when the key must not appear in the map.
# TL2 gap: on-disk .env behaviour lives in tests/feature-2223-local-env-overlay.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_DIR_NODE="$AGENTS_DIR"
fi

LOAD_ENV="$AGENTS_DIR/hooks/lib/load-env.js"
LOAD_ENV_NODE="$AGENTS_DIR_NODE/hooks/lib/load-env.js"

# Fixture isolation: pin both halves of the plans-dir pair and drop inherited
# session ids so no child node touches live workflow state.
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$TMP_ROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID

PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

decode() {
    local s="$1"
    s="${s//@NL@/$'\n'}"
    s="${s//@CR@/$'\r'}"
    printf '%s' "$s"
}

# parse_key_json <content> <key> [raw|filtered] — JSON.stringify of the parsed
# value, or __ABSENT__. "filtered" prepends filterOsBlocks, as readEnvFile does.
parse_key_json() {
    local content="$1" key="$2" mode="${3:-raw}"
    run_with_timeout 15 node -e '
const m = require(process.argv[1]);
const raw = process.argv[2];
const text = process.argv[4] === "filtered" ? m.filterOsBlocks(raw, process.platform) : raw;
const map = m.parseEnv(text);
const key = process.argv[3];
process.stdout.write(Object.prototype.hasOwnProperty.call(map, key) ? JSON.stringify(map[key]) : "__ABSENT__");
' "$LOAD_ENV_NODE" "$content" "$key" "$mode" 2>/dev/null
}

if [ ! -f "$LOAD_ENV" ]; then
    fail "prerequisite: $LOAD_ENV not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Table 1 — parseEnv() alone. Columns: name | input | key | want
while IFS='|' read -r name input key want; do
    name="$(trim "$name")"
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    input="$(decode "$(trim "$input")")"
    key="$(trim "$key")"
    want="$(trim "$want")"
    got="$(parse_key_json "$input" "$key")"
    assert_eq "T2223G-$name" "$want" "$got"
done <<'TABLE'
single-bare              | KEY=value                                  | KEY   | "value"
single-double            | KEY="value"                                | KEY   | "value"
single-single            | KEY='value'                                | KEY   | "value"
multi-double             | KEY="a@NL@b@NL@c"                          | KEY   | "a\nb\nc"
multi-single             | KEY='a@NL@b@NL@c'                          | KEY   | "a\nb\nc"
escape-n                 | KEY="a\nb"                                 | KEY   | "a\nb"
escape-t                 | KEY="a\tb"                                 | KEY   | "a\tb"
escape-backslash         | KEY="a\\b"                                 | KEY   | "a\\b"
escape-quote             | KEY="a\"b"                                 | KEY   | "a\"b"
single-no-escape         | KEY='a\nb'                                 | KEY   | "a\\nb"
comment-inside-multi     | KEY="a@NL@# not a comment@NL@b"            | KEY   | "a\n# not a comment\nb"
kv-inside-multi          | KEY="a@NL@OTHER=val@NL@b"                  | KEY   | "a\nOTHER=val\nb"
kv-inside-multi-no-entry | KEY="a@NL@OTHER=val@NL@b"                  | OTHER | __ABSENT__
unclosed-key-discarded   | PRIOR=ok@NL@KEY="unterminated              | KEY   | __ABSENT__
unclosed-prior-intact    | PRIOR=ok@NL@KEY="unterminated              | PRIOR | "ok"
eof-no-closing-quote     | KEY="a@NL@b                                | KEY   | __ABSENT__
eof-prior-intact         | FIRST=1@NL@SECOND=2@NL@KEY='a@NL@b         | SECOND| "2"
crlf-multi               | KEY="a@CR@@NL@b@CR@@NL@c"                  | KEY   | "a\nb\nc"
crlf-single              | KEY=value@CR@                              | KEY   | "value"
trailing-newline-dropped | KEY="a@NL@b@NL@"                           | KEY   | "a\nb"
blank-line-inside-multi  | KEY="a@NL@@NL@b"                           | KEY   | "a\n\nb"
empty-double             | KEY=""                                     | KEY   | ""
after-multi-key-parsed   | KEY="a@NL@b"@NL@AFTER=tail                 | AFTER | "tail"
comment-line-skipped     | # comment@NL@KEY=value                      | KEY   | "value"
comment-key-absent       | # comment@NL@KEY=value                      | #     | __ABSENT__
blank-line-skipped       | FIRST=1@NL@@NL@KEY=value                    | KEY   | "value"
duplicate-last-wins      | KEY=first@NL@KEY=second                     | KEY   | "second"
empty-single-quote       | KEY=''@NL@AFTER=ok                          | KEY   | ""
TABLE

# Table 2 — the composed filterOsBlocks + parseEnv path readEnvFile() uses.
while IFS='|' read -r name input key want; do
    name="$(trim "$name")"
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    input="$(decode "$(trim "$input")")"
    key="$(trim "$key")"
    want="$(trim "$want")"
    got="$(parse_key_json "$input" "$key" filtered)"
    assert_eq "T2223F-$name" "$want" "$got"
done <<'TABLE'
filtered-single-bare   | KEY=value                    | KEY | "value"
filtered-multi-double  | KEY="a@NL@b@NL@c"            | KEY | "a\nb\nc"
filtered-multi-single  | KEY='a@NL@b@NL@c'            | KEY | "a\nb\nc"
filtered-escape-n      | KEY="a\nb"                   | KEY | "a\nb"
filtered-crlf-multi    | KEY="a@CR@@NL@b@CR@@NL@c"    | KEY | "a\nb\nc"
TABLE

# T2223-atif — running filterOsBlocks first consumes a `#@if` line even inside a
# quoted value. Accepted constraint (DD-3); the spec is only that it never
# survives into the value, which holds on both platforms.
atif_got="$(parse_key_json "$(decode 'KEY="a@NL@#@if windows@NL@b"')" KEY filtered)"
case "$atif_got" in
    *'#@if'*) fail "T2223-atif-inside-multi — marker leaked into value: $atif_got" ;;
    *)        pass "T2223-atif-inside-multi — '#@if' consumed by filterOsBlocks, absent from value" ;;
esac

# T2223-debug — an unclosed quote must be diagnosable without printing the secret
# it guarded: key NAME may reach stderr, the VALUE must reach neither stream.
DEBUG_INPUT="$(decode 'LEAKKEY="supersecretvalue@NL@still inside')"
DEBUG_OUT="$TMP_ROOT/debug-out.txt"
DEBUG_ERR="$TMP_ROOT/debug-err.txt"
AGENTS_HOOK_DEBUG=1 run_with_timeout 15 node -e '
const m = require(process.argv[1]);
const map = m.parseEnv(process.argv[2]);
process.stdout.write(JSON.stringify(Object.keys(map)));
' "$LOAD_ENV_NODE" "$DEBUG_INPUT" >"$DEBUG_OUT" 2>"$DEBUG_ERR"

if grep -qF 'supersecretvalue' "$DEBUG_ERR" 2>/dev/null || grep -qF 'supersecretvalue' "$DEBUG_OUT" 2>/dev/null; then
    fail "T2223-debug-no-value — unclosed-quote value leaked into debug output"
else
    pass "T2223-debug-no-value — unclosed-quote value absent from stdout and stderr"
fi

if grep -qF 'LEAKKEY' "$DEBUG_ERR" 2>/dev/null; then
    pass "T2223-debug-key-named — discarded key name reported under AGENTS_HOOK_DEBUG=1"
else
    fail "T2223-debug-key-named — expected 'LEAKKEY' on stderr under AGENTS_HOOK_DEBUG=1; got: $(tr '\n' '|' < "$DEBUG_ERR")"
fi

# T2223-readfile-multi — the on-disk door parses the same way the grammar does.
DISK_ENV="$TMP_ROOT/disk.env"
printf 'BEFORE=1\nDISKKEY="line one\nline two"\nAFTER=2\n' > "$DISK_ENV"
DISK_ENV_NODE="$DISK_ENV"
if command -v cygpath >/dev/null 2>&1; then
    DISK_ENV_NODE="$(cygpath -m "$DISK_ENV")"
fi
disk_got="$(run_with_timeout 15 node -e '
const m = require(process.argv[1]);
const map = m.readEnvFile(process.argv[2]) || {};
process.stdout.write(JSON.stringify([map.BEFORE, map.DISKKEY, map.AFTER]));
' "$LOAD_ENV_NODE" "$DISK_ENV_NODE" 2>/dev/null)"
assert_eq "T2223-readfile-multi" '["1","line one\nline two","2"]' "$disk_got"

# ---------------------------------------------------------------------------
# T2223U — unterminated quote followed by a further assignment, diagnosed with
# AGENTS_HOOK_DEBUG UNSET. The two loaders answer differently on purpose and
# both answers are pinned here rather than assumed equal (CPR-SC).
# ---------------------------------------------------------------------------
U_SECRET='Sup3rSecret-2223-Unterminated'
U_TEXT="PRIOR=ok
BADKEY=\"$U_SECRET
GOODKEY=goodvalue
TAIL=t"

unset AGENTS_HOOK_DEBUG
U_OUT="$TMP_ROOT/u-out.txt"
U_ERR="$TMP_ROOT/u-err.txt"
run_with_timeout 15 node -e '
const m = require(process.argv[1]);
const map = m.parseEnv(process.argv[2]);
process.stdout.write(JSON.stringify(map));
' "$LOAD_ENV_NODE" "$U_TEXT" >"$U_OUT" 2>"$U_ERR"

u_map="$(cat "$U_OUT")"
assert_eq "T2223U-js-bad-key-discarded" "__ABSENT__" \
  "$(parse_key_json "$U_TEXT" BADKEY)"
assert_eq "T2223U-js-prior-survives" '"ok"' "$(parse_key_json "$U_TEXT" PRIOR)"

# js: the grammar's multi-line rule absorbs every following line until a matching
# quote appears, so GOODKEY is data inside the discarded value, not an entry.
# The bash loader has no such rule — its half below is the contrasting case.
assert_eq "T2223U-js-following-key-absorbed" "__ABSENT__" \
  "$(parse_key_json "$U_TEXT" GOODKEY)"

if [ -z "$u_map" ]; then
    fail "T2223U-js-no-secret-in-map — parser produced nothing; absence not provable"
elif printf '%s' "$u_map" | grep -qF -- "$U_SECRET"; then
    fail "T2223U-js-no-secret-in-map — the discarded value reached the map"
else
    pass "T2223U-js-no-secret-in-map"
fi

if [ ! -s "$U_ERR" ]; then
    fail "T2223U-js-diagnostic-unconditional — nothing on stderr with AGENTS_HOOK_DEBUG unset"
elif ! grep -qF 'BADKEY' "$U_ERR"; then
    fail "T2223U-js-diagnostic-unconditional — stderr does not name BADKEY: $(tr '\n' '|' < "$U_ERR")"
elif grep -qF -- "$U_SECRET" "$U_ERR"; then
    fail "T2223U-js-diagnostic-unconditional — the attempted value leaked to stderr"
else
    pass "T2223U-js-diagnostic-unconditional (names BADKEY, withholds the value)"
fi

# hooks/lib/load-env.sh — no multi-line quote grammar, so the concern's stricter
# expectation holds here: the offending key alone is dropped and the very next
# quoted assignment still exports.
LOAD_ENV_SH="$AGENTS_DIR/hooks/lib/load-env.sh"
SH_CFG="$TMP_ROOT/sh-cfg"
mkdir -p "$SH_CFG"
printf 'PRIOR=ok\nBADKEY="%s\nGOODKEY="goodvalue"\nTAIL=t\n' "$U_SECRET" > "$SH_CFG/.env"
SH_OUT="$TMP_ROOT/sh-out.txt"
SH_ERR="$TMP_ROOT/sh-err.txt"
unset PRIOR BADKEY GOODKEY TAIL
AGENTS_CONFIG_DIR="$SH_CFG" run_with_timeout 20 bash -c '
  . "$1" || exit 3
  _load_env_file
  printf "PRIOR=%s|BADKEY=%s|GOODKEY=%s|TAIL=%s" "${PRIOR:-__ABSENT__}" "${BADKEY:-__ABSENT__}" "${GOODKEY:-__ABSENT__}" "${TAIL:-__ABSENT__}"
' _ "$LOAD_ENV_SH" >"$SH_OUT" 2>"$SH_ERR"

assert_eq "T2223U-sh-only-bad-key-dropped" \
  "PRIOR=ok|BADKEY=__ABSENT__|GOODKEY=goodvalue|TAIL=t" "$(cat "$SH_OUT")"

if [ ! -s "$SH_ERR" ]; then
    fail "T2223U-sh-diagnostic — nothing on stderr; the discard is silent"
elif ! grep -qF 'BADKEY' "$SH_ERR"; then
    fail "T2223U-sh-diagnostic — stderr does not name BADKEY: $(tr '\n' '|' < "$SH_ERR")"
elif grep -qF -- "$U_SECRET" "$SH_ERR"; then
    fail "T2223U-sh-diagnostic — the attempted value leaked to stderr"
else
    pass "T2223U-sh-diagnostic (names BADKEY, withholds the value)"
fi

# ---------------------------------------------------------------------------
# T2223I — loadDefaultEnv() twice in one process against unchanged fixtures.
# The second call's pre-injection snapshot already contains what the first
# injected, so the overlay must resolve to the same values, not drift.
# ---------------------------------------------------------------------------
I_CFG="$TMP_ROOT/idem-cfg"
I_PROJ="$TMP_ROOT/idem-proj"
mkdir -p "$I_CFG" "$I_PROJ/.git"
printf '%s\n' 'CODE_LANG=english' 'ENFORCE_WORKTREE=on' > "$I_CFG/.env"
printf '%s\n' 'CODE_LANG=japanese' 'ENFORCE_WORKTREE=off' > "$I_PROJ/.env"".local"
I_PROJ_NODE="$I_PROJ"
if command -v cygpath >/dev/null 2>&1; then I_PROJ_NODE="$(cygpath -m "$I_PROJ")"; fi
unset CODE_LANG ENFORCE_WORKTREE
idem_got="$(AGENTS_CONFIG_DIR="$I_CFG" CLAUDE_PROJECT_DIR="$I_PROJ_NODE" run_with_timeout 20 node -e '
const m = require(process.argv[1]);
const snap = () => ({ CODE_LANG: process.env.CODE_LANG, ENFORCE_WORKTREE: process.env.ENFORCE_WORKTREE });
m.loadDefaultEnv();
const first = snap();
m.loadDefaultEnv();
const second = snap();
process.stdout.write(JSON.stringify({ first, second, same: JSON.stringify(first) === JSON.stringify(second) }));
' "$LOAD_ENV_NODE" 2>/dev/null)"

assert_eq "T2223I-loadDefaultEnv-idempotent" \
  '{"first":{"CODE_LANG":"japanese","ENFORCE_WORKTREE":"on"},"second":{"CODE_LANG":"japanese","ENFORCE_WORKTREE":"on"},"same":true}' \
  "$idem_got"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
