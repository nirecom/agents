# shellcheck shell=bash
# Tests: agents/survey-code.md, agents/detail-planner.md, agents/outline-planner.md, agents/detail-reviewer.md, agents/outline-reviewer.md, agents/security-scanner.md, agents/test-reviewer.md, agents/skip-verifier.md, agents/plan-security-reviewer.md, agents/lib/codegraph-usage.md
# Tags: codegraph, wiring, static, agent-frontmatter, mcp, table-driven, TL2, pwsh-not-required, scope:issue-specific
# W7 — agent exposure. Claude Code has no shared base tool list for agent definitions,
# so the nine allowlists are nine independent places to forget. A grep for the tool
# name cannot tell an allowlist entry from a mention in prose, cannot see that the
# frontmatter block itself is malformed, and cannot see a duplicated entry — so the
# nine files are parsed as real frontmatter and the tools: value is compared as a
# list of discrete entries.

echo "=== W7: the nine adopting agents (frontmatter parsed, entries counted) ==="

AGENT_FM_JS='
const fs = require("fs");
const path = require("path");
const RE = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(?:\r?\n|$)/;
const TOOL = "mcp__codegraph__codegraph_explore";
const PTR = "agents/lib/codegraph-usage.md";
const root = process.argv[1];
const out = [];
for (const rel of process.argv.slice(2)) {
  let text;
  try {
    text = fs.readFileSync(path.join(root, rel), "utf8");
  } catch (e) {
    out.push(rel + "|UNREADABLE|0|0|");
    continue;
  }
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  const m = RE.exec(text);
  if (!m) {
    out.push(rel + "|NO_FRONTMATTER|0|0|");
    continue;
  }
  const body = text.slice(m[0].length);
  const ptrCount = body.split(PTR).length - 1;
  const keys = m[1].split(/\r?\n/).filter((l) => /^tools:/.test(l));
  if (keys.length !== 1) {
    out.push(rel + "|TOOLS_KEYS_" + keys.length + "|0|" + ptrCount + "|");
    continue;
  }
  const entries = keys[0]
    .slice("tools:".length)
    .split(",")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  const toolCount = entries.filter((s) => s === TOOL).length;
  out.push(rel + "|OK|" + toolCount + "|" + ptrCount + "|" + entries.join(" "));
}
process.stdout.write(out.join("\n") + "\n");
'

# The third column is the WHOLE expected tools: list, in the order detail plan ST-8
# fixes it (pre-existing entries unchanged, the CodeGraph tool appended). Counting the
# new entry alone cannot see a lost one — an edit that replaced a nine-tool allowlist
# with the single CodeGraph tool would satisfy a count of 1 and silently strip Read,
# Glob and Grep from that agent.
W7_ROWS=()
while IFS='|' read -r name rel want; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    W7_ROWS+=("$name|$(trim "$rel")|$(trim "$want")")
done <<'W7_TABLE'
W7-01 | agents/survey-code.md           | Read Glob Grep Bash Write mcp__codegraph__codegraph_explore
W7-02 | agents/detail-planner.md        | Read Glob Grep Bash WebFetch Write mcp__codegraph__codegraph_explore
W7-03 | agents/outline-planner.md       | Read Glob Grep Bash WebFetch Write mcp__codegraph__codegraph_explore
W7-04 | agents/detail-reviewer.md       | Read Glob Grep mcp__codegraph__codegraph_explore
W7-05 | agents/outline-reviewer.md      | Read Glob Grep mcp__codegraph__codegraph_explore
W7-06 | agents/security-scanner.md      | Read Glob Grep Bash mcp__codegraph__codegraph_explore
W7-07 | agents/test-reviewer.md         | Read Glob Grep mcp__codegraph__codegraph_explore
W7-08 | agents/skip-verifier.md         | Read Glob Grep Bash mcp__codegraph__codegraph_explore
W7-09 | agents/plan-security-reviewer.md| Read Glob Grep mcp__codegraph__codegraph_explore
W7_TABLE

AGENT_FM_OUT="$TMPDIR_LOCAL/agent-frontmatter.txt"
: > "$AGENT_FM_OUT"
W7_ARGS=()
for row in "${W7_ROWS[@]}"; do
    rest="${row#*|}"
    W7_ARGS+=("${rest%%|*}")
done

if ! command -v node >/dev/null 2>&1; then
    fail "W7-00: node is not on PATH" "the nine agent files must be parsed as frontmatter, not grepped; this environment cannot run the check"
else
    bash "$AGENTS_DIR/bin/run-with-timeout.sh" 120 node -e "$AGENT_FM_JS" \
        "$(nodepath "$AGENTS_DIR")" "${W7_ARGS[@]}" > "$AGENT_FM_OUT" 2> "$TMPDIR_LOCAL/w7.err" || true
    if [ -s "$TMPDIR_LOCAL/w7.err" ]; then
        fail "W7-00: the frontmatter parser itself failed" "$(head -1 "$TMPDIR_LOCAL/w7.err")"
    fi
fi

for row in "${W7_ROWS[@]}"; do
    name="${row%%|*}"
    rest="${row#*|}"
    rel="${rest%%|*}"
    want_tools="${rest#*|}"
    line="$(grep -m1 -F -e "$rel|" "$AGENT_FM_OUT" 2>/dev/null || true)"
    status="$(printf '%s' "$line" | cut -d'|' -f2)"
    ntool="$(printf '%s' "$line" | cut -d'|' -f3)"
    nptr="$(printf '%s' "$line" | cut -d'|' -f4)"
    entries="$(printf '%s' "$line" | cut -d'|' -f5)"
    assert_eq "$name-a: $rel parses as frontmatter with exactly one tools: key" "OK" "${status:-NO_PARSER_OUTPUT}"
    assert_eq "$name-b: $rel lists mcp__codegraph__codegraph_explore exactly once as a discrete tools: entry (got: ${entries:-<none>})" "1" "${ntool:-0}"
    assert_eq "$name-c: $rel points at agents/lib/codegraph-usage.md exactly once in its body" "1" "${nptr:-0}"
    assert_eq "$name-d: $rel keeps its whole pre-existing tools: list and appends only the CodeGraph tool" \
        "$want_tools" "${entries:-<none>}"
done

# W10 — the shared policy the nine pointers resolve to. W7-c only proves the pointer
# is spelled; a pointer at a file that does not exist, or at an empty stub, hands nine
# agents a tool with no contract — and the projectPath caveat is the single prompt-level
# defence against silently planning and reviewing against main instead of the worktree.
echo "=== W10: agents/lib/codegraph-usage.md exists and carries its three requirements ==="

USAGE_REL="agents/lib/codegraph-usage.md"
USAGE_ABS="$AGENTS_DIR/$USAGE_REL"
if [ ! -f "$USAGE_ABS" ]; then
    fail "W10-00: $USAGE_REL does not exist" "nine agents point at it; a dangling pointer is exposure without adoption"
elif [ ! -s "$USAGE_ABS" ]; then
    fail "W10-00: $USAGE_REL exists but is empty" "an empty policy file satisfies every pointer assertion and states no contract"
else
    pass "W10-00: $USAGE_REL exists and is non-empty ($(wc -c < "$USAGE_ABS" | tr -d ' ') bytes)"
fi

# The tool name is the one string that must be spelled exactly — a typo here exposes
# nine agents to a name no MCP server answers to.
assert_contains "W10-01" "$USAGE_REL" "mcp__codegraph__codegraph_explore"

# W10-02..04 assert the substance, not the section labels. A heading search passes on a
# heading with an empty body, on a truncated sentence, and on an instruction reversed
# into its opposite — all three ship nine agents a policy that says nothing or says the
# wrong thing. Each row therefore requires several concepts to co-occur inside ONE
# section (a section starts at a heading or a numbered item), so the terms cannot be
# satisfied by scattering them across unrelated sentences. Matching is case-folded and
# each concept is an alternation, so wording stays the author's choice; only the
# contract is fixed.
# assert_policy_section <name> <rel> <why> <re1> <re2> [re3] [re4]
assert_policy_section() {
    local name="$1" rel="$2" why="$3"; shift 3
    local abs="$AGENTS_DIR/$rel"
    if [ ! -f "$abs" ]; then
        fail "$name: $rel is absent" "$why"
        return
    fi
    local hits
    hits="$(awk -v r1="${1:-}" -v r2="${2:-}" -v r3="${3:-}" -v r4="${4:-}" '
        function check(rec) {
            if (rec == "") return
            if (r1 != "" && rec !~ r1) return
            if (r2 != "" && rec !~ r2) return
            if (r3 != "" && rec !~ r3) return
            if (r4 != "" && rec !~ r4) return
            n++
        }
        /^[[:space:]]*(#+[[:space:]]|[0-9]+\.[[:space:]])/ { check(rec); rec = "" }
        { rec = rec "\n" tolower($0) }
        END { check(rec); print n + 0 }
    ' "$abs" 2>/dev/null || true)"
    if [ "${hits:-0}" -ge 1 ]; then
        pass "$name: $rel states this contract inside one section"
    else
        fail "$name: $rel has no single section carrying all of /${1:-}/ /${2:-}/ /${3:-}/ /${4:-}/" "$why"
    fi
}

assert_policy_section "W10-02" "$USAGE_REL" \
    "projectPath pointing at main is the one failure mode that returns a plausible answer instead of an error; a policy that names the parameter without that warning leaves nine agents planning and reviewing against main" \
    "projectpath" "worktree" "main" "(silent|quiet|fail|error)"

assert_policy_section "W10-03" "$USAGE_REL" \
    "with CODEGRAPH=off the tool is absent by design; unless the policy names Read and Grep as the fallback and forbids blocking, absence turns into a stalled agent" \
    "(absen|unavailable|not available|missing|no index|off)" "read" "grep" "(never block|not block|do not block|fall ?back|fallback)"

assert_policy_section "W10-04" "$USAGE_REL" \
    "agents that record evidence must re-read the file:line before citing it; codegraph output quoted straight into an artifact is evidence nobody verified" \
    "evidence" "read" "(file:line|line number|verif|confirm|check)"
