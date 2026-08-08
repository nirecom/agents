# shellcheck shell=bash
# Helpers for tests/feature-1305-adopt-session-state.sh. Sourced, not run.
# Tests: tests/feature-1305-adopt-session-state.sh
# Tags: scope:issue-specific

NOW_ISO="$(node -e "console.log(new Date().toISOString())")"
ADOPT_CLI="$AGENTS_DIR/bin/workflow/adopt-session-state"
DRIVER="$AGENTS_DIR/bin/workflow/workflow-init-driver"

to_node_path() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
WORKFLOW_DIR_NODE="$(to_node_path "$WORKFLOW_DIR")"
PLANS_DIR_NODE="$(to_node_path "$PLANS_DIR")"
TBASE_NODE="$(to_node_path "$TBASE")"

resolve_path() { run_with_timeout node -e "console.log(require('path').resolve(process.argv[1]))" "$1"; }
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

# write_state_v2 <sid> <cwd> <branch> <steps-json>
# v2 with an explicit event stream: contiguous 1-based seq + valid provenance,
# so assertStreamIntegrity accepts it. An empty steps object yields the
# all-pending heir shape the CLI requires before it will overwrite anything.
write_state_v2() {
    run_with_timeout node -e '
      const fs = require("fs"), path = require("path");
      const [dir, sid, cwd, branch, stepsJson, now] = process.argv.slice(1);
      const events = [];
      for (const [step, status] of Object.entries(JSON.parse(stepsJson))) {
        events.push({ seq: events.length + 1, kind: "step_status", step, status,
          at: now, provenance: "observed", origin: "test-fixture" });
      }
      fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify({
        version: 2, session_id: sid, created_at: now,
        session_start_context: { cwd, git_branch: branch },
        workflow_type: "wf-code", events,
      }, null, 2));
    ' "$WORKFLOW_DIR_NODE" "$1" "$2" "$3" "$4" "$NOW_ISO"
}

# announce_donor <donor-sid> <resolved-cwd>
# The breadcrumb listRecentContextCandidates follows. The announce string is a
# byte-for-byte SSOT contract — do not reword it.
announce_donor() {
    local dir="$TBASE/$(encode_cwd "$2")"
    mkdir -p "$dir"
    printf '{"type":"attachment","attachment":{"type":"hook_success","hookEvent":"SessionStart","exitCode":0,"stdout":"{\\"additionalContext\\": \\"Current workflow session_id: %s\\"}","command":"node session-start.js"}}\n' \
        "$1" > "$dir/$1.jsonl"
}

# adopt <heir-sid> <cwd> <args...> → stdout+stderr; ADOPT_RC holds the exit code
adopt() {
    local heir="$1" cwd="$2"; shift 2
    set +e
    ADOPT_OUT="$( (cd "$TMPDIR_BASE" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_NODE" \
        WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" CLAUDE_TRANSCRIPT_BASE_DIR="$TBASE_NODE" \
        CLAUDE_PROJECT_DIR="$cwd" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout node "$ADOPT_CLI" --session "$heir" "$@" 2>&1) )"
    ADOPT_RC=$?
    set -e
    # A CLI that does not exist yet exits non-zero and mutates nothing — which
    # would satisfy every "must be refused" / "must stay unchanged" assertion
    # for entirely the wrong reason. Record that so those assertions can fail
    # loudly instead of going false-green.
    ADOPT_MISSING=0
    case "$ADOPT_OUT" in *"Cannot find module"*|*MODULE_NOT_FOUND*) ADOPT_MISSING=1 ;; esac
}

# run_driver <heir-sid> <cwd> <args...> → stdout+stderr; DRIVER_RC holds the code
# CLAUDE_SESSION_ID is set per invocation (never inherited) so the driver keys
# its checkpoint on the fixture heir, not on the live session.
run_driver() {
    local heir="$1" cwd="$2"; shift 2
    set +e
    DRIVER_OUT="$( (cd "$TMPDIR_BASE" && CLAUDE_SESSION_ID="$heir" \
        CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_NODE" WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
        CLAUDE_TRANSCRIPT_BASE_DIR="$TBASE_NODE" CLAUDE_PROJECT_DIR="$cwd" \
        AGENTS_CONFIG_DIR="$AGENTS_DIR" \
        run_with_timeout node "$DRIVER" "$@" 2>&1) )"
    DRIVER_RC=$?
    set -e
    # Same guard as ADOPT_MISSING: an unregistered phase makes the driver abort
    # before doing anything, which trivially satisfies every negative assertion.
    DRIVER_PHASE_MISSING=0
    case "$DRIVER_OUT" in
        *"Unknown phase: adopt-prior-state"*|*"Cannot find module"*) DRIVER_PHASE_MISSING=1 ;;
        # A blocked/aborted run never reached the adoption decision either;
        # none of the guarded assertions below may claim a pass from it.
        *"ACTION=blocked"*|*"checkpoint error"*) DRIVER_PHASE_MISSING=1 ;;
    esac
}

cli_ran() { [ "${ADOPT_MISSING:-1}" = "0" ]; }
phase_ran() { [ "${DRIVER_PHASE_MISSING:-1}" = "0" ]; }

get_kv() {
    local line
    line="$(printf '%s\n' "$1" | grep "^$2=" | head -1 || true)"
    if [ -z "$line" ]; then echo "MISSING_KEY"; else printf '%s\n' "${line#*=}"; fi
}

# step_status <sid> <step> — read through the canonical projection API
step_status() {
    (cd "$AGENTS_DIR" && CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR_NODE" WORKFLOW_PLANS_DIR="$PLANS_DIR_NODE" \
        run_with_timeout node -e '
          try {
            const s = require("./hooks/workflow-state").readState(process.argv[1]);
            const st = s && s.steps && s.steps[process.argv[2]];
            console.log(st && st.status ? st.status : "MISSING");
          } catch (e) { console.log("ERR:" + e.message); }
        ' "$1" "$2" 2>/dev/null) || echo "ERR"
}

# event_signature <sid> — the shape of the appended stream with everything
# session- or clock-specific removed, so two adoptions can be compared directly.
event_signature() {
    run_with_timeout node -e '
      const fs = require("fs"), path = require("path");
      let raw;
      try { raw = JSON.parse(fs.readFileSync(path.join(process.argv[1], process.argv[2] + ".json"), "utf8")); }
      catch (e) { console.log("NO_STATE"); process.exit(0); }
      const evs = Array.isArray(raw.events) ? raw.events : [];
      console.log(evs.map((e) => [e.kind, e.step || "", e.status || "", e.provenance || "",
        e.origin || "", e.inherited_from ? "FROM_DONOR" : ""].join(":")).join("|"));
    ' "$WORKFLOW_DIR_NODE" "$1"
}

# inherited_from_of <sid> — the donor id recorded on the backfilled events
inherited_from_of() {
    run_with_timeout node -e '
      const fs = require("fs"), path = require("path");
      let raw;
      try { raw = JSON.parse(fs.readFileSync(path.join(process.argv[1], process.argv[2] + ".json"), "utf8")); }
      catch (e) { console.log("NO_STATE"); process.exit(0); }
      const ids = new Set((raw.events || []).map((e) => e.inherited_from).filter(Boolean));
      console.log(ids.size ? [...ids].join(",") : "NONE");
    ' "$WORKFLOW_DIR_NODE" "$1"
}

state_cksum() { cksum < "$WORKFLOW_DIR/$1.json"; }

assert_eq_desc() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$desc"
    else fail "$desc — expected '$want', got '$got'"; fi
}

assert_contains() {
    local desc="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$desc"
    else fail "$desc — '$needle' not found in [$(printf '%s' "$hay" | tr '\n' '|')]"; fi
}

assert_not_contains() {
    local desc="$1" needle="$2" hay="$3"
    if printf '%s' "$hay" | grep -qF -- "$needle"; then
        fail "$desc — '$needle' unexpectedly present in [$(printf '%s' "$hay" | tr '\n' '|')]"
    else pass "$desc"; fi
}

assert_rc_nonzero() {
    local desc="$1" rc="$2" out="$3"
    if ! cli_ran; then fail "$desc — the adopt CLI never executed; refusal unproven"; return; fi
    if [ "$rc" -ne 0 ]; then pass "$desc"
    else fail "$desc — expected a non-zero exit, got 0 [$(printf '%s' "$out" | tr '\n' '|')]"; fi
}

# Guarded variants: `guard` is cli_ran / phase_ran. A negative assertion that
# holds only because the subject never ran is a false green, not a pass.
assert_eq_guarded() {
    local guard="$1" desc="$2" want="$3" got="$4"
    if ! $guard; then fail "$desc — precondition failed: the subject under test did not execute"; return; fi
    assert_eq_desc "$desc" "$want" "$got"
}

assert_not_contains_guarded() {
    local guard="$1" desc="$2" needle="$3" hay="$4"
    if ! $guard; then fail "$desc — precondition failed: the subject under test did not execute"; return; fi
    assert_not_contains "$desc" "$needle" "$hay"
}

# assert_list_row <desc> <sid> <branch> — one --list line naming both fields.
assert_list_row() {
    local desc="$1" sid="$2" branch="$3"
    if ! cli_ran || [ "$ADOPT_RC" -ne 0 ]; then
        fail "$desc — --list did not produce a listing [$(printf '%s' "$ADOPT_OUT" | tr '\n' '|')]"
        return
    fi
    if printf '%s\n' "$ADOPT_OUT" | grep -F -- "$sid" | grep -qF -- "$branch"; then pass "$desc"
    else fail "$desc — no row pairing '$sid' with '$branch' [$(printf '%s' "$ADOPT_OUT" | tr '\n' '|')]"; fi
}

STEPS_INHERITABLE='{"workflow_init":"complete","research":"complete","outline":"complete","detail":"complete"}'
STEPS_ALL_PENDING='{}'
STEPS_USER_VERIFIED='{"research":"complete","user_verification":"complete"}'
STEPS_INTENT_DONE='{"workflow_init":"complete","clarify_intent":"complete","research":"complete"}'

REPO="$(setup_repo main)"
CWD="$(resolve_path "$REPO")"
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"
