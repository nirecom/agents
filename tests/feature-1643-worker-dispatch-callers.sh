#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-callers.sh
# Tests: skills/_shared/worker-dispatch.md, hooks/lib/worker-dispatch-registry.js, skills/run-tests/SKILL.md, skills/worktree-start/SKILL.md, skills/worktree-end/SKILL.md, skills/worktree-end/scripts/cleanup-cascade.md, skills/update-docs/SKILL.md, skills/issue-reconcile/SKILL.md, skills/session-close/SKILL.md
# Tags: worker-dispatch, callers, skill-orchestration, static, regression, TL1, scope:issue-specific
#
# Issue #1643 — caller-side contract. Six LLM subagents were deleted and replaced
# by plain scripts behind one dispatcher; each calling skill now dispatches per
# skills/_shared/worker-dispatch.md instead of spawning a subagent.
#
# The regression that matters is the SYMMETRIC NEGATIVE: a caller left pointing at
# a deleted agents/*.md, or still using the Task/Agent tool, would fail only at
# run time inside a live session. The worker list is read from the registry SSOT
# (hooks/lib/worker-dispatch-registry.js), and the table below must cover it
# exactly — so a seventh worker cannot be added without a caller row here.
#
# TL1 (static): the subject is prompt text and a pure-data registry, both of which
# this test reads directly. Behavior of the dispatcher itself is covered by
# tests/feature-1643-worker-dispatch-output-contract.sh and the resolver by
# tests/feature-1643-worker-dispatch-paths.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"
SHARED_REL="skills/_shared/worker-dispatch.md"
SHARED_MD="$AGENTS_DIR/$SHARED_REL"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-callers-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# caller-rel | worker | step-label | start-line-prefix | end-line-prefix
# Anchors are literal line prefixes (not regexes) so that `+` and `.` in step
# labels cannot be reinterpreted as regex metacharacters.
CALLER_TABLE='skills/run-tests/SKILL.md|test-runner|RNT-7|RNT-7.|RNT-8.
skills/worktree-start/SKILL.md|worktree-copy|WS-7|WS-7.|WS-8.
skills/worktree-end/SKILL.md|worktree-backup|WE-9|### Step WE-9|### Step WE-10
skills/update-docs/SKILL.md|doc-append|UD-9a/UD-9b|UD-9a.|UD-9c.
skills/worktree-end/scripts/cleanup-cascade.md|doc-append|WE-21|## WE-21|## WE-22
skills/issue-reconcile/SKILL.md|issue-reconcile|Step 2|## Step 2|## Step 3
skills/session-close/SKILL.md|session-close-gate|SC-4+SC-5|## Steps SC-4+SC-5|## Step SC-6'

has_prefix_line() {
    awk -v p="$2" 'substr($0, 1, length(p)) == p { found = 1; exit } END { exit !found }' "$1"
}

# Block = [start-prefix, end-prefix). A never-matching end anchor would swallow
# the rest of the file and turn every scoped grep into a false green, so the
# caller of this helper asserts the end anchor exists independently.
extract_block() {
    awk -v s="$2" -v e="$3" '
        function pre(line, p) { return substr(line, 1, length(p)) == p }
        !inb && pre($0, s) { inb = 1 }
        inb && seen && pre($0, e) { exit }
        inb { seen = 1; print }
    ' "$1"
}

# ===========================================================================
# Group A — the table covers the registry SSOT exactly
# ===========================================================================
group_table_covers_registry() {
    if [ ! -f "$REGISTRY_JS" ]; then
        fail "A1: hooks/lib/worker-dispatch-registry.js missing"
        return
    fi
    local registry_names table_names
    registry_names=$(run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      process.stdout.write(reg.WORKER_NAMES.slice().sort().join(","));
    ' "$(nodepath "$REGISTRY_JS")" 2>&1)
    table_names=$(printf '%s\n' "$CALLER_TABLE" | cut -d'|' -f2 | sort -u | tr '\n' ',' | sed 's/,$//')
    if [ -n "$registry_names" ] && [ "$registry_names" = "$table_names" ]; then
        pass "A1: caller table covers exactly the registry worker names ($registry_names)"
    else
        fail "A1: caller table / registry drift" "registry='$registry_names' table='$table_names'"
    fi
}

# ===========================================================================
# Group B — each caller dispatches its worker via the shared protocol
# ===========================================================================
group_caller_rows() {
    local rel worker label start end path block blockfile lines
    while IFS='|' read -r rel worker label start end; do
        [ -z "${rel// /}" ] && continue
        path="$AGENTS_DIR/$rel"
        if [ ! -f "$path" ]; then
            fail "B/$label: caller $rel missing"
            continue
        fi
        # Whole-file: the shared protocol must be referenced at all.
        if grep -qF "$SHARED_REL" "$path"; then
            pass "B/$label: $rel references $SHARED_REL"
        else
            fail "B/$label: $rel does not reference $SHARED_REL"
        fi

        if ! has_prefix_line "$path" "$end"; then
            fail "B/$label: end anchor '$end' not found in $rel (block scoping unreliable)"
            continue
        fi
        blockfile="$TMPD/block-$(printf '%s' "$rel-$label" | tr '/.+ ' '____').md"
        extract_block "$path" "$start" "$end" > "$blockfile"
        lines=$(wc -l < "$blockfile" | tr -d '[:space:]')
        [ -n "$lines" ] || lines=0
        if [ "$lines" -eq 0 ]; then
            fail "B/$label: start anchor '$start' not found in $rel"
            continue
        fi
        if [ "$lines" -gt 40 ]; then
            fail "B/$label: extracted block is $lines lines — scoping looks broken"
            continue
        fi
        block="$(cat "$blockfile")"
        local has_worker has_shared
        has_worker=0; has_shared=0
        printf '%s' "$block" | grep -qF "$worker" && has_worker=1
        printf '%s' "$block" | grep -qF "$SHARED_REL" && has_shared=1
        if [ "$has_worker" -eq 1 ] && [ "$has_shared" -eq 1 ]; then
            pass "B/$label: step names worker '$worker' and dispatches per $SHARED_REL"
        else
            fail "B/$label: step dispatch incomplete" "worker=$has_worker shared=$has_shared block='$block'"
        fi
    done <<TABLE
$CALLER_TABLE
TABLE
}

# ===========================================================================
# Group C — SYMMETRIC NEGATIVE: no caller still points at a deleted subagent
# ===========================================================================

# Legacy agent basenames derived from the registry worker names, not hardcoded:
#   <name>.md and <name>-worker.md, plus the -gate suffix variant
#   (session-close-gate replaced agents/session-close-worker.md).
legacy_agent_basenames() {
    run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      const out = new Set();
      for (const n of reg.WORKER_NAMES) {
        out.add(n + ".md");
        out.add(n + "-worker.md");
        const stripped = n.replace(/-gate$/, "");
        if (stripped !== n) out.add(stripped + "-worker.md");
      }
      process.stdout.write([...out].sort().join("\n"));
    ' "$(nodepath "$REGISTRY_JS")" 2>&1
}

group_no_legacy_agent_files() {
    local names missing_ok found
    names="$(legacy_agent_basenames)"
    if [ -z "$names" ]; then
        fail "C1: could not derive legacy agent basenames from the registry"
        return
    fi
    found=""
    while IFS= read -r n; do
        [ -z "$n" ] && continue
        [ -e "$AGENTS_DIR/agents/$n" ] && found="$found agents/$n"
    done <<< "$names"
    if [ -z "$found" ]; then
        pass "C1: no worker subagent .md file exists under agents/ (derived from the registry)"
    else
        fail "C1: deleted worker subagent file(s) present:$found"
    fi
}

group_explicit_six_deleted() {
    local six found n
    six="test-runner.md worktree-copy-worker.md worktree-backup-worker.md doc-append-worker.md issue-reconcile-worker.md session-close-worker.md"
    found=""
    for n in $six; do
        [ -e "$AGENTS_DIR/agents/$n" ] && found="$found agents/$n"
    done
    if [ -z "$found" ]; then
        pass "C2: all six #1643-deleted agents/*.md files are absent"
    else
        fail "C2: #1643-deleted agent file(s) still on disk:$found"
    fi
}

group_no_caller_references_legacy() {
    local names rel path hits n
    names="$(legacy_agent_basenames)"
    if [ -z "$names" ]; then
        fail "C3: could not derive legacy agent basenames from the registry"
        return
    fi
    hits=""
    while IFS='|' read -r rel _worker _label _start _end; do
        [ -z "${rel// /}" ] && continue
        path="$AGENTS_DIR/$rel"
        [ -f "$path" ] || continue
        while IFS= read -r n; do
            [ -z "$n" ] && continue
            grep -qF "agents/$n" "$path" && hits="$hits $rel->agents/$n"
        done <<< "$names"
    done <<TABLE
$CALLER_TABLE
TABLE
    if [ -z "$hits" ]; then
        pass "C3: no caller references a deleted worker subagent file"
    else
        fail "C3: caller(s) still reference deleted subagent file(s):$hits"
    fi
}

group_no_task_tool_dispatch() {
    local rel path hits
    hits=""
    while IFS='|' read -r rel _worker _label _start _end; do
        [ -z "${rel// /}" ] && continue
        path="$AGENTS_DIR/$rel"
        [ -f "$path" ] || continue
        if grep -qE 'subagent_type|Task tool|Agent tool' "$path"; then
            hits="$hits $rel"
        fi
    done <<TABLE
$CALLER_TABLE
TABLE
    if [ -z "$hits" ]; then
        pass "C4: no caller dispatches a worker via the Task/Agent tool"
    else
        fail "C4: Task/Agent tool dispatch found in:$hits"
    fi
}

# Mutation probe: prove C3/C4's detectors actually fire. A synthetic caller
# carrying both violations must be flagged by the same greps.
group_negative_detector_probe() {
    local synth="$TMPD/synthetic-caller.md" a=0 b=0
    printf '%s\n' \
        'XX-1. Dispatch the worker via `agents/doc-append-worker.md`.' \
        'Use the Task tool with subagent_type: doc-append-worker.' > "$synth"
    grep -qF 'agents/doc-append-worker.md' "$synth" && a=1
    grep -qE 'subagent_type|Task tool|Agent tool' "$synth" && b=1
    if [ "$a" -eq 1 ] && [ "$b" -eq 1 ]; then
        pass "C5: the C3/C4 detectors fire on a synthetic violating caller (mutation probe)"
    else
        fail "C5: negative detectors do not fire" "legacy-ref=$a task-tool=$b"
    fi
}

# ===========================================================================
# Group D — the shared protocol states the rules callers depend on
# ===========================================================================
group_shared_command_purity() {
    if [ ! -f "$SHARED_MD" ]; then
        fail "D1: $SHARED_REL missing"
        return
    fi
    local missing="" tok
    # Each forbidden addition to the WD-3 command must be named explicitly.
    grep -qF 'redirect' "$SHARED_MD" || missing="$missing redirect"
    grep -qF 'pipe' "$SHARED_MD" || missing="$missing pipe"
    grep -qF '&&' "$SHARED_MD" || missing="$missing &&"
    grep -qF '`;`' "$SHARED_MD" || missing="$missing semicolon"
    grep -qF '`cd`' "$SHARED_MD" || missing="$missing cd"
    grep -qF 'env prefix' "$SHARED_MD" || missing="$missing env-prefix"
    grep -qF '$VAR' "$SHARED_MD" || missing="$missing \$VAR"
    for tok in Never; do
        grep -qF "$tok" "$SHARED_MD" || missing="$missing $tok"
    done
    if [ -z "$missing" ]; then
        pass "D1: $SHARED_REL forbids redirect/pipe/&&/;/cd/env-prefix/\$VAR on the WD-3 command"
    else
        fail "D1: command-purity rule incomplete" "missing:$missing"
    fi
}

group_shared_exit_codes() {
    if [ ! -f "$SHARED_MD" ]; then
        fail "D2: $SHARED_REL missing"
        return
    fi
    local has_zero has_failed has_two
    has_zero=0; has_failed=0; has_two=0
    grep -qE 'Exit 0' "$SHARED_MD" && has_zero=1
    grep -qF 'status: failed' "$SHARED_MD" && has_failed=1
    grep -qE 'Exit 2' "$SHARED_MD" && has_two=1
    if [ "$has_zero" -eq 1 ] && [ "$has_failed" -eq 1 ] && [ "$has_two" -eq 1 ]; then
        pass "D2: $SHARED_REL documents exit 0 (rendered output incl. status: failed) and exit 2 (unusable invocation)"
    else
        fail "D2: exit-code contract incomplete" "exit0=$has_zero status-failed=$has_failed exit2=$has_two"
    fi
}

group_shared_payload_location() {
    if [ ! -f "$SHARED_MD" ]; then
        fail "D3: $SHARED_REL missing"
        return
    fi
    local writes_under refuses_outside
    writes_under=0; refuses_outside=0
    grep -qE 'PLANS_DIR>?/<session-id>-worker-' "$SHARED_MD" && writes_under=1
    grep -qE 'Never place the payload outside PLANS_DIR' "$SHARED_MD" && refuses_outside=1
    if [ "$writes_under" -eq 1 ] && [ "$refuses_outside" -eq 1 ]; then
        pass "D3: $SHARED_REL requires the payload to live under PLANS_DIR"
    else
        fail "D3: payload-location rule incomplete" "write-rule=$writes_under never-outside=$refuses_outside"
    fi
}

group_table_covers_registry
group_caller_rows
group_no_legacy_agent_files
group_explicit_six_deleted
group_no_caller_references_legacy
group_no_task_tool_dispatch
group_negative_detector_probe
group_shared_command_purity
group_shared_exit_codes
group_shared_payload_location

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
