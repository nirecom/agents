# Tests: hooks/workflow-state/session-id.js
# Tags: workflow, hook, scope:common
# JS-20..26: 4-tier supply-only priority chain (#2270); see
# docs/architecture/claude-code/session-id-resolution.md. Negative cases are
# MUTATION PROBES: bait sits at the exact spot a pruned tier used to read.
# $4 (cwd, default ".") is cd'd inside the command-substitution subshell only,
# so no case leaks a working directory into the next one.
run_supply_tier() {
    local desc="$1" expect="$2" script="$3" cwd="${4:-.}"
    local out
    out="$(cd "$cwd" && run_with_timeout 30 node -e "$script" 2>/dev/null)"
    if [ "$out" = "$expect" ]; then
        pass "$desc"
    else
        fail "$desc: got '$out', expected '$expect'"
    fi
}

setup

# JS-20: P1 (sessionIdFromInput) wins over P2/P3/P4 all present.
CLAUDE_CODE_SESSION_ID="p2-sid" CLAUDE_SESSION_ID="p3-sid" \
run_supply_tier "JS-20: P1 beats P2/P3/P4" "p1-sid" "
const { resolveSessionId } = require('$TARGET_NODE');
const r = resolveSessionId({ sessionIdFromInput: 'p1-sid', transcriptPath: '$TMP/p4-sid.jsonl' });
process.stdout.write(r === null ? '<null>' : String(r));
"

# JS-21: P2 (CLAUDE_CODE_SESSION_ID) wins over P3/P4 when P1 absent.
CLAUDE_CODE_SESSION_ID="p2-sid" CLAUDE_SESSION_ID="p3-sid" \
run_supply_tier "JS-21: P2 beats P3/P4 when P1 absent" "p2-sid" "
const { resolveSessionId } = require('$TARGET_NODE');
const r = resolveSessionId({ transcriptPath: '$TMP/p4-sid.jsonl' });
process.stdout.write(r === null ? '<null>' : String(r));
"

# JS-22: P3 (CLAUDE_SESSION_ID) wins over P4 when P1/P2 absent.
CLAUDE_SESSION_ID="p3-sid" \
run_supply_tier "JS-22: P3 beats P4 when P1/P2 absent" "p3-sid" "
const { resolveSessionId } = require('$TARGET_NODE');
const r = resolveSessionId({ transcriptPath: '$TMP/p4-sid.jsonl' });
process.stdout.write(r === null ? '<null>' : String(r));
"

# JS-23: P4 (transcriptPath basename) used when P1/P2/P3 all absent.
run_supply_tier "JS-23: P4 used when P1/P2/P3 absent" "p4-sid" "
const { resolveSessionId } = require('$TARGET_NODE');
const r = resolveSessionId({ transcriptPath: '$TMP/p4-sid.jsonl' });
process.stdout.write(r === null ? '<null>' : String(r));
"

# JS-24 (negative): a CLAUDE_ENV_FILE pointing at a valid session id no longer
# resolves anything — the inferred tier it used to feed was removed. The removed
# tier read the path in the variable directly, so the bait needs no cwd staging.
printf 'CLAUDE_SESSION_ID=envfile-sid\n' > "$TMP/envfile"
CLAUDE_ENV_FILE="$TMP/envfile" \
run_supply_tier "JS-24: CLAUDE_ENV_FILE bait ignored (P1-P4 all absent)" "<null>" "
const { resolveSessionId } = require('$TARGET_NODE');
const r = resolveSessionId({});
process.stdout.write(r === null ? '<null>' : String(r));
"

# JS-25 (negative): a WORKTREE_NOTES.md advertising a session id no longer
# resolves anything — resolveSessionId never reads cwd-relative files at all.
# Mutation probe: the removed tier read path.join(process.cwd(), 'WORKTREE_NOTES.md'),
# so the subprocess is launched WITH its cwd at the bait directory.
NOTES_CWD="$TMP/notes-cwd"
mkdir -p "$NOTES_CWD"
printf 'Session-ID: notes-sid\n' > "$NOTES_CWD/WORKTREE_NOTES.md"
run_supply_tier "JS-25: WORKTREE_NOTES.md bait ignored (P1-P4 all absent)" "<null>" "
const { resolveSessionId } = require('$TARGET_NODE');
const r = resolveSessionId({});
process.stdout.write(r === null ? '<null>' : String(r));
" "$NOTES_CWD"

# JS-26 (negative): a JSONL transcript sitting where the removed mtime-scan tier
# looked no longer resolves anything without an explicit ctx.transcriptPath.
# Mutation probe: that tier only considered a cwd inside the agents repo, and
# derived its directory as resolve(cwd).toLowerCase() with every non-alphanumeric
# replaced by '-' under CLAUDE_TRANSCRIPT_BASE_DIR. Both conditions are reproduced
# here — hence the deliberately non-neutral cwd ($AGENTS_DIR). Safe despite
# rules/test/fixture-isolation.md's neutral-CWD guidance: resolveSessionId only
# reads, and CLAUDE_TRANSCRIPT_BASE_DIR is pinned to the fixture, so the real
# ~/.claude/projects is never reached.
JSONL_DIR="$CLAUDE_TRANSCRIPT_BASE_DIR/$(encode_path "$AGENTS_DIR_NODE")"
mkdir -p "$JSONL_DIR"
printf '{}\n' > "$JSONL_DIR/jsonl-bait-sid.jsonl"
run_supply_tier "JS-26: JSONL mtime-scan bait ignored (P1-P4 all absent)" "<null>" "
const { resolveSessionId } = require('$TARGET_NODE');
const r = resolveSessionId({});
process.stdout.write(r === null ? '<null>' : String(r));
" "$AGENTS_DIR"

teardown
