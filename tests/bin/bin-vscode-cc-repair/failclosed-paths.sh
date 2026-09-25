# Part of tests/bin-vscode-cc-repair.sh (sourced, not standalone).
# C2 — the two fail-closed paths reachable from a fixture. Both must refuse loudly
# (exit-1 side, stderr prefixed) rather than skip silently, and neither may write.

# C2a: a matching extension directory with no extension.js at all.
run_c2a() {
  local root dir
  root="$(new_root)"
  dir="$root/$DIR_A"
  mkdir -p "$dir"
  run_cli --extensions-dir "$(native_path "$root")"
  check "C2a: missing extension.js exits 1" "1" "$CLI_RC"
  check_token "C2a: reported refused" "refused" "$CLI_OUT"
  check_contains "C2a: detail names no-extension-js" "no-extension-js" "$CLI_OUT"
  check_contains "C2a: full count prefix present on refused" "literal=0" "$CLI_OUT"
  check_contains "C2a: count prefix carries key=0" "key=0" "$CLI_OUT"
  check_contains "C2a: directory still enumerated (not silently skipped)" "dirs=1" "$CLI_OUT"
  check_contains "C2a: summary counts 1 refused" "refused=1" "$CLI_OUT"
  check_contains "C2a: failure message carries the stderr prefix" "$STDERR_PREFIX" "$CLI_OUT"
  check "C2a: nothing written into the matching directory" "0" "$(count_files "$dir")"
  check_no_file "C2a: no .bak fabricated" "$dir/extension.js.bak"
  check "C2a: no leftover tmp" "0" "$(count_tmp "$root")"
}

# C2b: unpatched but syntactically invalid baseline — the pre-write `node --check`
# must refuse, so an already-broken bundle is never made worse.
run_c2b() {
  local root f before
  root="$(new_root)"
  make_ext_dir "$root" "$DIR_A" "$BODY_BAD_SYNTAX"
  f="$root/$DIR_A/extension.js"; before="$(bytes "$f")"

  # Precondition: the classifier says `unpatched`, so the refusal below can only
  # come from the baseline syntax check — not from a classifier verdict.
  BODY="$BODY_BAD_SYNTAX" node_m 'const m=require("'"$REQUIRE_PATH"'");
const r=m.classify(process.env.BODY);
console.log("S="+r.state+" L="+r.counts.nLiteral);'
  check "C2b: precondition — one literal, classifies unpatched" "S=unpatched L=1" "$NODE_OUT"

  run_cli --extensions-dir "$(native_path "$root")"
  check "C2b: unparsable baseline exits 1" "1" "$CLI_RC"
  check_token "C2b: reported refused" "refused" "$CLI_OUT"
  check_contains "C2b: detail names baseline-unparsable" "baseline-unparsable" "$CLI_OUT"
  check_contains "C2b: full count prefix present on refused" "literal=1" "$CLI_OUT"
  check_contains "C2b: failure message carries the stderr prefix" "$STDERR_PREFIX" "$CLI_OUT"
  check "C2b: extension.js byte-identical" "$BODY_BAD_SYNTAX" "$(cat "$f")"
  check "C2b: byte count unchanged" "$before" "$(bytes "$f")"
  check_no_file "C2b: no .bak written" "$f.bak"
  check "C2b: no leftover tmp" "0" "$(count_tmp "$root")"
  check "C2b: directory still holds only extension.js" "1" "$(count_files "$root/$DIR_A")"
}

# C7 — the same two fail-closed paths re-run with SPLIT streams. C2a/C2b assert on
# combined stdout+stderr, which cannot tell "the report line is on stdout" from "the
# diagnostic mentions the same token on stderr" — a report line accidentally emitted to
# stderr (or a diagnostic leaking to stdout) would still pass there. These rows pin the
# channel: report line + summary on stdout, prefixed diagnostic on stderr only.
run_c7_split() {
  local name dirbody want_reason root dir f before
  while IFS='|' read -r name dirbody want_reason; do
    name="${name//[[:space:]]/}"
    case "$name" in ''|'#'*) continue ;; esac
    dirbody="${dirbody//[[:space:]]/}"
    want_reason="${want_reason//[[:space:]]/}"
    root="$(mktemp -d "$TMPROOT/c7.XXXXXX")"
    dir="$root/$DIR_A"
    if [ "$dirbody" = "NONE" ]; then
      mkdir -p "$dir"
      f=""
    else
      make_ext_dir "$root" "$DIR_A" "${!dirbody}"
      f="$dir/extension.js"; before="$(bytes "$f")"
    fi

    run_cli_split --extensions-dir "$(native_path "$root")"
    check "$name: exit 1" "1" "$CLI_RC"
    check_token "$name: directory report line lands on stdout" "refused" "$CLI_STDOUT"
    check_contains "$name: stdout report line names $want_reason" "$want_reason" "$CLI_STDOUT"
    check_contains "$name: stdout report line is basename-only" \
      "refused  $DIR_A  " "$CLI_STDOUT"
    check_contains "$name: summary line lands on stdout" \
      "summary: roots=1 dirs=1" "$CLI_STDOUT"
    check_contains "$name: stdout summary counts 1 refused" "refused=1" "$CLI_STDOUT"
    check_absent "$name: stdout carries no diagnostic prefix" "$STDERR_PREFIX" "$CLI_STDOUT"
    check_contains "$name: prefixed diagnostic lands on stderr" "$STDERR_PREFIX" "$CLI_STDERR"
    check_contains "$name: stderr diagnostic names $want_reason" "$want_reason" "$CLI_STDERR"
    check_absent "$name: stderr carries no summary line" "summary:" "$CLI_STDERR"
    check_absent "$name: stderr carries no root line" "root: " "$CLI_STDERR"
    check "$name: no leftover tmp" "0" "$(count_tmp "$root")"
    if [ -n "$f" ]; then
      check "$name: extension.js byte-identical" "${!dirbody}" "$(cat "$f")"
      check "$name: byte count unchanged" "$before" "$(bytes "$f")"
      check_no_file "$name: no .bak written" "$f.bak"
    else
      check "$name: nothing written into the matching directory" "0" "$(count_files "$dir")"
    fi
  done <<'TABLE'
C7-s01-no-extension-js    | NONE            | no-extension-js
C7-s02-baseline-unparsable| BODY_BAD_SYNTAX | baseline-unparsable
TABLE
}

# ---------------------------------------------------------------------------
# C5 — concurrency guard: paired gap documentation (Pattern 3).
# Deterministic injection would require a fault-injection seam in production code;
# the approved plan puts the residual TOCTOU window explicitly out of scope, so no
# seam is added and the contract is not weakened.
#
# SKIPPED: extension.js is replaced by a concurrent writer with an ALREADY-PATCHED
#          body between the step-10 re-read and the step-11 rename -> tmp unlinked,
#          rename skipped, state `already`, detail `raced`, exit-0 side.
# Because: reaching the branch means landing another process's write inside the
#          sub-millisecond window between Buffer.compare and renameSync. TL2 has no
#          way to stall the script mid-function without an injectable pre-rename hook.
# Needed:  an injectable pre-rename callback (or a filesystem interposer such as a
#          FUSE shim / Detours hook) plus a concurrent-writer harness.
# TL3 gap: only a real VS Code extension auto-update, or a second concurrent run of
#          this script, exercises it on a live install.
#
# SKIPPED: extension.js is replaced by a concurrent writer with a body that does NOT
#          classify `already` between the step-10 re-read and the step-11 rename ->
#          tmp unlinked, rename skipped, state `failed`, detail `changed-during-patch`,
#          exit-1 side.
# Because: same window, same missing seam. The two branches differ only in how the
#          re-read text classifies, so neither is reachable without the seam.
# Needed:  same as above; the harness must additionally control WHAT the concurrent
#          writer writes so both re-classification outcomes can be selected.
# TL3 gap: a partially written / truncated bundle produced by a crashing concurrent
#          installer is the realistic trigger, and only a real host produces it.
#
# Both branches are also listed in the `# TL3 gap` block of the dispatcher.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# C7 — runtime filesystem-failure injection: paired gap documentation (Pattern 3).
# Two members of this family ARE covered and must stay covered:
#   - pre-existing extension.js.bak is preserved, never overwritten
#     -> patch-lifecycle.sh T2d (detail `backup=preserved`)
#   - a per-directory failure does not abort the sibling loop
#     -> guard-cli.sh T3g (patched + refused siblings, aggregate exit 1)
#
# SKIPPED: the .bak temp write fails (EACCES / ENOSPC) -> no patch attempted.
# Because: making writeFileSync fail for one specific path while the rest of the
#          directory stays writable needs per-file ACL manipulation that is not
#          portable between the Windows host and POSIX CI, and Windows ACL denial
#          also blocks the fixture teardown.
# Needed:  a writable-path fault seam, or a platform-specific ACL/quota harness.
# TL3 gap: a read-only extensions tree (managed install, roaming profile) on a real
#          host is the realistic trigger.
#
# SKIPPED: the extension.<pid>-<rand>.tmp.js write fails -> unlink + `failed`.
# Because: same ACL/ENOSPC portability problem; the tmp name is randomised at write
#          time, so it cannot even be pre-created as a directory to force EISDIR
#          deterministically.
# Needed:  the same fault seam, plus control over the generated tmp name.
# TL3 gap: a full disk or an antivirus write lock on a real host.
#
# SKIPPED: renameSync(tmp, target) fails -> tmp unlinked, target untouched, `failed`.
# Because: on Windows the realistic trigger is another process holding extension.js
#          open with a sharing violation; TL2 cannot hold that handle portably.
# Needed:  a helper process holding an exclusive handle, gated per platform.
# TL3 gap: VS Code running while the patch lands — exactly the real-world case.
#
# SKIPPED: the post-rename re-read fails to classify `already` -> `post-verify-failed`.
# Because: it requires corrupting the renamed file between renameSync and the final
#          read, i.e. the same missing seam as C5.
# Needed:  a post-rename injection point.
# TL3 gap: filesystem-level write reordering / caching anomalies on a real host.
# ---------------------------------------------------------------------------

run_c2a
run_c2b
run_c7_split
