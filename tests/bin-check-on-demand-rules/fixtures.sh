# shellcheck shell=bash
# Tests: bin/check-on-demand-rules.sh, hooks/lib/rules-injection-policy.js
# Tags: rules-injection, on-demand-rules, fixtures, TL2, scope:common
#
# Fixture builders and the checker driver for ../bin-check-on-demand-rules.sh.
# Assumes TOKEN, MARKER, BASE, CHECKER, node_path(), pass(), fail() are defined.

wr() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

mk_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config core.hooksPath /dev/null
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
}

# The stand-in owner every generated on-demand row points at. #2037 made the reader set
# part of the declaration, so a fixture that names a rule without naming a reader is now
# malformed by construction — and every case here would fail for that reason rather than
# for the one it was written to check. So the builder attaches this one owner and creates
# the file, keeping the callers' 2nd argument what it has always been: rule names only.
FX_OWNER_SKILL="skills/fx-owner/SKILL.md"

# --- #2037 minimized-declaration baseline ----------------------------------
# WHY (CPR-WPH): the checker now fails CLOSED on an absent or unparseable
# MINIMIZED_UNCONDITIONAL (violation MINIMIZED_DECLARATION_MISSING), so a policy that
# never declares the class is itself a violation. Every fixture below therefore has to
# carry the declaration, or a case written about the marker comment or the staged-path
# handling would be graded on a class it never meant to exercise.
# The baseline declaration is deliberately EMPTY: it declares the class and nothing in
# it, so it needs no extra rule files, no pointer targets, and cannot perturb any other
# check. Cases that are ABOUT the declaration itself (absent, unparseable, commented out)
# opt out by passing the literal NONE, and cases about the rows pass their own literal.
FX_MINIMIZED_DEFAULT='[]'
FX_MAXBYTES_DEFAULT='1500'

# emit_minimized <minimized> <maxbytes> — prints the two declaration lines on stdout.
# NONE in either position suppresses that line, which is how a case exercises the
# fail-closed path without hand-writing a whole policy file.
emit_minimized() {
    local minimized="$1" maxbytes="$2"
    [ "$minimized" = "NONE" ] || printf 'const MINIMIZED_UNCONDITIONAL = %s;\n' "$minimized"
    [ "$maxbytes" = "NONE" ] || printf 'const MINIMIZED_MAX_BYTES = "%s";\n' "$maxbytes"
}

# write_policy <dir> <on_demand_json> <expected_json> [<minimized>] [<maxbytes>]
# <on_demand_json> is a JSON array of RULE NAMES; each becomes one "<rule>|<owner>" row.
# <minimized>/<maxbytes> default to the empty baseline above; NONE opts out.
write_policy() {
    local readers
    # "rules/a.md","rules/b.md"  ->  "rules/a.md|<owner>","rules/b.md|<owner>"
    # An empty array survives untouched, which is what cases that register nothing want.
    readers="$(printf '%s' "$2" | sed "s#\"\\([^\"]*\\)\"#\"\\1|$FX_OWNER_SKILL\"#g")"
    mkdir -p "$1/hooks/lib"
    cat > "$1/hooks/lib/rules-injection-policy.js" <<POLICY_EOF
"use strict";
const ON_DEMAND_TOKEN = "$TOKEN";
// suffix-tight on purpose: \b alone does not stop \`on-demand-only-ish\`, because the
// boundary between \`y\` and \`-\` IS a word boundary. See cases-marker.sh K3/K4.
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const ON_DEMAND_READERS = $readers;
const EXPECTED_UNCONDITIONAL = $3;
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };
POLICY_EOF
    emit_minimized "${4:-$FX_MINIMIZED_DEFAULT}" "${5:-$FX_MAXBYTES_DEFAULT}" \
        >> "$1/hooks/lib/rules-injection-policy.js"
    # READER_TARGET_MISSING is an unconditional check — the declared owner has to exist.
    mkdir -p "$1/$(dirname "$FX_OWNER_SKILL")"
    printf '# Fixture owner\n\n## Step 1\n\nRead the rules this skill declares before continuing.\n' \
        > "$1/$FX_OWNER_SKILL"
}

# Baseline tree: one on-demand file (correct notation), one listed unconditional
# file, one ordinary conditional file. Expected verdict for the baseline: clean.
fx_base() {
    local d="$1"
    mk_repo "$d"
    write_policy "$d" '["rules/od.md"]' '["rules/plain.md"]'
    wr "$d/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
---
$MARKER

# On demand rule
EOF
    wr "$d/rules/plain.md" <<'EOF'
# Plain unconditional rule (listed in EXPECTED_UNCONDITIONAL)
EOF
    wr "$d/rules/cond.md" <<'EOF'
---
paths:
  - "tests/**"
---

# Ordinary conditional rule
EOF
}

fx_c1_no_frontmatter() {
    fx_base "$1"
    wr "$1/rules/od.md" <<EOF
$MARKER

# On demand rule that forgot its frontmatter entirely
EOF
}

fx_c1_token_plus_glob() {
    fx_base "$1"
    wr "$1/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
  - "docs/**"
---
$MARKER
EOF
}

fx_c1_wrong_single_glob() {
    fx_base "$1"
    wr "$1/rules/od.md" <<EOF
---
paths:
  - "docs/**"
---
$MARKER
EOF
}

fx_c2_missing_marker() {
    fx_base "$1"
    wr "$1/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
---

# Token present, marker comment absent
EOF
}

fx_c2_orphan_marker() {
    fx_base "$1"
    wr "$1/rules/orphan.md" <<EOF
---
paths:
  - "tests/**"
---
$MARKER

# Marker present, token absent
EOF
}

fx_c3_reserved_path() {
    fx_base "$1"
    mkdir -p "$1/.on-demand-only"
    printf 'this real path must never exist\n' > "$1/$TOKEN"
}

fx_c4_bangbang()   { fx_base "$1"; _fx_near "$1" '!!on-demand-only'; }
fx_c4_underscore() { fx_base "$1"; _fx_near "$1" '.on-demand-only/never_match'; }
fx_c4_bare()       { fx_base "$1"; _fx_near "$1" 'on-demand-only'; }
_fx_near() {
    wr "$1/rules/near.md" <<EOF
---
paths:
  - "$2"
---

# Near-miss spelling of the reserved token
EOF
}

fx_c5_unlisted() {
    fx_base "$1"
    wr "$1/rules/unlisted.md" <<'EOF'
# No paths: line anywhere, and absent from EXPECTED_UNCONDITIONAL
EOF
}

# --- driver ----------------------------------------------------------------
# run_checker <dir> <mode> -> prints exit code; output lands in `outfile_for <dir>`.
# Derived from <dir>, not passed via a variable: run_checker always runs inside `$( )`,
# and a subshell's assignments never reach the caller.
outfile_for() { echo "$1/.checker-output.txt"; }

run_checker() {
    local d="$1" mode="$2" rc=0
    local OUTFILE; OUTFILE="$(outfile_for "$d")"
    local pol; pol="$(node_path "$d/hooks/lib/rules-injection-policy.js")"
    if [ "$mode" = "all" ]; then
        ( cd "$d" && RULES_INJECTION_POLICY="$pol" bash "$CHECKER" --all "$(node_path "$d")" ) \
            >"$OUTFILE" 2>&1 || rc=$?
    else
        git -C "$d" add -A >/dev/null 2>&1 || true
        local files
        files="$(git -C "$d" diff --cached --name-only)"
        # shellcheck disable=SC2086
        ( cd "$d" && RULES_INJECTION_POLICY="$pol" bash "$CHECKER" --staged $files ) \
            >"$OUTFILE" 2>&1 || rc=$?
    fi
    echo "$rc"
}

# run_checker_nopin <dir> -> prints exit code; --all with RULES_INJECTION_POLICY
# deliberately UNSET, so the checker must fall back to <root>/hooks/lib/rules-injection-policy.js.
# Every other harness here pins the env var, which leaves the documented default path
# unexercised: a checker that only ever honoured the env var would look correct.
run_checker_nopin() {
    local d="$1" rc=0
    local OUTFILE; OUTFILE="$(outfile_for "$d")"
    ( cd "$d" && unset RULES_INJECTION_POLICY && bash "$CHECKER" --all "$(node_path "$d")" ) \
        >"$OUTFILE" 2>&1 || rc=$?
    echo "$rc"
}

# run_checker_files <dir> <file...> -> prints exit code; --staged with an EXPLICIT
# file list, so the caller controls exactly which paths are handed to the checker.
run_checker_files() {
    local d="$1" rc=0; shift
    local OUTFILE; OUTFILE="$(outfile_for "$d")"
    local pol; pol="$(node_path "$d/hooks/lib/rules-injection-policy.js")"
    ( cd "$d" && RULES_INJECTION_POLICY="$pol" bash "$CHECKER" --staged "$@" ) \
        >"$OUTFILE" 2>&1 || rc=$?
    echo "$rc"
}

git_commit_all() {
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" commit -q --no-verify -m "baseline" >/dev/null 2>&1
}

# --- #2037 declaration-shape helpers ---------------------------------------
# Shared by cases-readers.sh and cases-minimized.sh. They live here rather than in
# either case file because a helper owned by one of them would make the other's
# correctness depend on the dispatcher's source order (CPR-SSOT).
# rd_policy <dir> <readers-literal> <expected-literal> [<minimized-literal>] [<max-bytes>]
# MINIMIZED_* default to the empty baseline (see FX_MINIMIZED_DEFAULT above) rather than
# being omitted: an omitted declaration is itself a violation now, so omitting it by
# default would grade every unrelated case on the minimized class. Pass NONE in either
# position to omit that line — that is how the fail-closed cases are built.
rd_policy() {
    local d="$1" readers="$2" expected="$3"
    local minimized="${4:-$FX_MINIMIZED_DEFAULT}" maxbytes="${5:-$FX_MAXBYTES_DEFAULT}"
    mkdir -p "$d/hooks/lib"
    {
        printf '"use strict";\n'
        printf 'const ON_DEMAND_TOKEN = "%s";\n' "$TOKEN"
        printf 'const ON_DEMAND_MARKER_RE = /<!--\\s*injection:\\s*on-demand-only(?!-?\\w)/;\n'
        printf 'const ON_DEMAND_READERS = %s;\n' "$readers"
        printf 'const EXPECTED_UNCONDITIONAL = %s;\n' "$expected"
        emit_minimized "$minimized" "$maxbytes"
        printf 'module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_READERS, EXPECTED_UNCONDITIONAL };\n'
    } > "$d/hooks/lib/rules-injection-policy.js"
}

# rd_base <dir> -> a clean tree in the NEW declaration shape: one on-demand rule with a
# real reader skill and a CLAUDE.md pointer, one ordinary unconditional rule.
rd_base() {
    local d="$1"
    mk_repo "$d"
    rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md"]'
    wr "$d/rules/od.md" <<EOF
---
paths:
  - "$TOKEN"
---
$MARKER

# On demand rule
EOF
    wr "$d/rules/plain.md" <<'EOF'
# Plain unconditional rule
EOF
    wr "$d/skills/owner/SKILL.md" <<'EOF'
# Owner skill

Read `rules/od.md` before continuing.
EOF
    wr "$d/CLAUDE.md" <<'EOF'
# Project instructions

- `rules/od.md` is not auto-injected — Read it before the work it governs.
EOF
}

# rd_min_base <dir> [<pointer>] [<max-bytes>] -> rd_base plus a minimized unconditional
# escape-hatch rule whose body names the pointer by slash form.
rd_min_base() {
    local d="$1" ptr="${2:-skills/eho/SKILL.md}" mb="${3:-1500}"
    rd_base "$d"
    rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/min.md"]' \
        "[\"rules/min.md|$ptr\"]" "$mb"
    wr "$d/rules/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Details and the sentinel procedure: `/eho`.
EOF
    wr "$d/skills/eho/SKILL.md" <<'EOF'
# eho

The full procedure.
EOF
}

# rd_expect <label> <dir> <token> <yes|no|no-token-only> [<subject-substring>]
#
# yes: the checker must exit 1 AND emit a line beginning with the token, naming the subject.

# no : the sanctioned positive control. The fixture is valid by construction, so the
#      assertion is a CLEAN VERDICT — exit 0 and no violation line of any token. Grading
#      only "this one token stayed silent" would stay green while the checker crashed or
#      refused the sanctioned input under an unrelated token.

# no-token-only: the named exception (CPR-UNV) — one token silent while the fixture
#      deliberately carries other violations. Use only with a comment naming them.
rd_expect() {
    local label="$1" d="$2" tok="$3" want="$4" subj="${5:-}" rc out line others
    rc="$(run_checker "$d" all)"
    out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
    line="$(printf '%s\n' "$out" | grep "^$tok:" | head -1)"
    if [ "$want" = "no-token-only" ]; then
        if [ -z "$line" ]; then pass "$label"
        else fail "$label — checker emitted an unwanted $tok: $line"; fi
        return
    fi
    if [ "$want" = "no" ]; then
        others="$(printf '%s\n' "$out" | grep -E '^[A-Z][A-Z_]+:' | head -3 | tr '\n' ' ')"
        if [ -n "$line" ]; then
            fail "$label — checker emitted an unwanted $tok: $line"
        elif [ "$rc" != "0" ]; then
            fail "$label — $tok stayed silent but the checker exited $rc on a fixture that is valid by construction; the sanctioned input is being refused for some other reason: ${others:-(no violation line — a crash or an unparsed error)} $(printf '%s' "$out" | head -4 | tr '\n' ' ' | cut -c1-300)"
        elif [ -n "$others" ]; then
            fail "$label — exit 0, yet violation line(s) were printed on a fixture that is valid by construction: $others"
        else
            pass "$label"
        fi
        return
    fi
    if [ -z "$line" ]; then
        fail "$label — no $tok line (rc=$rc); output: $(printf '%s' "$out" | head -6 | tr '\n' ' ' | cut -c1-400)"
    elif [ "$rc" != "1" ]; then
        fail "$label — $tok emitted but exit code was $rc, not 1: $line"
    elif [ -n "$subj" ] && ! printf '%s' "$line" | grep -qF "$subj"; then
        fail "$label — $tok fired but never names $subj: $line"
    else
        pass "$label"
    fi
}
