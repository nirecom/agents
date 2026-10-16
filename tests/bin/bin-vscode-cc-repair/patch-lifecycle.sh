# Part of tests/bin/bin-vscode-cc-repair.sh (sourced, not standalone).
# Tests: bin/vscode-cc-repair
# Tags: bin, vscode, extension-patch, scope:common, pwsh-not-required, TL2
# T1/T2 — the happy-path lifecycle: already-patched no-op, dry-run, real patch,
# idempotent re-run, and backup preservation.

# ---- T1: already patched (no-op, and must not become the pristine backup) --

run_t1() {
  local root f before
  root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$BODY_TRUTHY"
  f="$root/$DIR_A/extension.js"; before="$(bytes "$f")"
  run_cli --extensions-dir "$(native_path "$root")"
  check "T1: exit 0" "0" "$CLI_RC"
  check_token "T1: reported already" "already" "$CLI_OUT"
  check "T1: extension.js content unchanged" "$BODY_TRUTHY" "$(cat "$f")"
  check "T1: byte count unchanged" "$before" "$(bytes "$f")"
  check_no_file "T1: already-patched copy did not become extension.js.bak" "$f.bak"
  check "T1: no leftover tmp" "0" "$(count_tmp "$root")"
}

# ---- T2: unpatched -> dry-run, patch, idempotent re-run, backup preserved --

run_t2() {
  local root f before after_patch bak
  root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$BODY_FALSY"
  f="$root/$DIR_A/extension.js"; bak="$f.bak"; before="$(bytes "$f")"

  # T2a: --dry-run classifies but never writes.
  run_cli --extensions-dir "$(native_path "$root")" --dry-run
  check "T2a: dry-run exit 0" "0" "$CLI_RC"
  check_token "T2a: dry-run reported would-patch" "would-patch" "$CLI_OUT"
  check "T2a: dry-run left extension.js untouched" "$BODY_FALSY" "$(cat "$f")"
  check_no_file "T2a: dry-run created no .bak" "$bak"
  check "T2a: dry-run left no tmp file" "0" "$(count_tmp "$root")"

  # T2b: real run patches exactly the literal site.
  run_cli --extensions-dir "$(native_path "$root")"
  check "T2b: exit 0" "0" "$CLI_RC"
  check_token "T2b: reported patched" "patched" "$CLI_OUT"
  after_patch="$(cat "$f")"
  check_contains "T2b: call site is now !0" 'includeWorktrees:!0' "$after_patch"
  check_absent "T2b: no !1 remains" '!1' "$after_patch"
  check_contains "T2b: destructuring site untouched" 'includeWorktrees:i' "$after_patch"
  check "T2b: byte length unchanged by patch" "$before" "$(bytes "$f")"
  check_file "T2b: backup created" "$bak"
  if [ -f "$bak" ]; then
    check_contains "T2b: backup holds the original !1" 'includeWorktrees:!1' "$(cat "$bak")"
  else
    echo "FAIL: T2b: backup holds the original !1 -- no backup file"; FAIL=$((FAIL + 1))
  fi
  check_contains "T2b: detail reports backup=created" "backup=created" "$CLI_OUT"
  check "T2b: no leftover tmp" "0" "$(count_tmp "$root")"

  # T2c: re-run is a no-op.
  run_cli --extensions-dir "$(native_path "$root")"
  check "T2c: re-run exit 0" "0" "$CLI_RC"
  check_token "T2c: re-run reported already" "already" "$CLI_OUT"
  check "T2c: re-run left extension.js unchanged" "$after_patch" "$(cat "$f")"

  # T2d: unpatched + pre-existing .bak -> patch, but never overwrite the backup.
  # This is the covered half of the runtime-FS matrix (see failclosed-paths.sh).
  local root2 f2 sentinel
  sentinel="PREEXISTING-BAK-SENTINEL-DO-NOT-OVERWRITE"
  root2="$(new_root)"; make_ext_dir "$root2" "$DIR_A" "$BODY_FALSY"
  f2="$root2/$DIR_A/extension.js"
  printf '%s' "$sentinel" > "$f2.bak"
  run_cli --extensions-dir "$(native_path "$root2")"
  check "T2d: exit 0" "0" "$CLI_RC"
  check_token "T2d: reported patched" "patched" "$CLI_OUT"
  check_contains "T2d: detail reports backup=preserved" "backup=preserved" "$CLI_OUT"
  check_contains "T2d: extension.js patched" 'includeWorktrees:!0' "$(cat "$f2")"
  check "T2d: pre-existing .bak not overwritten" "$sentinel" "$(cat "$f2.bak")"
}

# ---- A1: #2683 extension 2.1.300 shape (anchor site + resolveSession site) --
# Only the anchor-internal `!1` is rewritten; the resolveSession `!1` survives. The run
# ending `patched` (not `failed`) also proves the post-rename verify uses the anchor
# method — the legacy count would see one `!0` plus one `!1` and refuse the result.

run_a1_v2130() {
  local name bodyvar want_after root f after
  while IFS='|' read -r name bodyvar want_after; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    want_after="${want_after//[[:space:]]/}"
    root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "${!bodyvar}"
    f="$root/$DIR_A/extension.js"

    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: exit 0" "0" "$CLI_RC"
    check_token "$name: reported patched" "patched" "$CLI_OUT"
    check_absent "$name: post-rename verify did not fail" "post-verify-failed" "$CLI_OUT"
    after="$(cat "$f")"
    if [ "$want_after" = "-" ]; then
      check_contains "$name: anchor site is now !0" \
        'sessionListOptions(){return{cwd:this.cwd,includeWorktrees:!0}}' "$after"
    else
      check "$name: whole body equals the expected patched body" "${!want_after}" "$after"
    fi
    check_contains "$name: resolveSession site keeps !1" \
      'dir:Y.folder,includeWorktrees:!1})' "$after"
    check_file "$name: backup created" "$f.bak"

    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: re-run exit 0" "0" "$CLI_RC"
    check_token "$name: re-run reported already" "already" "$CLI_OUT"
    check "$name: re-run left the body unchanged" "$after" "$(cat "$f")"
  done <<'TABLE'
A1-l01-v2130-anchor-first  | BODY_V2130     | BODY_V2130_PATCHED
A1-l02-v2130-outside-first | BODY_V2130_REV | -
TABLE
}

# Already-patched 2.1.300 bundle: anchor `!0`, outside `!1` -> already, nothing written.
run_a1_v2130_already() {
  local root f before
  root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$BODY_V2130_PATCHED"
  f="$root/$DIR_A/extension.js"; before="$(bytes "$f")"
  run_cli --extensions-dir "$(native_path "$root")"
  check "A1-l03: already-patched 2.1.300 exit 0" "0" "$CLI_RC"
  check_token "A1-l03: reported already" "already" "$CLI_OUT"
  check "A1-l03: body unchanged" "$BODY_V2130_PATCHED" "$(cat "$f")"
  check "A1-l03: byte count unchanged" "$before" "$(bytes "$f")"
  check_no_file "A1-l03: no .bak written" "$f.bak"
}

# ---- A2: --legacy-single-literal ----------------------------------------------
# The legacy method is fixed for the whole run: initial classify, re-check and post-rename
# verify. A no-anchor bundle patched under it ends `patched`, not `failed`.

run_a2_legacy() {
  local root f after
  root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$BODY_NOANCHOR_FALSY"
  f="$root/$DIR_A/extension.js"

  # A2-g01: the default method refuses the no-anchor single literal, writing nothing.
  run_cli --extensions-dir "$(native_path "$root")"
  check "A2-g01: default method on a no-anchor literal exits 1" "1" "$CLI_RC"
  check_token "A2-g01: reported refused" "refused" "$CLI_OUT"
  check "A2-g01: body unchanged" "$BODY_NOANCHOR_FALSY" "$(cat "$f")"
  check_no_file "A2-g01: no .bak written" "$f.bak"

  # A2-g02: dry-run under the flag classifies would-patch and writes nothing.
  run_cli --extensions-dir "$(native_path "$root")" --legacy-single-literal --dry-run
  check "A2-g02: legacy dry-run exit 0" "0" "$CLI_RC"
  check_token "A2-g02: reported would-patch" "would-patch" "$CLI_OUT"
  check "A2-g02: body unchanged" "$BODY_NOANCHOR_FALSY" "$(cat "$f")"
  check_no_file "A2-g02: no .bak written" "$f.bak"
  check "A2-g02: no leftover tmp" "0" "$(count_tmp "$root")"

  # A2-g03: real run under the flag patches the single literal.
  run_cli --extensions-dir "$(native_path "$root")" --legacy-single-literal
  check "A2-g03: legacy run exit 0" "0" "$CLI_RC"
  check_token "A2-g03: reported patched" "patched" "$CLI_OUT"
  check_absent "A2-g03: post-rename verify did not fail" "post-verify-failed" "$CLI_OUT"
  after="$(cat "$f")"
  check "A2-g03: patched body" "$BODY_NOANCHOR_TRUTHY" "$after"
  check_file "A2-g03: backup created" "$f.bak"

  # A2-g04: re-run with the flag is a no-op.
  run_cli --extensions-dir "$(native_path "$root")" --legacy-single-literal
  check "A2-g04: legacy re-run exit 0" "0" "$CLI_RC"
  check_token "A2-g04: reported already" "already" "$CLI_OUT"
  check "A2-g04: body unchanged" "$after" "$(cat "$f")"

  # A2-g05: `;` delimiter accepted under the legacy method (the old C1-s12 intent).
  root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$BODY_SEMI_FALSY"
  f="$root/$DIR_A/extension.js"
  run_cli --extensions-dir "$(native_path "$root")" --legacy-single-literal
  check "A2-g05: semicolon-delimited literal exit 0" "0" "$CLI_RC"
  check_token "A2-g05: reported patched" "patched" "$CLI_OUT"
  check_contains "A2-g05: literal is now !0" 'includeWorktrees:!0;' "$(cat "$f")"
}

# The flag does not loosen any refusal: two literals (the 2.1.300 shape included) and an
# unknown value still refuse under it.
run_a2_legacy_refusals() {
  local name bodyvar root f
  while IFS='|' read -r name bodyvar; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "${!bodyvar}"
    f="$root/$DIR_A/extension.js"
    run_cli --extensions-dir "$(native_path "$root")" --legacy-single-literal
    check "$name: exits 1" "1" "$CLI_RC"
    check_token "$name: reported refused" "refused" "$CLI_OUT"
    check "$name: body unchanged" "${!bodyvar}" "$(cat "$f")"
    check_no_file "$name: no .bak written" "$f.bak"
  done <<'TABLE'
A2-g06-two-falsy | BODY_TWO_FALSY
A2-g07-v2130     | BODY_V2130
A2-g08-unknown   | BODY_UNKNOWN
TABLE
}

# An anchor with no key and the only literal outside it: refused, bytes and backups untouched.
run_a1_anchor_keyless() {
  local root f before
  root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$BODY_ANCHOR_KEYLESS"
  f="$root/$DIR_A/extension.js"; before="$(bytes "$f")"
  run_cli --extensions-dir "$(native_path "$root")"
  check "A1-l04: keyless anchor exits 1" "1" "$CLI_RC"
  check_token "A1-l04: reported refused" "refused" "$CLI_OUT"
  check "A1-l04: body unchanged" "$BODY_ANCHOR_KEYLESS" "$(cat "$f")"
  check "A1-l04: byte count unchanged" "$before" "$(bytes "$f")"
  check_no_file "A1-l04: no .bak written" "$f.bak"
}

# Nested objects / key-free anchor through the CLI. `-` in the patched column = unchanged.
run_a1_anchor_shapes() {
  local name bodyvar want_state want_rc patchedvar root f before want_body
  while IFS='|' read -r name bodyvar want_state want_rc patchedvar; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"; want_state="${want_state//[[:space:]]/}"
    want_rc="${want_rc//[[:space:]]/}"; patchedvar="${patchedvar//[[:space:]]/}"
    root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "${!bodyvar}"
    f="$root/$DIR_A/extension.js"; before="$(bytes "$f")"
    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: exit $want_rc" "$want_rc" "$CLI_RC"
    check_token "$name: reported $want_state" "$want_state" "$CLI_OUT"
    check "$name: byte count unchanged" "$before" "$(bytes "$f")"
    if [ "$patchedvar" = "-" ]; then
      want_body="${!bodyvar}"
      check_no_file "$name: no .bak written" "$f.bak"
    else
      want_body="${!patchedvar}"
      check_file "$name: backup created" "$f.bak"
    fi
    check "$name: whole body" "$want_body" "$(cat "$f")"
  done <<'TABLE'
A1-l05-nested-nokey   | BODY_ANCHOR_NESTED_NOKEY  | patched | 0 | BODY_ANCHOR_NESTED_NOKEY_PATCHED
A1-l06-nested-before  | BODY_ANCHOR_NESTED_BEFORE | refused | 1 | -
A1-l07-nested-after   | BODY_ANCHOR_NESTED_AFTER  | refused | 1 | -
A1-l08-anchor-nokey   | BODY_ANCHOR_NOKEY         | absent  | 0 | -
A1-l09-nested-only        | BODY_ANCHOR_NESTED_ONLY        | refused | 1 | -
A1-l10-nested-only-truthy | BODY_ANCHOR_NESTED_ONLY_TRUTHY | refused | 1 | -
A1-l11-array-nested       | BODY_ANCHOR_ARRAY_NESTED       | refused | 1 | -
A1-l12-str-sibling        | BODY_ANCHOR_STR_SIBLING        | refused | 1 | -
A1-l13-str-close          | BODY_ANCHOR_STR_CLOSE          | patched | 0 | BODY_ANCHOR_STR_CLOSE_PATCHED
A1-l14-esc-dq             | BODY_ANCHOR_ESC_DQ             | patched | 0 | BODY_ANCHOR_ESC_DQ_PATCHED
A1-l15-esc-sq             | BODY_ANCHOR_ESC_SQ             | patched | 0 | BODY_ANCHOR_ESC_SQ_PATCHED
A1-l16-key-in-str         | BODY_ANCHOR_KEY_IN_STR         | refused | 1 | -
A1-l17-template           | BODY_ANCHOR_TEMPLATE           | refused | 1 | -
A1-l18-regex              | BODY_ANCHOR_REGEX              | refused | 1 | -
A1-l19-anchor-in-dq        | BODY_ANCHOR_IN_DQ              | refused | 1 | -
A1-l20-anchor-in-dq-truthy | BODY_ANCHOR_IN_DQ_TRUTHY       | refused | 1 | -
A1-l21-anchor-in-sq        | BODY_ANCHOR_IN_SQ              | refused | 1 | -
A1-l22-anchor-in-comment   | BODY_ANCHOR_IN_COMMENT         | refused | 1 | -
TABLE
}

# Accepted anchor boundaries through the CLI: the lone `!1` (inside the anchor) becomes `!0`.
run_a1_anchor_boundaries() {
  local name bodyvar root f body
  while IFS='|' read -r name bodyvar; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    body="${!bodyvar}"
    root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$body"
    f="$root/$DIR_A/extension.js"
    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: exit 0" "0" "$CLI_RC"
    check_token "$name: reported patched" "patched" "$CLI_OUT"
    check "$name: whole body has the anchor site flipped" "${body//'!1'/'!0'}" "$(cat "$f")"
    check_file "$name: backup created" "$f.bak"
  done <<'TABLE'
A1-l23-after-rbrace  | BODY_ANCHOR_AFTER_RBRACE
A1-l24-after-comma   | BODY_ANCHOR_AFTER_COMMA
A1-l25-after-semi    | BODY_ANCHOR_AFTER_SEMI
A1-l26-after-lbrace  | BODY_ANCHOR_AFTER_LBRACE
TABLE
}

run_t1
run_t2
run_a1_v2130
run_a1_v2130_already
run_a1_anchor_keyless
run_a1_anchor_shapes
run_a1_anchor_boundaries
run_a2_legacy
run_a2_legacy_refusals
