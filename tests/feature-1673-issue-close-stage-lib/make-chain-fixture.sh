#!/usr/bin/env bash
# tests/feature-1673-issue-close-stage-lib/make-chain-fixture.sh <fixture-root>
#
# Builds the fixture AGENTS_CONFIG_DIR and the PATH `gh` stub that the real
# skills/issue-close-stage/scripts/run-stage-chain.sh needs in order to run
# offline. Extracted from the test file only to keep it under the 300-line WARN.
#
# Produces:
#   <root>/fakeacd/bin/github-issues/issue-close-stage-triage.sh
#   <root>/fakeacd/bin/issue-close-gate.sh
#   <root>/fakeacd/bin/github-issues/parent-body-update.sh
#   <root>/ghbin/gh
#
# Behaviour is steered by env vars read at call time:
#   STUB_ACTION (default proceed)  STUB_STEPS (default B,D,F,G)
#   STUB_GATE_RC (default 0)       STUB_GH_API_RC (default 0)
set -eu

ROOT="${1:?fixture root required}"
mkdir -p "$ROOT/fakeacd/bin/github-issues" "$ROOT/ghbin"

cat > "$ROOT/fakeacd/bin/github-issues/issue-close-stage-triage.sh" <<'EOS'
#!/bin/bash
printf 'STATE=OPEN\nSENTINEL=\nACTION=%s\nNEXT_STEPS=%s\n' \
    "${STUB_ACTION:-proceed}" "${STUB_STEPS:-B,D,F,G}"
EOS

cat > "$ROOT/fakeacd/bin/issue-close-gate.sh" <<'EOS'
#!/bin/bash
exit "${STUB_GATE_RC:-0}"
EOS

cat > "$ROOT/fakeacd/bin/github-issues/parent-body-update.sh" <<'EOS'
#!/bin/bash
exit 0
EOS

cat > "$ROOT/ghbin/gh" <<'EOS'
#!/bin/bash
case "$1" in
    issue)
        if [ "$2" = "comment" ]; then
            echo "https://github.com/example-owner/example-repo/issues/12#issuecomment-987654"
            exit 0
        fi
        ;;
    api) exit "${STUB_GH_API_RC:-0}" ;;
esac
exit 0
EOS

chmod +x "$ROOT/fakeacd/bin/github-issues/issue-close-stage-triage.sh" \
    "$ROOT/fakeacd/bin/issue-close-gate.sh" \
    "$ROOT/fakeacd/bin/github-issues/parent-body-update.sh" \
    "$ROOT/ghbin/gh"
