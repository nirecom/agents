# tests/bin/feature-2501-launch-classify/security.sh
# Tests: bin/lib/run-all-classify.sh, bin/lib/run-all-launch.sh
# Tags: TL2, bin, run-all, launch, classify, unrunnable, security, scope:issue-specific
# Launch/classify hardening (#2501): a test-written `unrunnable` marker counts only when it is one of
# the launched entry's labels; a relative path starting with '-' stays a path; {nativePathSq}
# doubles every PowerShell single-quote character. Sourced by the dispatcher after exec.sh.

echo ""
echo "=== launch/classify hardening ==="

# --- C1a: a bash test (its entry has no labels) forges the marker and exits 79 ------------
cat >"$CO/tests/bin/m-forge-glob.sh" <<'EOF'
printf '%s\n' '* x evil' >"$RUN_ALL_RESULT_DIR/unrunnable"
exit 79
EOF
cat >"$CO/tests/bin/m-forge-label.sh" <<'EOF'
printf '%s\n' 'no-such-tool-2501' >"$RUN_ALL_RESULT_DIR/unrunnable"
exit 79
EOF
# `bash` is what the bash entry's own command starts with: valid only as the launcher's finding.
cat >"$CO/tests/bin/m-forge-exe.sh" <<'EOF'
printf '%s\n' 'bash' >"$RUN_ALL_RESULT_DIR/unrunnable"
exit 79
EOF

case_begin "bash-test-cannot-forge-unrunnable" "bin/lib/run-all-classify.sh"
for fg in glob label exe; do
  mkdir -p "$TMPBASE/res-forge-$fg"
  rae "forge-$fg" "$CO" "$CO/tests/bin/m-forge-$fg.sh" "$TMPBASE/res-forge-$fg"
  K="$TMPBASE/rae-forge-$fg.kv"
  assert_eq "forged marker ($fg) from a bash test: $(rae_sum "forge-$fg")" \
    "forged marker ($fg) from a bash test: rc=79 state=FAIL"
  assert_eq "forged marker ($fg): RUN_ALL_EXEC_MISSING=[$(kv missing "$K")]" \
    "forged marker ($fg): RUN_ALL_EXEC_MISSING=[]"
done
case_end

# --- C1b: a launched wrapper may only name its entry's minimum-version label --------------
COF="$TMPBASE/co-forge"
fx_co "$COF" wrap || fail "fixture checkout (forge)" "fx_co failed"
# The fixture wrapper copies the test file's content into the marker and exits 79.
cat >"$COF/bin/lib/test-wrappers/fx-echo-2501.sh" <<'EOF'
cat "$1" >"$RUN_ALL_RESULT_DIR/unrunnable"
exit 79
EOF

# name|marker text|want ("<state> <RUN_ALL_EXEC_MISSING>")
MK_ROWS=(
  'minver|fxrt>=1.2|UNRUNNABLE fxrt>=1.2'
  'requires|bash|FAIL '
  'minver-extra|fxrt>=1.2 extra|FAIL '
  'other-entry|pwsh|FAIL '
  'glob|* x evil|FAIL '
  'wrong-version|fxrt>=9.9|FAIL '
)

case_begin "wrapper-marker-must-be-an-entry-label" "bin/lib/run-all-classify.sh"
for row in "${MK_ROWS[@]}"; do
  IFS='|' read -r mk_name mk_text mk_want <<<"$row"
  printf '%s\n' "$mk_text" >"$COF/tests/bin/mk-$mk_name.fxwrap"
  mkdir -p "$TMPBASE/res-mk-$mk_name"
  rae "mk-$mk_name" "$COF" "$COF/tests/bin/mk-$mk_name.fxwrap" "$TMPBASE/res-mk-$mk_name"
  K="$TMPBASE/rae-mk-$mk_name.kv"
  assert_eq "marker [$mk_text]: $(kv state "$K") $(kv missing "$K")" "marker [$mk_text]: $mk_want"
done
case_end

# --- C1b': the marker's whole content, byte for byte, must be the label (one line terminator) ----
# name|printf format of the marker bytes (no '%')|want ("<state> <RUN_ALL_EXEC_MISSING>")
MKB_ROWS=(
  'no-newline|fxrt>=1.2|UNRUNNABLE fxrt>=1.2'
  'crlf|fxrt>=1.2\r\n|UNRUNNABLE fxrt>=1.2'
  'nul-suffix|fxrt>=1.2\0extra\n|FAIL '
  'nul-at-end|fxrt>=1.2\0|FAIL '
  'nul-then-newline|fxrt>=1.2\0\n|FAIL '
  'empty||FAIL '
  'newline-only|\n|FAIL '
  'label-then-junk|fxrt>=1.2\njunk\n|FAIL '
  'junk-then-label|junk\nfxrt>=1.2\n|FAIL '
  'label-then-blank-line|fxrt>=1.2\n\n|FAIL '
  'trailing-space|fxrt>=1.2 \n|FAIL '
  'trailing-tab|fxrt>=1.2\t\n|FAIL '
  'leading-space| fxrt>=1.2\n|FAIL '
  'cr-then-junk|fxrt>=1.2\rjunk\n|FAIL '
  'double-cr|fxrt>=1.2\r\r\n|FAIL '
)

case_begin "wrapper-marker-bytes-must-be-exactly-a-label" "bin/lib/run-all-classify.sh"
for row in "${MKB_ROWS[@]}"; do
  IFS='|' read -r mkb_name mkb_fmt mkb_want <<<"$row"
  # shellcheck disable=SC2059 # the row's format is the marker's bytes
  printf "$mkb_fmt" >"$COF/tests/bin/mkb-$mkb_name.fxwrap"
  mkdir -p "$TMPBASE/res-mkb-$mkb_name"
  rae "mkb-$mkb_name" "$COF" "$COF/tests/bin/mkb-$mkb_name.fxwrap" "$TMPBASE/res-mkb-$mkb_name"
  K="$TMPBASE/rae-mkb-$mkb_name.kv"
  if cmp -s "$COF/tests/bin/mkb-$mkb_name.fxwrap" "$TMPBASE/res-mkb-$mkb_name/unrunnable"; then
    pass "marker bytes [$mkb_name] reached the result dir unchanged"
  else
    fail "marker bytes [$mkb_name] reached the result dir unchanged" "no such marker or different bytes"
  fi
  assert_eq "marker bytes [$mkb_name]: rc=$(kv rc "$K") $(kv state "$K") $(kv missing "$K")" \
    "marker bytes [$mkb_name]: rc=79 $mkb_want"
done
case_end

# --- C1c: what prepare / command start with is a label; their other words are not -----------
cat >"$TMPBASE/lbl.sh" <<'EOF'
# lbl.sh <checkout> <id> <resultdir> — rac_classify of rc 79 against <id>'s labels; "STATE MISSING".
. "$1/bin/lib/run-all-launch.sh" || exit 95
tlr_load || exit 94
rac_entry_labels "$2"
rac_classify 79 0 "$3"
printf '%s %s' "$RUN_ALL_EXEC_STATE" "$RUN_ALL_EXEC_MISSING"
EOF

# name|entry id|marker text|want ("<state> <RUN_ALL_EXEC_MISSING>")
LBL_ROWS=(
  'command-exe|fx-nocmd|no-such-cmd-2501|UNRUNNABLE no-such-cmd-2501'
  'command-arg|fx-nocmd|{path}|FAIL '
  'other-entry-prepare-exe|fx-nocmd|no-such-prep-2501|FAIL '
  'prepare-exe|fx-noprep|no-such-prep-2501|UNRUNNABLE no-such-prep-2501'
  'prepare-arg|fx-noprep|prep-arg-2501|FAIL '
  'suite-command-exe|fx-noprep|bash|UNRUNNABLE bash'
  'suite-command-arg|fx-noprep|-c|FAIL '
  'other-entry-command-exe|fx-noprep|no-such-cmd-2501|FAIL '
)

case_begin "launch-executables-are-entry-labels" "bin/lib/run-all-classify.sh"
for row in "${LBL_ROWS[@]}"; do
  IFS='|' read -r lb_name lb_id lb_text lb_want <<<"$row"
  mkdir -p "$TMPBASE/res-lbl-$lb_name"
  printf '%s\n' "$lb_text" >"$TMPBASE/res-lbl-$lb_name/unrunnable"
  lb_got="$(run_with_timeout 60 bash "$TMPBASE/lbl.sh" "$COX" "$lb_id" "$TMPBASE/res-lbl-$lb_name" 2>>"$TMPBASE/lbl.err" || printf '<rc=%s>' "$?")"
  assert_eq "$lb_id marker [$lb_text]: $lb_got" "$lb_id marker [$lb_text]: $lb_want"
done
case_end

# --- C4 (bash entry): a relative path that begins with '-' --------------------------------
DASH="$TMPBASE/dash"
mkdir -p "$DASH" "$TMPBASE/res-dash"
printf '%s\n' 'echo dash-test-ran-2501' \
  'if [ "${RUN_ALL_RESULT_OWNER-}" = "$0" ]; then echo dash-owner-is-zero-2501; fi' >"$DASH/-dash.sh"

case_begin "dash-leading-relative-path-is-a-path" "bin/lib/run-all-launch.sh"
(cd "$DASH" && rae dash "$CO" "-dash.sh" "$TMPBASE/res-dash")
assert_eq "relative '-dash.sh': $(rae_sum dash)" "relative '-dash.sh': rc=0 state=PASS"
assert_eq "relative '-dash.sh' ran: $(grep -c dash-test-ran-2501 "$TMPBASE/rae-dash.out" 2>/dev/null || true)" \
  "relative '-dash.sh' ran: 1"
# The harness records cases only when the owner equals its own $0 — the path as launched.
assert_eq "relative '-dash.sh' owner equals \$0: $(grep -c dash-owner-is-zero-2501 "$TMPBASE/rae-dash.out" 2>/dev/null || true)" \
  "relative '-dash.sh' owner equals \$0: 1"
case_end

# --- C7: {nativePathSq} doubles every PowerShell single-quote character -----------------
# UTF-8 rows travel through files, never argv, so no code-page conversion touches them.
cat >"$TMPBASE/sq.sh" <<'EOF'
# sq.sh <agents> <rows> — "name<TAB>got<TAB>want" per row of "name<TAB>native<TAB>want".
. "$1/bin/lib/run-all-launch.sh" || exit 95
while IFS=$'\t' read -r name native want; do
  [ -n "$name" ] || continue
  _TLR_A_ID=(fx) _TLR_A_KIND=(command) _TLR_A_VAL=("[{nativePathSq}]")
  _rae_argv fx command p "$native" w m
  printf '%s\t%s\t%s\n' "$name" "${_RAE_ARGV[0]-<none>}" "$want"
done <"$2"
EOF
# ASCII ', left/right single quotes, low-9 and high-reversed-9 all close a PowerShell '...' string.
printf '%s\t%s\t%s\n' \
  ascii "a'b" "[a''b]" \
  left "a‘b" "[a‘‘b]" \
  right "a’b" "[a’’b]" \
  low9 "a‚b" "[a‚‚b]" \
  rev9 "a‛b" "[a‛‛b]" \
  mixed "x'‘’y" "[x''‘‘’’y]" \
  none "C:/pd/plain.Tests.ps1" "[C:/pd/plain.Tests.ps1]" >"$TMPBASE/sq-rows.tsv"

case_begin "native-path-sq-doubles-every-single-quote" "bin/lib/run-all-launch.sh"
run_with_timeout 60 bash "$TMPBASE/sq.sh" "$SCRIPT_CHECKOUT_ROOT" "$TMPBASE/sq-rows.tsv" >"$TMPBASE/sq-out.tsv" 2>"$TMPBASE/sq.err" || true
sq_n=0
while IFS=$'\t' read -r sq_name sq_got sq_want; do
  sq_n=$((sq_n + 1))
  assert_eq "{nativePathSq} $sq_name: $sq_got" "{nativePathSq} $sq_name: $sq_want"
done <"$TMPBASE/sq-out.tsv"
assert_eq "{nativePathSq} rows evaluated: $sq_n" "{nativePathSq} rows evaluated: 7"
case_end
