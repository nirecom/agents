# Part of tests/bin/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/vscode-cc-repair
# Tags: bin, vscode, prune, cli, prune-gate, scope:common, pwsh-not-required, TL2
# F4 — #2683 prune gate. Sourced after cli-exit-codes.sh: exf_pruned (the prunable-stub fixture) is defined there.
# ---- F4: #2683 prune gate ----------------------------------------------------
# A patch pass ending `refused`/`failed` means worktree sessions are still hidden, so the
# prune pass must not run: stubs stay (no .jsonl.bak), a line says why, exit stays 1.
# A per-dir `failed` has no fixture route (C7 gap, failclosed-paths.sh); root-level: F4-g13.

# A line naming both the prune pass and the skip, spelling-agnostic.
prune_skip_line() { grep -iE 'prune.*skip|skip.*prune' <<< "$1" | head -1 || true; }

run_f_prune_gate_blocked() {
  local name dry body1 body2 want_reason home ext proj stub out_skip
  while IFS='|' read -r name dry body1 body2 want_reason; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    dry="${dry//[[:space:]]/}"
    body1="${body1//[[:space:]]/}"
    body2="${body2//[[:space:]]/}"
    want_reason="${want_reason//[[:space:]]/}"
    home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
    make_ext_dir "$ext" "$EXT_DIR_A" "${!body1}"
    if [ "$body2" != "-" ]; then
      make_ext_dir "$ext" "anthropic.claude-code-2.0.0" "${!body2}"
    fi
    exf_pruned "$proj"
    stub="$(session_path "$proj/stub" "$SID_A")"
    if [ "$dry" = "dry-run" ]; then
      run_cli_prune "$home" "$ext" "$proj" --dry-run
    else
      run_cli_prune "$home" "$ext" "$proj"
    fi
    check "$name: exit 1 (the patch refusal)" "1" "$CLI_RC"
    check_token "$name: patch pass reported refused" "refused" "$CLI_OUT"
    check_contains "$name: the refused line carries its reason" \
      "reason=$want_reason" "$(prune_line "refused" "$CLI_OUT")"
    check_file "$name: the prunable stub is still in place" "$stub"
    check_no_file "$name: no .jsonl.bak displacement" "$stub.bak"
    check_absent "$name: no prune-root line (the pass did not run)" "prune-root:" "$CLI_OUT"
    check_no_token "$name: no pruned line" "pruned" "$CLI_OUT"
    check_no_token "$name: no would-prune line" "would-prune" "$CLI_OUT"
    if [ "$body2" != "-" ]; then
      # The patchable sibling really was patched; only the prune pass is gated off.
      check_contains "$name: the second bundle is now !0" 'includeWorktrees:!0' \
        "$(cat "$ext/anthropic.claude-code-2.0.0/extension.js")"
      check_contains "$name: report lists the refused dir" "refused  $EXT_DIR_A" "$CLI_OUT"
      check_contains "$name: report lists the patched dir" \
        "patched  anthropic.claude-code-2.0.0" "$CLI_OUT"
      check_contains "$name: summary counts both dirs" "dirs=2" "$CLI_OUT"
      check_contains "$name: summary counts the patched dir" "patched=1" "$CLI_OUT"
    fi
    out_skip="$(prune_skip_line "$CLI_OUT")"
    if [[ "$out_skip" == *"the extension patch refused or failed"* ]]; then
      echo "PASS: $name: a report line states the prune pass was skipped and why"; PASS=$((PASS + 1))
    else
      echo "FAIL: $name: no prune-skip report line in: $CLI_OUT"; FAIL=$((FAIL + 1))
    fi
  done <<'TABLE'
F4-g01-refused          | run     | BODY_TWO_FALSY      | -          | no-anchor
F4-g02-refused-dry-run  | dry-run | BODY_TWO_FALSY      | -          | no-anchor
F4-g03-refused-plus-ok  | run     | BODY_TWO_FALSY      | BODY_FALSY | no-anchor
F4-g08-anchor-keyless   | run     | BODY_ANCHOR_KEYLESS | -          | no-anchor-key
F4-g11-nested-only      | run     | BODY_ANCHOR_NESTED_ONLY | -     | ambiguous-anchor
F4-g12-anchor-in-string | run     | BODY_ANCHOR_IN_DQ       | -      | ambiguous-anchor
TABLE
}

# The gate's other side: every non-failing patch outcome — and a run with zero extension
# roots — still lets the prune pass run and displace the stub.
run_f_prune_gate_open() {
  local name bodyvar want_patch home ext proj stub
  while IFS='|' read -r name bodyvar want_patch; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    want_patch="${want_patch//[[:space:]]/}"
    home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
    make_ext_dir "$ext" "$EXT_DIR_A" "${!bodyvar}"
    exf_pruned "$proj"
    stub="$(session_path "$proj/stub" "$SID_A")"
    run_cli_prune "$home" "$ext" "$proj"
    check "$name: exit 0" "0" "$CLI_RC"
    check_token "$name: patch pass reported $want_patch" "$want_patch" "$CLI_OUT"
    check_contains "$name: the prune pass ran" "pruned=1" "$CLI_OUT"
    check_no_file "$name: the stub was displaced" "$stub"
    check_file "$name: as <uuid>.jsonl.bak" "$stub.bak"
  done <<'TABLE'
F4-g04-absent   | BODY_ABSENT | absent
F4-g05-already  | BODY_TRUTHY | already
F4-g06-patched  | BODY_FALSY  | patched
TABLE

  # F4-g07 — roots=0: the one row without --extensions-dir, since no extension root is the
  # condition under test; HOME/USERPROFILE still point at a fixture home with no .vscode*.
  home="$(new_home)"; proj="$(new_proj_root)"
  exf_pruned "$proj"
  stub="$(session_path "$proj/stub" "$SID_A")"
  CLI_RC=0
  CLI_OUT="$(HOME="$home" USERPROFILE="$(native_path "$home")" run_with_timeout 60 \
    node "$SCRIPT" --prune-stub-sessions --claude-projects-dir "$(native_path "$proj")" 2>&1)" \
    || CLI_RC=$?
  check "F4-g07-no-ext-roots: exit 0" "0" "$CLI_RC"
  check_contains "F4-g07-no-ext-roots: the patch pass saw zero roots" "roots=0" "$CLI_OUT"
  check_contains "F4-g07-no-ext-roots: the prune pass ran" "pruned=1" "$CLI_OUT"
  check_no_file "F4-g07-no-ext-roots: the stub was displaced" "$stub"

  # F4-g09/g10 — --dry-run with a non-failing patch outcome: the prune PREVIEW still runs,
  # and neither the bundle nor the session store is touched.
  local f
  while IFS='|' read -r name bodyvar want_patch; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    want_patch="${want_patch//[[:space:]]/}"
    home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
    make_ext_dir "$ext" "$EXT_DIR_A" "${!bodyvar}"
    f="$ext/$EXT_DIR_A/extension.js"
    exf_pruned "$proj"
    stub="$(session_path "$proj/stub" "$SID_A")"
    run_cli_prune "$home" "$ext" "$proj" --dry-run
    check "$name: exit 0" "0" "$CLI_RC"
    check_token "$name: patch pass reported $want_patch" "$want_patch" "$CLI_OUT"
    check_token "$name: the prune preview ran" "would-prune" "$CLI_OUT"
    check_file "$name: the stub is still in place" "$stub"
    check_no_file "$name: no .jsonl.bak displacement" "$stub.bak"
    check "$name: bundle unchanged" "${!bodyvar}" "$(cat "$f")"
    check_no_file "$name: no bundle backup" "$f.bak"
  done <<'TABLE'
F4-g09-already-dry-run      | BODY_TRUTHY | already
F4-g10-would-patch-dry-run  | BODY_FALSY  | would-patch
TABLE
}

# F4-g13 — a patch-pass `failed` from an unreadable extension root (#2683) gates the prune
# off too. chmod is advisory on Windows, so a NODE_OPTIONS --require preload makes
# fs.readdirSync throw EACCES for that one root; the patch suite's C12 pins the unit side.
run_f_prune_gate_root_unreadable() {
  local home ext proj stub preload preload_n
  preload="$TMPROOT/deny-readdir-prune.js"
  printf '%s\n' 'const fs=require("fs"),p=require("path");' \
    'const key=(s)=>process.platform==="win32"?p.resolve(s).toLowerCase():p.resolve(s);' \
    'const deny=key(process.env.CCR_DENY_ROOT);const orig=fs.readdirSync;' \
    'fs.readdirSync=function(d,...r){if(typeof d==="string"&&key(d)===deny){const e=new Error("EACCES: stub scandir");e.code="EACCES";throw e;}return orig.call(fs,d,...r);};' \
    > "$preload"
  preload_n="$(native_file "$preload")"
  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  make_ext_dir "$ext" "$EXT_DIR_A" "$BODY_FALSY"
  exf_pruned "$proj"
  stub="$(session_path "$proj/stub" "$SID_A")"
  NODE_OPTIONS="--require \"$preload_n\"" CCR_DENY_ROOT="$(native_path "$ext")" \
    run_cli_prune "$home" "$ext" "$proj"
  check "F4-g13-root-unreadable: exit 1" "1" "$CLI_RC"
  check_contains "F4-g13-root-unreadable: root reported failed" \
    "failed  $(basename "$ext")  reason=root-unreadable" "$CLI_OUT"
  check_contains "F4-g13-root-unreadable: the unreadable root is not counted as a dir" \
    "summary: roots=1 dirs=0" "$CLI_OUT"
  check_contains "F4-g13-root-unreadable: failed=1 in the patch summary" "refused=0 failed=1" "$CLI_OUT"
  check_contains "F4-g13-root-unreadable: the prune-skipped line is printed" "prune-skipped:" "$CLI_OUT"
  check_contains "F4-g13-root-unreadable: the skip line states the patch refused or failed" \
    "the extension patch refused or failed" "$CLI_OUT"
  check_absent "F4-g13-root-unreadable: no prune-root line" "prune-root:" "$CLI_OUT"
  check_file "F4-g13-root-unreadable: the prunable stub is still in place" "$stub"
  check_no_file "F4-g13-root-unreadable: no .jsonl.bak displacement" "$stub.bak"
  check "F4-g13-root-unreadable: the bundle is untouched" "$BODY_FALSY" \
    "$(cat "$ext/$EXT_DIR_A/extension.js")"
}

# F4-g14 — --legacy-single-literal composes with --prune-stub-sessions: a no-anchor bundle
# with one literal is patched under the legacy method, so the gate opens and the stub is
# displaced. The mirror without the flag is a no-anchor refusal and the gate stays shut.
run_f_prune_gate_legacy() {
  local body home ext proj stub
  body='function f({includeWorktrees:i}){return i}var o={includeWorktrees:!1};module.exports={f,o};'

  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  make_ext_dir "$ext" "$EXT_DIR_A" "$body"
  exf_pruned "$proj"
  stub="$(session_path "$proj/stub" "$SID_A")"
  run_cli_prune "$home" "$ext" "$proj" --legacy-single-literal
  check "F4-g14a-legacy: exit 0" "0" "$CLI_RC"
  check_token "F4-g14a-legacy: patch pass reported patched" "patched" "$CLI_OUT"
  check_absent "F4-g14a-legacy: no prune-skipped line" "prune-skipped" "$CLI_OUT"
  check_contains "F4-g14a-legacy: the prune pass ran" "pruned=1" "$CLI_OUT"
  check_no_file "F4-g14a-legacy: the stub was displaced" "$stub"
  check_file "F4-g14a-legacy: as <uuid>.jsonl.bak" "$stub.bak"

  home="$(new_home)"; ext="$(new_ext_root)"; proj="$(new_proj_root)"
  make_ext_dir "$ext" "$EXT_DIR_A" "$body"
  exf_pruned "$proj"
  stub="$(session_path "$proj/stub" "$SID_A")"
  run_cli_prune "$home" "$ext" "$proj"
  check "F4-g14b-no-legacy: exit 1" "1" "$CLI_RC"
  check_contains "F4-g14b-no-legacy: refused with its reason" \
    "reason=no-anchor" "$(prune_line "refused" "$CLI_OUT")"
  check_contains "F4-g14b-no-legacy: the prune-skipped line is printed" "prune-skipped:" "$CLI_OUT"
  check_file "F4-g14b-no-legacy: the stub is still in place" "$stub"
  check_no_file "F4-g14b-no-legacy: no .jsonl.bak displacement" "$stub.bak"
}

run_f_prune_gate_blocked
run_f_prune_gate_open
run_f_prune_gate_root_unreadable
run_f_prune_gate_legacy
