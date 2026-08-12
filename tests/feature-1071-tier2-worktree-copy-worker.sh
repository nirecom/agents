#!/bin/bash
# tests/feature-1071-tier2-worktree-copy-worker.sh
# Tests: bin/worker-dispatch/workers/worktree-copy.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/emit.js, skills/worktree-start/SKILL.md, bin/worktree-copy-include.js
# Tags: static, worker, worker-dispatch, worktree-copy, worktree-start, TL2, scope:issue-specific
#
# Tier 2 contract test for the worktree-copy worker (originally issue #1071).
# #1643 replaced the LLM subagent agents/worktree-copy-worker.md with the plain
# script bin/worker-dispatch/workers/worktree-copy.js, dispatched by
# skills/worktree-start/SKILL.md step WS-7 through skills/_shared/worker-dispatch.md.
# The contract each case guards is unchanged; only its subject moved from prose to
# code, so the assertions now run against the module, the registry SSOT and the
# renderer instead of grepping a deleted .md file.
#
# TL3 gap (what this test does NOT catch):
# - a real /worktree-start run driving the dispatcher through the Claude Code Bash tool
# - runtime copy correctness for gitignored files inside a real linked worktree
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
WORKER_JS="${AGENTS_DIR}/bin/worker-dispatch/workers/worktree-copy.js"
REGISTRY_JS="${AGENTS_DIR}/hooks/lib/worker-dispatch-registry.js"
EMIT_JS="${AGENTS_DIR}/bin/worker-dispatch/emit.js"
WS_MD="${AGENTS_DIR}/skills/worktree-start/SKILL.md"
SHARED_MD="skills/_shared/worker-dispatch.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# ── Test 1: worker module exists ──────────────────────────────────────────────
test_worker_exists() {
    if [ -f "$WORKER_JS" ]; then
        pass "1: bin/worker-dispatch/workers/worktree-copy.js exists"
    else
        fail "1: bin/worker-dispatch/workers/worktree-copy.js missing"
    fi
}

# ── Test 2: output contract is the status/summary/artifact_path triple ────────
# The prose `## Output contract` block became a renderer selection in the
# registry SSOT plus emit.js. Drive the real renderer for this worker's entry and
# assert the rendered bytes are the 3-key triple in the contract order.
test_output_contract_lines() {
    if [ ! -f "$REGISTRY_JS" ] || [ ! -f "$EMIT_JS" ]; then
        fail "2: registry or emit module missing — cannot check output contract"
        return
    fi
    local out
    out=$(run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      const emit = require(process.argv[2]);
      const entry = reg.workers["worktree-copy"];
      if (!entry) { process.stdout.write("NO-ENTRY"); process.exit(0); }
      if (!/^status-triple/.test(String(entry.renderer))) {
        process.stdout.write("RENDERER:" + entry.renderer); process.exit(0);
      }
      const text = emit.render(entry, {
        status: "complete",
        summary: "3 files copied; WORKTREE_NOTES.md written",
        artifactPath: "/tmp/a.log",
      });
      const keys = text.split("\n").filter((l) => l !== "").map((l) => l.split(":")[0]);
      process.stdout.write(keys.join(","));
    ' "$(nodepath "$REGISTRY_JS")" "$(nodepath "$EMIT_JS")" 2>&1)
    if [ "$out" = "status,summary,artifact_path" ]; then
        pass "2: rendered output contract is status/summary/artifact_path (in order)"
    else
        fail "2: output contract incorrect" "rendered keys='$out'"
    fi
}

# ── Test 3: status enum complete|partial|failed is produced by the worker ─────
test_status_enum() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "3: worker module missing — cannot check status enum"
        return
    fi
    local has_complete has_partial has_failed
    has_complete=0; has_partial=0; has_failed=0
    grep -qE '"complete"' "$WORKER_JS" && has_complete=1
    grep -qE '"partial"'  "$WORKER_JS" && has_partial=1
    grep -qE '"failed"'   "$WORKER_JS" && has_failed=1
    if [ "$has_complete" -eq 1 ] && [ "$has_partial" -eq 1 ] && [ "$has_failed" -eq 1 ]; then
        pass "3: worker produces status values complete, partial, failed"
    else
        fail "3: status enum missing variants" "complete=$has_complete partial=$has_partial failed=$has_failed"
    fi
}

# ── Test 4: no sentinels, AskUserQuestion, or skill invocations in worker ─────
test_no_sentinels_no_ask_no_skills() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "4: worker module missing — cannot check prohibited content"
        return
    fi
    local found_sentinel found_ask found_skill_invoke
    found_sentinel=0; found_ask=0; found_skill_invoke=0
    grep -qE '<<[[:space:]]*WORKFLOW_' "$WORKER_JS" && found_sentinel=1
    grep -qF 'AskUserQuestion' "$WORKER_JS" && found_ask=1
    # skill invocation pattern: `/skill-name` in prose or a Skill tool call
    grep -qE '`/[a-z]|Skill tool' "$WORKER_JS" && found_skill_invoke=1
    if [ "$found_sentinel" -eq 0 ] && [ "$found_ask" -eq 0 ] && [ "$found_skill_invoke" -eq 0 ]; then
        pass "4: worker has no sentinels, AskUserQuestion, or skill invocations"
    else
        fail "4: worker contains prohibited content" "sentinels=$found_sentinel ask=$found_ask skill_invoke=$found_skill_invoke"
    fi
}

# ── Test 5: input contract has all 6 required fields ─────────────────────────
# The input contract is now the registry payloadSpec, not prose.
test_input_contract_fields() {
    if [ ! -f "$REGISTRY_JS" ]; then
        fail "5: registry missing — cannot check input contract"
        return
    fi
    local missing
    missing=$(run_with_timeout 30 node -e '
      const reg = require(process.argv[1]);
      const entry = reg.workers["worktree-copy"];
      const spec = (entry && entry.payloadSpec) || {};
      const want = ["main_root","worktree_path","branch","session_id","agents_config_dir","artifact_dir"];
      process.stdout.write(want.filter((f) => !Object.prototype.hasOwnProperty.call(spec, f)).join(" "));
    ' "$(nodepath "$REGISTRY_JS")" 2>&1)
    if [ -z "$missing" ]; then
        pass "5: registry payloadSpec has all 6 required fields"
    else
        fail "5: input contract missing fields: $missing"
    fi
}

# ── Test 6: worktree-start WS-7 dispatches worktree-copy via the shared protocol ─
test_ws_references_worker() {
    if [ ! -f "$WS_MD" ]; then
        fail "6: skills/worktree-start/SKILL.md missing"
        return
    fi
    local ws7 has_worker has_shared
    ws7=$(grep -E '^WS-7\.' "$WS_MD")
    has_worker=0; has_shared=0
    printf '%s' "$ws7" | grep -qF 'worktree-copy' && has_worker=1
    printf '%s' "$ws7" | grep -qF "$SHARED_MD" && has_shared=1
    if [ "$has_worker" -eq 1 ] && [ "$has_shared" -eq 1 ]; then
        pass "6: WS-7 names worker 'worktree-copy' and references $SHARED_MD"
    else
        fail "6: WS-7 dispatch reference incomplete" "worker=$has_worker shared=$has_shared ws7='$ws7'"
    fi
}

# ── Test 7: CONFIRM_WORKTREE is a config-dependent branch ────────────────
# Each branch is pinned explicitly rather than checked by "both words appear
# somewhere": a SKILL.md that mentioned the flag and called AskUserQuestion
# unconditionally would satisfy a co-occurrence check while ignoring the flag.
test_ws_confirm_worktree_ask() {
    if [ ! -f "$WS_MD" ]; then
        fail "7: skills/worktree-start/SKILL.md missing"
        return
    fi
    local off_block on_block st missing
    off_block="$(sed -n '/CONFIRM_WORKTREE=OFF/,/CONFIRM_WORKTREE=ON/p' "$WS_MD")"
    on_block="$(sed -n '/CONFIRM_WORKTREE=ON/,/^WS-8/p' "$WS_MD")"
    if [ -n "$off_block" ] && [ -n "$on_block" ]; then
        pass "7a: OFF and ON branches are documented separately"
    else
        fail "7a: CONFIRM_WORKTREE branch blocks not found" "off=${#off_block} on=${#on_block}"
        return
    fi
    # OFF must not ask (an AskUserQuestion here hangs a non-interactive run);
    # ON must ask. Both must dispose of all three worker statuses.
    if printf '%s' "$off_block" | grep -qF 'AskUserQuestion'; then
        fail "7b: the OFF branch still calls AskUserQuestion"
    else
        pass "7b: the OFF branch proceeds without AskUserQuestion"
    fi
    if printf '%s' "$on_block" | grep -qF 'AskUserQuestion'; then
        pass "7c: the ON branch confirms via AskUserQuestion"
    else
        fail "7c: the ON branch does not call AskUserQuestion"
    fi
    missing=""
    for st in complete partial failed; do
        printf '%s' "$off_block" | grep -qF "status: $st" || missing="$missing off/$st"
        printf '%s' "$on_block"  | grep -qF "status: $st" || missing="$missing on/$st"
    done
    if [ -z "$missing" ]; then
        pass "7d: both branches dispose of complete, partial and failed"
    else
        fail "7d: a branch leaves statuses undisposed" "missing:$missing"
    fi
    if grep -q 'headless.*CONFIRM_WORKTREE. as OFF' "$WS_MD"; then
        pass "7e: headless mode is pinned to the OFF branch"
    else
        fail "7e: headless mode is not pinned to OFF"
    fi
}

# ── Test 7f-7h: the resolver behind the branch returns all three values ──────
# The prose above only matters if `bin/confirm-off CONFIRM_WORKTREE on` can
# actually produce OFF, ON and ERROR. ON is the fail-safe default, so it is
# driven with the flag explicitly `on` rather than left ambient.
test_confirm_worktree_resolver() {
    local co="$AGENTS_DIR/bin/confirm-off" want out rc
    if [ ! -f "$co" ]; then
        fail "7f: bin/confirm-off missing"
        return
    fi
    while IFS='|' read -r label envspec want; do
        [ -z "$label" ] && continue
        rc=0
        # shellcheck disable=SC2086
        out="$(run_with_timeout 30 env $envspec bash "$co" CONFIRM_WORKTREE on 2>/dev/null)" || rc=$?
        if [ "$out" = "${want%%,*}" ] && [ "$rc" -eq "${want##*,}" ]; then
            pass "$label"
        else
            fail "$label" "out='$out' rc=$rc want='$want'"
        fi
    done <<TABLE
7f: CONFIRM_WORKTREE=off resolves to OFF|AGENTS_CONFIG_DIR=$AGENTS_DIR CONFIRM_WORKTREE=off|OFF,0
7g: CONFIRM_WORKTREE=on resolves to ON|AGENTS_CONFIG_DIR=$AGENTS_DIR CONFIRM_WORKTREE=on|ON,1
7h: an unresolvable config resolves to ERROR, never OFF|-u AGENTS_CONFIG_DIR CONFIRM_WORKTREE=off|ERROR,2
TABLE
}

# ── Test 8: WS-10 and WS-11 step labels no longer both present (renumbered) ──
# After the split, the step that was WS-11 should shift. Either WS-11 is gone
# (renumbered up), or only a single WS-11 exists (the new final step).
# We assert that WS-10 is no longer the WORKTREE_NOTES step (it moved earlier
# to accommodate the new copy-worker step), detected by checking that
# WS-9b no longer uses bin/worktree-copy-include.js inline shell pipe
# (the worker replaced that inline logic).
test_ws_inline_copy_replaced() {
    if [ ! -f "$WS_MD" ]; then
        fail "8: skills/worktree-start/SKILL.md missing"
        return
    fi
    # After #1071: WS-9b dispatches to the worker agent, not the inline pipe
    # The old inline invocation piped to bin/worktree-copy-include.js
    if grep -qF 'worktree-copy-include.js' "$WS_MD"; then
        fail "8: worktree-start still uses inline bin/worktree-copy-include.js (not replaced by worker)"
    else
        pass "8: worktree-start no longer uses inline bin/worktree-copy-include.js (replaced by worker)"
    fi
}

test_worker_exists
test_output_contract_lines
test_status_enum
test_no_sentinels_no_ask_no_skills
test_input_contract_fields
test_ws_references_worker
test_ws_confirm_worktree_ask
test_confirm_worktree_resolver
test_ws_inline_copy_replaced

# ── Tests 9-10: worktree-copy-include.js argv form + legacy stdin backward-compat ──
# Added for #1102: bin/worktree-copy-include.js gained a new argv form
# (--main-root / --worktree-path / --include-file) while keeping legacy stdin JSON.
# Both forms must produce a JSON object with {copied, skipped, denied, errors}.

COPY_INCLUDE_SCRIPT="${AGENTS_DIR}/bin/worktree-copy-include.js"

_TMPDIR_1071="$(mktemp -d)"
trap 'rm -rf "$_TMPDIR_1071"' EXIT

# Create a minimal git-repo fixture (main worktree) with a .worktreeinclude file
# and a gitignored file that should be copied.
_MAIN_ROOT="$_TMPDIR_1071/main"
_WORKTREE_PATH="$_TMPDIR_1071/wt"
mkdir -p "$_MAIN_ROOT" "$_WORKTREE_PATH"
git -C "$_MAIN_ROOT" -c init.defaultBranch=main init --quiet
git -C "$_MAIN_ROOT" config user.email "test@example.com"
git -C "$_MAIN_ROOT" config user.name "Test"
git -C "$_MAIN_ROOT" config core.hooksPath /dev/null
# Track a source file.
printf 'tracked\n' > "$_MAIN_ROOT/tracked.md"
git -C "$_MAIN_ROOT" add tracked.md
git -C "$_MAIN_ROOT" commit --quiet -m "init"
# Create a gitignored file by adding it to .gitignore.
printf '*.secret\n' > "$_MAIN_ROOT/.gitignore"
printf 'secret content\n' > "$_MAIN_ROOT/config.secret"
git -C "$_MAIN_ROOT" add .gitignore
git -C "$_MAIN_ROOT" commit --quiet -m "add gitignore"
# Write .worktreeinclude to include *.secret files.
printf '*.secret\n' > "$_MAIN_ROOT/.worktreeinclude"

# Helper: check JSON output has the four expected keys.
_has_result_keys() {
    node -e "
      try {
        const o = JSON.parse(process.argv[1]);
        const ok = ['copied','skipped','denied','errors'].every(k => Array.isArray(o[k]));
        process.stdout.write(ok ? 'yes' : 'no');
      } catch(e) { process.stdout.write('no: ' + e.message); }
    " "$1" 2>/dev/null
}

# ── Test 9: argv form runs and produces expected output ───────────────────────
test_argv_form() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "9: bin/worktree-copy-include.js missing"
        return
    fi
    local out rc
    out=$(run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" \
        --main-root "$_MAIN_ROOT" \
        --worktree-path "$_WORKTREE_PATH" 2>/dev/null)
    rc=$?
    local has_keys
    has_keys=$(_has_result_keys "$out")
    # config.secret should be in copied[] (matched by .worktreeinclude, gitignored).
    local copied
    copied=$(node -e "
      try {
        const o = JSON.parse(process.argv[1]);
        process.stdout.write(JSON.stringify(o.copied));
      } catch(e) { process.stdout.write('[]'); }
    " "$out" 2>/dev/null)
    # Content assertion (anti-false-green): config.secret (gitignored, matched by
    # .worktreeinclude) MUST appear in copied[]. A silently-broken copy that emits
    # an empty copied[] now FAILS instead of passing on key-presence alone.
    local has_secret
    has_secret=$(node -e "
      try {
        const o = JSON.parse(process.argv[1]);
        const found = Array.isArray(o.copied) &&
          o.copied.some(p => /(^|[\\\\/])config\.secret$/.test(String(p)));
        process.stdout.write(found ? 'yes' : 'no');
      } catch(e) { process.stdout.write('no'); }
    " "$out" 2>/dev/null)
    if [ "$rc" -eq 0 ] && [ "$has_keys" = "yes" ] && [ "$has_secret" = "yes" ]; then
        pass "9: argv form copies gitignored config.secret into copied[] (rc=0, has_keys=yes, copied=$copied)"
    else
        fail "9: argv form" "rc=$rc has_keys=$has_keys has_secret=$has_secret out='$out'"
    fi
}

# ── Test 10: legacy stdin JSON form still works (backward-compat) ─────────────
test_legacy_stdin_form() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "10: bin/worktree-copy-include.js missing"
        return
    fi
    # Use a fresh destination to avoid interference from test 9.
    local wt2="$_TMPDIR_1071/wt2"
    mkdir -p "$wt2"
    local json_input
    json_input=$(node -e "process.stdout.write(JSON.stringify({mainRoot: process.argv[1], worktreePath: process.argv[2], includeFile: null}))" \
        "$_MAIN_ROOT" "$wt2" 2>/dev/null)
    local out rc
    out=$(printf '%s' "$json_input" | run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" 2>/dev/null)
    rc=$?
    local has_keys
    has_keys=$(_has_result_keys "$out")
    # Content assertion (anti-false-green): same as T9 — config.secret must be copied.
    local has_secret
    has_secret=$(node -e "
      try {
        const o = JSON.parse(process.argv[1]);
        const found = Array.isArray(o.copied) &&
          o.copied.some(p => /(^|[\\\\/])config\.secret$/.test(String(p)));
        process.stdout.write(found ? 'yes' : 'no');
      } catch(e) { process.stdout.write('no'); }
    " "$out" 2>/dev/null)
    if [ "$rc" -eq 0 ] && [ "$has_keys" = "yes" ] && [ "$has_secret" = "yes" ]; then
        pass "10: legacy stdin JSON form copies gitignored config.secret into copied[] (backward-compat)"
    else
        fail "10: legacy stdin form" "rc=$rc has_keys=$has_keys has_secret=$has_secret out='$out'"
    fi
}

test_argv_form
test_legacy_stdin_form

# ── Tests 11-13: SECURITY — CWE-22 path-traversal guard (hasTraversal gate) ───
#
# Exit status alone is not proof of protection: a script can reject with rc=1
# after already having read or written through the traversal. Each case below
# therefore aims its `..` segment at a canary zone inside the fixture and
# asserts the zone is BYTE-UNCHANGED afterwards — same file set, same contents.
# (`hasTraversal` inspects the raw string, so a `..` aimed inside the fixture is
# rejected exactly like one aimed at /etc.)
_CANARY="$_TMPDIR_1071/canary-zone"
mkdir -p "$_CANARY/wt"
printf 'canary: this file must never be read through, written to, or replaced\n' > "$_CANARY/passwd"
printf '*.secret\n' > "$_CANARY/.worktreeinclude"
printf 'pre-existing destination content\n' > "$_CANARY/wt/keep.txt"

# Fingerprint = every relative path under the zone plus a hash of its bytes.
# A new file, a deleted file or a changed byte all move the fingerprint.
_canary_fingerprint() {
    node -e '
      const fs = require("fs"), path = require("path"), crypto = require("crypto");
      const root = process.argv[1];
      const rows = [];
      (function walk(d, rel) {
        for (const e of fs.readdirSync(d, { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : 1)) {
          const p = path.join(d, e.name), r = rel ? rel + "/" + e.name : e.name;
          if (e.isDirectory()) { rows.push("D " + r); walk(p, r); }
          else rows.push("F " + r + " " + crypto.createHash("sha256").update(fs.readFileSync(p)).digest("hex"));
        }
      })(root, "");
      process.stdout.write(rows.join("\n"));
    ' "$_CANARY" 2>/dev/null
}

# assert_canary_intact <test-label> <rc> <before-fingerprint>
assert_canary_intact() {
    local label="$1" rc="$2" before="$3" after
    after="$(_canary_fingerprint)"
    if [ -z "$before" ]; then
        fail "$label: canary fixture produced no fingerprint — the case proves nothing"
        return
    fi
    if [ "$rc" -eq 0 ]; then
        fail "$label: traversal not rejected" "rc=$rc (expected non-zero)"
        return
    fi
    if [ "$after" = "$before" ]; then
        pass "$label (rc=$rc, canary zone byte-unchanged)"
    else
        fail "$label: canary zone was modified despite the rejection" \
            "$(diff <(printf '%s' "$before") <(printf '%s' "$after") 2>&1 | head -6)"
    fi
}

# bin/worktree-copy-include.js rejects any path field whose normalized form
# contains a `..` segment (lines: hasTraversal + exit 1). Each test supplies a
# `..` segment in one field and asserts rc != 0. The argv branch is only taken
# when --main-root is present, so the worktree-path and include-file cases keep a
# valid --main-root and inject the traversal into the field under test.

# ── Test 11: --main-root with `..` traversal → exit non-zero ──────────────────
test_traversal_main_root() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "11: bin/worktree-copy-include.js missing"
        return
    fi
    local rc before
    before="$(_canary_fingerprint)"
    run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" \
        --main-root "$_MAIN_ROOT/../canary-zone" \
        --worktree-path "$_WORKTREE_PATH" >/dev/null 2>&1
    rc=$?
    assert_canary_intact "11: SECURITY — --main-root with '..' traversal rejected" "$rc" "$before"
}

# ── Test 12: --worktree-path with `..` traversal → exit non-zero ──────────────
test_traversal_worktree_path() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "12: bin/worktree-copy-include.js missing"
        return
    fi
    local rc before
    before="$(_canary_fingerprint)"
    run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" \
        --main-root "$_MAIN_ROOT" \
        --worktree-path "$_MAIN_ROOT/../canary-zone/wt" >/dev/null 2>&1
    rc=$?
    assert_canary_intact "12: SECURITY — --worktree-path with '..' traversal rejected" "$rc" "$before"
}

# ── Test 13: --include-file with `..` traversal → exit non-zero ───────────────
# Source guards includeFile too: `if (input.includeFile && hasTraversal(...))`.
test_traversal_include_file() {
    if [ ! -f "$COPY_INCLUDE_SCRIPT" ]; then
        fail "13: bin/worktree-copy-include.js missing"
        return
    fi
    local rc before
    before="$(_canary_fingerprint)"
    run_with_timeout 30 node "$COPY_INCLUDE_SCRIPT" \
        --main-root "$_MAIN_ROOT" \
        --worktree-path "$_WORKTREE_PATH" \
        --include-file "$_MAIN_ROOT/../canary-zone/.worktreeinclude" >/dev/null 2>&1
    rc=$?
    assert_canary_intact "13: SECURITY — --include-file with '..' traversal rejected" "$rc" "$before"
}

test_traversal_main_root
test_traversal_worktree_path
test_traversal_include_file

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
