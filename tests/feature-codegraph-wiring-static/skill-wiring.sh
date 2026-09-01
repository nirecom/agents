# shellcheck shell=bash
# Tests: skills/worktree-start/SKILL.md, skills/worktree-end/SKILL.md, skills/worktree-end/scripts/cleanup-cascade.md, skills/sweep-worktrees/SKILL.md, bin/sweep-worktrees.sh, bin/sweep-worktrees/orphan-dirs.sh
# Tags: codegraph, wiring, static, skill-orchestration, table-driven, TL2, pwsh-not-required, scope:issue-specific
# W5 — ordering inside the four skill documents. Same failure shape as W4-a: a step
# placed after the step it must precede reads fine and behaves wrong. The two rows
# per removal-path document bracket the new text between the heading that opens its
# section and the heading that closes it, which is the only static way to say
# "inside this section" about a Markdown file.

echo "=== W5: skill step and section ordering ==="

while IFS='|' read -r name rel early late why; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    assert_before "$name" "$(trim "$rel")" "$(trim "$early")" "$(trim "$late")" "$(trim "$why")"
done <<'W5_TABLE'
W5-01 | skills/worktree-start/SKILL.md | WS-7a | WS-8. | The index must be built before EnterWorktree, which can raise a confirmation dialog.
W5-02 | skills/worktree-end/scripts/cleanup-cascade.md | ## WE-14c | ## WE-15 | The daemon holds the index DB open; on Windows that file lock makes the WE-15 worktree removal fail with EPERM.
W5-03 | skills/worktree-end/SKILL.md | ### Steps WE-15..WE-22 | WE-14c | ST-13 puts the pointer inside the cleanup-cascade block; above that heading it reads as a step of the merge phase and nobody following the cascade sees it.
W5-04 | skills/worktree-end/SKILL.md | WE-14c | ## Rules | A pointer that lands in ## Rules is discoverable nowhere near the cascade it introduces, and the cascade is issued command-by-command from that block alone.
W5-05 | skills/sweep-worktrees/SKILL.md | ## Rules | CodeGraph index lock | ST-15 records the daemon-release obligation as a rule of this skill; above ## Rules the line is not a rule at all.
W5-06 | skills/sweep-worktrees/SKILL.md | CodeGraph index lock | ## Migration notes for #503 | The rule must stay inside ## Rules rather than drift into the migration notes, which are historical and not part of the skill contract.
W5_TABLE

# W6 — the deletion paths must each stop only THEIR OWN worktree's daemon. An
# unqualified call (no --path) reopens the C2 misfire surface from the other side:
# sweep processes several worktrees in one run, so <root>-old style siblings coexist.
echo "=== W6: sweep deletion paths pass --path ==="

while IFS='|' read -r name rel; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    rel="$(trim "$rel")"
    abs="$AGENTS_DIR/$rel"
    if [ ! -f "$abs" ]; then
        fail "$name: $rel is absent" "this file is edited, not created, by ST-14"
        continue
    fi
    n_all="$(grep -cF -e 'codegraph-lifecycle.js' "$abs" || true)"
    n_ok="$(grep -F -e 'codegraph-lifecycle.js' "$abs" | grep -F -e ' stop ' | grep -cF -e '--path' || true)"
    if [ "${n_all:-0}" -eq 0 ]; then
        fail "$name: $rel never invokes codegraph-lifecycle.js" "the deletion path leaves the index daemon holding the worktree"
    elif [ "${n_ok:-0}" -eq "${n_all:-0}" ]; then
        pass "$name: all ${n_ok} codegraph-lifecycle.js call(s) in $rel are 'stop ... --path'"
    else
        fail "$name: $rel has ${n_all} codegraph-lifecycle.js call(s) but only ${n_ok} carry both 'stop' and '--path'" \
             "an unqualified stop can match a sibling worktree's daemon"
    fi
done <<'W6_TABLE'
W6-01 | bin/sweep-worktrees.sh
W6-02 | bin/sweep-worktrees/orphan-dirs.sh
W6_TABLE

# W6-03 — duplicate-pointer guard for the two removal-path skill documents. ST-13 and
# ST-15 each add ONE line; a re-run of the same mechanical edit appends a second copy
# that reads as a contradiction to whoever follows the document.
while IFS='|' read -r name rel needle why; do
    name="$(trim "$name")"; [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    assert_count "$name" "$(trim "$rel")" "$(trim "$needle")" 1 "$(trim "$why")"
done <<'W6_DUP_TABLE'
W6-03 | skills/worktree-end/SKILL.md    | CodeGraph index lock | ST-13 adds one discovery pointer; a duplicate makes the cascade look like it releases the lock twice.
W6-04 | skills/sweep-worktrees/SKILL.md | CodeGraph index lock | ST-15 adds one rule line; a duplicate rule is an unreviewed second contract.
W6_DUP_TABLE
