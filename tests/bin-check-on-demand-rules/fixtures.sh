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

# write_policy <dir> <on_demand_json> <expected_json>
write_policy() {
    mkdir -p "$1/hooks/lib"
    cat > "$1/hooks/lib/rules-injection-policy.js" <<POLICY_EOF
"use strict";
const ON_DEMAND_TOKEN = "$TOKEN";
// suffix-tight on purpose: \b alone does not stop \`on-demand-only-ish\`, because the
// boundary between \`y\` and \`-\` IS a word boundary. See cases-marker.sh K3/K4.
const ON_DEMAND_MARKER_RE = /<!--\s*injection:\s*on-demand-only(?!-?\w)/;
const ON_DEMAND_FILES = $2;
const EXPECTED_UNCONDITIONAL = $3;
module.exports = { ON_DEMAND_TOKEN, ON_DEMAND_MARKER_RE, ON_DEMAND_FILES, EXPECTED_UNCONDITIONAL };
POLICY_EOF
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
