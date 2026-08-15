#!/usr/bin/env bash
# tests/feature-1894-hook-comment-block/registration.sh
# Tests: settings.json, hooks/block-comment-block-size.js
# Tags: comment-block-size, hook, pretooluse, settings, registration, wiring, e2e, integration, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 6 — the wiring.
#
# Every other case in this suite invokes the hook directly, which proves the
# hook works and says nothing about whether it ever runs. An unregistered hook
# is a file that passes its tests and guards nothing, and the failure is silent
# in the worst way: authors keep writing long comment blocks, the suite stays
# green, and the only signal is the absence of a signal.
#
# G1-G4 read settings.json as data, which is what it is. G5 then EXECUTES the
# command string it found there as a child process and validates the response
# against the PreToolUse protocol — the integration half required for a
# hook-registration change (rules/test.md). What remains beyond even that is
# whether Claude Code itself routes an Edit into the hook (the TL3 gap the
# dispatcher records, along with the fact that ~/.claude/settings.json is
# assembled by the installer and therefore needs a reinstall to take effect).
#
# Sourced by the dispatcher; all helpers are defined there.

REG_JS="$TMPDIR_BASE/reg.js"
cat > "$REG_JS" <<'REGJS'
// Prints one line per PreToolUse entry whose command mentions the hook:
//   <index>\t<matcher>\t<timeout>
const s = require(process.argv[2]);
const name = process.argv[3];
const list = (s.hooks && s.hooks.PreToolUse) || [];
list.forEach((entry, i) => {
  for (const h of entry.hooks || []) {
    if (typeof h.command === "string" && h.command.includes(name)) {
      process.stdout.write([i, entry.matcher || "", h.timeout === undefined ? "" : h.timeout, h.type || "", h.command].join("\t") + "\n");
    }
  }
});
REGJS

reg_lookup() {
    node "$REG_JS" "$(mpath "$SETTINGS_JSON")" "$1" 2>/dev/null || true
}

# ============================================================================
# G1 — the hook is registered exactly once under PreToolUse
# ============================================================================
g1_registered_once() {
    local rows
    rows="$(reg_lookup block-comment-block-size.js)"
    local n
    n="$(printf '%s' "$rows" | grep -c . || true)"
    if [ "$n" = "1" ]; then
        pass "G1: block-comment-block-size.js is registered exactly once"
    else
        fail "G1: found $n PreToolUse registration(s), expected 1" \
             "rows: ${rows:-<none>}"
        return
    fi
    REG_ROW="$rows"
}

# ============================================================================
# G2 — it carries the same matcher group as its sibling
#
# Compared against block-tests-direct.js rather than to a hard-coded string:
# the two guard the same tool class, so if that class ever gains or loses a tool
# they must move together (CPR-ORTH). A literal here would go stale silently.
# ============================================================================
g2_matcher_matches_the_sibling() {
    local mine sibling
    mine="$(printf '%s' "${REG_ROW:-}" | cut -f2)"
    sibling="$(reg_lookup block-tests-direct.js | head -1 | cut -f2)"
    if [ -z "$sibling" ]; then
        fail "G2: block-tests-direct.js is not registered — no sibling to compare against"
        return
    fi
    assert_eq "G2/matcher-equals-sibling" "$sibling" "$mine"
    # ...and the group really is the edit-write class, so a sibling that drifted
    # cannot drag this one along quietly.
    local t
    for t in Write Edit MultiEdit; do
        assert_contains "G2/matcher-covers-$t" "$t" "$mine"
    done
}

# ============================================================================
# G3 — invocation shape: command type, portable path, and a timeout
# ============================================================================
g3_invocation_shape() {
    local row="${REG_ROW:-}"
    if [ -z "$row" ]; then
        skip "G3: no registration row (see G1)"
        return
    fi
    local timeout type cmd
    timeout="$(printf '%s' "$row" | cut -f3)"
    type="$(printf '%s' "$row" | cut -f4)"
    cmd="$(printf '%s' "$row" | cut -f5)"
    assert_eq "G3/type-is-command" "command" "$type"
    # $AGENTS_CONFIG_DIR, never an absolute developer path: settings.json is
    # installed on every machine that uses this repo.
    assert_contains "G3/path-is-config-relative" 'AGENTS_CONFIG_DIR' "$cmd"
    assert_absent "G3/no-absolute-home-path" "/Users/" "$cmd"
    assert_absent "G3/no-absolute-windows-path" ":\\" "$cmd"
    # A hook on the Edit hot path without a timeout can hang the editor.
    if [ -n "$timeout" ] && [ "$timeout" -le 10 ] 2>/dev/null; then
        pass "G3/timeout-is-bounded ($timeout s)"
    else
        fail "G3/timeout-is-bounded" "timeout=${timeout:-<unset>}; expected a value <= 10"
    fi
}

# ============================================================================
# G4 — the file it points at exists and is a runnable Node entrypoint
# ============================================================================
g4_target_exists_and_runs() {
    if [ ! -f "$HOOK" ]; then
        fail "G4: $HOOK does not exist yet (issue #1894)"
        return
    fi
    if node --check "$(mpath "$HOOK")" >/dev/null 2>&1; then
        pass "G4: the hook parses as valid Node"
    else
        fail "G4: node --check failed on hooks/block-comment-block-size.js"
    fi
    # Loading the module must not run the hook: a require.main guard is what
    # lets tests and other hooks import it without consuming stdin.
    if grep -q 'require.main' "$HOOK"; then
        pass "G4: the hook has a require.main guard"
    else
        fail "G4: no require.main guard in hooks/block-comment-block-size.js" \
             "Without it, requiring the module executes the hook."
    fi
}

# ============================================================================
# G5 — the registered command line, run as a process, answers in the host
#      protocol (Codex round-1 C1)
#
# G1-G3 read settings.json as data and every other case in this suite invokes
# `node <path-to-hook>` that the TEST composed. Between those two sits the thing
# that actually runs in production: the command STRING settings.json carries.
# A registration that names a typo'd path, forgets `node`, or quotes badly is
# green under both halves and dead in the field; so is a hook that answers with
# a bare "block" line, a stray console.log before its JSON, or a non-zero exit
# (Claude Code surfaces that as a hook error on every keystroke, not a verdict).
#
# This case therefore takes the command verbatim from settings.json, expands
# only $AGENTS_CONFIG_DIR — to the worktree under test for the executable, while
# the child still resolves its .env from the pinned fixture config dir — and
# hands it a real PreToolUse payload on stdin through `bash -c`, so the host's
# own tokenisation is exercised rather than an argv the test hand-assembled.
# Both verdicts are proven, because a hook stuck on either one is still "valid
# JSON" to a parser.
#
# TL3 gap: this proves the registered command is runnable and protocol-correct.
# Whether Claude Code itself dispatches an Edit into it is still only checkable
# on a real host (see the dispatcher header).
# ============================================================================
E2E_JS="$TMPDIR_BASE/verdict.js"
cat > "$E2E_JS" <<'E2EJS'
// Validates one PreToolUse hook response. Prints "OK <decision> <reasonLen>"
// or "ERR <what-was-wrong>". Exit code is always 0 — the caller asserts on the
// text, so a validator crash cannot masquerade as a hook failure.
const fs = require("fs");
let raw = "";
try { raw = fs.readFileSync(process.argv[2], "utf8"); } catch (e) { }
const trimmed = raw.trim();
if (!trimmed) { console.log("ERR empty-stdout"); process.exit(0); }
let obj;
try { obj = JSON.parse(trimmed); } catch (e) {
  console.log("ERR not-parseable-as-single-json: " + String(e.message).slice(0, 120));
  process.exit(0);
}
if (obj === null || typeof obj !== "object" || Array.isArray(obj)) {
  console.log("ERR not-a-json-object"); process.exit(0);
}
const d = obj.decision;
if (d !== "approve" && d !== "block") {
  console.log("ERR bad-decision:" + JSON.stringify(d)); process.exit(0);
}
const reason = obj.reason;
if (d === "block" && (typeof reason !== "string" || reason.trim() === "")) {
  console.log("ERR block-without-reason"); process.exit(0);
}
console.log("OK " + d + " " + (typeof reason === "string" ? reason.length : 0));
E2EJS

# e2e_run — runs the settings.json command string against $PAYLOAD_FILE.
# Fills E2E_RC / E2E_OUT / E2E_ERR / E2E_VERDICT.
E2E_CMD=""
E2E_TIMEOUT=""
e2e_run() {
    local outfile="$TMPDIR_BASE/e2e.out" errfile="$TMPDIR_BASE/e2e.err"
    _hk_env 0
    E2E_RC=0
    (cd "$NEUTRAL_CWD" \
        && unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID \
        && run_with_timeout "${E2E_TIMEOUT:-10}" env "${HK_ENVS[@]}" \
            bash -c "$E2E_CMD" < "$PAYLOAD_FILE") > "$outfile" 2>"$errfile" || E2E_RC=$?
    E2E_OUT="$(cat "$outfile" 2>/dev/null || true)"
    E2E_ERR="$(cat "$errfile" 2>/dev/null || true)"
    E2E_VERDICT="$(node "$(mpath "$E2E_JS")" "$(mpath "$outfile")" 2>&1 || true)"
}

g5_registered_command_speaks_the_protocol() {
    local row="${REG_ROW:-}"
    if [ -z "$row" ]; then
        skip "G5: no registration row (see G1) — nothing to execute"
        return
    fi
    local cmd
    cmd="$(printf '%s' "$row" | cut -f5)"
    E2E_TIMEOUT="$(printf '%s' "$row" | cut -f3)"
    case "$E2E_TIMEOUT" in ''|*[!0-9]*) E2E_TIMEOUT=10 ;; esac
    # Expand only the config-dir placeholder, and only to the worktree copy:
    # the deployed ~/.claude tree is not the state under test.
    E2E_CMD="${cmd//\$AGENTS_CONFIG_DIR/$(mpath "$AGENTS_DIR")}"
    E2E_CMD="${E2E_CMD//\$\{AGENTS_CONFIG_DIR\}/$(mpath "$AGENTS_DIR")}"

    # --- block half: a fresh file whose content carries an 11-line run
    local f="$REPO_M/e2e-block.js"
    { echo "var x = 1;"; cmt 11 c; } > "$TMPDIR_BASE/e2e.block"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/e2e.block"
    e2e_run
    assert_eq "G5/block-exit-code-is-0" "0" "$E2E_RC"
    assert_eq "G5/block-response-is-protocol-json" "OK block" "$(printf '%s' "$E2E_VERDICT" | cut -d' ' -f1-2)"
    # An empty reason would parse but tells the author nothing.
    local rlen
    rlen="$(printf '%s' "$E2E_VERDICT" | cut -d' ' -f3)"
    if [ "${rlen:-0}" -gt 0 ] 2>/dev/null; then
        pass "G5/block-carries-a-reason"
    else
        fail "G5/block-carries-a-reason" "verdict=$E2E_VERDICT out=$E2E_OUT err=$E2E_ERR"
    fi

    # --- approve half: same shape, one line under the threshold
    { echo "var x = 1;"; cmt 10 c; } > "$TMPDIR_BASE/e2e.ok"
    mkpayload Write "$REPO_M" "$f" "content=@$TMPDIR_BASE/e2e.ok"
    e2e_run
    assert_eq "G5/approve-exit-code-is-0" "0" "$E2E_RC"
    assert_eq "G5/approve-response-is-protocol-json" "OK approve" \
        "$(printf '%s' "$E2E_VERDICT" | cut -d' ' -f1-2)"

    # --- Edit half: the tool the issue was filed for, through the same command
    local g
    g="$( { echo "var x = 1;"; cmt 5 c; echo "MARK"; } | wfile "e2e-edit.js" )"
    printf 'MARK' > "$TMPDIR_BASE/e2e.old"
    cmtn 6 more > "$TMPDIR_BASE/e2e.new"
    local before; before="$(snap_file "$g")"
    mkpayload Edit "$REPO_M" "$g" \
        "old_string=@$TMPDIR_BASE/e2e.old" "new_string=@$TMPDIR_BASE/e2e.new"
    e2e_run
    assert_eq "G5/edit-exit-code-is-0" "0" "$E2E_RC"
    assert_eq "G5/edit-response-is-protocol-json" "OK block" \
        "$(printf '%s' "$E2E_VERDICT" | cut -d' ' -f1-2)"
    assert_file_untouched "G5/edit-target-untouched-by-the-hook" "$g" "$before"
    assert_file_absent "G5/proposed-new-file-never-created" "$REPO/e2e-block.js"
}

REG_ROW=""
g1_registered_once
g2_matcher_matches_the_sibling
g3_invocation_shape
g4_target_exists_and_runs
g5_registered_command_speaks_the_protocol
