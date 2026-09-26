#!/usr/bin/env bash
# tests/feature-2075-append-destination.sh
# Tests: bin/find-tests-for-source.sh,bin/lib/test-route-destination.sh,bin/lib/test-dup-group.sh,skills/write-tests/SKILL.md,skills/review-tests/SKILL.md,skills/review-tests/scripts/select-staged-files.sh,skills/_shared/test-design/append-vs-new.md,skills/run-tests/SKILL.md,bin/lib/test-frontmatter-fix.sh,bin/resolve-worktree-path,install/settings-allow-commands.txt
# Tags: scope:issue-specific
# Dispatcher for #2075 (append-vs-new destination routing): shared fixtures only.
# Cases live in the sibling folder of the same name.
# TL3 gap (what this test does NOT catch):
# - whether a live write-tests / review-tests run actually invokes the helper
# - whether RT-1a's reviewer LLM raises the gap the row makes available to it
# Mitigation: WORKFLOW_USER_VERIFIED preflight, category skill-orchestration.

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GROUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2075-append-destination"
HELPER="$AGENTS_ROOT/bin/find-tests-for-source.sh"
ROUTE_LIB="$AGENTS_ROOT/bin/lib/test-route-destination.sh"
DUP_LIB="$AGENTS_ROOT/bin/lib/test-dup-group.sh"
SELECT_SH="$AGENTS_ROOT/skills/review-tests/scripts/select-staged-files.sh"
WT_SKILL="$AGENTS_ROOT/skills/write-tests/SKILL.md"
RT_SKILL="$AGENTS_ROOT/skills/review-tests/SKILL.md"
TD_SHARED="$AGENTS_ROOT/skills/_shared/test-design.md"
TD_APPEND="$AGENTS_ROOT/skills/_shared/test-design/append-vs-new.md"
ALLOW_TXT="$AGENTS_ROOT/install/settings-allow-commands.txt"
RUN_TIMEOUT="$AGENTS_ROOT/bin/run-with-timeout.sh"

PASS=0
FAIL=0
SKIP=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }
skip() { SKIP=$((SKIP + 1)); echo "SKIP: $1"; }

# assert_eq — table-driven assertion helper (skills/_shared/test-design/parser-regex-tests.md).
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [[ "$want" == "$got" ]]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin the workflow dirs,
# drop every inherited session channel, and never resolve the developer's session.
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE

# Neutral CWD: every helper run happens here, so a forgotten --root can never
# silently resolve the live agents repo and read the live tests/ corpus.
NEUTRAL_DIR="$TMPDIR_BASE/neutral"
mkdir -p "$NEUTRAL_DIR"

run_with_timeout() { bash "$RUN_TIMEOUT" 120 "$@"; }

# ── Fixture builders ────────────────────────────────────────────────────────

# make_repo — throwaway git repo with tests/. Echoes its root.
make_repo() {
    local root
    root="$(mktemp -d -p "$TMPDIR_BASE")"
    git -C "$root" init -q
    git -C "$root" config core.hooksPath /dev/null
    git -C "$root" config core.autocrlf false
    git -C "$root" config user.email "t@example.com"
    git -C "$root" config user.name "t"
    mkdir -p "$root/tests"
    printf 'init\n' > "$root/README.md"
    echo "$root"
}

# add_test_file <root> <name-under-tests> <tests-csv> [tags] [line-count]
# <tests-csv> is written VERBATIM so a case can reproduce `./`-prefixed,
# out-of-order and duplicated corpus spellings (the candidate-side of H11*).
# The body is padded to exactly <line-count> lines (minimum 4).
add_test_file() {
    local root="$1" name="$2" hdr="$3" tags="${4:-scope:common}" lines="${5:-0}" i f
    f="$root/tests/$name"
    mkdir -p "$(dirname "$f")"
    printf '#!/usr/bin/env bash\n' > "$f"
    printf '# Tests: %s\n' "$hdr" >> "$f"
    printf '# Tags: %s\n' "$tags" >> "$f"
    printf 'echo fixture\n' >> "$f"
    for ((i = 5; i <= lines; i++)); do printf '# pad %s\n' "$i" >> "$f"; done
}

# add_broken_test_file <root> <name> <kind> — the four tdg_classify failure
# shapes. `late_header` puts the header on line 12 (> FRONTMATTER_HEADER_MAX_LINE);
# `malformed_header` uses an empty CSV element, which tfm_parse_tests_line alone
# accepts as a shorter token list and only tdg_classify rejects.
add_broken_test_file() {
    local root="$1" name="$2" kind="$3" i f
    f="$root/tests/$name"
    mkdir -p "$(dirname "$f")"
    printf '#!/usr/bin/env bash\n' > "$f"
    case "$kind" in
        no_tests_header)
            printf '# Tags: scope:common\necho fixture\n' >> "$f" ;;
        duplicate_header)
            printf '# Tests: src/x.js\n' >> "$f"
            printf '# Tests: src/y.js\n' >> "$f"
            printf '# Tags: scope:common\n' >> "$f" ;;
        late_header)
            for ((i = 2; i <= 11; i++)); do printf '# filler %s\n' "$i" >> "$f"; done
            printf '# Tests: src/x.js\n' >> "$f"
            printf '# Tags: scope:common\n' >> "$f" ;;
        malformed_header)
            printf '# Tests: src/x.js,,src/y.js\n' >> "$f"
            printf '# Tags: scope:common\n' >> "$f" ;;
        *)
            fail "add_broken_test_file: unknown kind $kind" ;;
    esac
}

# add_nested_test_file <root> <dir> <name> <tests-csv> — tests/<dir>/<name>,
# outside the tdg_scan_corpus range contract.
add_nested_test_file() {
    local root="$1" dir="$2" name="$3" hdr="$4"
    mkdir -p "$root/tests/$dir"
    add_test_file "$root" "$dir/$name" "$hdr"
}

# ── Runner ──────────────────────────────────────────────────────────────────
# run_helper <args...> — sets OUT / ERR / RC. CWD is always the neutral dir.
OUT=""
ERR=""
RC=0
run_helper() {
    local outf errf
    outf="$(mktemp)"; errf="$(mktemp)"
    (
        cd "$NEUTRAL_DIR" || exit 2
        unset GIT_DIR GIT_WORK_TREE
        run_with_timeout bash "$HELPER" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"; ERR="$(cat "$errf")"
    rm -f "$outf" "$errf"
}

# ── TSV accessors ───────────────────────────────────────────────────────────
# Decoding goes through the bin/ codec (tdg_unescape_field / tdg_split_escaped_csv),
# never through a third private decoder — that is the whole point of adding the
# reverse transform next to tdg_escape_field (CPR-SSOT).
if [[ -f "$DUP_LIB" ]]; then
    # shellcheck source=../bin/lib/test-dup-group.sh
    . "$DUP_LIB"
fi

nrows() { if [[ -z "$1" ]]; then printf '0'; else printf '%s\n' "$1" | grep -c ''; fi; }
row_n() { printf '%s\n' "$1" | sed -n "${2}p"; }
col() { printf '%s\n' "$1" | cut -f "$2"; }
dcol() { tdg_unescape_field "$(col "$1" "$2")"; }

# list_count / list_entry_field — columns 6-8 are tdg_escape_field applied twice:
# an inner `file,lines,extra_count` element, escaped again as one outer element.
# Two passes of tdg_split_escaped_csv reverse exactly that.
list_count() {
    local colv="$1"
    if [[ "$colv" == "-" || -z "$colv" ]]; then printf '0'; return 0; fi
    local -a f2075_outer=()
    tdg_split_escaped_csv "$colv" f2075_outer 2>/dev/null
    printf '%s' "${#f2075_outer[@]}"
}

list_entry_field() {
    local colv="$1" ei="$2" fi="$3"
    if [[ "$colv" == "-" || -z "$colv" ]]; then printf ''; return 0; fi
    local -a f2075_outer=() f2075_inner=()
    tdg_split_escaped_csv "$colv" f2075_outer 2>/dev/null
    if (( ei < 1 || ei > ${#f2075_outer[@]} )); then printf ''; return 0; fi
    tdg_split_escaped_csv "${f2075_outer[ei - 1]}" f2075_inner 2>/dev/null
    if (( fi < 1 || fi > ${#f2075_inner[@]} )); then printf ''; return 0; fi
    printf '%s' "${f2075_inner[fi - 1]}"
}

# list_files <column> — rank-ordered paths as a comma-joined string, or `-`.
list_files() {
    local colv="$1" n i res=""
    if [[ "$colv" == "-" || -z "$colv" ]]; then printf '%s' '-'; return 0; fi
    n="$(list_count "$colv")"
    for ((i = 1; i <= n; i++)); do res="${res:+$res,}$(list_entry_field "$colv" "$i" 1)"; done
    printf '%s' "$res"
}

# assert_row <name> <row> <verdict> <reason> <target> <viable-files>
assert_row() {
    assert_eq "$1 verdict" "$3" "$(col "$2" 2)"
    assert_eq "$1 reason" "$4" "$(col "$2" 3)"
    assert_eq "$1 target" "$5" "$(dcol "$2" 4)"
    assert_eq "$1 viable" "$6" "$(list_files "$(col "$2" 7)")"
}

# ── Completion ledger (GRP pattern, from tests/feature-2065-dup-group-inventory.sh)
# Each case file's LAST line is `grp_done <its own basename>`; a file that bails
# after its fixture setup still sources "successfully", so only the ledger proves
# the whole family ran.
GRP_DONE=""
grp_done() { GRP_DONE="${GRP_DONE}$1
"; }

# case_ran <id> — the per-case half of the ledger. GRP2 proves a FILE finished;
# this proves an individual planned case id actually reported.
CASE_RAN=""
case_ran() { CASE_RAN="${CASE_RAN} $1"; }

# ── Preconditions ───────────────────────────────────────────────────────────
for _p in "$HELPER:bin/find-tests-for-source.sh" "$ROUTE_LIB:bin/lib/test-route-destination.sh" \
          "$DUP_LIB:bin/lib/test-dup-group.sh" "$SELECT_SH:skills/review-tests/scripts/select-staged-files.sh" \
          "$WT_SKILL:skills/write-tests/SKILL.md" "$RT_SKILL:skills/review-tests/SKILL.md" \
          "$TD_SHARED:skills/_shared/test-design.md" "$TD_APPEND:skills/_shared/test-design/append-vs-new.md" \
          "$ALLOW_TXT:install/settings-allow-commands.txt"; do
    if [[ -f "${_p%%:*}" ]]; then pass "P0 ${_p#*:} exists"; else fail "P0 ${_p#*:} missing at ${_p%%:*}"; fi
done

# P1 — the reverse codec the whole assertion harness decodes through.
for _fn in tdg_unescape_field tdg_split_escaped_csv; do
    if declare -F "$_fn" >/dev/null 2>&1; then
        pass "P1 $_fn is defined by bin/lib/test-dup-group.sh"
    else
        fail "P1 $_fn not defined by bin/lib/test-dup-group.sh (not implemented yet)"
    fi
done

# ── Case files ──────────────────────────────────────────────────────────────
# shellcheck source=feature-2075-append-destination/helper-cases.sh
. "$GROUP_DIR/helper-cases.sh"
# shellcheck source=feature-2075-append-destination/function-cases.sh
. "$GROUP_DIR/function-cases.sh"
# shellcheck source=feature-2075-append-destination/codec-cases.sh
. "$GROUP_DIR/codec-cases.sh"
# shellcheck source=feature-2075-append-destination/edge-cases.sh
. "$GROUP_DIR/edge-cases.sh"
# shellcheck source=feature-2075-append-destination/worktree-select-cases.sh
. "$GROUP_DIR/worktree-select-cases.sh"
# shellcheck source=feature-2075-append-destination/skill-static-cases.sh
. "$GROUP_DIR/skill-static-cases.sh"

# ── Case-file set integrity ─────────────────────────────────────────────────
GRP_PRESENT="$(ls -1 "$GROUP_DIR" 2>/dev/null | grep '\.sh$' | sort)"
GRP_SOURCED="$(sed -n 's|^\. "\$GROUP_DIR/\(.*\.sh\)"$|\1|p' "${BASH_SOURCE[0]}" | sort)"

grp_only_in_first() {
    comm -23 <(printf '%s\n' "$1" | grep -v '^$') <(printf '%s\n' "$2" | grep -v '^$') \
        | tr '\n' ' ' | sed 's/ *$//'
}
GRP_UNSOURCED="$(grp_only_in_first "$GRP_PRESENT" "$GRP_SOURCED")"
GRP_ABSENT="$(grp_only_in_first "$GRP_SOURCED" "$GRP_PRESENT")"

if [[ -z "$GRP_UNSOURCED" && -z "$GRP_ABSENT" ]]; then
    pass "GRP1 every case file is sourced and every sourced case file exists"
else
    fail "GRP1 case file set mismatch — present-but-unsourced: [${GRP_UNSOURCED:-none}] sourced-but-missing: [${GRP_ABSENT:-none}]"
fi

GRP_DONE_SORTED="$(printf '%s' "$GRP_DONE" | sort)"
GRP_UNFINISHED="$(grp_only_in_first "$GRP_SOURCED" "$GRP_DONE_SORTED")"
GRP_UNEXPECTED="$(grp_only_in_first "$GRP_DONE_SORTED" "$GRP_SOURCED")"

if [[ -z "$GRP_UNFINISHED" && -z "$GRP_UNEXPECTED" ]]; then
    pass "GRP2 every sourced case file ran through to its completion marker"
else
    fail "GRP2 case file completion mismatch — sourced-but-unfinished: [${GRP_UNFINISHED:-none}] marked-but-not-sourced: [${GRP_UNEXPECTED:-none}]"
fi

# CASE1 — the planned case ledger: every id in the plan's H/S/F tables must have
# reported at least one assertion, so a deleted case block cannot pass silently.
CASE_EXPECTED="H1 H2 H3 H4 H5 H6 H7 H8 H9 H10 H11 H11b H11c H11d H11e H12 H13 H13b H13c \
H14a H14b H14c H14d H15 H16 H17 H18a H18b F1 F2 F3 F4 F5 F6 F7 \
K1 K2 K3 K4 K5 B1 B2 B3 B4 B5 G1 G2 V1 V2 E1 E2 E3 E4 E5 I1 W1 W2 \
S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 S12 S13 S14 S15 S16 S17 S18 S19 S20"
CASE_MISSING=""
for _c in $CASE_EXPECTED; do
    case " $CASE_RAN " in
        *" $_c "*) ;;
        *) CASE_MISSING="${CASE_MISSING:+$CASE_MISSING }$_c" ;;
    esac
done
if [[ -z "$CASE_MISSING" ]]; then
    pass "CASE1 every planned case id ran"
else
    fail "CASE1 planned case ids that never ran: [$CASE_MISSING]"
fi

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
