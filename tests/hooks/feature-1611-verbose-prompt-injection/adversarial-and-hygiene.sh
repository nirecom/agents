#!/usr/bin/env bash
# tests/feature-1611-verbose-prompt-injection/adversarial-and-hygiene.sh
# Tests: hooks/lib/verbose-prompt.js, hooks/session-start.js, hooks/workflow-state/state-io.js
# Tags: hook, model-detection, session-state, prompt-injection, scope:issue-specific, TL2
#
# Fragment of tests/feature-1611-verbose-prompt-injection.sh — sourced by the
# parent, not run directly; cases run at source time. Owns groups J (adversarial
# session IDs: traversal / shell metacharacters / control characters), K
# (state-write failure and atomic-write hygiene) and I (CPR-SSOT drift check on
# the injected text).
#
# Depends on the parent for: TMPROOT, WFDIR, WFDIR_N, REPO_DIR, SESSION_START_JS,
# jsn, seed_state, run_with_timeout, to_node_path, assert_eq, pass, fail — and on
# provider-and-hooks.sh for VP_TEXT, VP_TEXT_OK, hook_out, contains.

# ---------------------------------------------------------------------------
echo ""
echo "=== J: adversarial session IDs ==="
# ---------------------------------------------------------------------------
#
# The session id reaches two places that build paths or spawn work from it:
# the read-only provider and SessionStart's own state handling. A traversal /
# metacharacter / control-character id must never create a file outside
# CLAUDE_WORKFLOW_DIR and must never reach a shell.

snapshot_outside_wfdir() {
    find "$TMPROOT" -mindepth 1 -not -path "$WFDIR" -not -path "$WFDIR/*" 2>/dev/null | LC_ALL=C sort
}
J_SNAPSHOT_BEFORE="$(snapshot_outside_wfdir)"

EVIL_TRAVERSAL='../../pwned-traversal'
EVIL_SHELL="a;touch $TMPROOT/pwned-semicolon;b"
EVIL_SUBSHELL="\$(touch $TMPROOT/pwned-subshell)"
EVIL_CONTROL="$(printf 'a\001b')"
EVIL_NEWLINE="$(printf 'a\nb')"

# evil_state_path <evil-sid> — print the raw, unsanitized path a state file
# for <evil-sid> would resolve to via path.join(WFDIR, sid + ".json"): the
# exact join formula getStatePath()/seed_state() use, with no validation.
evil_state_path() {
    run_with_timeout 30 node -e '
const path = require("path");
process.stdout.write(path.join(process.argv[2], process.argv[1] + ".json"));
' "$1" "$WFDIR_N" 2>/dev/null
}

j_idx=0
for evil in "$EVIL_TRAVERSAL" "$EVIL_SHELL" "$EVIL_SUBSHELL" "$EVIL_CONTROL" "$EVIL_NEWLINE"; do
    j_idx=$((j_idx + 1))

    # Seed a legitimate-looking state file (verbose_prompt: true) at the exact
    # location readState() would resolve to for this id if SESSION_ID_VALID_RE
    # were broken (seed_state uses the same unsanitized path.join formula as
    # getStatePath()). Without this, a "null" result is trivially true because
    # no file exists yet — it proves nothing about id-validation actually
    # rejecting the id. With the file present, "null" can only come from the
    # isUsableSessionId()/SESSION_ID_VALID_RE gate refusing to look it up.
    evil_path="$(evil_state_path "$evil")"
    seed_state "$evil" '{"verbose_prompt":true}'

    # Provider must refuse, never build a path from it — even with a seeded
    # verbose_prompt:true file sitting at the resolved location.
    assert_eq "J01-$j_idx-provider-returns-null" "null" \
        "$(jsn "VP.getVerbosePromptInjection(process.env.EVIL_SID)" \
              "EVIL_SID=$evil")"

    # Clean up immediately: the traversal id resolves outside $TMPROOT (which
    # the top-level trap does not clean), and any leftover file here would
    # also corrupt the J04/J05 outside-workflow-dir canary checks below.
    [ -n "$evil_path" ] && rm -f "$evil_path" 2>/dev/null
done

# SessionStart with an adversarial session_id must still emit valid JSON.
TMPROOT_FWD="$(printf '%s' "$TMPROOT" | sed 's#\\#/#g')"
J_STDIN_TRAVERSAL='{"session_id":"../../pwned-traversal"}'
J_STDIN_CONTROL='{"session_id":"ab"}'
J_STDIN_SHELL="{\"session_id\":\"a;touch $TMPROOT_FWD/pwned-hookshell;b\"}"

j_idx=0
for stdin_json in "$J_STDIN_TRAVERSAL" "$J_STDIN_CONTROL" "$J_STDIN_SHELL"; do
    j_idx=$((j_idx + 1))
    J_OUT="$(hook_out "$SESSION_START_JS" "$stdin_json" 'VERBOSE_PROMPT_MODELS=deepseek')"
    J_VALID="$(printf '%s' "$J_OUT" | run_with_timeout 30 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
  try { JSON.parse(s); process.stdout.write("ok"); } catch (e) { process.stdout.write("bad"); }
});' 2>/dev/null)"
    assert_eq "J03-$j_idx-sessionstart-emits-valid-json" "ok" "$J_VALID"
done

# No command was executed and no file escaped the workflow directory.
for canary in pwned-semicolon pwned-subshell pwned-hookshell pwned-traversal; do
    if [ -e "$TMPROOT/$canary" ] || [ -e "$TMPROOT/../$canary" ]; then
        fail "J04-no-canary-$canary" "an adversarial session id produced $canary — command or path injection"
    else
        pass "J04-no-canary-$canary"
    fi
done

if [ "$J_SNAPSHOT_BEFORE" = "$(snapshot_outside_wfdir)" ]; then
    pass "J05-nothing-written-outside-workflow-dir"
else
    fail "J05-nothing-written-outside-workflow-dir" \
        "path set changed: $(diff <(printf '%s\n' "$J_SNAPSHOT_BEFORE") <(snapshot_outside_wfdir) | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== K: state-write failure and atomic-write hygiene ==="
# ---------------------------------------------------------------------------
#
# CLAUDE_WORKFLOW_DIR is pointed at a regular file, so every open/mkdir beneath
# it fails with ENOTDIR. Both consumers must fail open, and neither may leave a
# half-written temp file behind (writeState uses tmp+rename).

BROKEN_WFDIR="$TMPROOT/not-a-directory"
printf 'this is a file, not a directory\n' > "$BROKEN_WFDIR"
BROKEN_WFDIR_N="$(to_node_path "$BROKEN_WFDIR")"

K02_OUT="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-k02","model":"deepseek-v4-flash"}' \
    'VERBOSE_PROMPT_MODELS=deepseek' "CLAUDE_WORKFLOW_DIR=$BROKEN_WFDIR_N")"
K02_VALID="$(printf '%s' "$K02_OUT" | run_with_timeout 30 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
  try { JSON.parse(s); process.stdout.write("ok"); } catch (e) { process.stdout.write("bad"); }
});' 2>/dev/null)"
assert_eq "K02-sessionstart-valid-json-on-unwritable-dir" "ok" "$K02_VALID"
if contains "$VP_TEXT" "$K02_OUT"; then
    fail "K02b-no-injection-when-state-unwritable" "injected although the flag could never be persisted"
else
    pass "K02b-no-injection-when-state-unwritable"
fi

assert_eq "K03-broken-dir-not-clobbered" "this is a file, not a directory" "$(cat "$BROKEN_WFDIR")"

# Atomic-write hygiene across every successful write performed above.
LEFTOVER="$(find "$WFDIR" -name '*.tmp*' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
if [ -z "$LEFTOVER" ]; then pass "K04-no-leftover-tmp-files"
else fail "K04-no-leftover-tmp-files" "found: $LEFTOVER"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== I: single source of the injected text (CPR-SSOT drift check) ==="
# ---------------------------------------------------------------------------

case "$VP_TEXT_OK" in
    0)
        fail "I01-text-defined-once" "VERBOSE_PROMPT_TEXT unavailable (module not implemented yet)"
        ;;
    *)
        HITS="$(grep -rlF "$VP_TEXT" "$REPO_DIR" \
            --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tests 2>/dev/null | sort -u)"
        COUNT="$(printf '%s\n' "$HITS" | grep -c . || true)"
        if [ "$COUNT" = "1" ] && [ "$(basename "$HITS")" = "verbose-prompt.js" ]; then
            pass "I01-text-defined-once"
        else
            fail "I01-text-defined-once" "want exactly hooks/lib/verbose-prompt.js, got: $(printf '%s' "$HITS" | tr '\n' ' ')"
        fi
        ;;
esac
