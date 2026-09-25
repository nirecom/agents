# Part of tests/bin-vscode-cc-repair.sh (sourced, not standalone).
# T4 + C6 — argument surface boundaries through the real subprocess. Every rejection
# path is paired with a guard root that holds an unpatched fixture, so "exit 2" is
# never accepted on its own: the fixture must still be unpatched afterwards.

# ---- T4: empty root / nonexistent override --------------------------------

run_t4() {
  local root missing
  root="$(new_root)"
  run_cli --extensions-dir "$(native_path "$root")"
  check "T4a: empty root exit 0" "0" "$CLI_RC"
  check_contains "T4a: summary reports dirs=0" "dirs=0" "$CLI_OUT"
  check_contains "T4a: summary reports roots=1" "roots=1" "$CLI_OUT"
  check "T4a: nothing written into the root" "0" "$(count_files "$root")"

  # Deliberate asymmetry vs the silently-skipped default candidates: a typo in an
  # explicit override must not read as a 0-hit success.
  missing="$(native_path "$TMPROOT")/definitely-not-here"
  run_cli_split --extensions-dir "$missing"
  check "T4b: explicit nonexistent --extensions-dir exits 2" "2" "$CLI_RC"
  check_contains "T4b: diagnostic on stderr" "$STDERR_PREFIX" "$CLI_STDERR"
  check "T4b: nothing on stdout" "" "$CLI_STDOUT"
}

# ---- C6: --help, malformed args, malformed override paths -----------------

run_c6_help() {
  run_cli_split --help
  check "C6a: --help exits 0" "0" "$CLI_RC"
  check_contains "C6a: usage on stdout" "Usage" "$CLI_STDOUT"
  check_contains "C6a: usage documents --extensions-dir" "--extensions-dir" "$CLI_STDOUT"
  check_contains "C6a: usage documents --dry-run" "--dry-run" "$CLI_STDOUT"
  check "C6a: nothing on stderr" "" "$CLI_STDERR"
}

# Each row is run as: <valid guard override> <bad-arg...>  -> must exit 2 and leave
# the guard fixture untouched even though a valid root was supplied.
run_c6_argerrors() {
  local guard f before name

  run_c6_case() { # <name> <extra-args...>
    local n="$1"; shift
    run_cli_split --extensions-dir "$(native_path "$guard")" "$@"
    check "$n: exits 2" "2" "$CLI_RC"
    check_contains "$n: diagnostic on stderr" "$STDERR_PREFIX" "$CLI_STDERR"
    check "$n: no report on stdout" "" "$CLI_STDOUT"
    check "$n: guard fixture still unpatched" "$BODY_FALSY" "$(cat "$f")"
    check "$n: guard byte count unchanged" "$before" "$(bytes "$f")"
    check_no_file "$n: no .bak written" "$f.bak"
    check "$n: no leftover tmp" "0" "$(count_tmp "$guard")"
  }

  guard="$(new_root)"
  make_ext_dir "$guard" "$DIR_A" "$BODY_FALSY"
  f="$guard/$DIR_A/extension.js"; before="$(bytes "$f")"

  run_c6_case "C6b-unknown-option" --no-such-flag
  run_c6_case "C6c-positional" stray-positional
  run_c6_case "C6d-missing-value" --extensions-dir
  name="C6e-override-is-a-file"
  run_c6_case "$name" --extensions-dir "$(native_path "$guard")/$DIR_A/extension.js"
  # Absolute AND existent, but contains `..` — rejection is on the traversal segment,
  # not on absence.
  run_c6_case "C6f-dotdot-override" --extensions-dir "$(native_path "$guard")/$DIR_A/.."
  run_c6_case "C6g-relative-override" --extensions-dir "relative/extensions"
  # C10 — an EMPTY option value. parseArgs accepts it (the flag did get a value), so the
  # rejection has to come from the absolute-path check; an implementation that treated a
  # falsy value as "flag not supplied" would silently fall back to scanning the real
  # home-relative roots.
  run_c6_case "C10-a01-empty-override" --extensions-dir ""
}

# Two distinct valid overrides in one run: both roots are reported and processed.
run_c6_multi() {
  local r1 r2 f1 f2
  r1="$(new_root)"; r2="$(new_root)"
  make_ext_dir "$r1" "$DIR_A" "$BODY_FALSY"
  make_ext_dir "$r2" "$DIR_B" "$BODY_FALSY"
  f1="$r1/$DIR_A/extension.js"; f2="$r2/$DIR_B/extension.js"
  run_cli --extensions-dir "$(native_path "$r1")" --extensions-dir "$(native_path "$r2")"
  check "C6h: exit 0" "0" "$CLI_RC"
  check_contains "C6h: summary reports roots=2" "roots=2" "$CLI_OUT"
  check_contains "C6h: summary reports dirs=2" "dirs=2" "$CLI_OUT"
  check_contains "C6h: summary reports patched=2" "patched=2" "$CLI_OUT"
  check_contains "C6h: first override dir listed" "$DIR_A" "$CLI_OUT"
  check_contains "C6h: second override dir listed" "$DIR_B" "$CLI_OUT"
  check_contains "C6h: first override patched" 'includeWorktrees:!0' "$(cat "$f1")"
  check_contains "C6h: second override patched" 'includeWorktrees:!0' "$(cat "$f2")"
  check "C6h: no leftover tmp in first root" "0" "$(count_tmp "$r1")"
  check "C6h: no leftover tmp in second root" "0" "$(count_tmp "$r2")"
}

run_t4
run_c6_help
run_c6_argerrors
run_c6_multi
