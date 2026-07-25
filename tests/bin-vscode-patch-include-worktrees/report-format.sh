# Part of tests/bin-vscode-patch-include-worktrees.sh (sourced, not standalone).
# C6 + C8 — the report format itself. Elsewhere the count prefix is probed one field at
# a time (`literal=0`, `key=2`), which cannot catch a reordered, renamed or truncated
# prefix; and the root line was only checked for the substring `root: `, which cannot
# catch a duplicated root line, a wrong path, or a reordered root list. These rows pin
# the full ordered prefix on every reachable state and the exact root-line contents.

# The single authoritative ordered prefix shape. Anything that renames a field, reorders
# two fields, or drops one breaks every C6 row at once.
c6_prefix() { # <literal> <falsy> <truthy> <dynamic> <unsupported> <unknown> <key>
  printf 'literal=%s falsy=%s truthy=%s dynamic=%s unsupported=%s unknown=%s key=%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# Details portion of the first per-directory report line: everything after
# "<state>  <basename>  ". The count prefix must open it.
dir_line_details() { # <cli-output>
  local line
  line="$(first_dir_line "$1")"
  printf '%s' "${line#*"  $DIR_A  "}"
}

# Every reachable per-directory state must carry the FULL ordered prefix. `failed` is
# unreachable from a fixture (see the C7 gap block in failclosed-paths.sh); the other
# five are all driven here.
run_c6_prefix_on_every_state() {
  local name bodyvar extra want_state want root f details head
  while IFS='|' read -r name bodyvar extra want_state want; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    extra="${extra//[[:space:]]/}"
    want_state="${want_state//[[:space:]]/}"
    want="$(c6_prefix ${want})"

    root="$(mktemp -d "$TMPROOT/c6.XXXXXX")"
    make_ext_dir "$root" "$DIR_A" "${!bodyvar}"
    f="$root/$DIR_A/extension.js"
    if [ "$extra" = "dry-run" ]; then
      run_cli --extensions-dir "$(native_path "$root")" --dry-run
    else
      run_cli --extensions-dir "$(native_path "$root")"
    fi

    check_token "$name: state token is $want_state" "$want_state" "$CLI_OUT"
    details="$(dir_line_details "$CLI_OUT")"
    head="$(printf '%s' "$details" | cut -c "1-${#want}")"
    check "$name: details open with the full ordered count prefix" "$want" "$head"
    check_contains "$name: the report line itself carries the prefix" \
      "$want_state  $DIR_A  $want" "$CLI_OUT"
  done <<'TABLE'
C6-p01-patched     | BODY_FALSY      | run     | patched     | 1 1 0 1 0 0 2
C6-p02-already     | BODY_TRUTHY     | run     | already     | 1 0 1 1 0 0 2
C6-p03-absent      | BODY_ABSENT     | run     | absent      | 0 0 0 0 0 0 0
C6-p04-would-patch | BODY_FALSY      | dry-run | would-patch | 1 1 0 1 0 0 2
C6-p05-refused     | BODY_TWO_FALSY  | run     | refused     | 2 2 0 0 0 0 2
TABLE
}

# `refused` is reachable by two further routes whose counts differ from C6-p05, and the
# no-extension-js route is the only one where the prefix is synthesised from a zeroed
# counts object rather than from a real classify() call.
run_c6_prefix_refused_routes() {
  local root want details head
  root="$(mktemp -d "$TMPROOT/c6r.XXXXXX")"
  mkdir -p "$root/$DIR_A"
  run_cli --extensions-dir "$(native_path "$root")"
  want="$(c6_prefix 0 0 0 0 0 0 0)"
  details="$(dir_line_details "$CLI_OUT")"
  head="$(printf '%s' "$details" | cut -c "1-${#want}")"
  check "C6-p06: no-extension-js refusal carries the full zeroed prefix" "$want" "$head"
  check_contains "C6-p07: and the reason token follows it" \
    "$want no-extension-js" "$CLI_OUT"

  root="$(mktemp -d "$TMPROOT/c6r.XXXXXX")"
  make_ext_dir "$root" "$DIR_A" "$BODY_BAD_SYNTAX"
  run_cli --extensions-dir "$(native_path "$root")"
  want="$(c6_prefix 1 1 0 0 0 0 1)"
  details="$(dir_line_details "$CLI_OUT")"
  head="$(printf '%s' "$details" | cut -c "1-${#want}")"
  check "C6-p08: baseline-unparsable refusal carries the classified prefix" "$want" "$head"
  check_contains "C6-p09: and the reason token follows it" \
    "$want baseline-unparsable" "$CLI_OUT"
}

# The patched state appends a backup reason AFTER the prefix — proving the prefix is a
# leading, fixed-width-shape field list and not an unordered bag of tokens.
run_c6_prefix_then_reason() {
  local root want
  root="$(mktemp -d "$TMPROOT/c6b.XXXXXX")"
  make_ext_dir "$root" "$DIR_A" "$BODY_FALSY"
  run_cli --extensions-dir "$(native_path "$root")"
  want="$(c6_prefix 1 1 0 1 0 0 2)"
  check_contains "C6-p10: backup reason follows the complete prefix, never inside it" \
    "$want backup=created" "$CLI_OUT"
  run_cli --extensions-dir "$(native_path "$root")"
  check_contains "C6-p11: the already re-run prefix is recomputed from the new body" \
    "already  $DIR_A  $(c6_prefix 1 0 1 1 0 0 2)" "$CLI_OUT"
}

root_lines() { # <cli-output>
  grep '^root: ' <<< "$1" || true
}

# C8 — exactly one root line per root, carrying the exact absolute root path, in input
# order; and per-directory lines stay basename-only.
run_c8_root_lines() {
  local r1 r2 n1 n2
  r1="$(new_root)"; r2="$(new_root)"
  make_ext_dir "$r1" "$DIR_A" "$BODY_FALSY"
  make_ext_dir "$r2" "$DIR_B" "$BODY_FALSY"
  n1="$(native_path "$r1")"; n2="$(native_path "$r2")"

  run_cli --extensions-dir "$n1"
  check "C8-r01: one override yields exactly one root line" "1" \
    "$(root_lines "$CLI_OUT" | grep -c .)"
  check "C8-r02: that line carries the exact absolute root path" "root: $n1" \
    "$(root_lines "$CLI_OUT" | sed -n 1p)"
  check "C8-r03: directory report line is basename-only" "$DIR_A" \
    "$(first_dir_line "$CLI_OUT" | awk '{print $2}')"
  check_absent "C8-r04: the directory line carries no path separator" "/" \
    "$(first_dir_line "$CLI_OUT")"

  run_cli --extensions-dir "$n1" --extensions-dir "$n2"
  check "C8-r05: two overrides yield exactly two root lines" "2" \
    "$(root_lines "$CLI_OUT" | grep -c .)"
  check "C8-r06: first root line is the first override" "root: $n1" \
    "$(root_lines "$CLI_OUT" | sed -n 1p)"
  check "C8-r07: second root line is the second override" "root: $n2" \
    "$(root_lines "$CLI_OUT" | sed -n 2p)"

  # Reversed input: proves the order comes from the input list, not from sorting or
  # from filesystem readdir order.
  run_cli --extensions-dir "$n2" --extensions-dir "$n1"
  check "C8-r08: reversed input still yields two root lines" "2" \
    "$(root_lines "$CLI_OUT" | grep -c .)"
  check "C8-r09: reversed first root line follows the input order" "root: $n2" \
    "$(root_lines "$CLI_OUT" | sed -n 1p)"
  check "C8-r10: reversed second root line follows the input order" "root: $n1" \
    "$(root_lines "$CLI_OUT" | sed -n 2p)"

  # A repeated override collapses to one root line (dedup happens before reporting).
  run_cli --extensions-dir "$n1" --extensions-dir "$n1"
  check "C8-r11: a repeated override still prints exactly one root line" "1" \
    "$(root_lines "$CLI_OUT" | grep -c .)"
  check_contains "C8-r12: and the summary agrees" "roots=1" "$CLI_OUT"
}

# Zero roots: the nothing-to-do path must print no root line at all.
run_c8_zero_roots() {
  local home
  home="$(mktemp -d "$TMPROOT/c8z.XXXXXX")"
  run_cli_home "$home"
  check "C8-r13: no candidate root yields zero root lines" "0" \
    "$(root_lines "$CLI_OUT" | grep -c .)"
  check_contains "C8-r14: the nothing-to-do message is printed instead" \
    "no VS Code extension root found" "$CLI_OUT"
}

run_c6_prefix_on_every_state
run_c6_prefix_refused_routes
run_c6_prefix_then_reason
run_c8_root_lines
run_c8_zero_roots
