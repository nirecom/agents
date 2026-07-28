# Part of tests/bin-vscode-cc-repair.sh (sourced, not standalone).
# C8 — EXTENSION_DIR_PATTERN edges and root-path edges. The /i flag and the \d anchor
# after the final `-` are both exercised in both directions, entries that are files
# rather than directories are excluded, and roots whose paths contain a space or shell
# metacharacters are driven end to end through the CLI.

list_dirs_of() { # <root> ; sets NODE_RC / NODE_OUT to "D=<sorted,basenames>"
  FIXROOT="$(native_path "$1")" \
  node_m 'const m=require("'"$REQUIRE_PATH"'");const p=require("path");
console.log("D="+m.listExtensionDirs(process.env.FIXROOT).map(y=>p.basename(String(y))).sort().join(","));'
}

# Mixed set: a case-variant match, an exact-case match, two non-digit suffixes, an
# unrelated publisher, and a digit-suffixed name that is a regular FILE.
run_c8_pattern() {
  local root
  root="$(mktemp -d "$TMPROOT/c8p.XXXXXX")"
  mkdir -p "$root/Anthropic.Claude-Code-2.0.0"
  mkdir -p "$root/$DIR_A"
  mkdir -p "$root/anthropic.claude-code-beta"
  mkdir -p "$root/anthropic.claude-code-"
  mkdir -p "$root/some-other.extension-1.0.0"
  printf 'x' > "$root/anthropic.claude-code-9.9.9"
  list_dirs_of "$root"
  check "C8a: node exit 0" "0" "$NODE_RC"
  check "C8a: only digit-suffixed directories enumerated, case-insensitively" \
    "D=Anthropic.Claude-Code-2.0.0,$DIR_A" "$NODE_OUT"
  check_contains "C8a: upper/mixed-case name matched" "Anthropic.Claude-Code-2.0.0" "$NODE_OUT"
  check_absent "C8a: unrelated publisher excluded" "some-other.extension" "$NODE_OUT"
  check_absent "C8a: file-not-directory entry excluded" "9.9.9" "$NODE_OUT"
}

# Isolated roots so the negative names cannot hide behind a positive substring.
run_c8_negatives() {
  local root
  root="$(mktemp -d "$TMPROOT/c8n.XXXXXX")"
  mkdir -p "$root/anthropic.claude-code-beta" "$root/anthropic.claude-code-"
  mkdir -p "$root/anthropic.claude-code" "$root/anthropic.claude-code-v2"
  list_dirs_of "$root"
  check "C8b: non-digit suffixes never enumerated" "D=" "$NODE_OUT"

  root="$(mktemp -d "$TMPROOT/c8f.XXXXXX")"
  printf 'x' > "$root/$DIR_A"
  list_dirs_of "$root"
  check "C8c: a matching name that is a regular file is not enumerated" "D=" "$NODE_OUT"
}

# Root paths with a space / with shell metacharacters, end to end through the CLI.
# The per-directory report line must carry the basename only — the absolute path
# appears once, on the root line.
run_c8_paths() {
  local name suffix root f before line
  while IFS='|' read -r name suffix; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    # Trim the padding but keep inner spaces — they are the point of case C8d.
    suffix="${suffix#"${suffix%%[![:space:]]*}"}"
    suffix="${suffix%"${suffix##*[![:space:]]}"}"
    root="$TMPROOT/$suffix"
    mkdir -p "$root"
    make_ext_dir "$root" "$DIR_A" "$BODY_FALSY"
    f="$root/$DIR_A/extension.js"; before="$(bytes "$f")"
    run_cli --extensions-dir "$(native_path "$root")"
    check "$name: exit 0" "0" "$CLI_RC"
    check_contains "$name: summary reports patched=1" "patched=1" "$CLI_OUT"
    check_contains "$name: file patched" 'includeWorktrees:!0' "$(cat "$f")"
    check "$name: byte count unchanged" "$before" "$(bytes "$f")"
    check_file "$name: backup created" "$f.bak"
    check "$name: no leftover tmp" "0" "$(count_tmp "$root")"
    line="$(first_dir_line "$CLI_OUT")"
    check_contains "$name: report line carries the basename" "$DIR_A" "$line"
    check_absent "$name: report line carries no forward slash" "/" "$line"
    check_absent "$name: report line carries no backslash" "\\" "$line"
    check_contains "$name: root line carries the absolute path once" "root: " "$CLI_OUT"
  done <<'TABLE'
C8d-space-in-path | c8 root with spaces
C8e-metachars     | c8-meta$;&+root
TABLE
}

# C5 — a matching entry inside the scanned root is a directory ALIAS whose target lives
# OUTSIDE that root. The contract's enumeration guard is `statSync(...).isDirectory()`,
# which follows a reparse point / symlink, and the contract defines no root-containment
# check — so the alias IS followed and its target's extension.js IS the patch target.
# This test therefore pins the CONTRACT-DERIVED behaviour plus the blast radius: the
# rewrite is confined to extension.js + extension.js.bak, the sibling sentinel beside it
# is byte-identical, no temp file survives anywhere, and the external absolute path
# never leaks into the per-directory report line.
#
# DIVERGENCE (recorded deliberately): the round-2 review asked for the external
# extension.js to be left untouched, i.e. for an escape guard. No such guard exists in
# the authoritative contract, and adding one here would assert behaviour the tool is not
# specified to have. If containment is ever adopted, C5-a03/C5-a04 below must be flipped
# in the same diff — that is the intended tripwire.
run_c5_escaping_alias() {
  local root outside target link f sib sentinel before sibbefore line
  sentinel='C5-EXTERNAL-SIBLING-SENTINEL'
  root="$(mktemp -d "$TMPROOT/c5root.XXXXXX")"
  outside="$(mktemp -d "$TMPROOT/c5out.XXXXXX")"
  target="$outside/escaped-target"
  mkdir -p "$target"
  f="$target/extension.js"
  sib="$target/sibling-sentinel.txt"
  printf '%s' "$BODY_FALSY" > "$f"
  printf '%s' "$sentinel" > "$sib"
  before="$(bytes "$f")"; sibbefore="$(bytes "$sib")"

  link="$root/$DIR_A"
  if ! make_dir_alias "$link" "$target"; then
    echo "SKIP: C5 escaping directory alias (neither 'ln -s' nor 'mklink /J' usable here)"
    SKIP=$((SKIP + 1))
    return 0
  fi

  run_cli --extensions-dir "$(native_path "$root")"
  check "C5-a01: exit 0" "0" "$CLI_RC"
  check_contains "C5-a02: the alias is enumerated as one directory" "dirs=1" "$CLI_OUT"
  check_contains "C5-a03: contract follows the alias (no containment guard specified)" \
    "patched=1" "$CLI_OUT"
  check_contains "C5-a04: the alias target's extension.js is the site that was rewritten" \
    'includeWorktrees:!0' "$(cat "$f")"
  check "C5-a05: the rewrite preserved the byte length" "$before" "$(bytes "$f")"
  check "C5-a06: the external sibling file is byte-identical" "$sentinel" "$(cat "$sib")"
  check "C5-a07: the external sibling byte count is unchanged" "$sibbefore" "$(bytes "$sib")"
  check "C5-a08: blast radius is extension.js + its .bak + the sibling only" "3" \
    "$(count_files "$target")"
  check "C5-a09: no leftover tmp outside the root" "0" "$(count_tmp "$outside")"
  check "C5-a10: no leftover tmp inside the root" "0" "$(count_tmp "$root")"
  line="$(first_dir_line "$CLI_OUT")"
  check_contains "C5-a11: report line carries the basename only" "$DIR_A" "$line"
  check_absent "C5-a12: report line does not leak the alias target path" "escaped-target" "$line"
  check_absent "C5-a13: report line carries no forward slash" "/" "$line"
  check_absent "C5-a14: report line carries no backslash" "\\" "$line"
}

# C9 — listExtensionDirs dedups by realpath. Two DIFFERENT matching names inside one
# root that resolve to the same real directory must be enumerated once, name-ascending
# order deciding which spelling survives. Without the realpath stage the directory would
# be processed twice: the second pass would see the already-patched body and report
# `already`, so the summary would read dirs=2 instead of dirs=1.
run_c9_realpath_dedup() {
  local root real f before
  root="$(mktemp -d "$TMPROOT/c9.XXXXXX")"
  real="$root/$DIR_A"
  mkdir -p "$real"
  f="$real/extension.js"
  printf '%s' "$BODY_FALSY" > "$f"
  before="$(bytes "$f")"

  if ! make_dir_alias "$root/$DIR_B" "$real"; then
    echo "SKIP: C9 realpath dedup of matching-name aliases (no directory alias available)"
    SKIP=$((SKIP + 1))
    return 0
  fi

  list_dirs_of "$root"
  check "C9-d01: node exit 0" "0" "$NODE_RC"
  check "C9-d02: two matching names resolving to one real dir collapse to one entry" \
    "D=$DIR_A" "$NODE_OUT"
  check_absent "C9-d03: the aliased spelling is not enumerated" "$DIR_B" "$NODE_OUT"

  run_cli --extensions-dir "$(native_path "$root")"
  check "C9-d04: exit 0" "0" "$CLI_RC"
  check_contains "C9-d05: the CLI enumerates one directory, not two" "dirs=1" "$CLI_OUT"
  check_contains "C9-d06: summary counts 1 patched" "patched=1" "$CLI_OUT"
  check_contains "C9-d07: summary counts 0 already (no second pass)" "already=0" "$CLI_OUT"
  check_absent "C9-d08: the aliased spelling is absent from the report" "$DIR_B" "$CLI_OUT"
  check_contains "C9-d09: the real directory was patched" 'includeWorktrees:!0' "$(cat "$f")"
  check "C9-d10: byte count unchanged" "$before" "$(bytes "$f")"
  check "C9-d11: no leftover tmp" "0" "$(count_tmp "$root")"
}

run_c8_pattern
run_c8_negatives
run_c8_paths
run_c5_escaping_alias
run_c9_realpath_dedup
