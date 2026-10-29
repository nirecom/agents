#!/usr/bin/env bash
# Tests: hooks/pre-commit, .github/workflows/migration-blocks-audit.yml
# Tags: scope:issue-specific, TL2, plans-dir-lint, feature-2434, plans-dir, pwsh-not-required
# Part file of tests/bin/feature-2434-plans-dir-lint.sh (sourced; uses its T, LINT,
# make_tree and check helpers). Consumers surface an unregistered detection (C5).

# The static checks in lint.sh prove each consumer names the lint; these run it. A
# throwaway agents repo holds the real lint, its libraries and one source file that
# spells an unregistered PLANS name. Each consumer must fail AND print the lint's
# diagnostic, so a swallowed stdout or a stray `|| true` cannot pass. The other agents-repo
# gates fail closed when absent (#2589), so each is a clean stub module (#2507).
CONS="$T/consumer-repo"
CONS_BAD='new-state.json'
make_tree "$CONS"
[ -f "$LINT" ] && cp "$LINT" "$CONS/bin/check-plans-artifacts"
[ -d "$SCRIPT_CHECKOUT_ROOT/bin/lib" ] && cp -r "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$CONS/bin/lib"
cp -r "$SCRIPT_CHECKOUT_ROOT/hooks/lib" "$CONS/hooks/lib"
[ -d "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state" ] && cp -r "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state" "$CONS/hooks/workflow-state"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/node-entry-sandbox.sh"
node_entry_sandbox_copy "$CONS" hooks/pre-commit.d/main.js >/dev/null
for _cons_gate in bin/lib/check-on-demand-rules.js bin/check-session-id-ssot/main.js bin/lib/check-migration-blocks.js \
    bin/check-plans-dir-isolation/main.js bin/check-root-names/main.js; do
  mkdir -p "$(dirname "$CONS/$_cons_gate")"
  printf 'exports.run = async () => 0;\n' > "$CONS/$_cons_gate"
done
printf '%s\n' '#!/usr/bin/env bash' "cat \"\$PLANS_DIR/\$SID-$CONS_BAD\"" > "$CONS/bin/consumer-probe.sh"
git -C "$CONS" init -q
git -C "$CONS" config core.hooksPath /dev/null
git -C "$CONS" config core.autocrlf false
git -C "$CONS" config user.email "test@example.com"
git -C "$CONS" config user.name "Test"
git -C "$CONS" add -A

case_begin "precommit-gate-surfaces-unregistered" "hooks/pre-commit"
PC_RC=0
PC_OUT="$(cd "$CONS" && run_with_timeout 60 node "$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/precommit-check-runner.js")" --cfg "$(np "$CONS")" agents-repo-gates 2>&1)" || PC_RC=$?
check "pre-commit: an unregistered PLANS name in source blocks the commit (exit 1)" "1" "$PC_RC"
check "pre-commit: the blocked commit shows the lint's diagnostic naming the file" "yes" \
  "$(printf '%s\n' "$PC_OUT" | grep -qF "$CONS_BAD" && printf yes || printf no)"
check "pre-commit: the diagnostic names the offending source file" "yes" \
  "$(printf '%s\n' "$PC_OUT" | grep -qF 'consumer-probe.sh' && printf yes || printf no)"
case_end

case_begin "ci-audit-step-surfaces-unregistered" ".github/workflows/migration-blocks-audit.yml"
# Run the workflow's own run: line (not a copy of it) the way the job does: from
# the checkout root with AGENTS_MAIN_ROOT set to the workspace.
YML="$SCRIPT_CHECKOUT_ROOT/.github/workflows/migration-blocks-audit.yml"
CI_CMD="$(grep -E '^[[:space:]]*run:[[:space:]]*[^|>].*check-plans-artifacts' "$YML" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*run:[[:space:]]*//')"
if [ -z "$CI_CMD" ]; then
  fail "ci-audit: migration-blocks-audit.yml has a one-line run: step calling check-plans-artifacts" "implementation missing"
else
  CI_RC=0
  CI_OUT="$(cd "$CONS" && export AGENTS_MAIN_ROOT="$CONS" && run_with_timeout 60 bash -c "$CI_CMD" 2>&1)" || CI_RC=$?
  check "ci-audit: the lint step fails on an unregistered PLANS name" "1" "$CI_RC"
  check "ci-audit: the job log shows the diagnostic naming the file" "yes" \
    "$(printf '%s\n' "$CI_OUT" | grep -qF "$CONS_BAD" && printf yes || printf no)"
fi
check "ci-audit: no step is allowed to fail silently (continue-on-error)" "no" \
  "$(grep -Eq 'continue-on-error:[[:space:]]*true' "$YML" 2>/dev/null && printf yes || printf no)"
case_end
true
