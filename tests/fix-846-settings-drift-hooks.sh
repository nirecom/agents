#!/bin/bash
# tests/fix-846-settings-drift-hooks.sh
# Tests: hooks/post-merge, hooks/post-checkout
# Tags: hook, settings, drift, post-merge, post-checkout, scope:common
# (scope:common, not scope:issue-specific: skills/_shared/test-design.md keys the classification
# on the FILENAME, and only a `feature-NNN-*` name is issue-specific. `fix-846-*` is not one.)
# Tests for issue #846 — git hooks that auto-reassemble ~/.claude/settings.json.
# Drift-detection module tests (T1-T8) and session-start tests (T17-T19) live in
# fix-846-settings-drift.sh.

set -u

# L2 narrow integration: hook trigger logic on sandbox git repos with stub assemblers, each in
# its own mktemp -d, never modifying the real ~/.claude/settings.json.
#
# The STUB assembler here is deliberate: it isolates TRIGGER logic from assembler behaviour, so a
# failing row names the trigger and nothing else. The other half -- both hooks driven against the
# REAL install/assemble-settings.js, with a fixture-private HOME, asserting the deployed settings
# really gains the generated rules, stays byte-identical when the assembler fails, and lets the
# assembler's own diagnostic through -- is covered at TL2 in
# tests/feature-2119-settings-allow-ssot/hook-callers.sh (T37). Neither file needs a real machine.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

POST_MERGE="$AGENTS_DIR/hooks/post-merge"
POST_CHECKOUT="$AGENTS_DIR/hooks/post-checkout"

# TL3 gap -- exactly two things, both needing a real machine. (1) The installer entry points:
# whether install/linux/dotfileslink.sh and install/win/dotfileslink.ps1 still install these two
# hooks at all; each runs on one platform only and neither may touch a developer's home. (2) A
# genuine `git checkout` / `git merge` routed through core.hooksPath, which every case here
# bypasses by invoking the script by path. Both are mitigated closest to the action, at the
# WORKFLOW_USER_VERIFIED preflight: (1) fires bin/check-verification-gate.sh category `installer`
# (install/ paths), (2) fires category `hook-registration` (hooks/post-merge, hooks/post-checkout).

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

require_source() {
    local path="$1" label="$2"
    if [ ! -f "$path" ]; then skip "$label (source not implemented yet)"; return 1; fi
    return 0
}

# --- Git hook helpers ---------------------------------------------------------

# init_sandbox_repo TYPE TMPDIR — creates a bare sandbox repo with no hooks.
init_sandbox_repo() {
    local typ="$1" tmp="$2"
    git init -q "$tmp"
    git -C "$tmp" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" config user.name "Test"
    git -C "$tmp" config commit.gpgsign false
    git -C "$tmp" config init.defaultBranch main >/dev/null 2>&1 || true
}

# Build a "fake agents" repo: copy the hooks into a fresh git repo so $0 dirname
# resolves to the sandbox top, allowing the repo guard to pass.
init_agents_sandbox() {
    local tmp="$1"
    git init -q "$tmp"
    git -C "$tmp" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" config user.name "Test"
    git -C "$tmp" config commit.gpgsign false
    mkdir -p "$tmp/hooks/lib" "$tmp/install"
    [ -f "$POST_MERGE" ] && cp "$POST_MERGE" "$tmp/hooks/post-merge" && chmod +x "$tmp/hooks/post-merge"
    [ -f "$POST_CHECKOUT" ] && cp "$POST_CHECKOUT" "$tmp/hooks/post-checkout" && chmod +x "$tmp/hooks/post-checkout"
    # Stub assembler: writes a sentinel file when invoked
    cat > "$tmp/install/assemble-settings.js" <<'NODEEOF'
#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const sentinel = process.env.ASSEMBLER_SENTINEL || path.join(__dirname, 'assembled.sentinel');
fs.writeFileSync(sentinel, String(Date.now()), 'utf8');
NODEEOF
    chmod +x "$tmp/install/assemble-settings.js"
    # Create an initial settings.json so commits can reference it
    echo '{}' > "$tmp/settings.json"
    echo '{}' > "$tmp/settings-extension.json"
    git -C "$tmp" add -A
    # ENFORCE_WORKTREE=off: the global pre-commit hook (agents/hooks/pre-commit) blocks commits on
    # standalone repos (git-common-dir == git-dir); bypass enforcement for sandbox commits.
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "initial"
}

# --- T9: post-merge in non-agents repo → no assembler call (exit 0) -----------
run_t9() {
    require_source "$POST_MERGE" "T9: post-merge non-agents repo no-op" || return
    local tmp; tmp="$(mktemp -d)"
    init_sandbox_repo "other" "$tmp"
    # Copy hook in but DON'T set up the agents layout — the guard should bail
    cp "$POST_MERGE" "$tmp/post-merge"
    chmod +x "$tmp/post-merge"
    local sentinel="$tmp/assembled.sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash "$tmp/post-merge" >/dev/null 2>&1
    local rc=$?
    if [ $rc -eq 0 ] && [ ! -f "$sentinel" ]; then
        pass "T9: post-merge non-agents repo no-op"
    else
        fail "T9: post-merge non-agents repo no-op (rc=$rc, sentinel exists: $([ -f "$sentinel" ] && echo yes || echo no))"
    fi
    rm -rf "$tmp"
}

# --- T10: post-merge, settings.json changed → assembler called ----------------
run_t10() {
    require_source "$POST_MERGE" "T10: post-merge settings.json changed → assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    # Create a branch + change settings.json + merge it
    git -C "$tmp" checkout -q -b feature
    echo '{"changed":true}' > "$tmp/settings.json"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "change settings"
    git -C "$tmp" checkout -q main 2>/dev/null || git -C "$tmp" checkout -q master 2>/dev/null
    # Use no-ff merge so ORIG_HEAD is set distinctly
    git -C "$tmp" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-merge" >/dev/null 2>&1
    if [ -f "$sentinel" ]; then
        pass "T10: post-merge settings.json changed → assembler"
    else
        fail "T10: post-merge settings.json changed → assembler (sentinel missing)"
    fi
    rm -rf "$tmp"
}

# --- T11: post-merge, settings.json NOT changed → no assembler call -----------
run_t11() {
    require_source "$POST_MERGE" "T11: post-merge settings.json unchanged → no assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    git -C "$tmp" checkout -q -b feature
    echo "// unrelated change" > "$tmp/unrelated.txt"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "unrelated"
    git -C "$tmp" checkout -q main 2>/dev/null || git -C "$tmp" checkout -q master 2>/dev/null
    git -C "$tmp" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-merge" >/dev/null 2>&1
    if [ ! -f "$sentinel" ]; then
        pass "T11: post-merge settings.json unchanged → no assembler"
    else
        fail "T11: post-merge settings.json unchanged → no assembler (sentinel exists)"
    fi
    rm -rf "$tmp"
}

# --- T12: post-merge, settings-extension.json changed → assembler called ------
run_t12() {
    require_source "$POST_MERGE" "T12: post-merge settings-extension changed → assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    git -C "$tmp" checkout -q -b feature
    echo '{"ext":"changed"}' > "$tmp/settings-extension.json"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "change ext"
    git -C "$tmp" checkout -q main 2>/dev/null || git -C "$tmp" checkout -q master 2>/dev/null
    git -C "$tmp" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-merge" >/dev/null 2>&1
    if [ -f "$sentinel" ]; then
        pass "T12: post-merge settings-extension changed → assembler"
    else
        fail "T12: post-merge settings-extension changed → assembler (sentinel missing)"
    fi
    rm -rf "$tmp"
}

# --- T13: post-checkout $3=0 (file checkout) → no assembler call --------------
run_t13() {
    require_source "$POST_CHECKOUT" "T13: post-checkout file-checkout no-op" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    local sha; sha="$(git -C "$tmp" rev-parse HEAD)"
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$sha' '$sha' 0" >/dev/null 2>&1
    if [ ! -f "$sentinel" ]; then
        pass "T13: post-checkout file-checkout no-op"
    else
        fail "T13: post-checkout file-checkout no-op (sentinel exists)"
    fi
    rm -rf "$tmp"
}

# --- T14: post-checkout $3=1, settings.json changed → assembler called --------
run_t14() {
    require_source "$POST_CHECKOUT" "T14: post-checkout settings.json changed → assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    local sha_prev; sha_prev="$(git -C "$tmp" rev-parse HEAD)"
    git -C "$tmp" checkout -q -b feature
    echo '{"changed":true}' > "$tmp/settings.json"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "change settings"
    local sha_new; sha_new="$(git -C "$tmp" rev-parse HEAD)"
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$sha_prev' '$sha_new' 1" >/dev/null 2>&1
    if [ -f "$sentinel" ]; then
        pass "T14: post-checkout settings.json changed → assembler"
    else
        fail "T14: post-checkout settings.json changed → assembler (sentinel missing)"
    fi
    rm -rf "$tmp"
}

# --- T15: post-checkout $3=1, settings.json NOT changed → no assembler --------
run_t15() {
    require_source "$POST_CHECKOUT" "T15: post-checkout settings.json unchanged → no assembler" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    local sha_prev; sha_prev="$(git -C "$tmp" rev-parse HEAD)"
    git -C "$tmp" checkout -q -b feature
    echo "// unrelated" > "$tmp/unrelated.txt"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "unrelated"
    local sha_new; sha_new="$(git -C "$tmp" rev-parse HEAD)"
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$sha_prev' '$sha_new' 1" >/dev/null 2>&1
    if [ ! -f "$sentinel" ]; then
        pass "T15: post-checkout settings.json unchanged → no assembler"
    else
        fail "T15: post-checkout settings.json unchanged → no assembler (sentinel exists)"
    fi
    rm -rf "$tmp"
}

# --- T16: post-checkout $3=1, $1=0000... (initial clone) → no assembler -------
run_t16() {
    require_source "$POST_CHECKOUT" "T16: post-checkout initial clone no-op" || return
    local tmp; tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    local sha_new; sha_new="$(git -C "$tmp" rev-parse HEAD)"
    local zero="0000000000000000000000000000000000000000"
    local sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$zero' '$sha_new' 1" >/dev/null 2>&1
    if [ ! -f "$sentinel" ]; then
        pass "T16: post-checkout initial clone no-op"
    else
        fail "T16: post-checkout initial clone no-op (sentinel exists)"
    fi
    rm -rf "$tmp"
}

# --- Two-stage trigger for the allow-rule SSOT (issue #2119) ------------------
# The trigger becomes two stages. Stage 1 is a fixed list that now also carries
# install/settings-allow-commands.txt; stage 2 is read OUT of that file — the
# command paths whose spellings the generated allow rules are built from.
# Editing bin/fx-tool moves the deployed permission surface exactly as editing
# settings.json does, and nothing re-assembles for it today. The negative rows
# keep the widening honest: a path in neither stage still gets no assembler.
seed_allow_ssot() {
    local tmp="$1"
    mkdir -p "$tmp/install" "$tmp/bin" "$tmp/docs"
    printf '%s\n' '# SSOT for which commands get allow rules' 'bin/fx-tool' \
        > "$tmp/install/settings-allow-commands.txt"
    printf '%s\n' '#!/usr/bin/env bash' 'echo fx-tool' > "$tmp/bin/fx-tool"
    chmod +x "$tmp/bin/fx-tool"
    printf '%s\n' 'unrelated prose' > "$tmp/docs/unrelated.md"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "seed allow-rule ssot"
}

# Rewrite the stage-2 SSOT with CRLF terminators in the WORKING TREE the hook reads, after every
# git operation is done. Doing it here and not in seed_allow_ssot keeps git's own eol handling
# (core.autocrlf, .gitattributes, whatever the host is configured with) out of the verdict: the
# bytes the hook greps are the bytes this line just wrote.
apply_ssot_eol() { # <tmp>
    [ "${SSOT_EOL:-lf}" = "crlf" ] || return 0
    printf '%s\r\n' '# SSOT for which commands get allow rules' 'bin/fx-tool' \
        > "$1/install/settings-allow-commands.txt"
}

# commit_change TMPDIR RELPATH — one commit touching exactly one file, so a
# firing hook can only be reacting to that path.
commit_change() {
    local tmp="$1" rel="$2" marker='#'
    # install/assemble-settings.js IS the stub whose sentinel the probe watches for. A `#` comment
    # appended to a node script is a syntax error, so the stub would die before writing, and a
    # trigger that FIRED correctly would be recorded as not-called. Take the comment syntax from
    # the extension so the edit stays a no-op for every file type the table touches.
    case "$rel" in *.js) marker='//' ;; esac
    mkdir -p "$(dirname "$tmp/$rel")"
    printf '%s\n' "$marker edited for the trigger probe" >> "$tmp/$rel"
    git -C "$tmp" add -A
    ENFORCE_WORKTREE=off git -C "$tmp" commit -q -m "change $rel"
}

probe_merge() { # <relpath> -> called|not-called
    local rel="$1" tmp sentinel
    tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    seed_allow_ssot "$tmp"
    git -C "$tmp" checkout -q -b feature
    commit_change "$tmp" "$rel"
    git -C "$tmp" checkout -q main 2>/dev/null || git -C "$tmp" checkout -q master 2>/dev/null
    git -C "$tmp" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
    apply_ssot_eol "$tmp"
    sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-merge" >/dev/null 2>&1
    if [ -f "$sentinel" ]; then printf 'called'; else printf 'not-called'; fi
    rm -rf "$tmp"
}

probe_checkout() { # <relpath> -> called|not-called
    local rel="$1" tmp sentinel sha_prev sha_new
    tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    seed_allow_ssot "$tmp"
    sha_prev="$(git -C "$tmp" rev-parse HEAD)"
    git -C "$tmp" checkout -q -b feature
    commit_change "$tmp" "$rel"
    sha_new="$(git -C "$tmp" rev-parse HEAD)"
    apply_ssot_eol "$tmp"
    sentinel="$tmp/install/assembled.sentinel"
    rm -f "$sentinel"
    ASSEMBLER_SENTINEL="$sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$sha_prev' '$sha_new' 1" >/dev/null 2>&1
    if [ -f "$sentinel" ]; then printf 'called'; else printf 'not-called'; fi
    rm -rf "$tmp"
}

# STAGE 1 IS A LIST, AND A LIST IS WHERE ENTRIES GET LOST. T20/T21 prove one of its new entries
# fires; every other input in the reassembly chain -- the second SSOT, both CLIs, and each of the
# three new install/lib modules -- would go untested, and a fixed ERE missing one of them produces
# exactly no symptom until somebody's machine silently stops re-deploying after a pull.
#
# The negative rows below are derived from the planned pattern, not invented: stage 1 matches
# `install/lib/[^/]+\.js` anchored at both ends (one directory level, .js only) and stage 2 uses
# `grep -qxF` (whole-line). So a nested module, a non-.js file beside the modules, and a longer
# sibling of an SSOT entry must NOT trigger -- and each is a shape the obvious loosening of the
# pattern would start matching.
run_trigger_rows() { # rows on stdin: <id>|<merge|checkout>|<relpath>|<want>|<label>
    # Shared by every trigger table here, so a second table cannot drift from the first in how
    # it reads a row or reports a mismatch.
    local id hook rel want label got
    while IFS='|' read -r id hook rel want label; do
        [ -n "$id" ] || continue
        if [ "$hook" = "merge" ]; then got="$(probe_merge "$rel")"; else got="$(probe_checkout "$rel")"; fi
        if [ "$got" = "$want" ]; then pass "$id: $label"; else fail "$id: $label (want $want, got $got)"; fi
    done
}

run_trigger_table() {
    require_source "$POST_MERGE" "T20-T47: two-stage trigger" || return
    require_source "$POST_CHECKOUT" "T20-T47: two-stage trigger (post-checkout)" || return
    run_trigger_rows <<'TRIGGER_CASES'
T20|merge|install/settings-allow-commands.txt|called|post-merge, the allow-rule SSOT changed alone → assembler (stage 1: the fixed list now carries the SSOT too)
T21|checkout|install/settings-allow-commands.txt|called|post-checkout, the same file across a branch switch → assembler (CPR-ORTH: one condition, both hooks)
T22|merge|bin/fx-tool|called|post-merge, a command file the SSOT lists changed alone → assembler (stage 2: its spellings ARE the generated rules)
T23|checkout|bin/fx-tool|called|post-checkout, the same dynamic match across a branch switch → assembler
T24|merge|docs/unrelated.md|not-called|NEGATIVE CONTROL post-merge: a path in neither stage leaves the assembler alone, so the widened trigger is not "always run"
T25|checkout|docs/unrelated.md|not-called|NEGATIVE CONTROL post-checkout: the same, so T11/T15 keep meaning what they meant
T30|merge|install/path-exposed-commands.txt|called|post-merge, the SECOND SSOT changed alone → assembler: it selects which commands get the path-form spellings, so editing it moves the deployed rules as surely as the first list does
T31|checkout|install/path-exposed-commands.txt|called|CPR-ORTH post-checkout, the same second SSOT across a branch switch
T32|merge|install/gen-settings-allow.js|called|post-merge, the generator itself changed → assembler: a change to how spellings are emitted rewrites every deployed rule without any input file moving
T33|checkout|install/gen-settings-allow.js|called|CPR-ORTH post-checkout, the same generator
T34|merge|install/assemble-settings.js|called|post-merge, the assembler entry point changed → assembler: the tool that performs the deploy is itself an input to what gets deployed
T35|checkout|install/assemble-settings.js|called|CPR-ORTH post-checkout, the same entry point
T36|merge|install/lib/settings-allow-rules.js|called|post-merge, the spelling-template module changed → assembler: this is where the 22 templates live, so a pull that changes it and does not re-deploy leaves a machine on the old rule set
T37|checkout|install/lib/settings-allow-rules.js|called|CPR-ORTH post-checkout, the same template module
T38|merge|install/lib/settings-assembly.js|called|post-merge, the merge-semantics module changed → assembler: it decides how generated rules combine with hand-written ones
T39|checkout|install/lib/settings-assembly.js|called|CPR-ORTH post-checkout, the same merge module
T40|merge|install/lib/settings-deploy.js|called|post-merge, the sole writer changed → assembler: the module that decides where and whether the file is written at all
T41|checkout|install/lib/settings-deploy.js|called|CPR-ORTH post-checkout, the same writer module
T42|merge|install/lib/nested/helper.js|not-called|NON-TRIGGER by the planned pattern post-merge: stage 1 matches ONE directory level under install/lib, so a nested file is out of scope and asserting otherwise would invent a trigger the plan does not describe
T43|checkout|install/lib/nested/helper.js|not-called|CPR-ORTH post-checkout, the same nested path stays out of scope
T44|merge|install/lib/NOTES.md|not-called|NON-TRIGGER post-merge: the pattern is keyed on .js, so prose sitting beside the modules does not re-deploy anything
T45|checkout|install/lib/NOTES.md|not-called|CPR-ORTH post-checkout, the same non-.js neighbour
T46|merge|bin/fx-tool-extra|not-called|NON-TRIGGER post-merge: stage 2 matches WHOLE LINES, so a longer sibling of the SSOT entry bin/fx-tool is not that entry -- a prefix match here would fire on unrelated commands forever after
T47|checkout|bin/fx-tool-extra|not-called|CPR-ORTH post-checkout, the same near-miss sibling
TRIGGER_CASES
}

# The `2>/dev/null` on the assembler call goes away with the widened trigger: a
# machine whose settings.json could not be rebuilt must be told why, not merely
# that it failed. Both exit polarities are probed on both hooks — the redirect
# sits on the condition of an if, so a half-removal would leak in one only.
write_noisy_stub() { # <tmp> <exit-code>
    printf '%s\n' \
        '#!/usr/bin/env node' \
        'const fs = require("fs");' \
        'const path = require("path");' \
        'process.stderr.write("STUB-DIAGNOSTIC-LINE\n");' \
        'const s = process.env.ASSEMBLER_SENTINEL || path.join(__dirname, "assembled.sentinel");' \
        'fs.writeFileSync(s, String(Date.now()), "utf8");' \
        "process.exit($2);" \
        > "$1/install/assemble-settings.js"
}

# settings.json is the file changed here on purpose: that trigger already works,
# so a failing row means the output was swallowed and nothing else.
probe_noisy() { # <merge|checkout> <exit-code> -> "<diag>/<message>"
    local hook="$1" code="$2" tmp out sha_prev sha_new diag msg
    tmp="$(mktemp -d)"
    init_agents_sandbox "$tmp"
    seed_allow_ssot "$tmp"
    sha_prev="$(git -C "$tmp" rev-parse HEAD)"
    git -C "$tmp" checkout -q -b feature
    commit_change "$tmp" settings.json
    sha_new="$(git -C "$tmp" rev-parse HEAD)"
    if [ "$hook" = "merge" ]; then
        git -C "$tmp" checkout -q main 2>/dev/null || git -C "$tmp" checkout -q master 2>/dev/null
        git -C "$tmp" merge -q --no-ff -m "merge feature" feature >/dev/null 2>&1
    fi
    write_noisy_stub "$tmp" "$code"
    rm -f "$tmp/install/assembled.sentinel"
    if [ "$hook" = "merge" ]; then
        out="$(ASSEMBLER_SENTINEL="$tmp/install/assembled.sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-merge" 2>&1)"
    else
        out="$(ASSEMBLER_SENTINEL="$tmp/install/assembled.sentinel" run_with_timeout 10 bash -c "cd '$tmp' && bash hooks/post-checkout '$sha_prev' '$sha_new' 1" 2>&1)"
    fi
    rm -rf "$tmp"
    if printf '%s\n' "$out" | grep -q 'STUB-DIAGNOSTIC-LINE'; then diag="surfaced"; else diag="SWALLOWED"; fi
    if [ "$code" = "0" ]; then
        if printf '%s\n' "$out" | grep -q 're-assembled'; then msg="reported"; else msg="NO-MESSAGE"; fi
    else
        if printf '%s\n' "$out" | grep -q 'assembler failed'; then msg="reported"; else msg="NO-MESSAGE"; fi
    fi
    printf '%s/%s' "$diag" "$msg"
}

run_stderr_table() {
    require_source "$POST_MERGE" "T26-T29: assembler stderr surfaced" || return
    require_source "$POST_CHECKOUT" "T26-T29: assembler stderr surfaced (post-checkout)" || return
    local id hook code want label got
    while IFS='|' read -r id hook code want label; do
        [ -n "$id" ] || continue
        got="$(probe_noisy "$hook" "$code")"
        if [ "$got" = "$want" ]; then
            pass "$id: $label"
        else
            fail "$id: $label (want $want, got $got)"
        fi
    done <<'STDERR_CASES'
T26|merge|0|surfaced/reported|post-merge lets a succeeding assembler's own stderr reach the operator, and still prints its own re-assembled line
T27|merge|1|surfaced/reported|post-merge on failure shows WHY the assembler failed, instead of only its own "run install manually" guidance
T28|checkout|0|surfaced/reported|CPR-ORTH: post-checkout drops the same redirect on the success branch
T29|checkout|1|surfaced/reported|and on the failure branch, so neither hook hides the reason a machine's settings.json was not rebuilt
STDERR_CASES
}

# T48-T51 live in a sibling part file: this driver sits at the 500-line HARD ceiling
# (rules/coding/file-split.md Pattern A) and the CRLF rows need room to grow.
. "$(dirname "${BASH_SOURCE[0]}")/fix-846-settings-drift-hooks/crlf-ssot.sh"

run_t9
run_t10
run_t11
run_t12
run_t13
run_t14
run_t15
run_t16
run_trigger_table
run_crlf_table
run_stderr_table

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
