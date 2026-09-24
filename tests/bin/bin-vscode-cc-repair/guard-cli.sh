# Part of tests/bin-vscode-cc-repair.sh (sourced, not standalone).
# T3 — classifier/guard table driven through the real CLI, so the report and exit
# wiring is covered as well as the verdict. Every refused/absent row asserts the
# protected resource is untouched (Pattern 1): byte-identical content, unchanged
# byte count, no .bak, no leftover tmp.

run_t3() {
  local name bodyvar want_state want_exit want_details body root f before d
  while IFS='|' read -r name bodyvar want_state want_exit want_details; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    want_state="${want_state//[[:space:]]/}"
    want_exit="${want_exit//[[:space:]]/}"
    body="${!bodyvar}"
    root="$(mktemp -d "$TMPROOT/t3.XXXXXX")"
    make_ext_dir "$root" "$DIR_A" "$body"
    f="$root/$DIR_A/extension.js"; before="$(bytes "$f")"
    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: exit code" "$want_exit" "$CLI_RC"
    check_token "$name: state token" "$want_state" "$CLI_OUT"
    for d in $want_details; do
      check_contains "$name: detail carries $d" "$d" "$CLI_OUT"
    done
    check "$name: extension.js unchanged" "$body" "$(cat "$f")"
    check "$name: byte count unchanged" "$before" "$(bytes "$f")"
    check_no_file "$name: no .bak written" "$f.bak"
    check "$name: no leftover tmp" "0" "$(count_tmp "$root")"
  done <<'TABLE'
T3a | BODY_TWO_FALSY        | refused | 1 | literal=2 falsy=2
T3b | BODY_MIXED            | refused | 1 | literal=2 falsy=1 truthy=1
T3c | BODY_TWO_TRUTHY       | refused | 1 | literal=2 truthy=2
T3d | BODY_UNSUPPORTED      | refused | 1 | unsupported=1
T3e | BODY_ABSENT           | absent  | 0 | literal=0 key=0
T3f | BODY_DYNAMIC          | absent  | 0 | literal=0 key=1 dynamic=1
T3h | BODY_UNKNOWN          | refused | 1 | literal=0 unknown=1 key=1
T3i | BODY_UNSUPPORTED_TRUE | refused | 1 | literal=0 unsupported=1 key=1
C1-m09-falsy-unknown      | BODY_FALSY_UNKNOWN      | refused | 1 | literal=1 falsy=1 unknown=1 key=2 refused=1 patched=0 already=0
C1-m10-falsy-unsupported  | BODY_FALSY_UNSUPPORTED  | refused | 1 | literal=1 falsy=1 unsupported=1 key=2 refused=1 patched=0 already=0
C1-m11-truthy-unknown     | BODY_TRUTHY_UNKNOWN     | refused | 1 | literal=1 truthy=1 unknown=1 key=2 refused=1 patched=0 already=0
C1-m12-truthy-unsupported | BODY_TRUTHY_UNSUPPORTED | refused | 1 | literal=1 truthy=1 unsupported=1 key=2 refused=1 patched=0 already=0
C10-g01-key-at-eof        | BODY_KEY_AT_EOF         | refused | 1 | literal=0 unknown=1 key=1 refused=1 patched=0 already=0
TABLE
}

# C10 — a zero-byte extension.js. It cannot ride the T3 table: that loop's `unchanged`
# row would compare an empty string against an empty string, so the guarantee is pinned
# on the byte count and the directory file inventory instead.
run_c10_empty_file() {
  local root dir f
  root="$(mktemp -d "$TMPROOT/c10e.XXXXXX")"
  dir="$root/$DIR_A"
  mkdir -p "$dir"
  f="$dir/extension.js"
  : > "$f"
  check "C10-g02: precondition — fixture extension.js is zero bytes" "0" "$(bytes "$f")"
  run_cli --extensions-dir "$(native_path "$root")"
  check "C10-g03: empty extension.js exits 0" "0" "$CLI_RC"
  check_token "C10-g04: reported absent" "absent" "$CLI_OUT"
  check_contains "C10-g05: summary counts 1 absent" "absent=1" "$CLI_OUT"
  check_contains "C10-g06: summary counts 0 refused" "refused=0" "$CLI_OUT"
  check_contains "C10-g07: all-zero count prefix on absent" \
    "literal=0 falsy=0 truthy=0 dynamic=0 unsupported=0 unknown=0 key=0" "$CLI_OUT"
  check "C10-g08: extension.js still zero bytes" "0" "$(bytes "$f")"
  check "C10-g09: directory still holds exactly one file" "1" "$(count_files "$dir")"
  check_no_file "C10-g10: no .bak written" "$f.bak"
  check "C10-g11: no leftover tmp" "0" "$(count_tmp "$root")"
  check_absent "C10-g13: no diagnostic prefix for an absent bundle" "$STDERR_PREFIX" "$CLI_OUT"
}

# T3g: one failing directory must not abort the loop over its siblings.
run_t3g() {
  local root fa fb
  root="$(new_root)"
  make_ext_dir "$root" "$DIR_A" "$BODY_FALSY"
  make_ext_dir "$root" "$DIR_B" "$BODY_TWO_FALSY"
  fa="$root/$DIR_A/extension.js"; fb="$root/$DIR_B/extension.js"
  run_cli --extensions-dir "$(native_path "$root")"
  check "T3g: aggregate exit 1" "1" "$CLI_RC"
  check_token "T3g: valid sibling reported patched" "patched" "$CLI_OUT"
  check_token "T3g: bad sibling reported refused" "refused" "$CLI_OUT"
  check_contains "T3g: first directory listed" "$DIR_A" "$CLI_OUT"
  check_contains "T3g: second directory listed" "$DIR_B" "$CLI_OUT"
  check_contains "T3g: summary counts 2 dirs" "dirs=2" "$CLI_OUT"
  check_contains "T3g: summary counts 1 patched" "patched=1" "$CLI_OUT"
  check_contains "T3g: summary counts 1 refused" "refused=1" "$CLI_OUT"
  check_contains "T3g: valid sibling actually patched" 'includeWorktrees:!0' "$(cat "$fa")"
  check "T3g: refused sibling untouched" "$BODY_TWO_FALSY" "$(cat "$fb")"
}

# C1 sanctioned-input direction, end to end: a single literal whose delimiter is
# `)` or `;` (not `,` / `}`) must still be recognised and patched. Guards against
# a delimiter rule tightened into an over-rejection.
run_c1_cli_delimiters() {
  local name bodyvar body root f before patched
  while IFS='|' read -r name bodyvar; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    body="${!bodyvar}"
    root="$(mktemp -d "$TMPROOT/c1d.XXXXXX")"
    make_ext_dir "$root" "$DIR_A" "$body"
    f="$root/$DIR_A/extension.js"; before="$(bytes "$f")"
    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: exit 0" "0" "$CLI_RC"
    check_token "$name: reported patched" "patched" "$CLI_OUT"
    check_contains "$name: summary counts 1 patched" "patched=1" "$CLI_OUT"
    patched="$(cat "$f")"
    check_contains "$name: literal flipped to !0" 'includeWorktrees:!0' "$patched"
    check_absent "$name: no !1 remains" '!1' "$patched"
    check "$name: byte count unchanged" "$before" "$(bytes "$f")"
    check_file "$name: backup created" "$f.bak"
    check "$name: no leftover tmp" "0" "$(count_tmp "$root")"
  done <<'TABLE'
C1-d01-paren | BODY_PAREN_FALSY
C1-d02-semi  | BODY_SEMI_FALSY
TABLE
}

run_t3
run_c10_empty_file
run_t3g
run_c1_cli_delimiters
