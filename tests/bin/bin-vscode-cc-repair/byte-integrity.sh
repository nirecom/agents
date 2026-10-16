# Part of tests/bin/bin-vscode-cc-repair.sh (sourced, not standalone).
# Tests: bin/vscode-cc-repair
# Tags: bin, vscode, extension-patch, scope:common, pwsh-not-required, TL2
# C3 — byte integrity against accidental UTF-8 decoding. Every other fixture in this
# suite is pure ASCII, so swapping latin1 for utf8 on the read/write pair would go
# unnoticed. This fixture embeds bytes 0xFF 0xFE 0x80 (never valid UTF-8) inside a
# block comment, far from the patch site: a utf8 round-trip rewrites them as U+FFFD
# (3 bytes each) and the byte-length invariant collapses.
# Whole-file comparison uses cmp / od — never "$(cat …)", which mangles raw bytes.

run_c3() {
  local root dir f orig before diffout nlines oct rc hex bakrc

  root="$(new_root)"
  dir="$root/$DIR_A"
  mkdir -p "$dir"
  f="$dir/extension.js"
  printf 'var a={sessionListOptions(){return{includeWorktrees:!1}}};\n/* raw bytes \377\376\200 kept verbatim */\nmodule.exports={a};\n' > "$f"

  orig="$TMPROOT/c3-original.bin"
  cp "$f" "$orig"
  before="$(bytes "$f")"

  # Precondition: the fixture really does hold non-UTF-8 bytes.
  hex="$(od -An -tx1 "$orig" | tr -d ' \n')"
  check_contains "C3: fixture embeds the invalid UTF-8 byte run" "fffe80" "$hex"

  run_cli --extensions-dir "$(native_path "$root")"
  check "C3: exit 0" "0" "$CLI_RC"
  check_token "C3: reported patched" "patched" "$CLI_OUT"
  check "C3: total byte count unchanged" "$before" "$(bytes "$f")"

  # Exactly one byte differs from the original, and it is ASCII '1' (061) -> '0' (060).
  diffout="$(cmp -l "$orig" "$f" 2>/dev/null || true)"
  nlines="$(printf '%s' "$diffout" | grep -c . || true)"
  check "C3: exactly one byte differs after the patch" "1" "$nlines"
  oct="$(printf '%s\n' "$diffout" | head -1 | awk '{print $2"-"$3}')"
  check "C3: the single differing byte is ASCII 1 -> 0" "61-60" "$oct"

  # The invalid bytes survived the latin1 round-trip untouched.
  hex="$(od -An -tx1 "$f" | tr -d ' \n')"
  check_contains "C3: invalid UTF-8 byte run survived the patch" "fffe80" "$hex"

  # The backup is a byte-for-byte copy of the pristine original.
  check_file "C3: backup created" "$f.bak"
  bakrc=0
  cmp -s "$orig" "$f.bak" || bakrc=$?
  check "C3: extension.js.bak is byte-identical to the original" "0" "$bakrc"

  check "C3: no leftover tmp" "0" "$(count_tmp "$root")"

  # Re-running must classify `already` — proving the patched bytes still parse and
  # the re-read path is latin1-clean too.
  run_cli --extensions-dir "$(native_path "$root")"
  check "C3: re-run exit 0" "0" "$CLI_RC"
  check_token "C3: re-run reported already" "already" "$CLI_OUT"
  rc=0
  cmp -s "$orig" "$f.bak" || rc=$?
  check "C3: re-run left the backup byte-identical" "0" "$rc"
}

# #2683 — on the 2.1.300 shape (resolveSession site FIRST) exactly one byte changes, and it
# is the anchor-internal literal's digit; the resolveSession `!1` keeps every byte.
run_c3_v2130() {
  local root f orig diffout nlines anchor_part pre want_pos got
  root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$BODY_V2130_REV"
  f="$root/$DIR_A/extension.js"
  orig="$TMPROOT/c3-v2130-original.bin"
  cp "$f" "$orig"

  anchor_part='sessionListOptions(){return{cwd:this.cwd,includeWorktrees:!'
  pre="${BODY_V2130_REV%%"$anchor_part"*}"
  want_pos=$(( ${#pre} + ${#anchor_part} + 1 ))

  run_cli --extensions-dir "$(native_path "$root")"
  check "C3-v01: 2.1.300 shape exit 0" "0" "$CLI_RC"
  check_token "C3-v01: reported patched" "patched" "$CLI_OUT"
  diffout="$(cmp -l "$orig" "$f" 2>/dev/null || true)"
  nlines="$(printf '%s' "$diffout" | grep -c . || true)"
  check "C3-v02: exactly one byte differs" "1" "$nlines"
  got="$(printf '%s\n' "$diffout" | head -1 | awk '{print $1":"$2"-"$3}')"
  check "C3-v03: the differing byte is the anchor literal's 1 -> 0" "$want_pos:61-60" "$got"
}

# #2683 — a `}` inside a string before the target key: the patch changes exactly one byte,
# the anchor key's digit (each body holds a single `includeWorktrees:!`).
run_c3_string_anchor() {
  local name bodyvar body root f orig diffout nlines pre want_pos got
  while IFS='|' read -r name bodyvar; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    body="${!bodyvar}"
    root="$(new_root)"; make_ext_dir "$root" "$DIR_A" "$body"
    f="$root/$DIR_A/extension.js"
    orig="$TMPROOT/c3-$name-original.bin"
    cp "$f" "$orig"
    pre="${body%%includeWorktrees:!*}"
    want_pos=$(( ${#pre} + ${#KEY_BANG} + 1 ))
    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: exit 0" "0" "$CLI_RC"
    check_token "$name: reported patched" "patched" "$CLI_OUT"
    diffout="$(cmp -l "$orig" "$f" 2>/dev/null || true)"
    nlines="$(printf '%s' "$diffout" | grep -c . || true)"
    check "$name: exactly one byte differs" "1" "$nlines"
    got="$(printf '%s\n' "$diffout" | head -1 | awk '{print $1":"$2"-"$3}')"
    check "$name: the differing byte is the anchor key's 1 -> 0" "$want_pos:61-60" "$got"
  done <<'TABLE'
C3-v04-str-close | BODY_ANCHOR_STR_CLOSE
C3-v05-esc-dq    | BODY_ANCHOR_ESC_DQ
C3-v06-esc-sq    | BODY_ANCHOR_ESC_SQ
TABLE
}

KEY_BANG='includeWorktrees:!'

run_c3
run_c3_v2130
run_c3_string_anchor
