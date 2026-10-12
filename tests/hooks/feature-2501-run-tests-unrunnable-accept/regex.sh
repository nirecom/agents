# shellcheck shell=bash
# tests/hooks/feature-2501-run-tests-unrunnable-accept/regex.sh
# Tests: hooks/lib/sentinel-patterns.js
# Tags: TL1, hooks, sentinel, regex, parser, security, scope:issue-specific
# The sentinel's two regexes (#2501 D5-7): RUN_TESTS_UNRUNNABLE_ACCEPTED_RE_DQ takes the
# WARNINGS_ACCEPTED reason charset [^>()`;|&]+; _LOOKSLIKE_RE catches the malformed forms; both are
# in isSentinel and only the strict one in isStrictSentinel. Sourced by the dispatcher.

echo ""
echo "=== regex: RUN_TESTS_UNRUNNABLE_ACCEPTED_RE_DQ / _LOOKSLIKE_RE ==="

# rx.js <sentinel-patterns.js> <cls|reason> <command> — one canonical line for the command.
cat >"$T/rx.js" <<'EOF'
const m = require(process.argv[2]);
const [mode, cmd] = process.argv.slice(3);
const dq = m.RUN_TESTS_UNRUNNABLE_ACCEPTED_RE_DQ;
const look = m.RUN_TESTS_UNRUNNABLE_ACCEPTED_LOOKSLIKE_RE;
const bit = (re) => (re instanceof RegExp ? (re.test(cmd) ? 1 : 0) : "missing");
if (mode === "cls") {
  console.log(`dq=${bit(dq)} look=${bit(look)} sent=${m.isSentinel(cmd) ? 1 : 0} strict=${m.isStrictSentinel(cmd) ? 1 : 0}`);
} else {
  const r = dq instanceof RegExp ? cmd.match(dq) : null;
  console.log(r ? `reason=${r[1]}` : "reason=(nomatch)");
}
EOF

rx() { run_with_timeout 30 node "$T/rx.js" "$SP_JS" "$@" 2>/dev/null | tr -d '\r' || printf '<error>'; }

case_begin "regex-classifies-forms" "hooks/lib/sentinel-patterns.js"
# Table: <label>~<command>~<dq look isSentinel isStrictSentinel>.
while IFS='~' read -r label cmd want; do
  [ -n "$label" ] || continue
  assert_eq "$label: $(rx cls "$cmd")" "$label: $want"
done <<'ROWS'
valid~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 cannot be installed here>>"~dq=1 look=1 sent=1 strict=1
valid-runtime-label~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: no Pester=5.0 on this host, uv too>>"~dq=1 look=1 sent=1 strict=1
gt~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester>=5.0 missing>>"~dq=0 look=1 sent=1 strict=0
open-paren~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 (CI only)>>"~dq=0 look=1 sent=1 strict=0
backtick~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester `5` missing>>"~dq=0 look=1 sent=1 strict=0
semicolon~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5; not here>>"~dq=0 look=1 sent=1 strict=0
pipe~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 | not here>>"~dq=0 look=1 sent=1 strict=0
ampersand~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 & uv missing>>"~dq=0 look=1 sent=1 strict=0
bare~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED>>"~dq=0 look=1 sent=1 strict=0
empty-reason~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: >>"~dq=0 look=1 sent=1 strict=0
single-quoted~echo '<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 missing>>'~dq=0 look=0 sent=0 strict=0
chained-tail~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 missing>>" && rm -rf x~dq=0 look=0 sent=0 strict=0
longer-name~echo "<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTEDX: Pester 5 missing>>"~dq=0 look=0 sent=0 strict=0
no-echo~"<<WORKFLOW_RUN_TESTS_UNRUNNABLE_ACCEPTED: Pester 5 missing>>"~dq=0 look=0 sent=0 strict=0
ROWS
case_end

case_begin "regex-captures-the-reason" "hooks/lib/sentinel-patterns.js"
assert_eq "capture: $(rx reason "$(acc_cmd "$REASON_OK")")" "capture: reason=$REASON_OK"
assert_eq "capture keeps inner spaces: $(rx reason "$(acc_cmd "a  b c")")" "capture keeps inner spaces: reason=a  b c"
case_end
