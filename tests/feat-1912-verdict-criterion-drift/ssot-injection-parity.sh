#!/usr/bin/env bash
# tests/feat-1912-verdict-criterion-drift/ssot-injection-parity.sh
# Tests: skills/_shared/issue-verdict-cascade.md, agents/issue-create-survey-worker.md, bin/github-issues/review-survey-verdict-codex.sh
# Tags: issue-create, verdict, cascade, ssot, prompt-assembly, parity, drift, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Whether the survey worker's Read of the path actually succeeds at runtime (it runs as
#   a Claude subagent). What is pinned here is that the path it is handed resolves, under
#   the same config dir, to the very bytes the reviewer is handed.
# - Whether the DEPLOYED $HOME/.claude copy matches the worktree copy.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Section of tests/feat-1912-verdict-criterion-drift.sh (subprocess; tests/lib/section-runner.sh).
#
# Why this file exists (CPR-WPH): the cascade is an SSOT only if both graders read the
# same bytes. The parent file proves each side REFERENCES the file — the worker names the
# path, the reviewer `cat`s it — and that the 2-column table survives the trip. Neither is
# the property that matters. A reviewer handed a truncated cascade, or a worker pointed at
# a stale sibling copy, satisfies every one of those checks while the two sides decide by
# different rules; and the failure is invisible, because each verdict on its own is
# well-formed. So this file compares the INJECTED TEXT itself:
#
#   V  the reviewer's prompt contains the cascade file verbatim and contiguous
#   W  the path the worker is given resolves to that same file, byte for byte
#   X  neither grader carries a SECOND copy — checked structurally (headings, rule IDs,
#      table rows), never by line length. A long line is not a copy and a short one is
#      not a reference; only the cascade's own structural landmarks answer the question.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

CASCADE="$AGENTS_DIR/skills/_shared/issue-verdict-cascade.md"
WORKER_MD="$AGENTS_DIR/agents/issue-create-survey-worker.md"
CODEX_SH="$AGENTS_DIR/bin/github-issues/review-survey-verdict-codex.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "=== V: the reviewer's prompt carries the cascade verbatim and contiguous ==="

# The prompt is built in a 0600 temp file and deleted on exit, so it can only be observed
# from inside the run. The mock codex reads it from stdin and keeps a copy.
MOCKDIR="$WORK/bin"; mkdir -p "$MOCKDIR"
cat > "$MOCKDIR/codex" <<'MOCK'
#!/usr/bin/env bash
cat > "${CODEX_PROMPT_LOG:-/dev/null}"
printf '%s\n' 'FINAL_VERDICT_JSON:'
printf '%s\n' '{"verdict":"none","target":null,"children":[],"related":[],"reason":"no overlap","worth_filing":true,"same_fix":false}'
MOCK
chmod +x "$MOCKDIR/codex"

ART="$WORK/survey.json"
"$RWT" 15 node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({
  schema_version: 3,
  proposal: { title: "P", background: "B", changes: "C" },
  verdict: "none", target: null, children: [], related: [],
  reason: "survey reason", same_fix: false,
  relations_mode: "batched", relation_errors: [],
  candidates: [
    { number: 10, title: "c10", state: "open", labels: [], body: "b10",
      relation_status: "resolved", parent_number: null, parent_is_meta: false, has_sub_issues: false }
  ]
}, null, 2));' "$(node_path "$ART")"

PROMPT="$WORK/prompt.txt"
: > "$PROMPT"
if [ -f "$CODEX_SH" ]; then
    CODEX_PROMPT_LOG="$PROMPT" PATH="$MOCKDIR:$PATH" \
        "$RWT" 60 bash "$CODEX_SH" --artifact "$ART" --out "$WORK/final.json" --no-log \
        >/dev/null 2>&1 || true
fi

if [ -s "$PROMPT" ]; then
    pass "V1-prompt-captured"
else
    fail "V1-prompt-captured" "the mock codex received no prompt (review-survey-verdict-codex.sh present=$([ -f "$CODEX_SH" ] && echo yes || echo no)) — every case below reads it"
fi

# Locate the injected region by the cascade's own first line, then compare the next N
# lines against the file. This is the whole concern: an equality on the TEXT catches a
# truncation, a re-wrap, a paraphrase and a stale copy alike, none of which a "does the
# prompt mention the cascade" check can see. Contiguity matters too — a cascade whose
# rules were interleaved with other prompt material is no longer an ordered cascade.
INJECTED="$WORK/injected.txt"
: > "$INJECTED"
if [ -s "$PROMPT" ] && [ -f "$CASCADE" ]; then
    CFIRST="$(sed -n '1p' "$CASCADE")"
    CN=$(grep -c '' "$CASCADE")
    START=$(grep -nxF -- "$CFIRST" "$PROMPT" 2>/dev/null | head -n 1 | cut -d: -f1)
    if [ -n "${START:-}" ]; then
        sed -n "${START},$((START + CN - 1))p" "$PROMPT" > "$INJECTED"
    fi
fi

if [ -s "$INJECTED" ] && diff -q "$CASCADE" "$INJECTED" >/dev/null 2>&1; then
    pass "V2-injected-cascade-is-byte-identical-to-the-ssot"
else
    fail "V2-injected-cascade-is-byte-identical-to-the-ssot" "the reviewer's prompt does not contain the cascade verbatim and contiguous; first differing lines: $(diff "$CASCADE" "$INJECTED" 2>&1 | head -n 6 | tr '\n' ' ')"
fi

# Non-vacuity: V2 compares a slice of the prompt against the file, so it would also pass
# if the prompt were nothing BUT the cascade — in which case the reviewer never received
# its instructions. The cascade must be embedded in a larger prompt.
PN=$(grep -c '' "$PROMPT" 2>/dev/null || printf 0)
CN2=$(grep -c '' "$CASCADE" 2>/dev/null || printf 0)
if [ "$PN" -gt "$CN2" ] && [ "$CN2" -gt 0 ]; then
    pass "V3-cascade-is-embedded-in-a-larger-prompt"
else
    fail "V3-cascade-is-embedded-in-a-larger-prompt" "prompt lines=$PN cascade lines=$CN2 — the cascade must be one part of the reviewer's prompt, not the whole of it"
fi

echo ""
echo "=== W: the worker is pointed at the SAME file the reviewer was handed ==="

# The worker receives a path, not text: it is a subagent that Reads the file at run time.
# So the comparable artifact on its side is the file that path resolves to. `$agents_config_dir`
# is the worker's name for what this test calls $AGENTS_DIR — the caller passes it in — so
# it is substituted rather than treated as an unresolvable variable.
WPATH_RAW=""
if [ -f "$WORKER_MD" ]; then
    WPATH_RAW="$(grep -oE '[^` ]*issue-verdict-cascade\.md' "$WORKER_MD" | head -n 1)"
fi
WPATH=""
if [ -n "$WPATH_RAW" ]; then
    WPATH="${WPATH_RAW/\$agents_config_dir/$AGENTS_DIR}"
    WPATH="${WPATH/\$\{agents_config_dir\}/$AGENTS_DIR}"
    WPATH="${WPATH/\$AGENTS_CONFIG_DIR/$AGENTS_DIR}"
fi

if [ -n "$WPATH_RAW" ]; then
    pass "W1-worker-names-a-cascade-path"
else
    fail "W1-worker-names-a-cascade-path" "the survey worker must name the cascade file by path; without one there is nothing to compare"
fi

if [ -n "$WPATH" ] && [ -f "$WPATH" ]; then
    pass "W2-worker-path-resolves-to-a-real-file"
else
    fail "W2-worker-path-resolves-to-a-real-file" "the worker's cascade path does not resolve under the agents config dir (raw: '${WPATH_RAW:-<none>}' → '${WPATH:-<none>}') — the worker would Read nothing and decide with no cascade at all"
fi

# The parity itself. Two graders, one text. Compared against the INJECTED copy rather than
# against $CASCADE, so this case fails when either side drifts — including the case where
# the reviewer's injection is stale but the worker's path is fine.
if [ -n "$WPATH" ] && [ -f "$WPATH" ] && [ -s "$INJECTED" ] \
   && diff -q "$WPATH" "$INJECTED" >/dev/null 2>&1; then
    pass "W3-both-graders-receive-the-same-cascade-text"
else
    fail "W3-both-graders-receive-the-same-cascade-text" "the text the worker Reads and the text injected into the reviewer's prompt differ (worker path: ${WPATH:-<unresolved>}); diff: $(diff "${WPATH:-/dev/null}" "$INJECTED" 2>&1 | head -n 6 | tr '\n' ' ')"
fi

echo ""
echo "=== X: neither grader carries a second copy — structural, not line-length ==="

# Why structural: the previous heuristic for "has the worker restated the cascade?" was
# the LENGTH of the line carrying each rule ID (>120 chars ⇒ assumed a restatement). Length
# is not evidence in either direction — a one-line paraphrase of IC-C1 is a full second
# copy at 90 characters, and a long line that merely cites the file is not a copy at all.
# The cascade's structural landmarks are: its `## ` headings, its rule-ID headings, and its
# 2-column table rows. Those are what a copy necessarily brings with it.

# cascade_headings: the section headings, normalised (leading #s and whitespace stripped).
cascade_headings() {
    [ -f "$CASCADE" ] || return 0
    sed -n 's/^##*[[:space:]]*//p' "$CASCADE" | sed -n '/./p'
}

# table_rows: the same parser the parent file uses, so "a copy of the table" means the
# same thing in both places.
table_rows() {
    [ -f "$1" ] || return 0
    awk -F'|' '
      /^[[:space:]]*\|/ && NF >= 3 {
        v = $2; b = $3;
        gsub(/[ \t`]/, "", v); gsub(/[ \t`]/, "", b);
        if (b == "true" || b == "false") print v "=" b;
      }' "$1" | LC_ALL=C sort
}

HEADCOUNT=$(cascade_headings | grep -c . || true)
if [ "${HEADCOUNT:-0}" -ge 4 ]; then
    pass "X0-cascade-has-structural-landmarks-to-look-for"
else
    fail "X0-cascade-has-structural-landmarks-to-look-for" "the cascade exposes only ${HEADCOUNT:-0} heading(s); X1/X2 below would be vacuous"
fi

# X1/X2: a grader file may CITE the cascade, but reproducing its headings means the rules
# have been restated locally — and the local copy is the one that drifts, silently, while
# every path-reference check keeps passing.
check_no_heading_copy() {  # <label> <file>
    local label="$1" f="$2" hits=""
    if [ ! -f "$f" ]; then
        fail "$label" "file not found: $f"
        return
    fi
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        # Heading text only, matched literally and whole-line-anchored at the start of a
        # markdown heading or a bullet: a passing MENTION of "IC-C1" is a citation, while
        # a heading line reproducing "IC-C1 — reopen (highest priority)" is a copy.
        if grep -qF -- "$h" "$f" 2>/dev/null; then
            hits="$hits[$h] "
        fi
    done <<EOF
$(cascade_headings)
EOF
    if [ -z "$hits" ]; then
        pass "$label"
    else
        fail "$label" "cascade section heading(s) reproduced outside the SSOT: $hits"
    fi
}

check_no_heading_copy "X1-worker-does-not-reproduce-cascade-headings" "$WORKER_MD"
check_no_heading_copy "X2-codex-does-not-reproduce-cascade-headings" "$CODEX_SH"

# X3/X4: the table rows, for the same reason and by the same parser. This is the check the
# `same_fix` values would drift through, and it is independent of the headings above: a
# copy can arrive as a bare table with no headings at all.
for pair in "X3-worker:$WORKER_MD" "X4-codex:$CODEX_SH"; do
    label="${pair%%:*}"; f="${pair#*:}"
    rows="$(table_rows "$f" | tr '\n' ' ')"
    if [ -z "$rows" ]; then
        pass "${label}-does-not-copy-the-same-fix-table"
    else
        fail "${label}-does-not-copy-the-same-fix-table" "same_fix table rows found outside the SSOT: $rows"
    fi
done

# X5: the counterweight that keeps X1–X4 from being satisfiable by silence. A file that
# neither copies NOR references the cascade passes every case above; the point of the
# non-duplication rule is single-sourcing, not absence.
for pair in "X5-worker:$WORKER_MD" "X6-codex:$CODEX_SH"; do
    label="${pair%%:*}"; f="${pair#*:}"
    if [ -f "$f" ] && grep -qF 'issue-verdict-cascade' "$f"; then
        pass "${label}-still-references-the-ssot"
    else
        fail "${label}-still-references-the-ssot" "$f neither copies the cascade nor references it — non-duplication is satisfied by single-sourcing, not by dropping the rules"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
