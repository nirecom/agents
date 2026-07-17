#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-patterns/patterns.js
# Tags: scope:issue-specific, canary-7, ir-migration, patterns-static, pwsh-not-required
#
# Static structural checks on patterns.js post-canary-7 retire (#1402).
#
# Verifies:
# - WRITE_PATTERNS does NOT contain the 23 retired kinds/names
# - STRIP_KINDS is empty (all kinds retired; here-* are kind:posix/pwsh-here, never in STRIP_KINDS)
# - QUOTED_COMMAND_WORD_WRITE_NAMES includes mi, ci (and existing members)
# - QUOTING_ONLY_NAMES still includes all 4 here-* names (retained by design)
#
# L3 gap: module load + export shape only; not a behavioral test.
# Closest-to-action: behavioral coverage is in the part files (here-ir/encoded-ir/file-op-ir).

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== PS-RETIRED-KINDS: retired kinds must be absent from WRITE_PATTERNS ==="
for rkind in "pwsh-alias" "pwsh-encoded" "file-op"; do
  count="$(run_with_timeout 30 node -e "
    const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    const c=(WRITE_PATTERNS||[]).filter(p=>p.kind===process.argv[1]).length;
    process.stdout.write(String(c));
  " -- "$rkind" 2>/dev/null)"
  assert_eq "PS-kind-$rkind-absent" "0" "$count"
done

echo "=== PS-RETIRED-NAMES: retired names must be absent from WRITE_PATTERNS ==="
for rname in "sc-alias" "ac-alias" "ni-alias" "ri-alias" "mi-alias" "ci-alias" \
             "encoded-command" "ps-stop-parsing" \
             "sed-inplace" "perl-inplace" "patch" "touch" "chmod" "dd" "rsync" \
             "tar-extract" "unzip" "gunzip" "bunzip2"; do
  count="$(run_with_timeout 30 node -e "
    const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    const c=(WRITE_PATTERNS||[]).filter(p=>p.name===process.argv[1]).length;
    process.stdout.write(String(c));
  " -- "$rname" 2>/dev/null)"
  assert_eq "PS-name-$rname-absent" "0" "$count"
done

echo "=== PS-STRIP_KINDS: STRIP_KINDS must be empty after full retire ==="
strip_size="$(run_with_timeout 30 node -e "
  const {STRIP_KINDS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  process.stdout.write(String(STRIP_KINDS.size));
" 2>/dev/null)"
assert_eq "PS-STRIP_KINDS-empty" "0" "$strip_size"

echo "=== PS-QCWW: QUOTED_COMMAND_WORD_WRITE_NAMES includes required entries ==="
# Existing members (must still be present after canary-7 changes).
for qname in "tee" "rm" "mv" "cp" "patch" "touch" "chmod" "dd" "rsync" "unzip" "gunzip" "bunzip2" "sc" "ac" "ni" "ri"; do
  qpresent="$(run_with_timeout 30 node -e "
    const {QUOTED_COMMAND_WORD_WRITE_NAMES}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    process.stdout.write(String(QUOTED_COMMAND_WORD_WRITE_NAMES.has(process.argv[1])));
  " -- "$qname" 2>/dev/null)"
  assert_eq "PS-QCWW-$qname-present" "true" "$qpresent"
done

# New entries added in canary-7 (mi/ci symmetry, CPR-5).
for qname in "mi" "ci"; do
  qpresent="$(run_with_timeout 30 node -e "
    const {QUOTED_COMMAND_WORD_WRITE_NAMES}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    process.stdout.write(String(QUOTED_COMMAND_WORD_WRITE_NAMES.has(process.argv[1])));
  " -- "$qname" 2>/dev/null)"
  assert_eq "PS-QCWW-$qname-new" "true" "$qpresent"
done

# sed/perl/tar must NOT be in QUOTED_COMMAND_WORD_WRITE_NAMES (flag-gated; name alone insufficient).
for qname in "sed" "perl" "tar"; do
  qpresent="$(run_with_timeout 30 node -e "
    const {QUOTED_COMMAND_WORD_WRITE_NAMES}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    process.stdout.write(String(QUOTED_COMMAND_WORD_WRITE_NAMES.has(process.argv[1])));
  " -- "$qname" 2>/dev/null)"
  assert_eq "PS-QCWW-$qname-excluded" "false" "$qpresent"
done

echo "=== PS-QUOTING_ONLY: QUOTING_ONLY_NAMES includes all 4 here-* names ==="
for qname in "here-doc" "here-string" "pwsh-here-single" "pwsh-here-double"; do
  qpresent="$(run_with_timeout 30 node -e "
    const {QUOTING_ONLY_NAMES}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    process.stdout.write(String(QUOTING_ONLY_NAMES.has(process.argv[1])));
  " -- "$qname" 2>/dev/null)"
  assert_eq "PS-QUOTING_ONLY-$qname" "true" "$qpresent"
done

echo "=== PS-RETAINED: WRITE_PATTERNS still has here-* 4 entries ==="
for rname in "here-doc" "here-string" "pwsh-here-single" "pwsh-here-double"; do
  count="$(run_with_timeout 30 node -e "
    const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    const c=(WRITE_PATTERNS||[]).filter(p=>p.name===process.argv[1]).length;
    process.stdout.write(String(c));
  " -- "$rname" 2>/dev/null)"
  assert_eq "PS-retained-$rname" "1" "$count"
done

echo "=== PS-FACADE: bash-write-targets.js must re-export the 3 new predicates ==="
# The facade (bash-write-targets.js) is the import point for classify.js innerSegIsWrite.
# If re-exports are missing, innerSegIsWrite would get undefined and C4 wiring silently breaks.
for fname in "isHereWriteIR" "isEncodedCommandWriteIR" "isExtendedFileOpWriteIR"; do
  ftype="$(run_with_timeout 30 node -e "
    try {
      const m=require('${WT_NODE}/hooks/lib/bash-write-targets');
      process.stdout.write(typeof m[process.argv[1]]);
    } catch (e) { process.stdout.write('error'); }
  " -- "$fname" 2>/dev/null)"
  assert_eq "PS-FACADE-$fname-exported" "function" "$ftype"
done

report_totals
exit "$FAIL"
