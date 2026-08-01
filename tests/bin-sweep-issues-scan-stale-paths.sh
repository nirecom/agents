#!/bin/bash
# tests/bin-sweep-issues-scan-stale-paths.sh
# Tests: bin/sweep-issues/scan-stale-paths.js
# Tags: sweep, issues, detector, stale-paths, scope:common, TL1
#
# TL1 tests for the SI-2 path-token stale detector.
#
# Contract under test (pure stdin → stdout; no network, no gh):
#   stdin  : a `gh issue list --json number,title,body` shaped JSON array
#   stdout : headerless TSV — number / status / missing_count / total_count / tokens_csv
#   status : stale (>=1 token, all missing) | live (>=1 token exists) | no-tokens
#   flags  : --repo-root <dir> (existence probe root), --all (emit non-stale rows too)
#   exits  : 0 normally; 2 on unparseable JSON (message on stderr)
#
# Token regex under test:
#   \b(bin|hooks|skills|tests|rules|agents|install|docs)\/[A-Za-z0-9._/-]+\.(js|sh|md|py|ps1|json)\b
# with trailing `.` `,` `)` stripped, tokens containing `..` discarded, and
# duplicates normalized to one.
#
# Table-driven per skills/_shared/test-design/parser-regex-tests.md — this file's
# target is registered in bin/check-table-driven.sh PARSER_TARGETS.
#
# The 5th column (tokens_csv) is the contract seam that feeds column 2 of the
# survivors TSV, so it must never contain a tab (case 12).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$AGENTS_DIR/bin/sweep-issues/scan-stale-paths.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# ── Fixture repo root: only these two paths exist ────────────────────────────
REPO_ROOT="$TMPDIR_BASE/repo"
mkdir -p "$REPO_ROOT/bin" "$REPO_ROOT/skills/foo"
printf '#!/bin/bash\n' > "$REPO_ROOT/bin/existing.sh"
printf '# SKILL\n'     > "$REPO_ROOT/skills/foo/SKILL.md"

# Normalize captured stdout for comparison: TAB → '>', NL → ';', empty → <empty>.
normalize() {
    local s="$1"
    [ -z "$s" ] && { printf '<empty>'; return; }
    printf '%s' "$s" | tr '\t' '>' | tr '\n' ';'
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

if [ ! -f "$SCANNER" ]; then
    fail "setup: detector not found at $SCANNER (bin/sweep-issues/scan-stale-paths.js is not implemented yet)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Table columns (IFS='|'):
#   name     — case label, injected into the assertion message
#   flags    — extra CLI flags, or '-' for none
#   json     — stdin payload (compact JSON array)
#   want_rc  — expected exit code
#   want_out — expected normalized stdout ('>' = TAB, ';' = NL, <empty> = none)
#   want_err — 'nonempty' if stderr must carry a message, '-' otherwise
# ─────────────────────────────────────────────────────────────────────────────

while IFS='|' read -r name flags json want_rc want_out want_err; do
    [[ -z "${name// /}" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"
    flags="$(trim "$flags")"
    json="$(trim "$json")"
    want_rc="$(trim "$want_rc")"
    want_out="$(trim "$want_out")"
    want_err="$(trim "$want_err")"

    argv=(--repo-root "$REPO_ROOT")
    [ "$flags" != "-" ] && argv+=("$flags")

    errf="$TMPDIR_BASE/stderr.txt"
    got_out="$(printf '%s' "$json" | run_with_timeout node "$SCANNER" "${argv[@]}" 2>"$errf")"
    got_rc=$?
    got_err="$(cat "$errf" 2>/dev/null || true)"
    got_norm="$(normalize "$got_out")"

    problems=""
    [ "$got_rc" != "$want_rc" ] && problems="$problems [rc=$got_rc want=$want_rc]"
    [ "$got_norm" != "$want_out" ] && problems="$problems [out=$got_norm want=$want_out]"
    if [ "$want_err" = "nonempty" ] && [ -z "${got_err// /}" ]; then
        problems="$problems [stderr empty, expected a diagnostic]"
    fi

    if [ -z "$problems" ]; then
        pass "$name"
    else
        fail "$name —$problems"
    fi
done <<'TABLE'
# 1. single missing token → stale
missing-token-only    | -     | [{"number":1,"title":"t","body":"broken bin/nonexistent.sh here"}]                     | 0 | 1>stale>1>1>bin/nonexistent.sh                       | -
# 2. existing token → suppressed by default, reported as live under --all
existing-token-hidden | -     | [{"number":2,"title":"t","body":"see bin/existing.sh"}]                                | 0 | <empty>                                              | -
existing-token-all    | --all | [{"number":2,"title":"t","body":"see bin/existing.sh"}]                                | 0 | 2>live>0>1>bin/existing.sh                           | -
# 3. one existing among missing → live (never a close candidate)
mixed-is-live         | --all | [{"number":3,"title":"t","body":"bin/existing.sh and bin/gone.sh"}]                    | 0 | 3>live>1>2>bin/existing.sh,bin/gone.sh               | -
# 4. no path tokens at all
no-tokens-hidden      | -     | [{"number":4,"title":"plain","body":"nothing path-like here"}]                         | 0 | <empty>                                              | -
no-tokens-all         | --all | [{"number":4,"title":"plain","body":"nothing path-like here"}]                         | 0 | 4>no-tokens>0>0>                                     | -
# 5. tokens in the title are scanned too
title-token-scanned   | -     | [{"number":5,"title":"fix bin/from-title.sh","body":"no path here"}]                   | 0 | 5>stale>1>1>bin/from-title.sh                        | -
# 6. empty input array → no output, exit 0
empty-array           | -     | []                                                                                     | 0 | <empty>                                              | -
# 7. malformed JSON → exit 2 with a stderr diagnostic
malformed-json        | -     | {not json                                                                              | 2 | <empty>                                              | nonempty
# 8. trailing punctuation is stripped off the token
trailing-punctuation  | -     | [{"number":8,"title":"t","body":"see `bin/foo.sh`, and (bin/bar.sh)."}]                | 0 | 8>stale>2>2>bin/foo.sh,bin/bar.sh                    | -
# 9. path-traversal tokens are discarded outright
dotdot-discarded      | --all | [{"number":9,"title":"t","body":"bin/../../etc/passwd.sh"}]                            | 0 | 9>no-tokens>0>0>                                     | -
# 10. out-of-scope extension and out-of-scope top dir are not tokens
out-of-scope-token    | --all | [{"number":10,"title":"t","body":"bin/foo.txt and src/foo.js"}]                        | 0 | 10>no-tokens>0>0>                                    | -
# 11. duplicate mentions of the same token count once
duplicate-token-once  | -     | [{"number":11,"title":"bin/dup.sh","body":"bin/dup.sh again bin/dup.sh"}]              | 0 | 11>stale>1>1>bin/dup.sh                              | -
# 12. tokens_csv is comma-separated and tab-free (feeds survivors TSV column 2)
tokens-csv-tab-free   | -     | [{"number":12,"title":"t","body":"bin/a.sh hooks/b.js skills/c.md"}]                   | 0 | 12>stale>3>3>bin/a.sh,hooks/b.js,skills/c.md         | -
TABLE

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
