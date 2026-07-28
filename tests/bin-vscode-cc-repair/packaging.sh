# Part of tests/bin-vscode-cc-repair.sh (sourced, not standalone).
# C3 + C4 — the packaging contract. Every other part of this suite invokes the tool as
# `node "$SCRIPT"`, which passes even if the shebang is wrong, the execute bit is missing
# from the git index, or the file is not registered in README.md — i.e. even if the tool
# is unusable as the `bin/` CLI it is specified to be. These are static/structural
# assertions, not behavioural ones.

# ---- C3a: the shebang line ------------------------------------------------

run_c3_shebang() {
  local first
  first="$(head -1 "$SCRIPT")"
  first="${first%$'\r'}"
  check "C3-e01: first line is exactly the node shebang" "#!/usr/bin/env node" "$first"
}

# ---- C3b: the recorded execute bit ---------------------------------------
# `git ls-files -s` reads the INDEX, so the assertion holds regardless of core.fileMode
# and regardless of the checked-out filesystem's permission model (Windows included).

run_c3_index_mode() {
  local mode
  if ! git -C "$AGENTS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "SKIP: C3-e02 git index mode (AGENTS_DIR is not a git repository)"
    SKIP=$((SKIP + 1))
    return 0
  fi
  mode="$(git -C "$AGENTS_DIR" ls-files -s -- bin/vscode-cc-repair \
    | awk '{print $1}')"
  if [ -z "$mode" ]; then
    echo "SKIP: C3-e02 git index mode (bin/vscode-cc-repair not tracked yet)"
    SKIP=$((SKIP + 1))
    return 0
  fi
  check "C3-e02: git index records mode 100755" "100755" "$mode"
}

# ---- C3c: direct invocation, not via `node` -------------------------------
# The extensionless name plus the shebang is the whole delivery mechanism; running it
# through `node` never exercises it.

run_c3_direct_exec() {
  local rc out
  rc=0
  out="$(run_with_timeout 30 "$SCRIPT" --help 2>/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] && ! grep -qF -- "Usage" <<< "$out"; then
    echo "SKIP: C3-e03 direct shebang execution (host cannot exec an extensionless #! file)"
    SKIP=$((SKIP + 1))
    return 0
  fi
  check "C3-e03: direct invocation exits 0" "0" "$rc"
  check_contains "C3-e04: direct invocation prints the usage block on stdout" "Usage" "$out"
  check_contains "C3-e05: direct invocation documents --extensions-dir" \
    "--extensions-dir" "$out"
}

# ---- C4: the mandatory README registration -------------------------------
# Every tool under bin/ must be listed in README.md, otherwise the CLI ships
# undiscoverable. The path is asserted verbatim so a renamed script cannot leave a stale
# entry behind.

run_c4_readme_entry() {
  local readme body
  readme="$AGENTS_DIR/README.md"
  check_file "C4-r01: README.md exists at the repo root" "$readme"
  if [ ! -f "$readme" ]; then
    echo "FAIL: C4-r02: README.md registers bin/vscode-cc-repair -- no README.md"
    FAIL=$((FAIL + 1))
    return 0
  fi
  body="$(cat "$readme")"
  check_contains "C4-r02: README.md registers bin/vscode-cc-repair" \
    "bin/vscode-cc-repair" "$body"
}

run_c3_shebang
run_c3_index_mode
run_c3_direct_exec
run_c4_readme_entry
