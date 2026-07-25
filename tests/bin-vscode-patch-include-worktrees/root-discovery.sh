# Part of tests/bin-vscode-patch-include-worktrees.sh (sourced, not standalone).
# C4 + T5 — candidate-root discovery. C4 drives it through the real subprocess with an
# injected fixture HOME/USERPROFILE, so main() cannot pass by ignoring resolveRoots;
# T5 pins the exported table and the dedup stages.

# ---- C4: default-root discovery through the real CLI ----------------------

run_c4a() {
  local home ext f
  home="$(mktemp -d "$TMPROOT/c4a.XXXXXX")"
  ext="$home/.vscode/extensions"
  mkdir -p "$ext"
  make_ext_dir "$ext" "$DIR_A" "$BODY_FALSY"
  f="$ext/$DIR_A/extension.js"
  run_cli_home "$home"
  check "C4a: exit 0 with no --extensions-dir" "0" "$CLI_RC"
  check_contains "C4a: summary reports roots=1" "roots=1" "$CLI_OUT"
  check_contains "C4a: summary reports dirs=1" "dirs=1" "$CLI_OUT"
  check_contains "C4a: summary reports patched=1" "patched=1" "$CLI_OUT"
  check_token "C4a: reported patched" "patched" "$CLI_OUT"
  check_contains "C4a: discovered dir listed" "$DIR_A" "$CLI_OUT"
  check_contains "C4a: the discovered file was actually patched" \
    'includeWorktrees:!0' "$(cat "$f")"
  check_file "C4a: backup created in the discovered dir" "$f.bak"
}

run_c4b() {
  local home stable server fa fb
  home="$(mktemp -d "$TMPROOT/c4b.XXXXXX")"
  stable="$home/.vscode/extensions"
  server="$home/.vscode-server/extensions"
  mkdir -p "$stable" "$server"
  make_ext_dir "$stable" "$DIR_A" "$BODY_FALSY"
  make_ext_dir "$server" "$DIR_B" "$BODY_FALSY"
  fa="$stable/$DIR_A/extension.js"; fb="$server/$DIR_B/extension.js"
  run_cli_home "$home"
  check "C4b: exit 0" "0" "$CLI_RC"
  check_contains "C4b: both candidate roots discovered" "roots=2" "$CLI_OUT"
  check_contains "C4b: both dirs enumerated" "dirs=2" "$CLI_OUT"
  check_contains "C4b: both dirs patched" "patched=2" "$CLI_OUT"
  check_contains "C4b: .vscode dir patched" 'includeWorktrees:!0' "$(cat "$fa")"
  check_contains "C4b: .vscode-server dir patched" 'includeWorktrees:!0' "$(cat "$fb")"
}

run_c4c() {
  local home
  home="$(mktemp -d "$TMPROOT/c4c.XXXXXX")"
  run_cli_home "$home"
  check "C4c: home with no candidate root exits 0" "0" "$CLI_RC"
  check_contains "C4c: reports the nothing-to-do message" \
    "no VS Code extension root found" "$CLI_OUT"
  check_contains "C4c: all-zero summary" \
    "summary: roots=0 dirs=0 patched=0 already=0 absent=0 would-patch=0 refused=0 failed=0" \
    "$CLI_OUT"
  check "C4c: nothing created under the fixture home" "0" "$(count_files "$home")"
}

# When --extensions-dir is supplied the default candidate table must not be scanned
# at all — the fixture home's own matching directory stays invisible and untouched.
run_c4d() {
  local home ext ovr fh fo
  home="$(mktemp -d "$TMPROOT/c4d.XXXXXX")"
  ext="$home/.vscode/extensions"
  mkdir -p "$ext"
  make_ext_dir "$ext" "$DIR_B" "$BODY_FALSY"
  ovr="$(new_root)"
  make_ext_dir "$ovr" "$DIR_A" "$BODY_FALSY"
  fh="$ext/$DIR_B/extension.js"; fo="$ovr/$DIR_A/extension.js"
  run_cli_home "$home" --extensions-dir "$(native_path "$ovr")"
  check "C4d: exit 0" "0" "$CLI_RC"
  check_contains "C4d: only the override root is scanned" "roots=1" "$CLI_OUT"
  check_contains "C4d: only one dir enumerated" "dirs=1" "$CLI_OUT"
  check_contains "C4d: override dir listed" "$DIR_A" "$CLI_OUT"
  check_absent "C4d: home candidate dir not listed" "$DIR_B" "$CLI_OUT"
  check_contains "C4d: override dir patched" 'includeWorktrees:!0' "$(cat "$fo")"
  check "C4d: home candidate left unpatched" "$BODY_FALSY" "$(cat "$fh")"
  check_no_file "C4d: no .bak in the unscanned home dir" "$fh.bak"
}

# C2 — all FOUR home-relative candidate roots in one run. C4a/C4b only ever create
# `.vscode` and `.vscode-server`, so the two insiders entries of CANDIDATE_ROOTS were
# never executed: a typo in either spelling (or an entry dropped from the table) stayed
# invisible. Every root here holds one matching directory with an unpatched body, so the
# assertion is that all four are discovered AND all four files are really rewritten.
C2_ROOT_RELS='.vscode .vscode-insiders .vscode-server .vscode-server-insiders'

run_c2_all_candidate_roots() {
  local home rel ext f
  home="$(mktemp -d "$TMPROOT/c2roots.XXXXXX")"
  for rel in $C2_ROOT_RELS; do
    ext="$home/$rel/extensions"
    mkdir -p "$ext"
    make_ext_dir "$ext" "$DIR_A" "$BODY_FALSY"
  done

  run_cli_home "$home"
  check "C2-r01: exit 0 with no --extensions-dir" "0" "$CLI_RC"
  check_contains "C2-r02: all four candidate roots discovered" "roots=4" "$CLI_OUT"
  check_contains "C2-r03: one matching dir per root enumerated" "dirs=4" "$CLI_OUT"
  check_contains "C2-r04: all four dirs patched" "patched=4" "$CLI_OUT"
  check_contains "C2-r05: no root refused" "refused=0" "$CLI_OUT"
  check "C2-r06: exactly four root lines" "4" "$(grep -c '^root: ' <<< "$CLI_OUT")"
  for rel in $C2_ROOT_RELS; do
    f="$home/$rel/extensions/$DIR_A/extension.js"
    check_contains "C2-r07-$rel: the discovered file was actually patched" \
      'includeWorktrees:!0' "$(cat "$f")"
    check_absent "C2-r08-$rel: no !1 remains" '!1' "$(cat "$f")"
    check_file "C2-r09-$rel: backup created" "$f.bak"
    check "C2-r10-$rel: no leftover tmp" "0" "$(count_tmp "$home/$rel")"
  done
}

# C11 — a default candidate path that exists as a REGULAR FILE. `isDir` is a statSync
# guard, so the entry must be skipped exactly like an absent candidate: silently, with
# no diagnostic and no exit-code change. Only the real sibling root is scanned.
run_c11_file_candidate() {
  local home ext cand sentinel before f
  sentinel='C11-REGULAR-FILE-NOT-A-DIRECTORY'
  home="$(mktemp -d "$TMPROOT/c11.XXXXXX")"
  ext="$home/.vscode/extensions"
  mkdir -p "$ext"
  make_ext_dir "$ext" "$DIR_A" "$BODY_FALSY"
  f="$ext/$DIR_A/extension.js"
  mkdir -p "$home/.vscode-insiders"
  cand="$home/.vscode-insiders/extensions"
  printf '%s' "$sentinel" > "$cand"
  before="$(bytes "$cand")"

  run_cli_home "$home"
  check "C11-r01: a file-not-directory candidate does not crash the run" "0" "$CLI_RC"
  check_contains "C11-r02: only the real directory root is counted" "roots=1" "$CLI_OUT"
  check "C11-r03: exactly one root line" "1" "$(grep -c '^root: ' <<< "$CLI_OUT")"
  check_absent "C11-r04: the file candidate is never reported as a root" \
    ".vscode-insiders" "$CLI_OUT"
  check_absent "C11-r05: skipped silently — no diagnostic emitted" "$STDERR_PREFIX" "$CLI_OUT"
  check_contains "C11-r06: the sibling real root still patched" "patched=1" "$CLI_OUT"
  check_contains "C11-r07: the sibling file was actually rewritten" \
    'includeWorktrees:!0' "$(cat "$f")"
  check "C11-r08: the regular-file candidate is byte-identical" "$sentinel" "$(cat "$cand")"
  check "C11-r09: its byte count is unchanged" "$before" "$(bytes "$cand")"
  check_no_file "C11-r10: no .bak fabricated beside it" "$cand.bak"
  check "C11-r11: no tmp file left under the insiders path" "0" \
    "$(count_tmp "$home/.vscode-insiders")"
  check "C11-r12: the insiders directory still holds exactly one entry" "1" \
    "$(count_files "$home/.vscode-insiders")"
}

# ---- T5: exported table and dedup stages ----------------------------------

run_t5a() {
  node_m 'const m=require("'"$REQUIRE_PATH"'");const p=require("path");
const r=m.CANDIDATE_ROOTS.map(x=>String(x).replace(/\\/g,"/"));
console.log("N="+r.length);console.log("L="+r.join(","));
console.log("ABS="+(m.CANDIDATE_ROOTS.some(x=>p.isAbsolute(String(x)))?"yes":"no"));'
  check "T5a: node exit 0" "0" "$NODE_RC"
  check_contains "T5a: CANDIDATE_ROOTS has 4 entries" "N=4" "$NODE_OUT"
  check_contains "T5a: covers stable" ".vscode/extensions" "$NODE_OUT"
  check_contains "T5a: covers insiders" ".vscode-insiders/extensions" "$NODE_OUT"
  check_contains "T5a: covers server" ".vscode-server/extensions" "$NODE_OUT"
  check_contains "T5a: covers server-insiders" ".vscode-server-insiders/extensions" "$NODE_OUT"
  check_contains "T5a: every entry is home-relative" "ABS=no" "$NODE_OUT"
}

run_t5b() {
  local home
  home="$(mktemp -d "$TMPROOT/home.XXXXXX")"
  mkdir -p "$home/.vscode/extensions"
  FIXHOME="$(native_path "$home")" \
  node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.resolveRoots({home:process.env.FIXHOME}).map(x=>String(x).replace(/\\/g,"/"));
console.log("N="+r.length);console.log("L="+r.join(","));'
  check "T5b: node exit 0" "0" "$NODE_RC"
  check_contains "T5b: only the existing root is returned" "N=1" "$NODE_OUT"
  check_contains "T5b: that root is .vscode/extensions" ".vscode/extensions" "$NODE_OUT"
  check_absent "T5b: absent server root silently skipped" ".vscode-server" "$NODE_OUT"
  check_absent "T5b: absent insiders root silently skipped" "insiders" "$NODE_OUT"
}

run_t5c() {
  local home
  home="$(mktemp -d "$TMPROOT/home.XXXXXX")"
  mkdir -p "$home/.vscode/extensions/$DIR_B" "$home/.vscode/extensions/$DIR_A"
  mkdir -p "$home/.vscode/extensions/some-other.extension-1.0.0"
  mkdir -p "$home/.vscode-server/extensions/anthropic.claude-code-3.0.0"
  FIXHOME="$(native_path "$home")" \
  node_m 'const m=require("'"$REQUIRE_PATH"'");const p=require("path");
const r=m.resolveRoots({home:process.env.FIXHOME});
console.log("N="+r.length);
for(const x of r){console.log("D="+m.listExtensionDirs(x).map(y=>p.basename(String(y))).join(","));}'
  check "T5c: node exit 0" "0" "$NODE_RC"
  check_contains "T5c: both existing roots returned" "N=2" "$NODE_OUT"
  check_contains "T5c: matching dirs name-ascending" "D=$DIR_A,$DIR_B" "$NODE_OUT"
  check_contains "T5c: second root enumerated" "D=anthropic.claude-code-3.0.0" "$NODE_OUT"
  check_absent "T5c: non-matching directory excluded" "some-other.extension" "$NODE_OUT"
}

resolve_override_count() { # <json-array-of-paths>
  OVR="$1" node_m 'const m=require("'"$REQUIRE_PATH"'");
console.log("N="+m.resolveRoots({home:process.env.HOME_UNUSED||"/nonexistent-home",overrides:JSON.parse(process.env.OVR)}).length);'
}

run_t5d() {
  local home base upper link
  home="$(mktemp -d "$TMPROOT/home.XXXXXX")"
  mkdir -p "$home/.vscode/extensions"
  base="$(native_path "$home/.vscode/extensions")"

  resolve_override_count "[\"$base\",\"$base\"]"
  check "T5d-1: node exit 0" "0" "$NODE_RC"
  check_contains "T5d-1: identical override paths collapse to 1" "N=1" "$NODE_OUT"

  if [ "${OS:-}" = "Windows_NT" ]; then
    upper="$(native_path "$home")/.vscode/EXTENSIONS"
    resolve_override_count "[\"$base\",\"$upper\"]"
    check_contains "T5d-2: win32 case-variant spellings collapse to 1" "N=1" "$NODE_OUT"
  else
    echo "SKIP: T5d-2 case-insensitive dedup (not Windows_NT)"; SKIP=$((SKIP + 1))
  fi

  link="$home/link-to-extensions"
  if ln -s "$home/.vscode/extensions" "$link" 2>/dev/null && [ -L "$link" ]; then
    resolve_override_count "[\"$base\",\"$(native_path "$link")\"]"
    check_contains "T5d-3: symlink to same dir collapses via realpath" "N=1" "$NODE_OUT"
  else
    echo "SKIP: T5d-3 symlink dedup (ln -s unavailable in this environment)"
    SKIP=$((SKIP + 1))
  fi
}

run_c4a
run_c4b
run_c4c
run_c4d
run_c2_all_candidate_roots
run_c11_file_candidate
run_t5a
run_t5b
run_t5c
run_t5d
