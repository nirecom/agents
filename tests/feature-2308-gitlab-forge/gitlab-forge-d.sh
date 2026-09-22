#!/bin/bash
# Tests: hooks/lib/is-private-repo.js
# Tags: scope:issue-specific, gitlab, forge, TL2
set -u

# Issue #2308 — Group D: shouldScanAsPublicTarget 3-branch forge routing.
# Split from gitlab-forge-abc.sh (was 535 lines; rules/coding/file-split.md Pattern A).

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Group D: shouldScanAsPublicTarget(ownerRepo, command) 3-branch forge routing.
# Branch 1 (!command || trackerGithub.isForgeScanTarget) -> codehostGithub;
# branch 2 (trackerGitlab.isForgeScanTarget) -> codehostGitlab; branch 3 (else) ->
# return true (fail-closed) with NO codehost call. Discriminator: prime gh and
# glab to give OPPOSITE verdicts so the returned value alone reveals which (if
# any) codehost was consulted. glab-mock.js additionally logs to GLAB_MOCK_LOG.
echo ""
echo "=== Group D: shouldScanAsPublicTarget 3-branch forge routing ==="

GLAB_D_LOG="$TMPROOT/glab-d.log"
export GLAB_MOCK_LOG="$GLAB_D_LOG"

# call_sspt <ownerRepo> <command|__EMPTY__> -> "true"/"false"/ERR (glab on PATH).
call_sspt() {
    PATH="$MOCK_BIN:$PATH" run_with_timeout 20 node -e '
const { shouldScanAsPublicTarget } = require(process.argv[1]);
let cmd = process.argv[3];
if (cmd === "__EMPTY__") cmd = "";
let r;
try { r = shouldScanAsPublicTarget(process.argv[2], cmd); }
catch (e) { process.stdout.write("ERR:threw:" + e.message); process.exit(0); }
process.stdout.write(String(r));
' "$IPR_JS" "$1" "$2" 2>/dev/null
}

# D1: gh scan-target command -> GitHub codehost. gh=private(true) -> false; glab
# (public) would give true, so false proves the github branch ran; glab NOT called.
: > "$GLAB_D_LOG"
setup_mock_gh true
GLAB_MOCK_VISIBILITY=public; export GLAB_MOCK_VISIBILITY
d1="$(call_sspt 'acme/widgets' 'gh pr create --title x --body y')"
if [ "$d1" = "false" ] && [ ! -s "$GLAB_D_LOG" ]; then
    pass "D1/gh scan-target -> GitHub codehost (private->false), glab NOT called"
else
    fail "D1/gh scan-target -> GitHub codehost — want false + no glab (got=$d1 glab-log=[$(cat "$GLAB_D_LOG" 2>/dev/null)])"
fi

# D2: glab scan-target command -> GitLab codehost. glab=private -> false; gh
# (public/false) would give true, so false proves the gitlab branch ran; glab
# MUST be consulted (non-empty log).
: > "$GLAB_D_LOG"
setup_mock_gh false
GLAB_MOCK_VISIBILITY=private; export GLAB_MOCK_VISIBILITY
d2="$(call_sspt 'acme/widgets' 'glab mr create --title x --description y')"
if [ "$d2" = "false" ] && [ -s "$GLAB_D_LOG" ]; then
    pass "D2/glab scan-target -> GitLab codehost (private->false), glab consulted"
else
    fail "D2/glab scan-target -> GitLab codehost — want false + glab consulted (got=$d2 glab-log=[$(cat "$GLAB_D_LOG" 2>/dev/null)])"
fi

# D3: unknown/non-forge command -> fail-closed true WITHOUT consulting either
# codehost. Both are primed to return false (gh private, glab private); a true
# result proves neither was called (branch 3).
: > "$GLAB_D_LOG"
setup_mock_gh true
GLAB_MOCK_VISIBILITY=private; export GLAB_MOCK_VISIBILITY
d3="$(call_sspt 'acme/widgets' 'echo hello')"
if [ "$d3" = "true" ] && [ ! -s "$GLAB_D_LOG" ]; then
    pass "D3/unknown command -> fail-closed true, neither codehost consulted"
else
    fail "D3/unknown command -> fail-closed — want true + no glab (got=$d3 glab-log=[$(cat "$GLAB_D_LOG" 2>/dev/null)])"
fi

# D4: empty command -> branch 1 (!command) -> GitHub codehost. gh=public(false) ->
# true; glab (private) would give false, so true proves the github branch ran on
# an empty command; glab NOT called.
: > "$GLAB_D_LOG"
setup_mock_gh false
GLAB_MOCK_VISIBILITY=private; export GLAB_MOCK_VISIBILITY
d4="$(call_sspt 'acme/widgets' '__EMPTY__')"
if [ "$d4" = "true" ] && [ ! -s "$GLAB_D_LOG" ]; then
    pass "D4/empty command -> GitHub codehost (public->true), glab NOT called"
else
    fail "D4/empty command -> GitHub codehost — want true + no glab (got=$d4 glab-log=[$(cat "$GLAB_D_LOG" 2>/dev/null)])"
fi

unset GLAB_MOCK_VISIBILITY
rm -f "$MOCK_BIN/gh" "$MOCK_BIN/gh.cmd"

finish
