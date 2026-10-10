#!/usr/bin/env bash
# tests/bin/fix-issue-724-sync-labels-status/copy-forge-lookup.sh
# Tests: bin/github-issues/sync-labels.sh
# Tags: github, labels, sync, forge, root-names, security, idempotency, scope:common
# Sourced by ../fix-issue-724-sync-labels-status.sh, which calls run_copy_forge_lookup_cases.
# Where the script looks for the forge tool: AGENTS_MAIN_ROOT for a copy, its own tree for
# the agents checkout (the two-marker verdict). Uses the parent's pass / fail and S_ROOT.
# TL3 gap: a real consumer-repo CI run against the live forge; drift of the dotfiles copy
# (bin/github-issues/propagate-labels.sh overwrites every copy).

_COPY_FORGE_LOOKUP_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

_cfl_np() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

# Under the parent's S_ROOT, which its EXIT trap removes; an empty path must never be used.
[[ -n "${S_ROOT:-}" && -d "$S_ROOT" ]] || { echo "copy-forge-lookup: the parent's S_ROOT is missing" >&2; exit 1; }
_CFL_TMP="$(mktemp -d "$S_ROOT/cfl.XXXXXX")"
[[ -n "$_CFL_TMP" && -d "$_CFL_TMP" ]] || { echo "copy-forge-lookup: cannot create a temp dir" >&2; exit 1; }
_CFL_TMP="$(_cfl_np "$_CFL_TMP")"
readonly _CFL_TMP
mkdir -p "$_CFL_TMP/workflow-state" "$_CFL_TMP/plans" || exit 1
export WORKFLOW_STATE_DIR="$_CFL_TMP/workflow-state"
export WORKFLOW_PLANS_DIR="$_CFL_TMP/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# shellcheck source=tests/lib/root-decoy.sh
. "$_COPY_FORGE_LOOKUP_SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy.sh"

_CFL_RWT="$_COPY_FORGE_LOOKUP_SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
_CFL_SYNC_REL="bin/github-issues/sync-labels.sh"
_CFL_SYNC_SRC="$_COPY_FORGE_LOOKUP_SCRIPT_CHECKOUT_ROOT/$_CFL_SYNC_REL"
_CFL_BUILDER="$_COPY_FORGE_LOOKUP_SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js"
_CFL_NO_FORGE_MSG="unsupported or undetected forge"
_CFL_OK_SUMMARY="1 created, 0 updated, 0 already-exists, 0 deleted / 1 total"
_CFL_RC=0
_CFL_OUT=""

_cfl_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 — want=$3 got=$2"; fi; }
_cfl_has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 — missing: $3 in: $2" ;; esac; }

# _cfl_mk_repo <dir>: a github-origin repository with one label to create.
_cfl_mk_repo() {
  mkdir -p "$1/.github"
  git init -q "$1"
  git -C "$1" config core.hooksPath /dev/null
  git -C "$1" config user.name "Sync Fixture"
  git -C "$1" config user.email "sync-fixture@example.com"
  git -C "$1" remote add origin "git@github.com:acme/widgets.git"
  printf -- '- name: "type:task"\n  color: "0e8a16"\n  description: "Normal work item."\n' >"$1/.github/labels.yml"
}

# _cfl_mk_stub <root>: <root>/bin/detect-forge-type that records each call next to its bin/.
_cfl_mk_stub() {
  mkdir -p "$1/bin"
  cat >"$1/bin/detect-forge-type" <<'STUB_JS'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);
fs.appendFileSync(path.join(__dirname, "..", "forge-calls.log"), `${args.join(" ")}\n`);
const field = args[args.indexOf("--field") + 1];
process.stdout.write(field === "project" ? "acme/widgets\n" : "github\n");
STUB_JS
  chmod +x "$1/bin/detect-forge-type"
}

_cfl_calls() {
  local n=0 _l
  if [[ -f "$1/forge-calls.log" ]]; then
    while IFS= read -r _l; do n=$((n + 1)); done <"$1/forge-calls.log"
  fi
  printf '%s' "$n"
}

# _cfl_copy <dest-root> [rel]: the script alone, at the same relative path by default.
_cfl_copy() {
  local rel="${2:-$_CFL_SYNC_REL}"
  mkdir -p "$1/${rel%/*}"
  cp "$_CFL_SYNC_SRC" "$1/$rel"
}

# _cfl_run <cwd-repo> <script> <agents-main-root | ->: sets _CFL_RC and _CFL_OUT (stdout + stderr).
_cfl_run() {
  _CFL_RC=0
  if [[ "$3" == "-" ]]; then
    _CFL_OUT="$(cd "$1" && env -u AGENTS_MAIN_ROOT bash "$_CFL_RWT" 120 bash "$2" --dry-run 2>&1)" || _CFL_RC=$?
  else
    _CFL_OUT="$(cd "$1" && AGENTS_MAIN_ROOT="$3" bash "$_CFL_RWT" 120 bash "$2" --dry-run 2>&1)" || _CFL_RC=$?
  fi
}

# (a) copy without markers + AGENTS_MAIN_ROOT -> that stub (path with a space and metacharacters)
_cfl_case_copy_uses_main_root() {
  local repo="$_CFL_TMP/a copy repo" main="$_CFL_TMP/a main \$HOME;x" first
  _cfl_mk_repo "$repo"
  _cfl_copy "$repo"
  _cfl_mk_stub "$main"
  _cfl_run "$repo" "$repo/$_CFL_SYNC_REL" "$main"
  _cfl_eq "a-copy-uses-agents-main-root-rc" "$_CFL_RC" "0"
  _cfl_eq "a-copy-uses-agents-main-root-stub-called" "$(_cfl_calls "$main")" "1"
  _cfl_has "a-copy-uses-agents-main-root-summary" "$_CFL_OUT" "$_CFL_OK_SUMMARY"
  first="$_CFL_OUT"
  _cfl_run "$repo" "$repo/$_CFL_SYNC_REL" "$main"
  _cfl_eq "a-second-run-same-output" "$_CFL_OUT" "$first"
  _cfl_eq "a-second-run-one-more-call" "$(_cfl_calls "$main")" "2"
}

# (b) agents checkout script: AGENTS_MAIN_ROOT (and every retired name) at a decoy -> 0 hits
_cfl_case_checkout_ignores_decoy() {
  local repo="$_CFL_TMP/b-repo" decoy="$_CFL_TMP/b-decoy" names name
  local -a assigns=()
  _cfl_mk_repo "$repo"
  if bash "$_CFL_RWT" 120 node "$(_cfl_np "$_CFL_BUILDER")" --single "$decoy" --marker sync-labels-decoy; then
    pass "b-decoy-built"
  else
    fail "b-decoy-built — root-decoy-build.js --single failed"
  fi
  _cfl_eq "b-decoy-carries-the-stub" "$([[ -f "$decoy/bin/detect-forge-type" ]] && echo yes || echo no)" "yes"
  _cfl_run "$repo" "$_CFL_SYNC_SRC" "$decoy"
  _cfl_eq "b-agents-checkout-ignores-agents-main-root-rc" "$_CFL_RC" "0"
  _cfl_has "b-agents-checkout-ignores-agents-main-root-summary" "$_CFL_OUT" "$_CFL_OK_SUMMARY"
  _cfl_eq "b-agents-checkout-decoy-hits" "$(root_decoy_hit_count "$decoy")" "0"
  _cfl_run "$repo" "$_CFL_SYNC_SRC" "-"
  _cfl_eq "b-agents-checkout-without-agents-main-root-rc" "$_CFL_RC" "0"
  _cfl_has "b-agents-checkout-without-agents-main-root-summary" "$_CFL_OUT" "$_CFL_OK_SUMMARY"
  names="$(node "$(_cfl_np "$_CFL_BUILDER")" --print-retired-env-names 2>/dev/null)" || names=""
  while IFS= read -r name; do
    name="${name%$'\r'}"
    if [[ -n "$name" ]]; then assigns+=("$name=$decoy"); fi
  done <<<"$names"
  if [[ "${#assigns[@]}" -eq 0 ]]; then
    fail "b-retired-names-do-not-redirect — the retired environment names are unavailable"
    return 0
  fi
  _CFL_RC=0
  _CFL_OUT="$(cd "$repo" && AGENTS_MAIN_ROOT="$decoy" env "${assigns[@]}" bash "$_CFL_RWT" 120 bash "$_CFL_SYNC_SRC" --dry-run 2>&1)" || _CFL_RC=$?
  _cfl_eq "b-retired-names-do-not-redirect-rc" "$_CFL_RC" "0"
  _cfl_eq "b-retired-names-do-not-redirect-hits" "$(root_decoy_hit_count "$decoy")" "0"
}

# (c) copy, no AGENTS_MAIN_ROOT, no sibling tool -> the no-forge error, exit 1
_cfl_case_copy_without_root() {
  local repo="$_CFL_TMP/c-repo"
  _cfl_mk_repo "$repo"
  _cfl_copy "$repo"
  _cfl_run "$repo" "$repo/$_CFL_SYNC_REL" "-"
  _cfl_eq "c-copy-without-root-rc" "$_CFL_RC" "1"
  _cfl_has "c-copy-without-root-message" "$_CFL_OUT" "$_CFL_NO_FORGE_MSG"
}

# (d) copy dest has its own stub + AGENTS_MAIN_ROOT -> only the AGENTS_MAIN_ROOT side runs
_cfl_case_root_beats_dest_stub() {
  local repo="$_CFL_TMP/d-repo" main="$_CFL_TMP/d-main"
  _cfl_mk_repo "$repo"
  _cfl_copy "$repo"
  _cfl_mk_stub "$repo"
  _cfl_mk_stub "$main"
  _cfl_run "$repo" "$repo/$_CFL_SYNC_REL" "$main"
  _cfl_eq "d-dest-stub-and-root-rc" "$_CFL_RC" "0"
  _cfl_eq "d-agents-main-root-stub-called" "$(_cfl_calls "$main")" "1"
  _cfl_eq "d-dest-stub-not-called" "$(_cfl_calls "$repo")" "0"
}

# (e) copy dest has a stub, no AGENTS_MAIN_ROOT (unset, then empty) -> the dest stub runs
_cfl_case_dest_stub_without_root() {
  local repo="$_CFL_TMP/e-repo"
  _cfl_mk_repo "$repo"
  _cfl_copy "$repo"
  _cfl_mk_stub "$repo"
  _cfl_run "$repo" "$repo/$_CFL_SYNC_REL" "-"
  _cfl_eq "e-dest-stub-without-root-rc" "$_CFL_RC" "0"
  _cfl_eq "e-dest-stub-called" "$(_cfl_calls "$repo")" "1"
  _cfl_run "$repo" "$repo/$_CFL_SYNC_REL" ""
  _cfl_eq "e-empty-root-counts-as-absent-rc" "$_CFL_RC" "0"
  _cfl_eq "e-empty-root-dest-stub-called" "$(_cfl_calls "$repo")" "2"
}

# (f) two-marker tree + stub, AGENTS_MAIN_ROOT at another stub -> only the tree's stub runs
_cfl_case_two_marker_tree() {
  local tree="$_CFL_TMP/f-tree" main="$_CFL_TMP/f-main"
  _cfl_mk_repo "$tree"
  _cfl_copy "$tree"
  _cfl_mk_stub "$tree"
  mkdir -p "$tree/hooks"
  printf '// marker\n' >"$tree/hooks/enforce-worktree.js"
  _cfl_mk_stub "$main"
  _cfl_run "$tree" "$tree/$_CFL_SYNC_REL" "$main"
  _cfl_eq "f-two-marker-tree-rc" "$_CFL_RC" "0"
  _cfl_eq "f-tree-stub-called" "$(_cfl_calls "$tree")" "1"
  _cfl_eq "f-agents-main-root-stub-not-called" "$(_cfl_calls "$main")" "0"
}

# classifier, the other verdict: one marker only, or a marker of the wrong kind
_cfl_case_not_the_agents_tree() {
  local tree="$_CFL_TMP/h-file-marker-only" main="$_CFL_TMP/h-main"
  _cfl_mk_repo "$tree"
  _cfl_copy "$tree" "tools/labels/sync-labels.sh"
  mkdir -p "$tree/hooks"
  printf '// marker\n' >"$tree/hooks/enforce-worktree.js"
  _cfl_mk_stub "$main"
  _cfl_run "$tree" "$tree/tools/labels/sync-labels.sh" "$main"
  _cfl_eq "file-marker-only-is-not-agents-rc" "$_CFL_RC" "0"
  _cfl_eq "file-marker-only-uses-agents-main-root" "$(_cfl_calls "$main")" "1"

  tree="$_CFL_TMP/i-marker-file-is-dir"
  main="$_CFL_TMP/i-main"
  _cfl_mk_repo "$tree"
  _cfl_copy "$tree"
  _cfl_mk_stub "$tree"
  mkdir -p "$tree/hooks/enforce-worktree.js"
  _cfl_mk_stub "$main"
  _cfl_run "$tree" "$tree/$_CFL_SYNC_REL" "$main"
  _cfl_eq "marker-file-as-directory-is-not-agents-rc" "$_CFL_RC" "0"
  _cfl_eq "marker-file-as-directory-uses-agents-main-root" "$(_cfl_calls "$main")" "1"
  _cfl_eq "marker-file-as-directory-own-stub-not-called" "$(_cfl_calls "$tree")" "0"
}

# (g) the two paths the script tests are the resolver's MARKER_FILE / MARKER_DIR
_cfl_case_markers_match_resolver() {
  local markers m_file m_dir
  markers="$(node - "$(_cfl_np "$_COPY_FORGE_LOOKUP_SCRIPT_CHECKOUT_ROOT/hooks/lib/script-checkout-root.js")" 2>&1 <<'MARKERS_JS'
"use strict";
const m = require(process.argv[2]);
if (!Array.isArray(m.MARKER_FILE) || !Array.isArray(m.MARKER_DIR)) {
  process.stderr.write("MARKER_FILE / MARKER_DIR are not exported\n");
  process.exit(1);
}
process.stdout.write(`${m.MARKER_FILE.join("/")}\n${m.MARKER_DIR.join("/")}\n`);
MARKERS_JS
)" || markers=""
  m_file="$(printf '%s\n' "$markers" | sed -n 1p)"
  m_dir="$(printf '%s\n' "$markers" | sed -n 2p)"
  if [[ -n "$m_file" && -n "$m_dir" ]]; then pass "g-resolver-exports-markers"
  else
    fail "g-resolver-exports-markers — hooks/lib/script-checkout-root.js does not export MARKER_FILE and MARKER_DIR"
    return 0
  fi
  if grep -q -F -- "-f \"\$SCRIPT_CHECKOUT_ROOT/$m_file\"" "$_CFL_SYNC_SRC"; then
    pass "g-script-tests-marker-file"
  else
    fail "g-script-tests-marker-file — no: -f \"\$SCRIPT_CHECKOUT_ROOT/$m_file\""
  fi
  if grep -q -F -- "-d \"\$SCRIPT_CHECKOUT_ROOT/$m_dir\"" "$_CFL_SYNC_SRC"; then
    pass "g-script-tests-marker-dir"
  else
    fail "g-script-tests-marker-dir — no: -d \"\$SCRIPT_CHECKOUT_ROOT/$m_dir\""
  fi
}

run_copy_forge_lookup_cases() {
  local saved_path="$PATH" mock_bin="$_CFL_TMP/mock-bin"
  unset GH_MOCK_LABEL_LIST GH_MOCK_LABEL_LIST_FAIL GH_MOCK_LABEL_LOG ROOT_DECOY_TEST_ID

  # The mock dir carries gh only: real git must answer the origin query.
  mkdir -p "$mock_bin"
  cp "$_COPY_FORGE_LOOKUP_SCRIPT_CHECKOUT_ROOT/tests/fixtures/gh-mock/gh" "$mock_bin/gh"
  chmod +x "$mock_bin/gh"
  if command -v cygpath >/dev/null 2>&1; then
    PATH="$(cygpath -u "$mock_bin"):$PATH"
  else
    PATH="$mock_bin:$PATH"
  fi
  export PATH
  # Never reach the real CLI: run no case unless the mock is the one on PATH.
  if [[ "$(_cfl_np "$(command -v gh)")" == "$mock_bin/gh" ]]; then
    pass "copy-forge-lookup: the gh mock is first on PATH"
    _cfl_case_copy_uses_main_root
    _cfl_case_checkout_ignores_decoy
    _cfl_case_copy_without_root
    _cfl_case_root_beats_dest_stub
    _cfl_case_dest_stub_without_root
    _cfl_case_two_marker_tree
    _cfl_case_not_the_agents_tree
    _cfl_case_markers_match_resolver
  else
    fail "copy-forge-lookup: the gh mock is not first on PATH ($(command -v gh)) — no case was run"
  fi

  export PATH="$saved_path"
  rm -rf "$_CFL_TMP"
}
