# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh, tests/bin-check-on-demand-rules.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, static-check, scanners, TL2, scope:common
# Shared primitives for this directory's case files: the text scanners D1/D2/D9 are built
# from, the fixtures.sh body dump D8/D10/D11 read, and the table-driven assertion helpers
# (skills/_shared/test-design/parser-regex-tests.md). Sourced first; emits no PASS lines.
brief() { printf '%s' "$1" | head -4 | tr '\n' ' ' | cut -c1-360; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name — want=$want got=$got"; fi
}
tbl_input() { # <raw field> — drop the padding; `~` is a space, `^` a pipe (IFS eats `|`)
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    s="${s//\~/ }"
    printf '%s' "${s//^/|}"
}

# `git` in command position, as two alternatives. Unquoted: line start or a separator,
# where the left class excludes `_ . -` (fx_ensure_git / git_commit_all / .gitignore) and
# also both quotes, so `echo "git status"` is not a call. Quoted command name: `"git"`
# closed before the space, which is why the quotes cannot simply be optional. `.exe` is
# optional on both because #2111's target host is Git Bash, where `git.exe status` is the
# same call and an `.exe`-blind scanner waves it through. The right class is "whitespace
# then any argument character", admitting `git \` and a redirect ahead of the subcommand;
# `#` is excluded so a bare mention trailed by a comment is not a call. D6 pins each row.
GIT_CALL_RE="((^|[^A-Za-z0-9_.'\"-])git(\.exe)?|['\"]git(\.exe)?['\"])[[:space:]]+[^[:space:]#]"

# The indirect half: a variable that IS git (`GIT=git`, `GIT=/usr/bin/git.exe`) turns
# every later `$GIT add` into a call GIT_CALL_RE cannot see. Only the ASSIGNMENT is
# decidable statically, so that is what this pins. The right-hand side must be the bare
# word or an ABSOLUTE path ending in it — `d="$BASE/git"` is a directory, not a binary,
# and admitting it would flag half the fixture tree. D6b pins each row.
GIT_ALIAS_ASSIGN_RE="(^|[^A-Za-z0-9_./-])[A-Za-z_][A-Za-z0-9_]*=[\"']?(/[^[:space:]\"']*)?git(\.exe)?[\"']?([[:space:]]|;|\$)"
# D1 takes both routes; D2/D9 stay on GIT_CALL_RE alone, because they read fixtures.sh,
# which OWNS the git primitive and may legitimately name it.
GIT_ROUTE_RE="$GIT_CALL_RE|$GIT_ALIAS_ASSIGN_RE"

# scan_file_direct_git <file> — prints `<file>:<line>:<text>` per direct call.
# Whole-line comments are dropped (cases-injection.sh names `git diff --cached` in
# prose); a trailing comment is deliberately NOT stripped, because a `#` inside a
# quoted path would make that unsound.
scan_file_direct_git() {
    local f="$1" hit num body trimmed
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        num="${hit%%:*}"
        body="${hit#*:}"
        trimmed="${body#"${body%%[![:space:]]*}"}"
        case "$trimmed" in '#'*) continue ;; esac
        printf '%s:%s:%s\n' "$f" "$num" "$trimmed"
    done < <(grep -nE -- "$GIT_ROUTE_RE" "$f" 2>/dev/null || true)
}

# scan_direct_git <dir> [<exempt-basename>...] — the D1 detection logic, parameterized
# by directory so D3/D4 can drive the very same code over planted trees.
scan_direct_git() {
    local d="$1"
    shift
    local f b x exempt
    for f in "$d"/*.sh; do
        [[ -f "$f" ]] || continue
        b="$(basename "$f")"
        exempt=0
        for x in "$@"; do
            [[ "$b" == "$x" ]] && exempt=1
        done
        if [[ "$exempt" -eq 0 ]]; then
            scan_file_direct_git "$f"
        fi
    done
}

FX_NAMES="$TMPDIR_BASE/fx-names.txt"
FX_DUMP="$TMPDIR_BASE/fx-dump.txt"
FX_BODY="$TMPDIR_BASE/fx-body.txt"
# extract_fx_names <file> — one top-level function name per line. Bash has two
# definition syntaxes and a `name()`-only scan drops every `function name { ... }`
# silently, taking that function's git calls out of D2b's reach with no FAIL to show
# for it. D7 pins both syntaxes and the non-definitions that must stay out.
extract_fx_names() {
    grep -oE '^(function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\))' "$1" \
        | sed -E 's/^function[[:space:]]+//; s/[[:space:]]*\(\)$//'
}
extract_fx_names "$FIXTURES" > "$FX_NAMES"
# Bodies come from `declare -f` in a FRESH bash, not from the file text: bash drops
# comments when it stores a function, so the dump cannot false-positive on prose.
# shellcheck disable=SC2046
bash "$TIMEOUT" 120 bash -c \
    'set +u; . "$1" >/dev/null 2>&1; shift; for n in "$@"; do printf "===FX===%s\n" "$n"; declare -f "$n" 2>/dev/null; done' \
    _ "$FIXTURES" $(cat "$FX_NAMES") > "$FX_DUMP" 2>/dev/null || true

fx_body() {
    awk -v want="===FX===$1" 'index($0,"===FX===")==1 { on = ($0 == want); next } on { print }' "$FX_DUMP"
}
first_line_matching() { # <file> <ere> -> 1-based line number, or 0
    local n
    n="$(grep -nE -m1 -- "$2" "$1" | cut -d: -f1)"
    printf '%s' "${n:-0}"
}

# Quoted segments are stripped first, so any expansion that survives is unquoted by
# construction. '$d' sits in single quotes and never expands, so it is not a finding.
UNQUOTED_EXP_RE='\$\{?[A-Za-z_@0-9][A-Za-z0-9_]*\}?'
strip_quoted() { sed -E 's/"[^"]*"//g; s/'"'"'[^'"'"']*'"'"'//g'; }

# scan_file_scope_git <file> — prints `<line>:<text>` per git call written OUTSIDE every
# function. It is the blind spot between D1 (which exempts fixtures.sh outright) and D2
# (which reads function bodies only). Nesting follows the same column-0 convention
# extract_fx_names relies on: a definition opens at column 0, a `}` at column 0 closes it,
# a one-liner never opens. D9t pins the states apart.
scan_file_scope_git() {
    awk -v re="$GIT_CALL_RE" '
        /^[[:space:]]*#/ { next }
        infn == 0 && /^(function[[:space:]]+[A-Za-z_][A-Za-z0-9_]*|[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\))/ {
            if ($0 !~ /\}[[:space:]]*$/) infn = 1
            next
        }
        infn == 1 && /^\}/ { infn = 0; next }
        infn == 0 && $0 ~ re { printf "%d:%s\n", NR, $0 }
    ' "$1" 2>/dev/null
}

# The fixtures.sh BODY scanners (D8/D10/D12). They live here rather than in the case file
# that first consumed them so the D8t-D12v tables pin the very same constants — a copy in
# the table would fix a regex nobody runs (CPR-SSOT).
SWALLOW_RE='\|\|[[:space:]]*(true|:)([[:space:]]|;|$)'
CP_CALL_RE='(^|[^A-Za-z0-9_.-])cp[[:space:]]'
CP_GUARDED_RE='(if[[:space:]]+!.*[^A-Za-z0-9_.-]cp[[:space:]]|[^A-Za-z0-9_.-]cp[[:space:]].*\|\|)'
TEMPLATE_CALL_RE='(^|[^A-Za-z0-9_.-])_fx_git_template([[:space:]]|;|$)'
# `git … add` / `git … diff --cached` with the flags between them optional, so a future
# `git add -A` written without `-C` is still seen (the old two-space form missed it).
GIT_ADD_RE='(^|[^A-Za-z0-9_.-])git(\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*add([[:space:]]|$)'
GIT_ADD_GUARDED_RE='(if[[:space:]]+!.*[^A-Za-z0-9_.-]git.*[[:space:]]add([[:space:]]|$)|[^A-Za-z0-9_.-]git.*[[:space:]]add([[:space:]].*)?\|\|)'
STAGED_ENUM_RE='(^|[^A-Za-z0-9_.-])git(\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*diff[[:space:]]+--cached'
EARLY_GIT_TEST_RE='-d[[:space:]]+[^[:space:]]*\.git'

# C6 (rules/test/fixture-isolation.md). The design initialises ONE repo and clones its
# `.git` afterwards, so the hooks-disabling obligation splits in two: the template must
# carry the setting, and the clone must move the WHOLE `.git` that holds it. REINIT_RE is
# the third half of the same claim — a clone that re-inits is not the template's repo.

# `config` is REQUIRED: only that form writes the setting into the template's own
# `.git/config`, the one byte-range a clone carries. The ephemeral `git -c
# core.hooksPath=/dev/null <cmd>` form stores nothing, so a template built with it clones
# the HOST's hooksPath while D12a still reads green — see E3/E4 and the D12t rows.
HOOKS_OFF_RE='(^|[^A-Za-z0-9_.-])config([[:space:]]+--[^[:space:]]+)*[[:space:]]+core\.hooksPath[[:space:]]+/dev/null'
CLONE_WHOLE_GIT_RE="cp[[:space:]].*/\\.git[\"']?[[:space:]]+[^[:space:]]*/\\.git[\"']?([[:space:]]|;|\$)"
REINIT_RE='(^|[^A-Za-z0-9_.-])git(\.exe)?[[:space:]]+([^[:space:]]+[[:space:]]+)*(init|config)([[:space:]]|$)'

# re_table <label> <regex> — runs a `name|input|match|no-match` table from stdin
# (skills/_shared/test-design/parser-regex-tests.md). `~` in the input stands for a space.
re_table() {
    local label="$1" re="$2" _n _i _w _got
    while IFS='|' read -r _n _i _w; do
        [[ -z "$_n" || "$_n" =~ ^[[:space:]]*# ]] && continue
        _n="${_n//[[:space:]]/}"
        _w="${_w//[[:space:]]/}"
        if printf '%s\n' "$(tbl_input "$_i")" | grep -qE -- "$re"; then _got=match; else _got=no-match; fi
        assert_eq "$label/$_n" "$_w" "$_got"
    done
}
