#!/usr/bin/env bash
# TL3-hook-skill-dispatch-payload.sh
# Tests: hooks/postuse-step-in-flight-mark.js, settings.json
# Tags: hooks, post-tool-use, skill-dispatch, payload-shape, payload-replay, wi-10-lookahead, hook-registration, live-host-dispatch, adoption, regression-2279, scope:issue-specific, pwsh-not-required, TL3

# Every TL1/TL2 case around the WI-10 lookahead feeds the hook a payload this
# repo composed itself. That proves the hook's logic, never the seam: if real
# Claude Code does not put the skill name at `tool_input.skill`, a name-based
# fix reads undefined forever and the suite stays green. This test drives one
# real `claude -p` and records the real PostToolUse payload for a Skill call.
set -uo pipefail

# TL3 gap: this file IS the gap-closer for the day-to-day TL2 runner
# tests/feature-2013-step-in-flight-automark/d-skill-dispatch.sh. It is
# RUN_TL3-gated and Anthropic-billable, so CI normally skips it; R1 below
# always runs so the field-name agreement is checked on every invocation.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_SRC="$AGENTS_DIR/hooks/postuse-step-in-flight-mark.js"
SKILL_FIELD_PATH='tool_input.skill'

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

# R1 (always runs) — the seam this file probes must be the seam the hook reads.
# A TL3 assertion on a field no source consumes is theatre; a hook that reads a
# different spelling than the one asserted below is the #2279 bug in a new
# place. Either way the two must name the same field.
run_R1() {
    local problems=""
    if [ ! -f "$HOOK_SRC" ]; then
        fail "R1: hooks/postuse-step-in-flight-mark.js not found"
        return
    fi
    if ! grep -qE 'tool_input' "$HOOK_SRC"; then
        problems="$problems [the hook never reads tool_input at all]"
    fi
    if ! grep -qE '\.skill\b|\[.skill.\]|skill_name|skillName' "$HOOK_SRC"; then
        problems="$problems [the hook never reads a skill-name field, so it cannot tell Skill(resume-session) from any other Skill dispatch — this is the #2279 root cause]"
    fi
    if [ -z "$problems" ]; then
        pass "R1: the hook reads a skill-name field out of tool_input, matching the $SKILL_FIELD_PATH seam asserted by R2"
    else
        fail "R1: the hook and this test disagree about the dispatch payload;$problems"
    fi
}

run_R1

# --- TL3 gates -------------------------------------------------------------
[ -x "$AGENTS_DIR/bin/get-config-var" ] || { skip "R2/P3/R4: bin/get-config-var not executable"; finish; }
if "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off; then
    skip "R2/P3/R4: requires RUN_TL3=on in .env (Anthropic-billable)"
    finish
fi
command -v claude >/dev/null 2>&1 || { skip "R2/P3/R4: claude CLI not found"; finish; }
command -v jq >/dev/null 2>&1 || { skip "R2/P3/R4: jq not found"; finish; }

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

mkdir -p "$FIXTURE_DIR/.claude/skills/tl3-payload-probe"
RECORD_FILE="$FIXTURE_DIR/payloads.jsonl"

cat > "$FIXTURE_DIR/.claude/skills/tl3-payload-probe/SKILL.md" <<'EOF'
---
name: tl3-payload-probe
description: Inert probe skill used by a TL3 test to observe the PostToolUse payload shape of a Skill dispatch.
user-invocable: true
---

Output the single word `probe-ok` and stop. Do nothing else.
EOF

cat > "$FIXTURE_DIR/record.js" <<'EOF'
const fs = require('fs');
let raw = '';
process.stdin.on('data', (c) => { raw += c; });
process.stdin.on('end', () => {
    try { fs.appendFileSync(process.env.TL3_RECORD_FILE, raw.replace(/\r?\n/g, ' ') + '\n'); } catch (_) {}
    process.exit(0);
});
EOF

# Minimal settings.json per rules/test/claude-e2e.md — only the recorder hook.
cat > "$FIXTURE_DIR/settings.json" <<EOF
{ "hooks": { "PostToolUse": [ { "matcher": "Skill", "hooks": [ { "type": "command", "command": "node \\"$FIXTURE_DIR/record.js\\"" } ] } ] } }
EOF

unset CLAUDECODE

export TL3_RECORD_FILE="$RECORD_FILE"
RESPONSE_FILE="$FIXTURE_DIR/response.json"
if ! (cd "$FIXTURE_DIR" && "$AGENTS_DIR/bin/run-with-timeout.sh" 180 claude -p "Invoke the tl3-payload-probe skill, then stop." \
        --output-format json \
        --session-id "9f2c1d3e-2279-4a7b-9c5d-0e1f2a3b4c5d" \
        --settings "$FIXTURE_DIR/settings.json" \
        > "$RESPONSE_FILE" 2>"$FIXTURE_DIR/claude.err"); then
    skip "R2: claude -p invocation failed or timed out (stderr: $(head -c 200 "$FIXTURE_DIR/claude.err" 2>/dev/null))"
    finish
fi

# R2 — the real payload for a Skill dispatch must carry the skill's name.
run_R2() {
    local problems="" line name
    if [ ! -s "$RECORD_FILE" ]; then
        skip "R2: the PostToolUse recorder never fired — no Skill tool call was made in this run"
        return
    fi
    line=$(grep '"Skill"' "$RECORD_FILE" | head -1)
    if [ -z "$line" ]; then
        skip "R2: payloads were recorded but none carried tool_name Skill"
        return
    fi
    name=$(printf '%s' "$line" | jq -r '.tool_input.skill // empty' 2>/dev/null)
    if [ -z "$name" ]; then
        problems="$problems [$SKILL_FIELD_PATH is absent or empty; recorded keys: $(printf '%s' "$line" | jq -rc '.tool_input | keys' 2>/dev/null)]"
    elif [ "$name" != "tl3-payload-probe" ]; then
        problems="$problems [$SKILL_FIELD_PATH is '$name', not the dispatched skill name 'tl3-payload-probe']"
    fi
    if [ -z "$problems" ]; then
        pass "R2: a real Claude Code Skill dispatch delivers the skill name at $SKILL_FIELD_PATH, so a name-based lookahead fix has something to read"
    else
        fail "R2: the real PostToolUse payload cannot support a name-based fix;$problems"
    fi
}

run_R2

# P3 (detail.md S-9(j)) — REPLAY. R1 proves the hook reads a skill-name field and
# R2 proves the host fills it in; neither drives the hook with what the host
# produced. Every case exercising the #2279 exclusion feeds a payload this repo
# composed itself, so the exclusion could hinge on some incidental property of
# that synthetic shape and stay green forever. Take the captured payload
# byte-for-byte, swap ONLY `tool_input.skill` to `resume-session`, and drive the
# REAL registered hook with it: the heir's state must come back untouched, so a
# meta-op name cannot claim a step even when it rides a genuine host payload.
p3_node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

P3_DIR="$FIXTURE_DIR/p3"
P3_WF="$P3_DIR/wf"
P3_TRANSCRIPTS="$P3_DIR/transcripts"
HOOK_SRC_NODE="$(p3_node_path "$HOOK_SRC")"
STATEIO_NODE="$(p3_node_path "$AGENTS_DIR/hooks/workflow-state/state-io.js")"

# Fixture isolation (rules/test/fixture-isolation.md): the two dirs are pinned as
# a pair, the inherited session ids AND the CLAUDE_ENV_FILE relay are cleared,
# and CLAUDE_TRANSCRIPT_BASE_DIR points at an empty dir — the captured payload
# carries the real session's transcript_path, and no resolution stage may be
# allowed to follow it back to a live session.
p3_env() {
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$P3_WF" WORKFLOW_PLANS_DIR="$P3_WF" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$P3_TRANSCRIPTS" \
        AGENTS_CONFIG_DIR="$(p3_node_path "$AGENTS_DIR")" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 25 "$@"
}

# p3_replay <payload-file> — the real hook, fed on stdin the way Claude Code does.
p3_replay() { p3_env node "$HOOK_SRC_NODE" < "$1" >/dev/null 2>&1; }

# p3_digest <sid> — every step's status, joined. Comparing the WHOLE map catches
# a replay that marked some other step as well as one that marked the step it was
# supposed to leave alone.
p3_digest() {
    P3_STATE="$(p3_node_path "$P3_WF/$1.json")" p3_env node -e "
const fs = require('fs');
let s;
try { s = JSON.parse(fs.readFileSync(process.env.P3_STATE, 'utf8')); } catch (e) { process.stdout.write('<no-state>'); process.exit(0); }
const steps = (s.current && s.current.steps) || s.steps || {};
process.stdout.write(Object.keys(steps).sort().map((k) => k + '=' + steps[k].status).join(','));" 2>/dev/null
}

run_P3() {
    local line sid problems="" before after control
    if [ ! -s "$RECORD_FILE" ]; then
        skip "P3: no recorded payload to replay (R2 captured nothing)"
        return
    fi
    line=$(grep '"Skill"' "$RECORD_FILE" | head -1)
    if [ -z "$line" ]; then
        skip "P3: no recorded payload carried tool_name Skill"
        return
    fi
    sid=$(printf '%s' "$line" | jq -r '.session_id // empty' 2>/dev/null)
    if [ -z "$sid" ]; then
        skip "P3: the recorded payload carries no session_id to replay against"
        return
    fi

    mkdir -p "$P3_WF" "$P3_TRANSCRIPTS"
    # A heir whose current effective step IS an in-flight candidate (`research`,
    # reached once workflow_init and clarify_intent are complete). Without it both
    # replays below exit at the pre-init lookahead guard and prove nothing.
    P3_SID="$sid" p3_env node -e "
const { markStep } = require('$STATEIO_NODE');
markStep(process.env.P3_SID, 'workflow_init', 'complete');
markStep(process.env.P3_SID, 'clarify_intent', 'complete');" >/dev/null 2>&1

    before=$(p3_digest "$sid")
    if [ "$before" = "<no-state>" ] || [ -z "$before" ]; then
        skip "P3: could not seed the heir fixture state (digest '$before')"
        return
    fi

    # Only the skill name changes; every other byte is the host's.
    printf '%s' "$line" | jq -c '.tool_input.skill = "resume-session"' > "$P3_DIR/swapped.json" 2>/dev/null
    if [ ! -s "$P3_DIR/swapped.json" ]; then
        skip "P3: could not rewrite tool_input.skill in the captured payload"
        return
    fi
    p3_replay "$P3_DIR/swapped.json"
    after=$(p3_digest "$sid")
    [ "$after" = "$before" ] || problems="$problems [replaying the host payload as Skill(resume-session) changed the heir state: '$before' -> '$after']"

    # Non-vacuity control: the SAME payload, unswapped, must still mark. If it
    # does not, the replay never reached the marking path and the assertion above
    # is theatre rather than the #2279 exclusion.
    printf '%s' "$line" > "$P3_DIR/original.json"
    p3_replay "$P3_DIR/original.json"
    control=$(p3_digest "$sid")
    case "$control" in
        *research=in_progress*) : ;;
        *) problems="$problems [control: the unswapped host payload marked nothing either (digest '$control'), so the replay never reached the marking path]" ;;
    esac

    if [ -z "$problems" ]; then
        pass "P3: replaying the REAL captured payload with tool_input.skill swapped to resume-session leaves the heir's workflow state untouched, while the same payload unswapped still marks — the meta-op exclusion holds on the host's own payload shape"
    else
        fail "P3: the replay of a host-produced payload did not behave like the synthetic cases;$problems"
    fi
}

run_P3

# R4 — the LIVE-HOST sentence, end to end. R2 registers its own recorder, P3
# spawns the hook by path, and fix-2279-resume-from-skill-dispatch.sh S11 feeds
# the registered command a payload composed here: nowhere does the PROJECT's
# settings.json registration fire inside a real host. Matcher and command are
# read OUT of settings.json; the recorder rides alongside them purely as firing
# evidence, since for a meta-op the hook writes nothing by design and its own
# silence cannot separate "the exclusion held" from "nothing fired at all".
# `/resume-session` hard-fails non-interactively (SKILL.md Step 1), so the live
# model dispatches the Skill and stops — the seam, and nothing more.
R4_DIR="$FIXTURE_DIR/r4"
R4_STORE="$R4_DIR/store"
R4_REPO="$R4_DIR/repo"
R4_RECORD="$R4_DIR/dispatch.jsonl"
R4_SETTINGS="$R4_DIR/settings.json"
R4_HEIR="7c4e5b62-2279-4f18-9a3c-1b2d3e4f5a6b"
R4_DONOR="tl3donor2279"
AGENTS_NODE="$(p3_node_path "$AGENTS_DIR")"
R4_STORE_NODE=""

# SKIP is reserved for environmental absence (the gates above, or claude -p
# failing to launch). A run that exits 0 with no dispatch evidence is a FAIL:
# once RUN_TL3 is on in CI, a SKIP there would report #2279 as a non-finding.

# r4_registration — "<matcher>\n<command>" for the settings.json PostToolUse
# entry that runs postuse-step-in-flight-mark.js AND matches tool_name Skill.
# Empty when the host would never fire the hook #2279 is about.
r4_registration() {
    "$AGENTS_DIR/bin/run-with-timeout.sh" 15 node -e "
const s = require('$(p3_node_path "$AGENTS_DIR/settings.json")');
const DOLLAR = String.fromCharCode(36);
const NL = String.fromCharCode(10);
const pick = () => {
  for (const g of ((s.hooks && s.hooks.PostToolUse) || [])) {
    for (const h of (g.hooks || [])) {
      if (typeof h.command !== 'string') continue;
      if (h.command.indexOf('postuse-step-in-flight-mark.js') === -1) continue;
      const m = String(g.matcher || '');
      let ok = false;
      try { ok = new RegExp('^(?:' + m + ')' + DOLLAR).test('Skill'); } catch (e) { ok = false; }
      if (ok) return [m, h.command];
    }
  }
  return null;
};
const hit = pick();
if (hit) process.stdout.write(hit[0] + NL + hit[1] + NL);" 2>/dev/null
}

# r4_env <node-body> — one node run from the fixture repo with the fixture store
# pinned (rules/test/fixture-isolation.md): both plans-dir variables, cleared
# session ids, and AGENTS_CONFIG_DIR pointing at this worktree.
r4_env() {
    ( cd "$R4_REPO" && env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$R4_STORE_NODE" WORKFLOW_PLANS_DIR="$R4_STORE_NODE" \
        AGENTS_CONFIG_DIR="$AGENTS_NODE" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node -e "$1" ) 2>/dev/null
}

# r4_digest <sid> — every recorded step's status, joined; `<no-state>` when the
# file is unreadable, so "no state" is never mistaken for "nothing recorded".
r4_digest() {
    R4_SID="$1" R4_STATE="$(p3_node_path "$R4_STORE/$1.json")" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 15 node -e "
const fs = require('fs');
let s;
try { s = JSON.parse(fs.readFileSync(process.env.R4_STATE, 'utf8')); } catch (e) { process.stdout.write('<no-state>'); process.exit(0); }
const steps = (s.current && s.current.steps) || s.steps || {};
process.stdout.write(Object.keys(steps).sort().map((k) => k + '=' + steps[k].status).join(','));" 2>/dev/null
}

# r4_build_fixture — a throwaway repo, a fresh store, and the two sessions the
# #2279 scenario needs: a donor that genuinely got as far as `research`, and an
# untouched heir shell for the live session to land in.
r4_build_fixture() {
    mkdir -p "$R4_STORE" "$R4_REPO"
    R4_STORE_NODE="$(p3_node_path "$R4_STORE")"
    git -C "$R4_REPO" init -q >/dev/null 2>&1
    git -C "$R4_REPO" config core.hooksPath /dev/null >/dev/null 2>&1
    git -C "$R4_REPO" config user.email t@example.com >/dev/null 2>&1
    git -C "$R4_REPO" config user.name t >/dev/null 2>&1
    R4_SID="$R4_DONOR" r4_env "
const io = require('$STATEIO_NODE');
io.markStep(process.env.R4_SID, 'workflow_init', 'complete');
io.markStep(process.env.R4_SID, 'clarify_intent', 'complete');
io.markStep(process.env.R4_SID, 'research', 'in_progress');" >/dev/null
    R4_SID="$R4_HEIR" r4_env "
require('$STATEIO_NODE').markStep(process.env.R4_SID, 'research', 'pending');" >/dev/null
    : > "$R4_STORE/$R4_DONOR-intent.md"
}

# r4_write_settings <matcher> <command> — the fixture settings.json, built with
# JSON.stringify so the registered command's own quoting survives verbatim.
r4_write_settings() {
    R4_M="$1" R4_CMD="$2" R4_REC="$(p3_node_path "$FIXTURE_DIR/record.js")" R4_OUT="$(p3_node_path "$R4_SETTINGS")" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 15 node -e "
const fs = require('fs');
const Q = String.fromCharCode(34);
fs.writeFileSync(process.env.R4_OUT, JSON.stringify({ hooks: { PostToolUse: [ { matcher: process.env.R4_M, hooks: [
  { type: 'command', command: process.env.R4_CMD, timeout: 10 },
  { type: 'command', command: 'node ' + Q + process.env.R4_REC + Q, timeout: 10 } ] } ] } }));" >/dev/null 2>&1
}

# r4_dispatched_skill — the skill name the host put in the recorded Skill
# payload, namespace/path prefix dropped and lower-cased, or empty when no Skill
# payload was recorded at all.
r4_dispatched_skill() {
    local line
    [ -s "$R4_RECORD" ] || return 0
    line=$(grep '"Skill"' "$R4_RECORD" | head -1)
    [ -n "$line" ] || return 0
    printf '%s' "$line" | jq -r '.tool_input.skill // empty' 2>/dev/null \
        | sed 's/.*[:/]//' | tr '[:upper:]' '[:lower:]'
}

run_R4() {
    local matcher cmd problems="" dispatched after adopted ok

    r4_build_fixture
    if [ "$(r4_digest "$R4_DONOR")" = "<no-state>" ] || [ "$(r4_digest "$R4_HEIR")" = "<no-state>" ]; then
        fail "R4: fixture — the donor/heir state files were not seeded (donor='$(r4_digest "$R4_DONOR")', heir='$(r4_digest "$R4_HEIR")'), so no live run could prove anything"
        return
    fi
    case "$(r4_digest "$R4_HEIR")" in
        *=complete*|*=in_progress*)
            fail "R4: fixture — the heir is not an untouched shell before the dispatch: '$(r4_digest "$R4_HEIR")'"
            return ;;
    esac

    matcher="$(r4_registration | head -1)"
    cmd="$(r4_registration | sed -n '2p')"
    if [ -z "$matcher" ] || [ -z "$cmd" ]; then
        fail "R4: settings.json registers no PostToolUse entry that runs postuse-step-in-flight-mark.js on a matcher a Skill dispatch reaches — the real host would never fire the hook #2279 is about"
        return
    fi
    r4_write_settings "$matcher" "$cmd"
    if [ ! -s "$R4_SETTINGS" ]; then
        fail "R4: could not write the fixture settings.json carrying the registered hook command"
        return
    fi

    # The live host. Only the launch itself may SKIP.
    if ! ( cd "$R4_REPO" && env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
            CLAUDE_WORKFLOW_DIR="$R4_STORE_NODE" WORKFLOW_PLANS_DIR="$R4_STORE_NODE" \
            AGENTS_CONFIG_DIR="$AGENTS_NODE" TL3_RECORD_FILE="$R4_RECORD" \
            "$AGENTS_DIR/bin/run-with-timeout.sh" 180 claude -p \
            "Invoke the resume-session skill with the argument --from $R4_DONOR. It will refuse because this is a non-interactive session; that refusal is expected. Do not retry it, do not use any other tool, and stop." \
            --output-format json \
            --session-id "$R4_HEIR" \
            --settings "$R4_SETTINGS" \
            > "$R4_DIR/response.json" 2>"$R4_DIR/claude.err" ); then
        skip "R4: claude -p invocation failed or timed out (stderr: $(head -c 200 "$R4_DIR/claude.err" 2>/dev/null))"
        return
    fi

    # (a) the registered chain fired for a Skill call naming resume-session.
    dispatched="$(r4_dispatched_skill)"
    if [ -z "$dispatched" ]; then
        fail "R4: claude -p completed but no PostToolUse Skill payload was recorded — the session never dispatched Skill(resume-session) through the registered chain, so the #2279 seam was not exercised (response: $(head -c 200 "$R4_DIR/response.json" 2>/dev/null))"
        return
    fi
    [ "$dispatched" = "resume-session" ] ||
        problems="$problems [the recorded dispatch names '$dispatched', not resume-session — the live run exercised some other Skill]"

    # (b) the registered hook left the heir unclaimed: a meta-op dispatch must not
    #     record a step of its own (the #2279 root cause).
    after="$(r4_digest "$R4_HEIR")"
    case "$after" in
        *=in_progress*)
            problems="$problems [after the live Skill(resume-session) dispatch the heir records '$after' — the registered hook claimed a step for the resume itself, which is exactly what disqualifies the heir from adopting (#2279)]" ;;
    esac

    # (c) the adoption /resume-session --from was invoked FOR still lands, driven
    #     through the real CLI (the S1-S10 assertion, on the live-host path).
    ok=$( ( cd "$R4_REPO" && env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$R4_STORE_NODE" WORKFLOW_PLANS_DIR="$R4_STORE_NODE" \
        AGENTS_CONFIG_DIR="$AGENTS_NODE" CLAUDE_SESSION_ID="$R4_HEIR" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 30 node "$AGENTS_DIR/bin/resume-session-detect" --from "$R4_DONOR" ) 2>/dev/null \
        | jq -r '.inherit_result.ok // empty' 2>/dev/null )
    [ "$ok" = "true" ] ||
        problems="$problems [--from returned inherit_result.ok='${ok:-<none>}' after the live dispatch — the resume is a no-op for the user]"
    adopted="$(r4_digest "$R4_HEIR")"
    case "$adopted" in
        *workflow_init=complete*) : ;;
        *) problems="$problems [the heir recorded '$adopted' after the adoption — the donor's progress never arrived]" ;;
    esac

    if [ -z "$problems" ]; then
        pass "R4: a real claude -p session dispatches Skill(resume-session), the settings.json-registered PostToolUse hook fires for it, no step is claimed for the meta-op, and --from still adopts the donor into the fresh heir (the whole #2279 sentence on a live host)"
    else
        fail "R4: the live-host dispatch of Skill(resume-session) does not behave like the TL2 replay cases;$problems"
    fi
}

run_R4
finish
