# Part of tests/bin-vscode-cc-repair.sh (sourced, not standalone).
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

run_t1
run_t2
