#!/usr/bin/env bash
# tests/hooks/fix-shell-snapshot-windows-path/settings-registration.sh
# Tests: settings.json
# Tags: hook, shell-snapshot, settings, registration, scope:issue-specific, TL1
# Part of tests/hooks/fix-shell-snapshot-windows-path.sh (sourced by the dispatcher; uses its snap_js).
# Exactly one Bash-matcher group runs postuse-shell-snapshot-repair.js under PostToolUse and one
# under PostToolUseFailure; the existing PostToolUse[0] matcher is unchanged.
# TL3 gap (what this test does NOT catch):
# - Real CC dispatching these entries: PostToolUseFailure (error "Exit code 127\n…") and SessionStart.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

snap_js "settings" <<'JS'
const S = () => JSON.parse(fs.readFileSync(path.join(ROOT, 'settings.json'), 'utf8'));
const groupsFor = (event) => ((S().hooks || {})[event] || []).filter((g) => (g.hooks || []).some((h) => String(h.command).includes('postuse-shell-snapshot-repair.js')));
for (const event of ['PostToolUse', 'PostToolUseFailure']) {
  T(event + ': exactly one group runs postuse-shell-snapshot-repair.js with matcher Bash', () => {
    const gs = groupsFor(event);
    assert.equal(gs.length, 1, JSON.stringify(gs));
    assert.equal(gs[0].matcher, 'Bash');
    const hs = gs[0].hooks.filter((h) => String(h.command).includes('postuse-shell-snapshot-repair.js'));
    assert.equal(hs.length, 1);
    // Same command form as the registered session-start.js entry, only the file name differs.
    const ss = S().hooks.SessionStart.flatMap((g) => g.hooks || []).find((h) => String(h.command).includes('/hooks/session-start.js'));
    assert.equal(hs[0].command, ss.command.replace('session-start.js', 'postuse-shell-snapshot-repair.js'));
    assert.equal(hs[0].timeout, 5);
  });
}
T('PostToolUse[0].matcher unchanged', () => {
  assert.equal(S().hooks.PostToolUse[0].matcher, 'Bash|runInTerminal|runCommands');
});
JS
