#!/usr/bin/env bash
# tests/install-path-exposed-commands.sh
# Tests: install/path-exposed-commands.txt, install/win/dotfileslink.ps1, install/linux/dotfileslink.sh, skills/review-code-security/scripts/run-quality-gates.sh
# Tags: install, dotfileslink, path, ssot, security-gate, scope:common, pwsh-not-required, TL2

# THE INCIDENT. skills/review-code-security/scripts/run-quality-gates.sh invokes eight
# quality gates by BARE NAME, each terminated with `|| true`. Three of them —
# check-inline-procedures, review-e2e-coverage, review-bare-python — have no ~/.local/bin
# shim, so the shell prints `command not found`, the `|| true` swallows the 127, and the
# security review reports as though eight gates ran. All three exist under bin/ and pass
# when invoked by full path. That is a FALSE GREEN on the gate that is supposed to catch
# false greens.

# THE ROOT CAUSE is not the three missing shims. It is that "which bin/ command is exposed
# on PATH" is written down twice — nineteen hand-written `Write-Launcher "$LocalBin\...`
# blocks in install/win/dotfileslink.ps1 and the same commands again as `ln -sf` blocks in
# install/linux/dotfileslink.sh — with no list and no loop anywhere. Adding a gate means
# remembering two files in two languages, and forgetting is silent (CPR-SSOT single source of
# truth; CPR-E2C fix the class, not the member).

# THE CONTRACT UNDER TEST. One declarative file, install/path-exposed-commands.txt, names
# the PATH-exposed bin/ commands. Both installers LOOP over it — the Windows script reusing
# its existing Write-Launcher helper and $links/foreach idiom, the Linux script its `ln -sf`
# idiom — so a command added to the list reaches both platforms or neither, and a
# half-added command becomes structurally impossible rather than merely unlikely.

# OUT OF SCOPE: the uv-based launchers (doc-append, doc-append-plain, repo-visibility).
# They wrap a `.py` under a different name and generate a different launcher body; nothing
# here demands they move into the list.

# LAYER. Static/structural only: it reads the installers as TEXT and never executes either
# one. No pwsh, no WSL, no writes to ~/.local/bin — running a real installer would edit the
# developer's own PATH, which is not something a test may do.

# SKIPPED: actually running install/win/dotfileslink.ps1 (or the Linux script) and asserting
#          that all eleven commands then resolve on PATH and exit 0 when invoked bare.
# Because: both installers write into the REAL ~/.local/bin and the real user profile;
#          there is no prefix override to redirect them at a fixture tree, so running one
#          from a test would mutate the developer's machine.

# TL3 gap (what this test does NOT catch):
# - Whether the launcher Write-Launcher writes actually resolves and runs: its file
#   contents, and the `wsl bash -c` hop it inserts on Windows, are never executed here.
# - Whether the execute bit survives `ln -sf` into a real ~/.local/bin on Linux/macOS.
# - Whether an installed name wins PATH ordering against a same-named binary already
#   present elsewhere on the machine.
# - Whether an entry added to the list reaches PATH on BOTH platforms after a real
#   install run -- only the loops' TEXT is read here, never their effect.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSOT_REL="install/path-exposed-commands.txt"
SSOT="$AGENTS_DIR/$SSOT_REL"
WIN="$AGENTS_DIR/install/win/dotfileslink.ps1"
LINUX="$AGENTS_DIR/install/linux/dotfileslink.sh"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { # <desc> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi
}

# ---- the derived invocation set (T1's input) --------------------------------

# Derived by PARSING the skill scripts, never by a hardcoded name list: a hardcoded copy
# would be a THIRD transcription of the very fact this file exists to de-duplicate, and it
# would go stale in exactly the way the two installers did.
#
# "Bare name" means command position: line start, or straight after `;`, `&`, `|`, `(`,
# `&&`, `||`. A name preceded by `/` is a full-path invocation (`"$AGENTS_CONFIG_DIR/bin/x"`)
# and is deliberately NOT counted — those already work and need no shim. Full-line comments
# are stripped first. The rule is conservative: `then foo` and `do foo` are not matched, so
# the derived set can be too small but never too large, and a false accusation is impossible.
bin_basenames() { # <root>
  local root="$1"
  find "$root/bin" -maxdepth 1 -type f 2>/dev/null | sed 's#.*/##' | sort
}

skill_scripts() { # <root>
  local root="$1"
  find "$root/skills" -path '*/scripts/*.sh' -type f 2>/dev/null | sort
}

# Scan root is parameterized (arg 1, defaulting to $AGENTS_DIR) so the T7 canary below can
# point the same, unmodified regex/extraction logic at a throwaway fixture tree instead of
# the real repo -- a positive control that ran different code than production would prove
# nothing. Nothing past this line changed.
derive_bare_invocations() { # <root=AGENTS_DIR>
  local root="${1:-$AGENTS_DIR}"
  local scripts b s
  scripts="$(skill_scripts "$root")"
  [ -n "$scripts" ] || return 0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    while IFS= read -r s; do
      [ -n "$s" ] || continue
      if sed 's/^[[:space:]]*#.*//' "$s" \
        | grep -qE "(^|[;&|(])[[:space:]]*${b}([[:space:]]|\$)"; then
        printf '%s\n' "$b"
        break
      fi
    done <<< "$scripts"
  done <<< "$(bin_basenames "$root")"
}

# ---- the SSOT list ----------------------------------------------------------

# One command per line; `#` comment lines and blank lines tolerated. Trailing whitespace is
# stripped so a stray space cannot silently create a second, different entry.
ssot_entries() {
  [ -f "$SSOT" ] || return 0
  sed -e 's/\r$//' -e 's/[[:space:]]*$//' "$SSOT" \
    | grep -vE '^[[:space:]]*(#|$)' \
    | sed -e 's/^[[:space:]]*//'
}

DERIVED="$(derive_bare_invocations)"
ENTRIES="$(ssot_entries)"

# The absence of the SSOT file is the CURRENT state and it is a FAILURE, never a skip: a
# skip here would report green on precisely the build this file was written to condemn.
# Every row still runs and still says what it wanted, so the output is diagnostic rather
# than a bare shell error about a missing path.
SSOT_PRESENT=0
[ -f "$SSOT" ] && SSOT_PRESENT=1
check "T0: $SSOT_REL exists (absent means every row below reports against an empty list)" \
  "1" "$SSOT_PRESENT"

# set difference: lines in $1 that are not in $2, rendered space-separated.
minus() { comm -23 <(printf '%s\n' "$1" | sort -u | grep -v '^$') \
                   <(printf '%s\n' "$2" | sort -u | grep -v '^$') | tr '\n' ' ' | sed 's/ $//'; }

# ---- T1: every bare-name gate is on the list --------------------------------

t1_invocations_covered() {
  local n missing
  n="$(printf '%s\n' "$DERIVED" | grep -c . || true)"
  # T1a ("$SSOT_REL is non-empty") was dropped: with T7's canary now proving
  # derive_bare_invocations() still detects a known bare invocation, "$DERIVED is empty"
  # is no longer read as possible parser breakage, so the only thing T1a was left guarding
  # was "the SSOT list is non-empty" -- which is T5c's assertion verbatim (CPR-SSOT: one
  # canonical location per fact). Re-asserting it here would be a second, driftable copy.
  if [ "$n" -eq 0 ]; then
    echo "INFO: T1: the parse found zero bare-name bin/ invocations in skills/**/scripts/*.sh (T1b is vacuously satisfied)"
  fi
  missing="$(minus "$DERIVED" "$ENTRIES")"
  if [ "$SSOT_PRESENT" -eq 0 ]; then
    fail "T1b: every bare-name bin/ command a skill script invokes is on the list -- $SSOT_REL does not exist; uncovered: $missing"
    return 0
  fi
  check "T1b: every bare-name bin/ command a skill script invokes is on the list" "" "$missing"
}

# ---- T2: every entry is a real, executable bin/ command ---------------------

t2_entries_are_executable() {
  local e missing_files bad_modes mode
  if [ "$SSOT_PRESENT" -eq 0 ]; then
    fail "T2a: every list entry names a file under bin/ -- $SSOT_REL does not exist"
    fail "T2b: every list entry is recorded 100755 in the git index -- $SSOT_REL does not exist"
    return 0
  fi
  missing_files=""
  bad_modes=""
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    if [ ! -f "$AGENTS_DIR/bin/$e" ]; then
      missing_files="$missing_files $e"
      continue
    fi
    # rules/coding.md: the execute bit is recorded in the INDEX, so the assertion holds on
    # Windows and regardless of core.fileMode. A shim pointing at a non-executable file
    # fails at run time with a permission error, which `|| true` would swallow just as
    # quietly as `command not found`.
    mode="$(git -C "$AGENTS_DIR" ls-files -s -- "bin/$e" 2>/dev/null | awk '{print $1}')"
    [ "$mode" = "100755" ] || bad_modes="$bad_modes $e:${mode:-untracked}"
  done <<< "$ENTRIES"
  check "T2a: every list entry names a file under bin/" "" "${missing_files# }"
  check "T2b: every list entry is recorded 100755 in the git index" "" "${bad_modes# }"
}

# ---- T3: the installers consume the list instead of transcribing it ---------

# A per-command hand-written block is what made the drift possible; the assertion is that
# the COUNT of them is zero, not that they are consistent. Together with "each installer
# names the list file", that means the only way a command reaches PATH is through the loop —
# which is what makes a half-added command structurally impossible rather than unlucky.
count_literal_shims() { # <installer-file> <needle-prefix>
  local f="$1" prefix="$2" e total hits
  total=0
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    hits="$(grep -cF -- "${prefix}${e}" "$f" 2>/dev/null || true)"
    total=$((total + hits))
  done <<< "$ENTRIES"
  printf '%s' "$total"
}

t3_installers_loop() {
  if [ "$SSOT_PRESENT" -eq 0 ]; then
    fail "T3a: install/win/dotfileslink.ps1 holds no per-command shim block -- $SSOT_REL does not exist, so there is no list to loop over"
    fail "T3b: install/linux/dotfileslink.sh holds no per-command shim block -- $SSOT_REL does not exist, so there is no list to loop over"
  else
    # Windows: `Write-Launcher "$LocalBin\<name>...` — matches both the .cmd and the bash
    # shim line of each hand-written pair.
    check "T3a: install/win/dotfileslink.ps1 holds no per-command shim block for a list entry" \
      "0" "$(count_literal_shims "$WIN" '$LocalBin\')"
    # Linux: `ln -sf "$AGENTS_ROOT/bin/<name>" ...`
    check "T3b: install/linux/dotfileslink.sh holds no per-command shim block for a list entry" \
      "0" "$(count_literal_shims "$LINUX" '/bin/')"
  fi
  if grep -qF -- "path-exposed-commands.txt" "$WIN" 2>/dev/null; then
    pass "T3c: install/win/dotfileslink.ps1 reads the list file"
  else
    fail "T3c: install/win/dotfileslink.ps1 reads the list file -- no reference to path-exposed-commands.txt"
  fi
  if grep -qF -- "path-exposed-commands.txt" "$LINUX" 2>/dev/null; then
    pass "T3d: install/linux/dotfileslink.sh reads the list file"
  else
    fail "T3d: install/linux/dotfileslink.sh reads the list file -- no reference to path-exposed-commands.txt"
  fi
}

# ---- T4: both platforms expose the same set (CPR-ORTH) -------------------------

# What an installer exposes = the list, if it reads the list, PLUS whatever it still
# hand-writes. Computed the same way for both scripts so no platform can silently ship a
# subset — the exact failure mode that put three gates on neither platform.
exposed_set() { # <installer-file> <needle-prefix>
  local f="$1" prefix="$2" e
  if grep -qF -- "path-exposed-commands.txt" "$f" 2>/dev/null; then
    printf '%s\n' "$ENTRIES"
  fi
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    grep -qF -- "${prefix}${e}" "$f" 2>/dev/null && printf '%s\n' "$e"
  done <<< "$ENTRIES"
}

t4_platform_symmetry() {
  local w l
  if [ "$SSOT_PRESENT" -eq 0 ]; then
    fail "T4: Windows and Linux expose the same command set -- $SSOT_REL does not exist, so neither installer has a set to compare"
    return 0
  fi
  w="$(exposed_set "$WIN" '$LocalBin\' | sort -u | grep -v '^$' | tr '\n' ' ')"
  l="$(exposed_set "$LINUX" '/bin/' | sort -u | grep -v '^$' | tr '\n' ' ')"
  check "T4: Windows and Linux expose the same command set" "$w" "$l"
}

# ---- T5: the list file's own format ----------------------------------------

t5_format() {
  local raw bad dups
  if [ "$SSOT_PRESENT" -eq 0 ]; then
    fail "T5a: every list entry matches the conservative command-name charset -- $SSOT_REL does not exist"
    fail "T5b: the list holds no duplicate entry -- $SSOT_REL does not exist"
    fail "T5c: the list is non-empty -- $SSOT_REL does not exist"
    return 0
  fi
  raw="$ENTRIES"
  # A command name, not a path and not a shell fragment: an entry that could be read as an
  # option, a path segment, or a glob would be interpolated straight into a `ln -sf` and a
  # PowerShell path by the loops that consume it.
  bad="$(printf '%s\n' "$raw" | grep -vE '^[A-Za-z0-9][A-Za-z0-9._-]*$' | tr '\n' ' ' || true)"
  check "T5a: every list entry matches the conservative command-name charset" "" "${bad% }"
  dups="$(printf '%s\n' "$raw" | grep -v '^$' | sort | uniq -d | tr '\n' ' ' || true)"
  check "T5b: the list holds no duplicate entry" "" "${dups% }"
  if [ -n "$(printf '%s\n' "$raw" | grep -c . || true)" ] && [ "$(printf '%s\n' "$raw" | grep -c . || true)" -gt 0 ]; then
    pass "T5c: the list is non-empty"
  else
    fail "T5c: the list is non-empty -- no entries survived comment/blank stripping"
  fi
}

# ---- T6: the regression pin -------------------------------------------------

# T1 would catch these too. They are named here so a future reader meets the incident
# itself rather than a set-difference message: these three gates ran as `command not found`
# inside a `|| true`, and the security review reported eight-of-eight regardless.
t6_regression_pin() {
  local c present
  for c in check-inline-procedures review-e2e-coverage review-bare-python; do
    present="$(printf '%s\n' "$ENTRIES" | grep -cx -- "$c" || true)"
    check "T6[$c]: the silently-unshimmed quality gate is on the list" "1" "$present"
  done
}

# ---- T7: positive control (canary) for derive_bare_invocations() -----------

# T1 only proves things about the CURRENT, real derived set -- which is now empty because
# run-quality-gates.sh's eight gates all moved to full-path form. An empty set makes T1
# vacuously green even if the parser's regex regressed and stopped matching real bare-name
# invocations. T7 feeds derive_bare_invocations() a throwaway fixture tree (never the real
# repo) containing one known bare-name bin/ line and one known full-path bin/ line, modeled
# on the exact form run-quality-gates.sh used before its full-path conversion
# (`<name> --base "$MERGE_BASE" || true`), and asserts the parser still tells them apart.
# This is orthogonal to T1: T1 asks "is today's real derived set covered by the SSOT list",
# T7 asks "does the parser itself still work" -- independent of what today's real set is.
t7_parser_canary() {
  local fixture bare_name full_name got
  fixture="$(mktemp -d "${TMPDIR:-/tmp}/path-exposed-canary.XXXXXX")" || {
    fail "T7: fixture setup -- mktemp -d failed"
    return 0
  }
  trap 'rm -rf "$fixture"' RETURN
  bare_name="canary-bare-gate"
  full_name="canary-full-gate"
  mkdir -p "$fixture/bin" "$fixture/skills/canary/scripts"
  : > "$fixture/bin/$bare_name"
  : > "$fixture/bin/$full_name"
  cat > "$fixture/skills/canary/scripts/run-canary-gates.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
${bare_name} --base "\$MERGE_BASE" || true
"\${AGENTS_CONFIG_DIR}/bin/${full_name}" --base "\$MERGE_BASE" || true
EOF
  got="$(derive_bare_invocations "$fixture")"
  check "T7a canary-positive: a bare-name bin/ invocation is detected" \
    "1" "$(printf '%s\n' "$got" | grep -cx -- "$bare_name" || true)"
  check "T7b canary-negative: a full-path bin/ invocation is NOT detected" \
    "0" "$(printf '%s\n' "$got" | grep -cx -- "$full_name" || true)"
}

# ---- T8: the confirm-flags helper is on the list (#1967) --------------------

# Why this is a section of its own rather than a fourth name inside T6: T6 is the pin for
# ONE incident -- three quality gates that ran as `command not found` while the review
# reported eight-of-eight -- and folding an unrelated origin into it would blur what T6
# tells a future reader (CPR-NRS).
#
# T8 comes from #1967 and closes a DIFFERENT gap: get-config-var is never invoked by bare
# name from skills/**/scripts/*.sh, so it never enters T1's derived set, and it is none of
# T6's three names. As of today, if it fell off the list, no row in this file would say so.

# EXECUTED-ROW BUDGET (#1967, review round 6). A table-driven test whose table is empty --
# or whose loop is never reached -- reports zero assertions and still exits 0, and every
# static delegation grep in tests/feature-confirm-flags-static.sh section 9 keeps passing
# over that shape because every string it looks for is still on the page.
T8_ROWS=0
T8_ROWS_EXPECTED=5   # 2 rows in T8_CASES + 3 rows in T8B_CASES

# Global, incremented inside the loops, asserted from a SEPARATE function on the run list:
# a count asserted at the end of T8's own body would be skipped by the same early `return`
# that makes the loop unreachable, which is one of the two shapes it must catch.

# The one predicate both T8 and T8b go through (CPR-SSOT): how many lines of <list-text> are
# exactly <cmd>. Two hand-written greps is how the pin and its control drift apart.
pinned_in_list() { # <list-text> <cmd>
  printf '%s\n' "$1" | grep -cx -- "$2" || true
}

# The named list shapes the case tables below draw on. Every variant except missing-list is
# built FROM the real list, so no case can quietly stop describing what
# install/path-exposed-commands.txt actually holds. missing-list is the "someone deleted the
# SSOT" shape, produced by pointing ssot_entries at a path that does not exist rather than by
# hand-writing an empty string -- that way it exercises the real reader.
t8_list_variant() { # <variant>
  case "$1" in
    present)      printf '%s\n' "$ENTRIES" ;;
    duplicate)    printf '%s\n%s\n' "$ENTRIES" "get-config-var" ;;
    removed)      printf '%s\n' "$ENTRIES" | grep -vx -- "get-config-var" || true ;;
    empty-list)   printf '' ;;
    missing-list) ( SSOT="$SSOT.no-such-file"; ssot_entries ) ;;
    *) echo "HARNESS ERROR: unknown T8 list variant '$1'" >&2; exit 2 ;;
  esac
}

# Table-driven, one row per named case (`case-id|variant|expected-count|label`), because the
# claim under test is about the predicate across a RANGE of list shapes; bespoke one-shot
# functions hide which shapes were never tried.
t8_get_config_var_pinned() {
  local id variant want label
  if [ "$SSOT_PRESENT" -eq 0 ]; then
    fail "T8[get-config-var]: the confirm-flags helper is on the list -- $SSOT_REL does not exist"
    return 0
  fi
  while IFS='|' read -r id variant want label; do
    [ -n "$id" ] || continue
    T8_ROWS=$((T8_ROWS + 1))
    check "T8[get-config-var/$id]: $label" \
      "$want" "$(pinned_in_list "$(t8_list_variant "$variant")" "get-config-var")"
  done <<'T8_CASES'
present|present|1|the confirm-flags helper is on the list
duplicate|duplicate|2|a second identical entry is counted, not collapsed (the predicate counts, it does not merely answer yes)
T8_CASES
}

# The negative control for T8's predicate -- the role T7 plays for derive_bare_invocations().
# Each row feeds pinned_in_list a list the entry is NOT on and requires 0: if the predicate
# ever degenerates into something that answers 1 unconditionally, T8 keeps reporting green
# while pinning nothing, and only these rows notice. Three shapes, because "removed" alone
# would not catch a predicate that answers 1 for any input it cannot parse.
t8b_pin_negative_control() {
  local id variant want label
  if [ "$SSOT_PRESENT" -eq 0 ]; then
    fail "T8b[get-config-var]: the pin detects removal from the list -- $SSOT_REL does not exist"
    return 0
  fi
  while IFS='|' read -r id variant want label; do
    [ -n "$id" ] || continue
    T8_ROWS=$((T8_ROWS + 1))
    check "T8b[get-config-var/$id]: $label" \
      "$want" "$(pinned_in_list "$(t8_list_variant "$variant")" "get-config-var")"
  done <<'T8B_CASES'
removed|removed|0|the pin detects removal from the list
empty-list|empty-list|0|an empty list is reported as not pinned
missing-list|missing-list|0|a list file that does not exist is reported as not pinned
T8B_CASES
}

# ---- T8c: the two tables above actually executed their rows (#1967) ---------
# The coverage-integrity assertion for T8/T8b. An empty case table, a heredoc whose
# delimiter drifted, or an early `return` in front of either loop all leave both functions
# reporting nothing at all -- which is indistinguishable from "everything passed" in a file
# that only counts failures. Exact equality, not `> 0`: a row silently dropped from either
# table is the same loss of coverage as the whole table going empty, and must be re-budgeted
# deliberately by editing T8_ROWS_EXPECTED.
t8c_row_budget() {
  check "T8c[get-config-var]: T8 and T8b together executed every case row (0 would mean an empty or unreachable table reporting green)" \
    "$T8_ROWS_EXPECTED" "$T8_ROWS"
}

t1_invocations_covered
t2_entries_are_executable
t3_installers_loop
t4_platform_symmetry
t5_format
t6_regression_pin
t7_parser_canary
t8_get_config_var_pinned
t8b_pin_negative_control
t8c_row_budget

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
