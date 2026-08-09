# shellcheck shell=bash
# Helpers for tests/feature-1305-inheritance-lineage.sh. Sourced, not run.
# Tests: tests/feature-1305-inheritance-lineage.sh
# Tags: scope:issue-specific

NOW_ISO="$(node -e "console.log(new Date().toISOString())")"
PROBE_JS="$AGENTS_DIR/tests/feature-1305-inheritance-lineage/probe.js"

to_node_path() { cygpath -m "$1" 2>/dev/null || echo "$1"; }

AGENTS_DIR_NODE="$(to_node_path "$AGENTS_DIR")"
WORKFLOW_DIR_NODE="$(to_node_path "$WORKFLOW_DIR")"
PLANS_DIR_NODE="$(to_node_path "$PLANS_DIR")"
TBASE_NODE="$(to_node_path "$TBASE")"
PROBE_JS_NODE="$(to_node_path "$PROBE_JS")"

# path.resolve() form — the shape getCurrentContext() stores in a state file,
# so fixture cwds and heir ctx cwds compare byte-for-byte on every platform.
resolve_path() { run_with_timeout node -e "console.log(require('path').resolve(process.argv[1]))" "$1"; }

# The transcript directory name Claude Code derives from a resolved cwd.
encode_cwd() {
    run_with_timeout node -e "console.log(process.argv[1].toLowerCase().replace(/[^a-zA-Z0-9]/g,'-'))" "$1"
}

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$1"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config core.autocrlf false
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    echo "$repo"
}

# write_state_v1 <sid> <resolved-cwd> <branch> <steps-json>
# steps-json lists only the non-pending steps, e.g. '{"research":"complete"}'.
# v1 is the legacy shape; normalizeStateVersion migrates it on read, and both
# session_start_context and the `current` projection end up at <cwd>/<branch>.
write_state_v1() {
    run_with_timeout node -e '
      const fs = require("fs"), path = require("path");
      const [dir, sid, cwd, branch, stepsJson, now] = process.argv.slice(1);
      const steps = {};
      for (const [k, v] of Object.entries(JSON.parse(stepsJson))) steps[k] = { status: v, updated_at: now };
      fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify({
        version: 1, session_id: sid, created_at: now,
        cwd, git_branch: branch === "null" ? null : branch, steps,
      }, null, 2));
    ' "$WORKFLOW_DIR_NODE" "$1" "$2" "$3" "$4" "$NOW_ISO"
}

# write_state_v2_worktree <sid> <start-cwd> <start-branch> <current-cwd> <current-branch>
# A v2 fixture whose START context differs from its CURRENT context — the only
# way to produce that divergence, since migrateV1ToV2 synthesizes the worktree
# event from the same top-level cwd/branch a v1 file carries.
# seq is contiguous and 1-based and every event carries a valid provenance, so
# assertStreamIntegrity accepts the stream.
write_state_v2_worktree() {
    run_with_timeout node -e '
      const fs = require("fs"), path = require("path");
      const [dir, sid, scwd, sbranch, ccwd, cbranch, now] = process.argv.slice(1);
      fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify({
        version: 2, session_id: sid, created_at: now,
        session_start_context: { cwd: scwd, git_branch: sbranch },
        workflow_type: "wf-code",
        events: [
          { seq: 1, kind: "worktree", transition: "entered", cwd: ccwd, git_branch: cbranch,
            at: now, provenance: "observed", origin: "test-fixture" },
          { seq: 2, kind: "step_status", step: "research", status: "complete",
            at: now, provenance: "observed", origin: "test-fixture" },
        ],
      }, null, 2));
    ' "$WORKFLOW_DIR_NODE" "$1" "$2" "$3" "$4" "$5" "$NOW_ISO"
}

# transcript_dir <resolved-cwd> → mkdir -p'd transcript dir for that cwd
transcript_dir() {
    local d="$TBASE/$(encode_cwd "$1")"
    mkdir -p "$d"
    echo "$d"
}

# write_forked_transcript <path> <heir-sid> <donor-sid>
# Fork evidence: Claude Code stamps `forkedFrom` on the rows carried over from
# the parent session when a session is forked / resumed / compacted.
write_forked_transcript() {
    local file="$1" heir="$2" donor="$3"
    {
        printf '{"type":"user","uuid":"u1-%s","sessionId":"%s","forkedFrom":{"sessionId":"%s","messageUuid":"m1"}}\n' "$heir" "$heir" "$donor"
        printf '{"type":"assistant","uuid":"u2-%s","sessionId":"%s","forkedFrom":{"sessionId":"%s","messageUuid":"m2"}}\n' "$heir" "$heir" "$donor"
        printf '{"type":"user","uuid":"u3-%s","sessionId":"%s"}\n' "$heir" "$heir"
    } > "$file"
}

# write_announce_transcript <path> <donor-sid> [hookEvent]
# The other lineage evidence: the donor's SessionStart/PostCompact announce line
# is COPIED into the heir's transcript. The contract string is SSOT — byte-for-
# byte "Current workflow session_id: <sid>".
write_announce_transcript() {
    local file="$1" donor="$2" ev="${3:-SessionStart}"
    printf '{"type":"attachment","attachment":{"type":"hook_success","hookEvent":"%s","exitCode":0,"stdout":"{\\"additionalContext\\": \\"Current workflow session_id: %s\\\\nState file: /tmp/%s.json\\"}","command":"node session-start.js"}}\n' \
        "$ev" "$donor" "$donor" > "$file"
}

# probe '<json-args>' → key=value lines (neutral CWD; fixture-pinned env only)
probe() {
    (cd "$TMPDIR_BASE" && AGENTS_DIR_NODE="$AGENTS_DIR_NODE" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_NODE" \
        WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TBASE_NODE" \
        run_with_timeout node "$PROBE_JS_NODE" "$1" 2>&1) || echo "error=PROBE_CRASHED"
}

# resolve_donor <heir-sid> <source|NONE> <transcript-path> <cwd> <branch> [agent-id]
resolve_donor() {
    run_with_timeout node -e '
      const [sid, source, tp, cwd, branch, agentId] = process.argv.slice(1);
      const a = { fn: "resolveInheritanceDonor", sessionId: sid,
        transcriptPath: tp === "NONE" ? undefined : tp,
        ctx: { cwd, git_branch: branch === "null" ? null : branch } };
      if (source !== "NONE") a.source = source;
      if (agentId && agentId !== "NONE") a.agentId = agentId;
      process.stdout.write(JSON.stringify(a));
    ' "$1" "$2" "$3" "$4" "$5" "${6:-NONE}" | { read -r j; probe "$j"; }
}

# list_candidates <cwd> <branch> → candidates=<comma-joined session ids>
list_candidates() {
    run_with_timeout node -e '
      process.stdout.write(JSON.stringify({ fn: "listRecentContextCandidates",
        ctx: { cwd: process.argv[1], git_branch: process.argv[2] } }));
    ' "$1" "$2" | { read -r j; probe "$j"; }
}

# read_lineage <transcript-path> → readable=…, ancestors=…
read_lineage() {
    run_with_timeout node -e '
      process.stdout.write(JSON.stringify({ fn: "readLineageAncestors", transcriptPath: process.argv[1] }));
    ' "$1" | { read -r j; probe "$j"; }
}

# An ABSENT key reads as MISSING_KEY, never as "". Without that distinction a
# probe that emitted nothing at all (e.g. MISSING_EXPORT) would satisfy every
# "expected empty" / "expected not X" assertion — false green.
get_kv() {
    local line
    line="$(printf '%s\n' "$1" | grep "^$2=" | head -1 || true)"
    if [ -z "$line" ]; then echo "MISSING_KEY"; else printf '%s\n' "${line#*=}"; fi
}

assert_kv() {
    local desc="$1" out="$2" key="$3" want="$4" got
    got="$(get_kv "$out" "$key")"
    if [ "$got" = "$want" ]; then pass "$desc"
    else fail "$desc — expected $key='$want', got '$got' [$(printf '%s' "$out" | tr '\n' '|')]"; fi
}

assert_prefix() {
    local desc="$1" out="$2" key="$3" want="$4" got
    got="$(get_kv "$out" "$key")"
    case "$got" in
        "$want"*) pass "$desc" ;;
        *) fail "$desc — expected $key to start with '$want', got '$got' [$(printf '%s' "$out" | tr '\n' '|')]" ;;
    esac
}

assert_ne() {
    local desc="$1" out="$2" key="$3" unwanted="$4" got
    got="$(get_kv "$out" "$key")"
    if [ "$got" = "MISSING_KEY" ]; then
        fail "$desc — $key was not reported at all [$(printf '%s' "$out" | tr '\n' '|')]"
    elif [ "$got" != "$unwanted" ]; then pass "$desc"
    else fail "$desc — $key must NOT be '$unwanted' [$(printf '%s' "$out" | tr '\n' '|')]"; fi
}

# Steps fixture shorthands ---------------------------------------------------
STEPS_INHERITABLE='{"workflow_init":"complete","research":"complete","outline":"complete","detail":"complete"}'
STEPS_ALL_PENDING='{}'
STEPS_USER_VERIFIED='{"research":"complete","user_verification":"complete"}'
STEPS_SECURITY_DONE='{"research":"complete","outline":"complete","review_security":"complete"}'
STEPS_INTENT_DONE='{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}'

# The shared context every gate case uses unless it needs a mismatch.
REPO_A="$(setup_repo a)"
CWD_A="$(resolve_path "$REPO_A")"
BRANCH_A="$(git -C "$REPO_A" rev-parse --abbrev-ref HEAD)"
TDIR_A="$(transcript_dir "$CWD_A")"
