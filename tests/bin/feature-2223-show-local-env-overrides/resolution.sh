#!/usr/bin/env bash
# tests/feature-2223-show-local-env-overrides/resolution.sh
# Tests: bin/show-local-env-overrides, hooks/lib/local-env.js
# Tags: scope:issue-specific, TL2, load-env, local-env, cli, resolution, pwsh-not-required
# Case file for tests/feature-2223-show-local-env-overrides.sh — sourced from it,
# never run standalone (it uses that file's helpers, fixtures and counters).
# Holds the two resolutions the CLI performs before it can report anything —
# which hooks/lib it loads, which project root it inspects — plus how that
# report relates to what the real loader injects into a live process.
# TL3 gap: same as the parent's — a PATH shim symlinked into ~/.local/bin is out
# of reach here; only the AGENTS_CONFIG_DIR half of libDir() is TL2-testable.
SHOW_LOCAL_ENV_RESOLUTION_CASES_LOADED=1

# ---------------------------------------------------------------------------
# G1: libDir(). Every other case leaves AGENTS_CONFIG_DIR without a hooks/lib,
# so the configured branch and its two-file completeness probe never run. The
# production install path is exactly the one that does carry hooks/lib.
# ---------------------------------------------------------------------------

# install_lib_copy — copy the whole hooks/lib into the case config dir, so
# agents-config-dir.js and every other sibling require() comes along.
install_lib_copy() {
    mkdir -p "$CASE_CFG/hooks"
    cp -r "$AGENTS_DIR/hooks/lib" "$CASE_CFG/hooks/"
}

# A key the real blocklist does not name, added to the COPY only: it can be
# refused only if the configured library is the one that loaded.
LIB_MARK='  "PROJECT_TAGLINE",'

new_case lib-configured-wins 'CODE_LANG=english' \
  'PROJECT_TAGLINE=SENT2223-libcfg-2a71ff@NL@PROJECT_NFR=SENT2223-libnfr-84c0d3'
install_lib_copy
sed -i '/ENV_ENTRY_BLOCKLIST_EXACT = new Set(\[/a\  "PROJECT_TAGLINE",' \
  "$CASE_CFG/hooks/lib/local-env.js"
if grep -qF "$LIB_MARK" "$CASE_CFG/hooks/lib/local-env.js"; then
    pass "T2223S-lib-configured-fixture-patched"
else
    fail "T2223S-lib-configured-fixture-patched — the copy was not edited; the case below would be vacuous"
fi
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-lib-configured-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-lib-configured-refused" "PROJECT_TAGLINE" \
  "$(section_keys "$CLI_OUT" "refused by blocklist")"
assert_eq "T2223S-lib-configured-applied" "PROJECT_NFR" "$(section_keys "$CLI_OUT" applied)"
assert_report_lacks "T2223S-lib-configured-no-value-leak" "$CLI_OUT" "SENT2223-"

# Half-populated config dir: the completeness probe rejects it, and the fallback
# tree answers instead — no broken require() takes the CLI down.
new_case lib-incomplete-falls-back 'CODE_LANG=english' \
  'PROJECT_TAGLINE=SENT2223-libhalf-6d92ab@NL@PROJECT_NFR=SENT2223-libhalf-nfr-1fe407'
install_lib_copy
sed -i '/ENV_ENTRY_BLOCKLIST_EXACT = new Set(\[/a\  "PROJECT_TAGLINE",' \
  "$CASE_CFG/hooks/lib/local-env.js"
rm -f "$CASE_CFG/hooks/lib/local-env.js"
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-lib-incomplete-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-lib-incomplete-applied" "$(printf 'PROJECT_NFR\nPROJECT_TAGLINE')" \
  "$(section_keys "$CLI_OUT" applied)"
assert_eq "T2223S-lib-incomplete-refused-count" "0" \
  "$(section_count "$CLI_OUT" "refused by blocklist")"

# CPR-ORTH: the other half of the two-file probe. A config dir missing load-env.js
# must be rejected exactly as one missing local-env.js is — and the patched copy
# left behind proves the fallback, not the copy, is what answered.
new_case lib-incomplete-loadenv 'CODE_LANG=english' \
  'PROJECT_TAGLINE=SENT2223-libhalf2-c40e8b@NL@PROJECT_NFR=SENT2223-libhalf2-nfr-72a5d1'
install_lib_copy
sed -i '/ENV_ENTRY_BLOCKLIST_EXACT = new Set(\[/a\  "PROJECT_TAGLINE",' \
  "$CASE_CFG/hooks/lib/local-env.js"
if grep -qF "$LIB_MARK" "$CASE_CFG/hooks/lib/local-env.js"; then
    pass "T2223S-lib-incomplete-loadenv-fixture-patched"
else
    fail "T2223S-lib-incomplete-loadenv-fixture-patched — the copy was not edited; the case below would be vacuous"
fi
rm -f "$CASE_CFG/hooks/lib/load-env.js"
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-lib-incomplete-loadenv-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-lib-incomplete-loadenv-applied" "$(printf 'PROJECT_NFR\nPROJECT_TAGLINE')" \
  "$(section_keys "$CLI_OUT" applied)"
assert_eq "T2223S-lib-incomplete-loadenv-refused-count" "0" \
  "$(section_count "$CLI_OUT" "refused by blocklist")"
assert_report_lacks "T2223S-lib-incomplete-loadenv-no-value-leak" "$CLI_OUT" "SENT2223-"

# The status quo every other case rides on, stated once by name rather than
# depended on by accident: no hooks/ under the config dir at all.
new_case lib-no-hooks-dir 'CODE_LANG=english' \
  'PROJECT_TAGLINE=SENT2223-libnone-b7d155@NL@PROJECT_NFR=SENT2223-libnone-nfr-30ca6e'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-lib-no-hooks-dir-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-lib-no-hooks-dir-applied" "$(printf 'PROJECT_NFR\nPROJECT_TAGLINE')" \
  "$(section_keys "$CLI_OUT" applied)"

# ---------------------------------------------------------------------------
# G2: the bare invocation. Without --repo-root the CLI must resolve a root on
# its own — CLAUDE_PROJECT_DIR, else the nearest enclosing .git from cwd. That
# is the form a human types, and nothing proved process.cwd() was even wired in.
# ---------------------------------------------------------------------------
new_case cwd-upward 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' \
  'PROJECT_NFR=SENT2223-cwd-nfr-c81b40@NL@ENFORCE_WORKTREE=SENT2223-cwd-blocked-77ae12'
mkdir -p "$CASE_ROOT/a/b/c"
run_cli_in "$CASE_ROOT/a/b/c"
assert_eq "T2223S-cwd-upward-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-cwd-upward-root-line" "$(to_node_path "$CASE_ROOT")" \
  "$(header_value "$CLI_OUT" "project-root:")"
assert_eq "T2223S-cwd-upward-applied" "PROJECT_NFR" "$(section_keys "$CLI_OUT" applied)"
assert_eq "T2223S-cwd-upward-refused" "ENFORCE_WORKTREE" \
  "$(section_keys "$CLI_OUT" "refused by blocklist")"
assert_report_lacks "T2223S-cwd-upward-no-value-leak" "$CLI_OUT" "SENT2223-"

# Two roots, each with a key only it declares, so the applied list names which
# root actually answered.
new_case pdir-a 'CODE_LANG=english' 'A_ONLY_KEY=SENT2223-roota-9b3e05'
ROOT_A="$CASE_ROOT"; ROOT_A_NODE="$CASE_ROOT_NODE"
new_case pdir-b 'CODE_LANG=english' 'B_ONLY_KEY=SENT2223-rootb-4f7c28'
ROOT_B="$CASE_ROOT"; ROOT_B_NODE="$CASE_ROOT_NODE"

export CLAUDE_PROJECT_DIR="$ROOT_B_NODE"
run_cli_in "$ROOT_A"
assert_eq "T2223S-project-dir-branch-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-project-dir-branch-applied" "B_ONLY_KEY" "$(section_keys "$CLI_OUT" applied)"

# An explicit --repo-root outranks CLAUDE_PROJECT_DIR.
run_cli_in "$ROOT_A" --repo-root "$ROOT_A_NODE"
assert_eq "T2223S-repo-root-beats-project-dir" "A_ONLY_KEY" "$(section_keys "$CLI_OUT" applied)"
# Restore the harness invariant the parent's isolation block established.
unset CLAUDE_PROJECT_DIR

# ---------------------------------------------------------------------------
# G8: --repo-root values that are not an existing repository directory.
# resolveProjectRoot path.resolve()s an explicit root with no existence and no
# .git check, so each of these is a reportable outcome, not a usage error.
# ---------------------------------------------------------------------------
new_case root-nonexistent 'CODE_LANG=english' '__NONE__'
run_cli --repo-root "$CASE_ROOT_NODE/no-such-dir-2223"
assert_eq "T2223S-nonexistent-root-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-nonexistent-root-status" "$CLI_OUT" "status:       absent or unreadable"
assert_contains "T2223S-nonexistent-root-still-named" "$CLI_OUT" "no-such-dir-2223"

# A plain directory with no .git still wins when it is named explicitly.
new_case root-non-repo 'CODE_LANG=english' '__NONE__'
NON_REPO="$TMP_ROOT/c-root-non-repo/plain"
mkdir -p "$NON_REPO"
printf 'PROJECT_NFR=SENT2223-nonrepo-1c8fa3\n' > "$NON_REPO/$LOCAL_ENV_BASENAME"
run_cli --repo-root "$(to_node_path "$NON_REPO")"
assert_eq "T2223S-non-repo-root-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-non-repo-root-applied" "PROJECT_NFR" "$(section_keys "$CLI_OUT" applied)"
assert_report_lacks "T2223S-non-repo-root-no-value-leak" "$CLI_OUT" "SENT2223-"

# A file where a directory belongs: open fails one level down, so it reads as
# "nothing overridden" rather than as a crash.
new_case root-is-a-file 'CODE_LANG=english' '__NONE__'
run_cli --repo-root "$(to_node_path "$CASE_CFG")/.env"
assert_eq "T2223S-root-is-a-file-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-root-is-a-file-status" "$CLI_OUT" "status:       absent or unreadable"

# The row that matters most: --repo-root "$UNSET_VAR" degrades to cwd resolution
# and reports a different project than the caller named. Today that is legal.
new_case root-empty-value 'CODE_LANG=english' 'CWD_ONLY_KEY=SENT2223-cwdonly-52b9e7'
run_cli_in "$CASE_ROOT" --repo-root ""
assert_eq "T2223S-empty-repo-root-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-empty-repo-root-applied" "CWD_ONLY_KEY" "$(section_keys "$CLI_OUT" applied)"

# A relative root is resolved against cwd before anything is printed.
new_case root-relative 'CODE_LANG=english' 'PROJECT_NFR=SENT2223-relroot-e604b1'
mkdir -p "$CASE_ROOT/a"
run_cli_in "$CASE_ROOT/a" --repo-root ".."
assert_eq "T2223S-relative-repo-root-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-relative-repo-root-line" "$(to_node_path "$CASE_ROOT")" \
  "$(header_value "$CLI_OUT" "project-root:")"
assert_eq "T2223S-relative-repo-root-applied" "PROJECT_NFR" "$(section_keys "$CLI_OUT" applied)"

# ---------------------------------------------------------------------------
# G14: argument-parser edges. Every row pins current behaviour — there is no
# --help today, and the second --repo-root simply overwrites the first.
# ---------------------------------------------------------------------------
for _flag in --help -h; do
    run_cli "$_flag"
    assert_eq "T2223S-argv-$_flag-exit-64" "64" "$CLI_RC"
    assert_eq "T2223S-argv-$_flag-empty-stdout" "" "$CLI_OUT"
    assert_contains "T2223S-argv-$_flag-usage-stderr" "$CLI_ERR" "usage: show-local-env-overrides"
done

run_cli --repo-root "$ROOT_A_NODE" --repo-root "$ROOT_B_NODE"
assert_eq "T2223S-argv-repeated-repo-root-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-argv-repeated-repo-root-last-wins" "B_ONLY_KEY" \
  "$(section_keys "$CLI_OUT" applied)"

# A flag-shaped value is consumed as the path, never re-read as a flag.
run_cli --repo-root --bogus
assert_eq "T2223S-argv-flag-shaped-value-exit-0" "0" "$CLI_RC"
assert_contains "T2223S-argv-flag-shaped-value-status" "$CLI_OUT" \
  "status:       absent or unreadable"

# ---------------------------------------------------------------------------
# G19: reporter vs runtime, pinned as documentation rather than fixed. "applied"
# answers "what would this FILE override", computed from the two files alone;
# loadDefaultEnv additionally skips any key the caller already exported truthy.
# So a key reads applied here and still never reaches a live process.env — the
# divergence is intentional, and unpinned it would read as a reporter bug.
# ---------------------------------------------------------------------------
RUNTIME_PROBE="$TMP_ROOT/runtime-probe.js"
cat > "$RUNTIME_PROBE" <<'RUNTIME_PROBE_EOF'
"use strict";
const path = require("path");
const lib = path.join(process.env.RUNTIME_PROBE_LIB, "hooks", "lib");
require(path.join(lib, "load-env.js")).loadDefaultEnv();
const v = process.env[process.argv[2]];
process.stdout.write(v === undefined ? "__ABSENT__" : JSON.stringify(v));
RUNTIME_PROBE_EOF
RUNTIME_PROBE_NODE="$(to_node_path "$RUNTIME_PROBE")"
RUNTIME_PROBE_LIB="$(to_node_path "$AGENTS_DIR")"

# rvr_probe <exported-CODE_LANG|__NONE__> — the real loader over the same fixture.
rvr_probe() {
    if [ "$1" = "__NONE__" ]; then
        RUNTIME_PROBE_LIB="$RUNTIME_PROBE_LIB" AGENTS_CONFIG_DIR="$(to_node_path "$CASE_CFG")" \
            CLAUDE_PROJECT_DIR="$CASE_ROOT_NODE" \
            run_with_timeout 20 node "$RUNTIME_PROBE_NODE" CODE_LANG 2>/dev/null
    else
        RUNTIME_PROBE_LIB="$RUNTIME_PROBE_LIB" AGENTS_CONFIG_DIR="$(to_node_path "$CASE_CFG")" \
            CLAUDE_PROJECT_DIR="$CASE_ROOT_NODE" CODE_LANG="$1" \
            run_with_timeout 20 node "$RUNTIME_PROBE_NODE" CODE_LANG 2>/dev/null
    fi
}

new_case reporter-vs-runtime 'CODE_LANG=english' 'CODE_LANG=SENT2223-rvr-3f81c2'
run_cli --repo-root "$CASE_ROOT_NODE"
assert_eq "T2223S-rvr-exit-0" "0" "$CLI_RC"
assert_eq "T2223S-rvr-reporter-says-applied" "CODE_LANG" "$(section_keys "$CLI_OUT" applied)"
assert_report_lacks "T2223S-rvr-no-value-leak" "$CLI_OUT" "SENT2223-"
# The companion half: the caller's export survives the loader untouched, even
# though the reporter above called the very same key applied.
assert_eq "T2223S-rvr-runtime-export-survives" '"exported-wins-2223"' \
  "$(rvr_probe exported-wins-2223)"
# Positive control: without that export the local value does reach process.env,
# so the row above means the export won — not that the probe reads nothing.
assert_eq "T2223S-rvr-runtime-control-local-applies" '"SENT2223-rvr-3f81c2"' \
  "$(rvr_probe __NONE__)"
