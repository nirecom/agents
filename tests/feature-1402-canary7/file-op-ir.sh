#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-targets/file-op.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js
# Tags: scope:issue-specific, canary-7, ir-migration, file-op-ir, pwsh-not-required
#
# file-op.js IR predicate + target extractor (#1402 canary-7 Step 4).
#
# Contract under test (C3 is-correction):
# - Positional verbs (touch/chmod/patch/unzip/gunzip/bunzip2/rsync): write on verb match.
# - Flag-gated verbs (sed/perl/tar/dd): write ONLY when the specific flag is present.
#   sed without -i, tar without -x, dd without of=, gunzip with -l → NOT a write.
# - extractFileOpTargets: returns bare path strings (caller wraps as ancestor).
#   Returns null (fail-closed) when target cannot be statically determined.
# - WRITE_PATTERNS must NOT contain file-op kind entries post-retire.
# - STRIP_KINDS must NOT contain "file-op" post-retire.
#
# L3 gap: real enforce-worktree hook invocation in a live claude session not tested.
# Closest-to-action: bin/check-verification-gate.sh category: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! file_op_module_present; then
  skip "file-op.js not yet implemented — isExtendedFileOpWriteIR unavailable (RED-pending, fail-before-fix)"
  report_totals
  exit 0
fi

echo "=== FO-POS: Positional verbs — always write on verb match ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(file_op_write_ir "$cmd")"
done <<'POS_TABLE'
FO-touch^touch file.txt^true
FO-chmod^chmod 755 script.sh^true
FO-patch^patch -p1 < input.patch^true
FO-unzip^unzip archive.zip^true
FO-gunzip^gunzip file.gz^true
FO-bunzip2^bunzip2 file.bz2^true
FO-rsync^rsync -av src/ dst/^true
POS_TABLE

echo "=== FO-FLAG: Flag-gated verbs — write only with specific flag ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(file_op_write_ir "$cmd")"
done <<'FLAG_TABLE'
FO-sed-i^sed -i 's/a/b/' file.txt^true
FO-perl-i^perl -i -pe 's/a/b/' file.txt^true
FO-perl-ibak^perl -i.bak -pe 's/x/y/' file.txt^true
FO-tar-x^tar -xf archive.tar^true
FO-tar-xzf^tar -xzf archive.tar.gz^true
FO-dd-of^dd if=input.img of=output.img^true
FLAG_TABLE

echo "=== FO-GATE: Flag-gated false-positive prevention (C3 core) ==="
# These commands must NOT be classified as writes (no write flag present).
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(file_op_write_ir "$cmd")"
done <<'GATE_TABLE'
FO-sed-no-i^sed 's/a/b/' file.txt^false
FO-perl-no-i^perl -pe 's/a/b/' file.txt^false
FO-tar-list^tar -tf archive.tar^false
FO-tar-create^tar -cf new.tar dir/^false
FO-dd-devnull^dd if=input.img of=/dev/null^false
FO-dd-no-of^dd if=input.img^false
FO-gunzip-list^gunzip -l file.gz^false
FO-gunzip-test^gunzip --test file.gz^false
FO-bunzip2-test^bunzip2 -t file.bz2^false
GATE_TABLE

echo "=== FO-TGT: extractFileOpTargets — positional target extraction ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(file_op_targets "$cmd")"
done <<'TGT_TABLE'
FO-TGT-touch^touch /path/to/file.txt^["/path/to/file.txt"]
FO-TGT-chmod^chmod 755 /path/to/script.sh^["/path/to/script.sh"]
FO-TGT-sed-i^sed -i 's/a/b/' /path/to/file.txt^["/path/to/file.txt"]
FO-TGT-touch-multi^touch file1.txt file2.txt^["file1.txt","file2.txt"]
TGT_TABLE

echo "=== FO-FAIL: extractFileOpTargets — null on unresolvable target ==="
# tar without -C: CWD-implicit → null (fail-closed).
tgt_tar_no_c="$(file_op_targets 'tar -xzf archive.tar.gz')"
assert_eq "FO-FAIL-tar-no-C" "null" "$tgt_tar_no_c"

# patch stdin-driven: target depends on diff content → null (fail-closed).
tgt_patch_stdin="$(file_op_targets 'patch < diff.patch')"
assert_eq "FO-FAIL-patch-stdin" "null" "$tgt_patch_stdin"

echo "=== FO-CL: classify() of file-op write commands → read (IR predicate handles detection) ==="
# Post-retire design: file-op entries retired from WRITE_PATTERNS.
# classify() returns "read"; isExtendedFileOpWriteIR=true handles detection at hook level.
# Consistent with the WRITE_PATTERNS retire pattern: git-write, posix-redir, pwsh,
# file-op (rm/cp/mv), pkg-mgr, interpreter-c all follow the same "classify=read + IR=true" SSOT.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'FOCL_TABLE'
FO-CL-touch^touch foo.txt^read
FO-CL-chmod^chmod 644 foo.txt^read
FO-CL-sed-i^sed -i 's/old/new/g' foo.txt^read
FO-CL-tar-x^tar -xzf archive.tar.gz -C /tmp^read
FO-CL-dd^dd if=in.img of=out.img^read
FOCL_TABLE

echo "=== FO-CL-READ: classify() of read-only file-op → read ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'FOREAD_TABLE'
FO-CL-sed-no-i^sed 's/a/b/' file.txt^read
FO-CL-tar-list^tar -tf archive.tar^read
FO-CL-dd-devnull^dd if=input.img of=/dev/null^read
FOREAD_TABLE

echo "=== FP-CL: classify() — quoted file-op verb in echo should be read ==="
# 'touch' inside an echo string should not false-positive as a write.
# (QUOTED_COMMAND_WORD_WRITE_NAMES includes touch/chmod/rsync but NOT sed/perl/tar.)
assert_eq "FP-CL-echo-touch-prose" "read" "$(classify_ir 'echo "Use touch to create files"')"

echo "=== FO-PATTERNS: WRITE_PATTERNS — file-op entries MUST be retired ==="
# Post-retire: no entry with kind "file-op" should remain in WRITE_PATTERNS.
file_op_count="$(run_with_timeout 30 node -e "
  const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  const count=(WRITE_PATTERNS||[]).filter(p=>p.kind==='file-op').length;
  process.stdout.write(String(count));
" 2>/dev/null)"
assert_eq "FO-PATTERNS-no-file-op-entries" "0" "$file_op_count"

# STRIP_KINDS must NOT contain "file-op" post-retire.
strip_has_file_op="$(run_with_timeout 30 node -e "
  const {STRIP_KINDS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  process.stdout.write(String(STRIP_KINDS.has('file-op')));
" 2>/dev/null)"
assert_eq "FO-STRIP_KINDS-no-file-op" "false" "$strip_has_file_op"

# Verify specific retired names are absent.
for rname in "sed-inplace" "perl-inplace" "patch" "touch" "chmod" "dd" "rsync" "tar-extract" "unzip" "gunzip" "bunzip2"; do
  rpresent="$(run_with_timeout 30 node -e "
    const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    const count=(WRITE_PATTERNS||[]).filter(p=>p.name===process.argv[1]).length;
    process.stdout.write(String(count));
  " -- "$rname" 2>/dev/null)"
  assert_eq "FO-retired-$rname-absent" "0" "$rpresent"
done

report_totals
exit "$FAIL"
