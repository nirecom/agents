# shellcheck shell=bash
# tests/hooks/feature-2517-run-tests-baseline-accept/regex.sh
# Tests: hooks/lib/sentinel-patterns.js
# Tags: TL1, hooks, sentinel, regex, parser, security, scope:issue-specific
# The sentinel's two regexes (#2517 Steps 3): RUN_TESTS_BASELINE_ACCEPTED_RE_DQ takes the
# reason charset [^>()`;|&]+; _LOOKSLIKE_RE catches the malformed forms; both are in isSentinel and
# only the strict one in isStrictSentinel. The UNRUNNABLE pair never matches the baseline form and
# the baseline pair never matches the UNRUNNABLE form. Sourced by the dispatcher.

echo ""
echo "=== regex: RUN_TESTS_BASELINE_ACCEPTED_RE_DQ / _LOOKSLIKE_RE ==="

# rx.js <sentinel-patterns.js> <cls|reason> <command> — one canonical line for the command.
cat >"$T/rx.js" <<'EOF'
const m = require(process.argv[2]);
const [mode, cmd] = process.argv.slice(3);
const dq = m.RUN_TESTS_BASELINE_ACCEPTED_RE_DQ;
const look = m.RUN_TESTS_BASELINE_ACCEPTED_LOOKSLIKE_RE;
const bit = (re) => (re instanceof RegExp ? (re.test(cmd) ? 1 : 0) : "missing");
if (mode === "cls") {
  console.log(`dq=${bit(dq)} look=${bit(look)} sent=${m.isSentinel(cmd) ? 1 : 0} strict=${m.isStrictSentinel(cmd) ? 1 : 0}`);
} else if (mode === "ua") {
  console.log(`uadq=${bit(m.RUN_TESTS_UNRUNNABLE_ACCEPTED_RE_DQ)} ualook=${bit(m.RUN_TESTS_UNRUNNABLE_ACCEPTED_LOOKSLIKE_RE)}`);
} else {
  const r = dq instanceof RegExp ? cmd.match(dq) : null;
  console.log(r ? `reason=${r[1]}` : "reason=(nomatch)");
}
EOF

rx() { run_with_timeout 30 node "$T/rx.js" "$SP_JS" "$@" 2>/dev/null | tr -d '\r' || printf '<error>'; }

case_begin "regex-classifies-forms" "hooks/lib/sentinel-patterns.js"
# Table: <label>|<command>|<dq look isSentinel isStrictSentinel>  (a literal pipe is written %PIPE%).
while IFS='|' read -r label cmd want; do
  [ -n "$label" ] || continue
  cmd="$(unpipe "$cmd")"
  assert_eq "$label: $(rx cls "$cmd")" "$label: $want"
done <<'ROWS'
valid|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: these fail on main too>>"|dq=1 look=1 sent=1 strict=1
valid-punct|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: a.sh=flaky, b.sh on main/CI>>"|dq=1 look=1 sent=1 strict=1
gt|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky > not ours>>"|dq=0 look=1 sent=1 strict=0
open-paren|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky (on main)>>"|dq=0 look=1 sent=1 strict=0
backtick|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky `x` here>>"|dq=0 look=1 sent=1 strict=0
semicolon|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky; on main>>"|dq=0 look=1 sent=1 strict=0
pipe|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky %PIPE% on main>>"|dq=0 look=1 sent=1 strict=0
ampersand|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky & on main>>"|dq=0 look=1 sent=1 strict=0
bare|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED>>"|dq=0 look=1 sent=1 strict=0
empty-reason|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: >>"|dq=0 look=1 sent=1 strict=0
single-quoted|echo '<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky on main>>'|dq=0 look=0 sent=0 strict=0
chained-tail|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky on main>>" && rm -rf x|dq=0 look=0 sent=0 strict=0
longer-name|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTEDX: flaky on main>>"|dq=0 look=0 sent=0 strict=0
no-echo|"<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: flaky on main>>"|dq=0 look=0 sent=0 strict=0
unrunnable-form|echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 missing>>"|dq=0 look=0 sent=1 strict=1
ROWS
case_end

case_begin "regex-no-cross-match" "hooks/lib/sentinel-patterns.js"
# The UNRUNNABLE pair must not take the baseline form (the reverse is the unrunnable-form row above).
while IFS='|' read -r label cmd want; do
  [ -n "$label" ] || continue
  assert_eq "$label: $(rx ua "$cmd")" "$label: $want"
done <<'ROWS'
baseline-valid|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED: these fail on main too>>"|uadq=0 ualook=0
baseline-bare|echo "<<WORKFLOW_RUN_TESTS_BASELINE_ACCEPTED>>"|uadq=0 ualook=0
unrunnable-control|echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 missing>>"|uadq=1 ualook=1
ROWS
case_end

case_begin "regex-captures-the-reason" "hooks/lib/sentinel-patterns.js"
assert_eq "capture: $(rx reason "$(acc_cmd "$REASON_OK")")" "capture: reason=$REASON_OK"
assert_eq "capture keeps inner spaces: $(rx reason "$(acc_cmd "a  b c")")" "capture keeps inner spaces: reason=a  b c"
case_end
