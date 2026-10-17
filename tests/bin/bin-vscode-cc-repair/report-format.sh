# Part of tests/bin/bin-vscode-cc-repair.sh (sourced, not standalone).
# Tests: bin/vscode-cc-repair
# Tags: bin, vscode, extension-patch, scope:common, pwsh-not-required, TL2
# C6 + C8 — the report format itself. Elsewhere the count prefix is probed one field at
# a time (`literal=0`, `key=2`), which cannot catch a reordered, renamed or truncated
# prefix; and the root line was only checked for the substring `root: `, which cannot
# catch a duplicated root line, a wrong path, or a reordered root list. These rows pin
# the full ordered prefix on every reachable state and the exact root-line contents.

# The single authoritative ordered prefix shape. Anything that renames a field, reorders
# two fields, or drops one breaks every C6 row at once. #2683 appended anchor= / anchor-value=.
c6_prefix() { # <literal> <falsy> <truthy> <dynamic> <unsupported> <unknown> <key> <anchor> <anchor-value>
  printf 'literal=%s falsy=%s truthy=%s dynamic=%s unsupported=%s unknown=%s key=%s anchor=%s anchor-value=%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
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
C6-p01-patched     | BODY_FALSY      | run     | patched     | 1 1 0 1 0 0 2 1 falsy
C6-p02-already     | BODY_TRUTHY     | run     | already     | 1 0 1 1 0 0 2 1 truthy
C6-p03-absent      | BODY_ABSENT     | run     | absent      | 0 0 0 0 0 0 0 0 -
C6-p04-would-patch | BODY_FALSY      | dry-run | would-patch | 1 1 0 1 0 0 2 1 falsy
C6-p05-refused     | BODY_TWO_FALSY  | run     | refused     | 2 2 0 0 0 0 2 0 -
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
  want="$(c6_prefix 0 0 0 0 0 0 0 0 -)"
  details="$(dir_line_details "$CLI_OUT")"
  head="$(printf '%s' "$details" | cut -c "1-${#want}")"
  check "C6-p06: no-extension-js refusal carries the full zeroed prefix" "$want" "$head"
  check_contains "C6-p07: and the reason token follows it" \
    "$want no-extension-js" "$CLI_OUT"

  root="$(mktemp -d "$TMPROOT/c6r.XXXXXX")"
  make_ext_dir "$root" "$DIR_A" "$BODY_BAD_SYNTAX"
  run_cli --extensions-dir "$(native_path "$root")"
  want="$(c6_prefix 1 1 0 0 0 0 1 1 falsy)"
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
  want="$(c6_prefix 1 1 0 1 0 0 2 1 falsy)"
  check_contains "C6-p10: backup reason follows the complete prefix, never inside it" \
    "$want backup=created" "$CLI_OUT"
  run_cli --extensions-dir "$(native_path "$root")"
  check_contains "C6-p11: the already re-run prefix is recomputed from the new body" \
    "already  $DIR_A  $(c6_prefix 1 0 1 1 0 0 2 1 truthy)" "$CLI_OUT"
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

# #2683 — the refusal reason is readable from the report line. Token scheme (one token in
# the tail after the unchanged count prefix): reason=no-anchor | reason=multiple-anchors |
# reason=ambiguous-anchor | reason=unknown-value. Unknown wins over anchor causes (checked first).
run_c6_anchor_diagnostics() {
  local name bodyvar reason root line tail
  local -a names=() tails=()
  while IFS='|' read -r name bodyvar reason; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"
    reason="${reason//[[:space:]]/}"
    root="$(mktemp -d "$TMPROOT/c6d.XXXXXX")"
    make_ext_dir "$root" "$DIR_A" "${!bodyvar}"
    run_cli --extensions-dir "$(native_path "$root")"
    check_token "$name: refused" "refused" "$CLI_OUT"
    line="$(first_dir_line "$CLI_OUT")"
    tail="$(printf '%s' "$line" | sed -E 's/.* key=[0-9]+//')"
    check_contains "$name: diagnostics after the count prefix name the anchor" "anchor" \
      "$(printf '%s' "$tail" | tr '[:upper:]' '[:lower:]')"
    check_contains "$name: diagnostic names the cause" "reason=$reason" "$tail"
    names+=("$name"); tails+=("$tail")
  done <<'TABLE'
C6-d01-no-anchor      | BODY_NOANCHOR_FALSY  | no-anchor
C6-d02-two-anchors    | BODY_TWO_ANCHORS     | multiple-anchors
C6-d03-ambiguous      | BODY_ANCHOR_TWO_KEYS | ambiguous-anchor
TABLE
  local i j
  for i in 0 1 2; do
    for j in 0 1 2; do
      [ "$i" -lt "$j" ] || continue
      if [ "${tails[$i]}" != "${tails[$j]}" ]; then
        echo "PASS: C6-d04: ${names[$i]} and ${names[$j]} diagnostics differ"; PASS=$((PASS + 1))
      else
        echo "FAIL: C6-d04: ${names[$i]} and ${names[$j]} diagnostics identical [${tails[$i]}]"
        FAIL=$((FAIL + 1))
      fi
    done
  done

  root="$(mktemp -d "$TMPROOT/c6d.XXXXXX")"
  make_ext_dir "$root" "$DIR_A" "$BODY_OUTSIDE_UNKNOWN"
  run_cli --extensions-dir "$(native_path "$root")"
  check_contains "C6-d05: unknown-value refusal keeps the unknown=1 count token" \
    "refused  $DIR_A  $(c6_prefix 1 1 0 0 0 1 2 1 falsy)" "$CLI_OUT"
  check_contains "C6-d06: unknown-value refusal names its cause" "reason=unknown-value" \
    "$(first_dir_line "$CLI_OUT")"
  check_absent "C6-d07: and not an anchor cause" "-anchor" "$(first_dir_line "$CLI_OUT")"

  # A nested key inside the anchor literal is an ambiguity, not a second anchor.
  root="$(mktemp -d "$TMPROOT/c6d.XXXXXX")"
  make_ext_dir "$root" "$DIR_A" "$BODY_ANCHOR_NESTED_BEFORE"
  run_cli --extensions-dir "$(native_path "$root")"
  check_contains "C6-d08: nested in-anchor key reports ambiguous-anchor" \
    "reason=ambiguous-anchor" "$(first_dir_line "$CLI_OUT")"
}

# #2683 — `anchor=<n> anchor-value=<token>` directly follow `key=N`, under both methods.
# Column 3: run | legacy (--legacy-single-literal).
run_c6_anchor_fields() {
  local name bodyvar mode want_state n_anchor value root line tail want
  while IFS='|' read -r name bodyvar mode want_state n_anchor value; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"; mode="${mode//[[:space:]]/}"
    want_state="${want_state//[[:space:]]/}"; n_anchor="${n_anchor//[[:space:]]/}"
    value="${value//[[:space:]]/}"
    root="$(mktemp -d "$TMPROOT/c6a.XXXXXX")"
    make_ext_dir "$root" "$DIR_A" "${!bodyvar}"
    if [[ "$mode" == "legacy" ]]; then
      run_cli --extensions-dir "$(native_path "$root")" --legacy-single-literal
    else
      run_cli --extensions-dir "$(native_path "$root")"
    fi
    check_token "$name: state token is $want_state" "$want_state" "$CLI_OUT"
    line="$(first_dir_line "$CLI_OUT")"
    tail="$(printf '%s' "$line" | sed -E 's/^.* key=[0-9]+//')"
    want=" anchor=$n_anchor anchor-value=$value"
    check "$name: anchor fields directly follow key=N" "$want" "$(printf '%s' "$tail" | cut -c "1-${#want}")"
  done <<'TABLE'
C6-d09-v2130-patched      | BODY_V2130                     | run    | patched | 1 | falsy
C6-d10-v2130-already      | BODY_V2130_PATCHED             | run    | already | 1 | truthy
C6-d11-no-anchor          | BODY_NOANCHOR_FALSY            | run    | refused | 0 | -
C6-d12-two-anchors        | BODY_TWO_ANCHORS               | run    | refused | 2 | -
C6-d13-nested-only        | BODY_ANCHOR_NESTED_ONLY        | run    | refused | 1 | ambiguous
C6-d14-anchor-nokey       | BODY_ANCHOR_NOKEY              | run    | absent  | 1 | none
C6-d15-anchor-keyless     | BODY_ANCHOR_KEYLESS            | run    | refused | 1 | none
C6-d16-anchor-dynamic     | BODY_ANCHOR_DYNAMIC            | run    | refused | 1 | dynamic
C6-d17-anchor-unknown     | BODY_ANCHOR_UNKNOWN            | run    | refused | 1 | unknown
C6-d18-anchor-true        | BODY_ANCHOR_TRUE               | run    | refused | 1 | unsupported
C6-d19-unclosed           | BODY_ANCHOR_UNCLOSED           | run    | refused | 1 | ambiguous
C6-d20-template           | BODY_ANCHOR_TEMPLATE           | run    | refused | 1 | ambiguous
C6-d21-str-sibling        | BODY_ANCHOR_STR_SIBLING        | run    | refused | 1 | none
C6-d22-legacy-noanchor    | BODY_NOANCHOR_FALSY            | legacy | patched | 0 | -
C6-d23-legacy-v2130       | BODY_V2130                     | legacy | refused | 1 | falsy
C6-d24-legacy-nested-only | BODY_ANCHOR_NESTED_ONLY        | legacy | patched | 1 | ambiguous
C6-d35-anchor-in-dq        | BODY_ANCHOR_IN_DQ              | run    | refused | 1 | ambiguous
C6-d36-legacy-anchor-in-dq | BODY_ANCHOR_IN_DQ              | legacy | patched | 1 | ambiguous
TABLE

  # The same bundle across a real patch: falsy on the first run, truthy on the re-run.
  root="$(mktemp -d "$TMPROOT/c6a.XXXXXX")"
  make_ext_dir "$root" "$DIR_A" "$BODY_V2130"
  run_cli --extensions-dir "$(native_path "$root")"
  check_contains "C6-d25: first run reports anchor-value=falsy" \
    "patched  $DIR_A  $(c6_prefix 2 2 0 0 0 0 2 1 falsy)" "$CLI_OUT"
  run_cli --extensions-dir "$(native_path "$root")"
  check_contains "C6-d26: already re-run reports anchor-value=truthy" \
    "already  $DIR_A  $(c6_prefix 2 1 1 0 0 0 2 1 truthy)" "$CLI_OUT"
}

# #2683 — refusal reasons for the depth-1 and string-aware anchor rules.
run_c6_anchor_reasons() {
  local name bodyvar reason root
  while IFS='|' read -r name bodyvar reason; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    bodyvar="${bodyvar//[[:space:]]/}"; reason="${reason//[[:space:]]/}"
    root="$(mktemp -d "$TMPROOT/c6r2.XXXXXX")"
    make_ext_dir "$root" "$DIR_A" "${!bodyvar}"
    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: exit 1" "1" "$CLI_RC"
    check_token "$name: refused" "refused" "$CLI_OUT"
    check_contains "$name: reason=$reason" "reason=$reason" "$(first_dir_line "$CLI_OUT")"
  done <<'TABLE'
C6-d27-nested-only        | BODY_ANCHOR_NESTED_ONLY        | ambiguous-anchor
C6-d28-nested-only-truthy | BODY_ANCHOR_NESTED_ONLY_TRUTHY | ambiguous-anchor
C6-d29-array-nested       | BODY_ANCHOR_ARRAY_NESTED       | ambiguous-anchor
C6-d30-str-sibling        | BODY_ANCHOR_STR_SIBLING        | no-anchor-key
C6-d31-key-in-str         | BODY_ANCHOR_KEY_IN_STR         | ambiguous-anchor
C6-d32-template           | BODY_ANCHOR_TEMPLATE           | ambiguous-anchor
C6-d33-regex              | BODY_ANCHOR_REGEX              | ambiguous-anchor
C6-d34-unclosed           | BODY_ANCHOR_UNCLOSED           | ambiguous-anchor
C6-d37-anchor-in-dq        | BODY_ANCHOR_IN_DQ              | ambiguous-anchor
C6-d38-anchor-in-dq-truthy | BODY_ANCHOR_IN_DQ_TRUTHY       | ambiguous-anchor
C6-d39-anchor-in-sq        | BODY_ANCHOR_IN_SQ              | ambiguous-anchor
C6-d40-anchor-in-comment   | BODY_ANCHOR_IN_COMMENT         | ambiguous-anchor
TABLE

  # The full string-anchor line: unchanged prefix, then the reason token.
  root="$(mktemp -d "$TMPROOT/c6r2.XXXXXX")"
  make_ext_dir "$root" "$DIR_A" "$BODY_ANCHOR_IN_DQ"
  run_cli --extensions-dir "$(native_path "$root")"
  check_contains "C6-d41: string-anchor line carries anchor-value=ambiguous then the reason" \
    "refused  $DIR_A  $(c6_prefix 1 1 0 0 0 0 1 1 ambiguous) reason=ambiguous-anchor" "$CLI_OUT"
}

run_c6_prefix_on_every_state
run_c6_anchor_fields
run_c6_anchor_reasons
run_c6_anchor_diagnostics
run_c6_prefix_refused_routes
run_c6_prefix_then_reason
run_c8_root_lines
run_c8_zero_roots
