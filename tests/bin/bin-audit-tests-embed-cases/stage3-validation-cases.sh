# Tests: bin/lib/test-embed-cases/stage-apply.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, stage-protocol, input-validation
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — stage 3 input validation
# is fail-closed (exit 2, nothing written): a workdir outside the embed root, a
# relpath with "..", a relpath outside the candidate set, an item path outside
# items/<idx>/. Each case tampers with a fresh, otherwise apply-ready workdir.

# v_ready — fresh repo with one passing output and an OK codex; sets V_HASH.
v_ready() {
  s3_plan alpha
  s3_good alpha
  ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
  V_HASH="$(s3_hash alpha)"
}

# v_rejected <label> — exit 2 from the stage-3 validator, nothing applied.
v_rejected() {
  if [[ "$RC" -eq 2 ]] && ec_not_unknown_arg; then
    pass "$1 is rejected with exit 2"
  else
    fail "$1 is rejected with exit 2" "rc=$RC out=${OUT:0:200} err=${ERR:0:200}"
  fi
  if printf '%s\n' "$OUT" | grep -q '^APPLIED'; then fail "$1 applies nothing" "out=${OUT:0:300}"; else pass "$1 applies nothing"; fi
  s3_untouched "$1" alpha "$V_HASH"
}

case_begin "validate-workdir-outside-root" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_outside="$EC_TMP/outside-workdir"
rm -rf "$_outside"
cp -R "$EC_WORKDIR" "$_outside"
ec_apply "$S3_REPO" "$_outside"
v_rejected "V1 a workdir copied outside <plans>/sweep-tests-embed/"
case_end

case_begin "validate-workdir-symlink-escape" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_outside="$EC_TMP/outside-workdir-2"
rm -rf "$_outside"
mv "$EC_WORKDIR" "$_outside"
if ln -s "$_outside" "$EC_WORKDIR" 2>/dev/null && [[ -L "$EC_WORKDIR" ]]; then
  ec_apply "$S3_REPO"
  v_rejected "V2 a workdir path whose real path leaves the root (symlink)"
else
  rm -rf "$EC_WORKDIR"
  mv "$_outside" "$EC_WORKDIR"
  skip "V2 symlinks are unavailable on this host"
fi
case_end

case_begin "validate-relpath-dotdot" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
ec_set_wl_field tests/bin/t-alpha.sh 2 "tests/bin/../bin/t-alpha.sh"
ec_apply "$S3_REPO"
v_rejected "V3 a worklist relpath containing .."
case_end

case_begin "validate-relpath-not-candidate" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
ec_set_wl_field tests/bin/t-alpha.sh 2 "tests/lib/harness.sh"
_harness_before="$(git -C "$S3_REPO" hash-object tests/lib/harness.sh)"
ec_apply "$S3_REPO"
v_rejected "V4 a relpath outside the tec_candidates set"
check_eq "V4 the non-candidate file is not written" "$_harness_before" "$(git -C "$S3_REPO" hash-object tests/lib/harness.sh)"
case_end

case_begin "validate-relpath-absolute" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
ec_set_wl_field tests/bin/t-alpha.sh 2 "$S3_REPO/tests/bin/t-alpha.sh"
ec_apply "$S3_REPO"
v_rejected "V5 an absolute relpath"
case_end

case_begin "validate-output-outside-item" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_evil="$EC_TMP/evil-output"
mkdir -p "$_evil"
cp "$(ec_item_output tests/bin/t-alpha.sh)" "$_evil/t-alpha.sh"
ec_set_wl_field tests/bin/t-alpha.sh 4 "$_evil/"
ec_apply "$S3_REPO"
v_rejected "V6 an output column pointing outside items/<idx>/"
case_end

case_begin "validate-input-outside-item" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
_idx="$(ec_wl_field tests/bin/t-alpha.sh 1)"
ec_set_wl_field tests/bin/t-alpha.sh 3 "$EC_WORKDIR/items/$_idx/../../worklist.tsv"
ec_apply "$S3_REPO"
v_rejected "V7 an input column escaping items/<idx>/ through .."
case_end

case_begin "validate-missing-workdir" "bin/lib/test-embed-cases/stage-apply.sh"
v_ready
ec_apply "$S3_REPO" "$WORKFLOW_PLANS_DIR/sweep-tests-embed/no-such-run"
v_rejected "V8 a workdir that does not exist"
case_end

grp_done stage3-validation-cases.sh
