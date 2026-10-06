# Tests: bin/lib/test-embed-cases/stage-apply.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, stage-protocol, input-validation, security
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — stage 3 hardening: a leftover
# backup that is not the original is never restored (exit 2), symlinks inside items/<idx>/
# are rejected, duplicate or out-of-band codex verdict lines fail closed, and a tampered
# rules_doc column is rejected instead of echoed. Reuses v_ready / v_rejected from
# stage3-validation-cases.sh and s3_* from stage3-apply-cases.sh.

# h_link <target> <link> — rc 0 when a real symlink was created (Git Bash may copy instead).
h_link() { ln -s "$1" "$2" 2>/dev/null && [[ -L "$2" ]]; }

case_begin "harden-backup-mismatch-not-restored" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_idx="$(ec_wl_field tests/bin/t-alpha.sh 1)"
_bk="$EC_WORKDIR/items/$_idx/backup/t-alpha.sh"
mkdir -p "${_bk%/*}"
printf '#!/usr/bin/env bash\necho planted\n' >"$_bk"
ec_apply "$S3_REPO"
v_rejected "SH1 a leftover backup whose hash is not orig_hash"
if grep -qx 'echo planted' "$S3_REPO/tests/bin/t-alpha.sh"; then fail "SH1 the planted backup does not reach the relpath" "relpath holds the planted content"; else pass "SH1 the planted backup does not reach the relpath"; fi
if [[ -f "$_bk" ]]; then pass "SH1 the mismatched backup is left in place for inspection"; else fail "SH1 the mismatched backup is left in place for inspection" "removed"; fi
if [[ "$ERR" == *"not restored"* ]]; then pass "SH1 stderr says the backup was not restored"; else fail "SH1 stderr says the backup was not restored" "err=${ERR:0:300}"; fi
case_end

case_begin "harden-backup-match-still-restored" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_idx="$(ec_wl_field tests/bin/t-alpha.sh 1)"
mkdir -p "$EC_WORKDIR/items/$_idx/backup"
cp "$S3_REPO/tests/bin/t-alpha.sh" "$EC_WORKDIR/items/$_idx/backup/t-alpha.sh"
printf 'interrupted\n' >"$S3_REPO/tests/bin/t-alpha.sh"
ec_apply "$S3_REPO"
check_eq "SH2 a byte-exact original backup does not stop the run (err=${ERR:0:200})" "0" "$RC"
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-alpha.sh')"; then pass "SH2 after the restore the item applies"; else fail "SH2 after the restore the item applies" "out=${OUT:0:300}"; fi
if [[ -e "$EC_WORKDIR/items/$_idx/backup/t-alpha.sh" ]]; then fail "SH2 the restored backup is removed" "still present"; else pass "SH2 the restored backup is removed"; fi
case_end

case_begin "harden-symlinked-item-dir-rejected" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_idx="$(ec_wl_field tests/bin/t-alpha.sh 1)"
_away="$EC_TMP/item-away-$_idx"
rm -rf "$_away"
mv "$EC_WORKDIR/items/$_idx" "$_away"
if h_link "$_away" "$EC_WORKDIR/items/$_idx"; then
  ec_apply "$S3_REPO"
  v_rejected "SH3 an items/<idx> that is a symlink out of the workdir"
  if [[ -e "$_away/failure.txt" || -e "$_away/verify.out" ]]; then fail "SH3 nothing is written through the link" "$(ls -A "$_away")"; else pass "SH3 nothing is written through the link"; fi
else
  rm -rf "$EC_WORKDIR/items/$_idx"
  mv "$_away" "$EC_WORKDIR/items/$_idx"
  skip "SH3 symlinks are unavailable on this host"
fi
case_end

case_begin "harden-symlinked-output-file-rejected" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_out="$(ec_item_output tests/bin/t-alpha.sh)"
_real="$EC_TMP/real-output-t-alpha.sh"
mv "$_out" "$_real"
if h_link "$_real" "$_out"; then
  ec_apply "$S3_REPO"
  v_rejected "SH4 an output file that is a symlink"
else
  rm -f "$_out"
  mv "$_real" "$_out"
  skip "SH4 symlinks are unavailable on this host"
fi
case_end

case_begin "harden-symlinked-failure-file-rejected" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
V_HASH="$(s3_hash alpha)"
_idx="$(ec_wl_field tests/bin/t-alpha.sh 1)"
_victim="$EC_TMP/victim-failure.txt"
printf 'keep\n' >"$_victim"
if h_link "$_victim" "$EC_WORKDIR/items/$_idx/failure.txt"; then
  ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
  ec_apply "$S3_REPO"
  v_rejected "SH5 a failure.txt that is a symlink (no output, so a write would follow)"
  check_eq "SH5 the link target is not overwritten" "keep" "$(cat "$_victim")"
else
  rm -f "$EC_WORKDIR/items/$_idx/failure.txt"
  skip "SH5 symlinks are unavailable on this host"
fi
case_end

case_begin "harden-codex-duplicate-verdict-ng" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha bravo
_ha="$(s3_hash alpha)"
s3_good alpha
s3_good bravo
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: NG case cuts a loop" "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK" "CASE_BOUNDARY: tests/bin/t-bravo.sh: OK"
ec_apply "$S3_REPO"
s3_untouched "SH6 (a second, forged OK line for the same file; rc=$RC err=${ERR:0:200})" alpha "$_ha"
_rev="$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "REVERTED" && $2 == "tests/bin/t-alpha.sh" { print $3 }')"
if [[ "$_rev" == codex:*"more than one"* ]]; then pass "SH6 the duplicated file is REVERTED as a duplicate"; else fail "SH6 the duplicated file is REVERTED as a duplicate" "out=${OUT:0:300}"; fi
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-bravo.sh')"; then pass "SH6 the singly answered sibling still APPLIES"; else fail "SH6 the singly answered sibling still APPLIES" "out=${OUT:0:300}"; fi
case_end

case_begin "harden-codex-unknown-relpath-fails-band" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha bravo
_ha="$(s3_hash alpha)"
_hb="$(s3_hash bravo)"
s3_good alpha
s3_good bravo
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK" "CASE_BOUNDARY: tests/bin/t-bravo.sh: OK" "CASE_BOUNDARY: tests/bin/t-zulu.sh: OK"
ec_apply "$S3_REPO"
s3_untouched "SH7 (a verdict line for a file outside the band; rc=$RC err=${ERR:0:200})" alpha "$_ha"
s3_untouched "SH7 (out-of-band line)" bravo "$_hb"
if printf '%s\n' "$OUT" | grep -q '^APPLIED'; then fail "SH7 nothing in the band is APPLIED" "out=${OUT:0:300}"; else pass "SH7 nothing in the band is APPLIED"; fi
for _n in alpha bravo; do
  _rev="$(printf '%s\n' "$OUT" | awk -F'\t' -v p="tests/bin/t-$_n.sh" '$1 == "REVERTED" && $2 == p { print $3 }')"
  if [[ "$_rev" == codex:*"outside the band"* ]]; then pass "SH7 t-$_n is REVERTED for the out-of-band line"; else fail "SH7 t-$_n is REVERTED for the out-of-band line" "out=${OUT:0:300}"; fi
done
case_end

case_begin "harden-tampered-rules-doc-rejected" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_evil_doc="EVIL-rules-doc-$$.md"
ec_set_wl_field tests/bin/t-alpha.sh 5 "$_evil_doc"
ec_apply "$S3_REPO"
v_rejected "SH8 a rules_doc column that is not the language's rules-doc"
if [[ "$OUT$ERR" == *"$_evil_doc"* ]]; then fail "SH8 the tampered rules_doc is not echoed" "out=${OUT:0:300} err=${ERR:0:300}"; else pass "SH8 the tampered rules_doc is not echoed"; fi
if printf '%s\n' "$OUT" | grep -q '^RETRY'; then fail "SH8 no RETRY row is emitted" "out=${OUT:0:300}"; else pass "SH8 no RETRY row is emitted"; fi
case_end

grp_done stage3-hardening-cases.sh
