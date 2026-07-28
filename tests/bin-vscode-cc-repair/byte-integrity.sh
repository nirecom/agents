# Part of tests/bin-vscode-cc-repair.sh (sourced, not standalone).
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
  printf 'var a={includeWorktrees:!1};\n/* raw bytes \377\376\200 kept verbatim */\nmodule.exports={a};\n' > "$f"

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

run_c3
