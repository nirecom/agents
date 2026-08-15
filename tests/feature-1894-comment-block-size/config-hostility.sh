#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/config-hostility.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, glob, extensions, scan-scope, tmpdir, quoting, trap, table-driven, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 9 — the two environment values the scanner treats as syntax rather than
# as data. Split out of injection-hardening.sh only to stay inside the 300-line
# file-split WARN (rules/coding/file-split.md); same fail-before-fix batch.
#
# C1/C2 (F4): review finding F4 read ext_ok's `[[ "$p" == *".$e" ]]` as leaving
# $e unquoted on the pattern side, i.e. as letting a configured extension act as
# a glob and silently widen the scan to files nobody meant to hand to a scanner.
# It does not: the double quotes open before the `.` and close after `$e`, and a
# quoted region of a [[ ]] pattern is matched LITERALLY, so only the leading `*`
# is a wildcard. These cases are therefore a REGRESSION PIN, not a fail-before-
# fix: they pass against the unfixed scanner and start failing the moment the
# quotes are dropped — which is precisely the edit a mis-aimed F4 fix would make.
# Both directions are pinned for that reason (CPR-ORTH): a metacharacter must
# not widen the scan, AND it must still match a name that literally contains it.
#
# C3 (F3): run_staged builds its cleanup trap by string interpolation —
# `trap "rm -f '$list'" EXIT` — so a single quote anywhere in $TMPDIR turns the
# trap body into unbalanced shell source. It is re-parsed at exit, i.e. after all
# real work, which is exactly why it fails quietly: a stale temp file per commit
# and a shell diagnostic on stderr that no assertion has ever looked for.
#
# Sourced by the dispatcher; every helper and constant is defined there.

cpad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "c_$i=$i"; done; }
ccm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

# stage_literal <repo> <path> — stage an over-threshold file whose NAME contains
# a glob metacharacter. make_special (special-paths.sh) stages via a wildcard
# pathspec, which cannot match a name that IS a glob (`lit.[a-z]` as a pathspec
# matches `lit.a`, never itself), so the `:(literal)` magic prefix is required
# here. The byte-exact NUL-delimited index round-trip is the same guard
# make_special uses, duplicated deliberately for that one difference.
stage_literal() {
    local repo="$1" fn="$2" entry
    ( { cpad 2; ccm 12 note; } > "$repo/$fn" ) 2>/dev/null || return 1
    [ -f "$repo/$fn" ] || return 1
    git -C "$repo" add -f -- ":(literal)$fn" >/dev/null 2>&1 || return 1
    while IFS= read -r -d '' entry; do
        [ "$entry" = "$fn" ] && return 0
    done < <(git -C "$repo" ls-files -z --)
    git -C "$repo" reset -q -- ":(literal)$fn" >/dev/null 2>&1 || true
    return 1
}

# ---------------------------------------------------------------------------
# C1 — a glob in the extension list must not widen the scan (F4)
# ---------------------------------------------------------------------------
# The two out-of-scope fixtures are deliberately the kind of file a reviewer
# would be unhappy to see a scanner open and quote line ranges from. Their bodies
# are harmless comment padding: the assertion is about SCOPE, and planting real
# key-shaped content would only trip the outbound scanner.
echo ""
echo "=== C1: glob-shaped CODE_FILE_EXTENSIONS (F4) ==="
GLOBR="$(new_repo extglob)"
{ cpad 2; ccm 12 plain; } > "$GLOBR/a.sh"
{ cpad 2; ccm 12 note; } > "$GLOBR/secrets.pem"
{ cpad 2; ccm 12 note; } > "$GLOBR/.env.local"
git -C "$GLOBR" add -A >/dev/null 2>&1

C1_LIT=0
if stage_literal "$GLOBR" 'lit.[a-z]'; then C1_LIT=1; fi

# Vacuity guard: every C1 assertion below is an absence, so all of them would
# also pass if the two fixtures had never been staged. Name their real
# extensions once and require them to be reported — after this, an absence means
# out-of-scope rather than not-there.
run_cb "$GLOBR" "CODE_FILE_EXTENSIONS=pem;local" -- --staged
assert_contains "C1/fixtures-are-really-staged-secrets.pem" "$CB_FIND: secrets.pem" "$CB_OUT"
assert_contains "C1/fixtures-are-really-staged-.env.local" "$CB_FIND: .env.local" "$CB_OUT"

while IFS='|' read -r name val; do
    [ -z "${name//[[:space:]]/}" ] && continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    val="${val# }"
    val="${val%"${val##*[![:space:]]}"}"
    run_cb "$GLOBR" "CODE_FILE_EXTENSIONS=$val" -- --staged
    cb_expect_rc "C1/$name-rc"
    assert_absent "C1/$name-does-not-reach-secrets.pem" "secrets.pem" "$CB_OUT"
    assert_absent "C1/$name-does-not-reach-.env.local" ".env.local" "$CB_OUT"
done <<'TABLE'
bare-star    | *
class-star   | [a-z]*
question     | p?m
suffix-star  | *local
TABLE

# CPR-ORTH counterpart: the fix cannot be "match nothing". A literal list still
# selects exactly the files it names, and nothing else.
run_cb "$GLOBR" "CODE_FILE_EXTENSIONS=sh;py" -- --staged
cb_expect_rc "C1/literal-list-rc"
assert_contains "C1/literal-list-still-matches-a.sh" "$CB_FIND: a.sh" "$CB_OUT"
assert_eq "C1/literal-list-warn-count-is-1" "1" "$(cb_warn_count)"
assert_absent "C1/literal-list-excludes-secrets.pem" "secrets.pem" "$CB_OUT"
assert_absent "C1/literal-list-excludes-.env.local" ".env.local" "$CB_OUT"

# ---------------------------------------------------------------------------
# C2 — the comparison is literal, not a match (F4, positive direction)
# ---------------------------------------------------------------------------
# Absence assertions alone would also pass for an implementation that dropped
# any extension containing a metacharacter. This one pins the opposite edge: a
# configured extension containing `[`/`]` must still select the file whose name
# literally ends in that text.
echo ""
echo "=== C2: glob-shaped extension matches literally ==="
if [ "$C1_LIT" = "1" ]; then
    run_cb "$GLOBR" "CODE_FILE_EXTENSIONS=[a-z]" -- --staged
    cb_expect_rc "C2/rc"
    assert_contains "C2/literal-suffix-matches" "$CB_FIND: lit.[a-z]" "$CB_OUT"
    assert_eq "C2/warn-count-is-1" "1" "$(cb_warn_count)"
else
    skip "C2: this host cannot stage a file named lit.[a-z] — literal-comparison direction unverified"
fi

# ---------------------------------------------------------------------------
# C3 — a single quote in $TMPDIR must not break the cleanup trap (F3)
# ---------------------------------------------------------------------------
echo ""
echo "=== C3: TMPDIR containing a single quote (F3) ==="
QTMP="$TMPDIR_BASE/tmp'quote"
if mkdir -p "$QTMP" 2>/dev/null && [ -d "$QTMP" ]; then
    QR="$(new_repo tmpdirquote)"
    { cpad 2; ccm 12 plain; } > "$QR/a.sh"
    git -C "$QR" add -A >/dev/null 2>&1
    run_cb "$QR" "TMPDIR=$QTMP" -- --staged
    cb_expect_rc "C3/rc-matches-mode"
    assert_contains "C3/report-still-produced" "$CB_FIND: a.sh" "$CB_OUT"
    assert_absent "C3/no-command-not-found" "command not found" "$CB_ERR"
    assert_absent "C3/no-unexpected-eof" "unexpected EOF" "$CB_ERR"
    assert_absent "C3/no-syntax-error" "syntax error" "$CB_ERR"
    # The trap exists solely to remove the temp file list, so a leftover entry
    # is the direct observable of a trap body that never parsed.
    LEFT="$(find "$QTMP" -mindepth 1 2>/dev/null | grep -c . || true)"
    assert_eq "C3/no-temp-file-left-behind" "0" "$LEFT"
    rm -rf "$QTMP"
else
    skip "C3: this platform refuses a directory name containing a single quote — trap-quoting unverified"
fi

# ---------------------------------------------------------------------------
# C6/C7 — ambient environment must never reach a verdict (S2-4 / C5)
# ---------------------------------------------------------------------------
# The two knobs that decide whether a commit is blocked are resolved from the
# config dir's .env and from nowhere else. The reason is not tidiness: an author
# who can turn the gate off by exporting a variable in the shell that runs
# `git commit` has an undocumented bypass, and the pre-commit backstop is the
# layer that is supposed to have none. run_cb / run_cb_ambient cannot express
# this on their own — both write the caller's value into the .env as well — so
# the two sides are set independently here: honest value in the file, hostile
# value in the environment.
#
# Each hostile row is paired with a control that sets the SAME key through the
# .env. Without the pair, a scanner that ignored the knob entirely would pass
# the hostile row for the wrong reason.
run_cb_split() {
    local repo="$1" dotenv="$2" ambient="$3"; shift 3
    [ "${1:-}" = "--" ] && shift
    printf '%s\n' "$dotenv" > "$CB_CFG_DIR/.env"
    local -a envs=("${CB_ENV_RESET[@]}")
    local kv
    # shellcheck disable=SC2086
    for kv in $ambient; do envs+=("$kv"); done
    envs+=("AGENTS_CONFIG_DIR=$CB_CFG_DIR")
    CB_MODE="none"
    for kv in "$@"; do
        case "$kv" in
            --staged) CB_MODE="staged" ;;
            --all) CB_MODE="all" ;;
        esac
    done
    if [ "$CB_MODE" = "staged" ]; then CB_FIND="BLOCK"; else CB_FIND="WARN"; fi
    local errfile="$TMPDIR_BASE/cb.err"
    CB_RC=0
    CB_OUT="$( (cd "$repo" && run_with_timeout 60 env "${envs[@]}" bash "$SCRIPT" "$@") 2>"$errfile" )" || CB_RC=$?
    CB_ERR="$(cat "$errfile" 2>/dev/null || true)"
}

# A staged 12-line comment run: over the default threshold of 10, and far under
# the raised one, so the two directions cannot be confused.
AMBR="$(new_repo ambientcfg)"
{ cpad 2; ccm 12 note; } > "$AMBR/a.sh"
git -C "$AMBR" add -A >/dev/null 2>&1

echo ""
echo "=== C6: ambient COMMENT_BLOCK_MAX_LINES cannot raise the threshold ==="
run_cb_split "$AMBR" "COMMENT_BLOCK_MAX_LINES=10
CODE_FILE_EXTENSIONS=js;sh;py" "COMMENT_BLOCK_MAX_LINES=999999" -- --staged
assert_finding "C6/ambient-threshold-ignored" "a.sh" "$CB_OUT"
assert_eq "C6/still-blocks" "1" "$CB_RC"
# Control: through the .env the same value DOES raise the threshold. Asserted on
# the run-length line rather than on the finding prefix, so the control cannot
# pass merely because the prefix has not been renamed yet.
run_cb_split "$AMBR" "COMMENT_BLOCK_MAX_LINES=999999
CODE_FILE_EXTENSIONS=js;sh;py" "" -- --staged
assert_absent "C6/dotenv-threshold-is-honoured" "longest comment run" "$CB_OUT"
assert_eq "C6/control-rc-0" "0" "$CB_RC"

echo ""
echo "=== C7: ambient COMMENT_BLOCK_ENFORCE=off cannot disable the gate ==="
run_cb_split "$AMBR" "COMMENT_BLOCK_MAX_LINES=10
COMMENT_BLOCK_ENFORCE=on
CODE_FILE_EXTENSIONS=js;sh;py" "COMMENT_BLOCK_ENFORCE=off" -- --staged
assert_finding "C7/ambient-killswitch-ignored" "a.sh" "$CB_OUT"
assert_eq "C7/still-blocks" "1" "$CB_RC"
# Control: the kill switch works when it is set where it belongs.
run_cb_split "$AMBR" "COMMENT_BLOCK_MAX_LINES=10
COMMENT_BLOCK_ENFORCE=off
CODE_FILE_EXTENSIONS=js;sh;py" "" -- --staged
assert_absent "C7/dotenv-killswitch-is-honoured" "longest comment run" "$CB_OUT"
assert_eq "C7/control-rc-0" "0" "$CB_RC"
