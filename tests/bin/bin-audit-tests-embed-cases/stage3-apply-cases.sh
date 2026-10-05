# Tests: bin/lib/test-embed-cases/stage-apply.sh, bin/lib/test-embed-cases/codex-band-check.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, stage-protocol, stage-3
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — stage 3 (apply): the
# verifier + codex gate, atomic replace with mode kept, verifier / codex NG and
# missing-line fail-closed, codex unavailable (tool-failed, not counted), and the
# re-run of a workdir. Stage 2 is simulated by writing the item outputs directly.

# s3_plan <name>... — fresh repo with tests/bin/t-<name>.sh (header bin/<name>.sh),
# then stage 1 over all of them. Sets S3_REPO and EC_WORKDIR.
s3_plan() {
  local n
  S3_REPO="$(ec_make_repo)"
  for n in "$@"; do ec_add_test "$S3_REPO" "tests/bin/t-$n.sh" "bin/$n.sh"; done
  ec_commit "$S3_REPO" init
  ec_stage1 "$S3_REPO" "$AUDIT" --band-size 5
}

# s3_good <name> — a verifier-passing output for tests/bin/t-<name>.sh.
s3_good() { ec_write_embedded "$(ec_item_output "tests/bin/t-$1.sh")" "bin/$1.sh" "bin/$1.sh"; }

# s3_hash <name> — current git hash-object of tests/bin/t-<name>.sh in S3_REPO.
s3_hash() { git -C "$S3_REPO" hash-object "tests/bin/t-$1.sh"; }

# s3_untouched <label> <name> <hash-before> — the original stayed byte-identical.
s3_untouched() { check_eq "$1 tests/bin/t-$2.sh is left as it was" "$3" "$(s3_hash "$2")"; }

case_begin "apply-pass-replaces-and-keeps-mode" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
_mode_before="$(stat -c '%a' "$S3_REPO/tests/bin/t-alpha.sh" 2>/dev/null)"
s3_good alpha
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
check_eq "A1 apply exits 0 (err=${ERR:0:200})" "0" "$RC"
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-alpha.sh')"; then pass "A1 reports APPLIED<TAB>relpath"; else fail "A1 reports APPLIED<TAB>relpath" "out=${OUT:0:300}"; fi
if cmp -s "$(ec_item_output tests/bin/t-alpha.sh)" "$S3_REPO/tests/bin/t-alpha.sh"; then pass "A1 the file now holds the stage-2 output"; else fail "A1 the file now holds the stage-2 output" "workdir=$EC_WORKDIR"; fi
check_eq "A1 the file mode is preserved" "$_mode_before" "$(stat -c '%a' "$S3_REPO/tests/bin/t-alpha.sh" 2>/dev/null)"
check_eq "A1 worklist state becomes applied" "applied" "$(ec_wl_field tests/bin/t-alpha.sh 8)"
check_eq "A1 the backup dir is left empty" "" "$(ls -A "$EC_WORKDIR/items/$(ec_wl_field tests/bin/t-alpha.sh 1)/backup" 2>/dev/null)"
case_end

case_begin "apply-verifier-ng-leaves-file" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
_h="$(s3_hash alpha)"
cp "$S3_REPO/tests/bin/t-alpha.sh" "$(ec_item_output tests/bin/t-alpha.sh)"
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
s3_untouched "A2 (marker-less output fails the verifier; rc=$RC)" alpha "$_h"
_rev="$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "REVERTED" && $2 == "tests/bin/t-alpha.sh"')"
if [[ -n "$_rev" && "$(printf '%s' "$_rev" | awk -F'\t' '{ print NF }')" -ge 3 ]]; then pass "A2 reports REVERTED<TAB>relpath<TAB>reason"; else fail "A2 reports REVERTED<TAB>relpath<TAB>reason" "out=${OUT:0:300} err=${ERR:0:200}"; fi
if printf '%s\n' "$OUT" | grep -q "^APPLIED"; then fail "A2 nothing is APPLIED" "out=${OUT:0:300}"; else pass "A2 nothing is APPLIED"; fi
case_end

case_begin "apply-no-output-is-ng" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha
_h="$(s3_hash alpha)"
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK"
ec_apply "$S3_REPO"
s3_untouched "A3 (no stage-2 output; rc=$RC)" alpha "$_h"
_rev="$(printf '%s\n' "$OUT" | awk -F'\t' '$1 == "REVERTED" && $2 == "tests/bin/t-alpha.sh" { print $3 }')"
if [[ "$_rev" == *no-output* ]]; then pass "A3 a missing output is REVERTED with no-output"; else fail "A3 a missing output is REVERTED with no-output" "out=${OUT:0:300} err=${ERR:0:200}"; fi
case_end

case_begin "apply-codex-ng-leaves-file" "bin/lib/test-embed-cases/codex-band-check.sh"
s3_plan alpha bravo
_ha="$(s3_hash alpha)"
s3_good alpha
s3_good bravo
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: NG case cuts an assertion in half" "CASE_BOUNDARY: tests/bin/t-bravo.sh: OK"
ec_apply "$S3_REPO"
s3_untouched "A4 (codex NG; rc=$RC err=${ERR:0:200})" alpha "$_ha"
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-bravo.sh')"; then pass "A4 the codex-OK sibling in the band is still APPLIED"; else fail "A4 the codex-OK sibling in the band is still APPLIED" "out=${OUT:0:300}"; fi
if printf '%s\n' "$OUT" | awk -F'\t' '$1 == "REVERTED" && $2 == "tests/bin/t-alpha.sh"' | grep -q .; then pass "A4 the codex-NG file is REVERTED"; else fail "A4 the codex-NG file is REVERTED" "out=${OUT:0:300}"; fi
case_end

case_begin "apply-codex-missing-line-is-ng" "bin/lib/test-embed-cases/codex-band-check.sh"
s3_plan alpha bravo
_ha="$(s3_hash alpha)"
s3_good alpha
s3_good bravo
ec_codex_says "CASE_BOUNDARY: tests/bin/t-bravo.sh: OK"
ec_apply "$S3_REPO"
s3_untouched "A5 (no CASE_BOUNDARY line for it; rc=$RC err=${ERR:0:200})" alpha "$_ha"
if printf '%s\n' "$OUT" | awk -F'\t' '$1 == "REVERTED" && $2 == "tests/bin/t-alpha.sh"' | grep -q .; then pass "A5 a file codex did not answer for is REVERTED"; else fail "A5 a file codex did not answer for is REVERTED" "out=${OUT:0:300}"; fi
if ec_has_line "$OUT" "$(printf 'APPLIED\ttests/bin/t-bravo.sh')"; then pass "A5 the answered sibling is APPLIED"; else fail "A5 the answered sibling is APPLIED" "out=${OUT:0:300}"; fi
case_end

case_begin "apply-codex-single-call-per-band" "bin/lib/test-embed-cases/codex-band-check.sh"
s3_plan alpha bravo
s3_good alpha
s3_good bravo
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK" "CASE_BOUNDARY: tests/bin/t-bravo.sh: OK"
export FAKE_CODEX_LOG="$EC_TMP/codex-call.log"
: >"$FAKE_CODEX_LOG"
ec_apply "$S3_REPO"
check_eq "A6 codex is called once for the whole band (rc=$RC err=${ERR:0:200})" "1" "$(grep -c '^ARGS: ' "$FAKE_CODEX_LOG")"
if grep -qF tests/bin/t-alpha.sh "$FAKE_CODEX_LOG" && grep -qF tests/bin/t-bravo.sh "$FAKE_CODEX_LOG"; then
  pass "A6 the prompt names every verified relpath"
else
  fail "A6 the prompt names every verified relpath" "log=$(head -c 300 "$FAKE_CODEX_LOG")"
fi
unset FAKE_CODEX_LOG
case_end

case_begin "apply-codex-unavailable-tool-failed" "bin/lib/test-embed-cases/stage-apply.sh"
s3_plan alpha bravo
_ha="$(s3_hash alpha)"
_hb="$(s3_hash bravo)"
s3_good alpha
s3_good bravo
ec_codex_fails
ec_apply "$S3_REPO"
s3_untouched "A7 (codex FAILED; rc=$RC)" alpha "$_ha"
s3_untouched "A7 (codex FAILED)" bravo "$_hb"
if ec_has_line "$OUT" "CODEX_UNAVAILABLE"; then pass "A7 reports CODEX_UNAVAILABLE"; else fail "A7 reports CODEX_UNAVAILABLE" "out=${OUT:0:300} err=${ERR:0:200}"; fi
for _n in alpha bravo; do
  if ec_has_line "$OUT" "$(printf 'TOOL_FAILED\ttests/bin/t-%s.sh' "$_n")"; then pass "A7 t-$_n is TOOL_FAILED"; else fail "A7 t-$_n is TOOL_FAILED" "out=${OUT:0:300}"; fi
  check_eq "A7 t-$_n state is tool-failed" "tool-failed" "$(ec_wl_field "tests/bin/t-$_n.sh" 8)"
  check_eq "A7 t-$_n attempts stay 0 (a tool failure is not a try)" "0" "$(ec_wl_field "tests/bin/t-$_n.sh" 9)"
done
if [[ -s "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv" ]] && grep -qF tests/bin/t-alpha.sh "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv"; then
  fail "A7 a tool failure writes no embed-retry row" "$(cat "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv")"
else
  pass "A7 a tool failure writes no embed-retry row"
fi
if printf '%s\n' "$OUT" | grep -q '^RETRY'; then fail "A7 a tool failure emits no RETRY row" "out=${OUT:0:300}"; else pass "A7 a tool failure emits no RETRY row"; fi
case_end

case_begin "apply-tool-failed-rerun-reports-only" "bin/lib/test-embed-cases/stage-apply.sh"
# Continues the A7 workdir: codex now works, but tool-failed is final for this workdir.
_ha="$(s3_hash alpha)"
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK" "CASE_BOUNDARY: tests/bin/t-bravo.sh: OK"
ec_apply "$S3_REPO"
s3_untouched "A8 (re-run on the same workdir; rc=$RC)" alpha "$_ha"
if ec_has_line "$OUT" "$(printf 'TOOL_FAILED\ttests/bin/t-alpha.sh')"; then pass "A8 the re-run re-reports TOOL_FAILED"; else fail "A8 the re-run re-reports TOOL_FAILED" "out=${OUT:0:300} err=${ERR:0:200}"; fi
if printf '%s\n' "$OUT" | grep -q '^APPLIED'; then fail "A8 the re-run applies nothing" "out=${OUT:0:300}"; else pass "A8 the re-run applies nothing"; fi
check_eq "A8 state stays tool-failed" "tool-failed" "$(ec_wl_field tests/bin/t-alpha.sh 8)"
ec_run "$S3_REPO" "$AUDIT" --embed-cases --dry-run --band-size 5
if ec_band_paths | grep -qxF tests/bin/t-alpha.sh; then pass "A8 the next stage 1 selects the tool-failed file again"; else fail "A8 the next stage 1 selects the tool-failed file again" "out=${OUT:0:300} err=${ERR:0:200}"; fi
case_end

# s3_path_without_codex — $PATH minus the fake codex dir; a dir holding a real codex
# (often beside node, e.g. fnm/npm) is swapped for a shim dir forwarding every other executable.
s3_path_without_codex() {
  local d f nm shim out="" parts=() n=0
  IFS=':' read -r -a parts <<<"$PATH"
  for d in "${parts[@]}"; do
    [[ -z "$d" || "$d" == "$EC_TMP/fakebin" ]] && continue
    if [[ -e "$d/codex" || -e "$d/codex.exe" || -e "$d/codex.cmd" || -e "$d/codex.bat" ]]; then
      n=$((n + 1))
      shim="$EC_TMP/nocodex-path/$n"
      mkdir -p "$shim"
      for f in "$d"/*; do
        nm="${f##*/}"
        nm="${nm%.exe}"
        [[ -f "$f" && -x "$f" && "$nm" != codex* && "$nm" != *.cmd && "$nm" != *.bat && "$nm" != *.ps1 ]] || continue
        [[ -e "$shim/$nm" ]] && continue
        printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$f" >"$shim/$nm"
        chmod +x "$shim/$nm"
      done
      d="$shim"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}

case_begin "apply-codex-absent-from-path-tool-failed" "bin/lib/test-embed-cases/codex-band-check.sh"
# codex-core's SKIPPED path (no codex on PATH) is a tool failure like FAILED.
s3_plan alpha bravo
_ha="$(s3_hash alpha)"
_hb="$(s3_hash bravo)"
s3_good alpha
s3_good bravo
# A reachable fake codex would answer OK and let both apply, exposing a PATH leak.
ec_codex_says "CASE_BOUNDARY: tests/bin/t-alpha.sh: OK" "CASE_BOUNDARY: tests/bin/t-bravo.sh: OK"
export FAKE_CODEX_LOG="$EC_TMP/codex-absent.log"
: >"$FAKE_CODEX_LOG"
_retry_before="$(cat "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv" 2>/dev/null)"
_saved_path="$PATH"
PATH="$(s3_path_without_codex)"
if command -v codex >/dev/null 2>&1; then fail "A9 the reduced PATH resolves no codex" "found $(command -v codex)"; else pass "A9 the reduced PATH resolves no codex"; fi
if command -v node >/dev/null 2>&1 && command -v git >/dev/null 2>&1; then pass "A9 the reduced PATH still resolves node and git"; else fail "A9 the reduced PATH still resolves node and git" "PATH=$PATH"; fi
ec_apply "$S3_REPO"
PATH="$_saved_path"
s3_untouched "A9 (codex absent; rc=$RC err=${ERR:0:200})" alpha "$_ha"
s3_untouched "A9 (codex absent)" bravo "$_hb"
if ec_has_line "$OUT" "CODEX_UNAVAILABLE"; then pass "A9 reports CODEX_UNAVAILABLE"; else fail "A9 reports CODEX_UNAVAILABLE" "out=${OUT:0:300} err=${ERR:0:200}"; fi
for _n in alpha bravo; do
  if ec_has_line "$OUT" "$(printf 'TOOL_FAILED\ttests/bin/t-%s.sh' "$_n")"; then pass "A9 t-$_n is TOOL_FAILED"; else fail "A9 t-$_n is TOOL_FAILED" "out=${OUT:0:300}"; fi
  check_eq "A9 t-$_n state is tool-failed" "tool-failed" "$(ec_wl_field "tests/bin/t-$_n.sh" 8)"
  check_eq "A9 t-$_n attempts stay 0" "0" "$(ec_wl_field "tests/bin/t-$_n.sh" 9)"
done
check_eq "A9 embed-retry.tsv gains no row" "$_retry_before" "$(cat "$SWEEP_TESTS_STATE_DIR/embed-retry.tsv" 2>/dev/null)"
check_eq "A9 the fake codex was never reached" "" "$(cat "$FAKE_CODEX_LOG")"
if printf '%s\n' "$OUT" | grep -q '^APPLIED'; then fail "A9 nothing is APPLIED" "out=${OUT:0:300}"; else pass "A9 nothing is APPLIED"; fi
unset FAKE_CODEX_LOG
case_end

grp_done stage3-apply-cases.sh
