# shellcheck shell=bash
# Tests: hooks/lib/sentinel-patterns.js, hooks/workflow-state/state-io/core.js, settings.json, hooks/workflow-gate.js, docs/architecture/claude-code/workflow.md
# Tags: tl1, workflow, run-tests, docs-only, registration-sites, scope:issue-specific
# Static (TL1) registration sites 1-4 and 8. Sourced by the dispatcher.

# Site 1 — sentinel-patterns.js must register the new sentinel in all THREE
# places it exposes a sentinel: isSentinel(), isStrictSentinel(), module.exports.
# Split into one case per place: dropping one is the typical asymmetric bug.
site1_sentinel_patterns() {
  local out
  out="$(SP_MOD="$AGENTS_DIR_N/hooks/lib/sentinel-patterns" \
    run_with_timeout node -e '
const sp = require(process.env.SP_MOD);
const ok = (v) => (v ? "yes" : "no");
const good = String.raw`echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: staged set is human-facing docs only>>"`;
const bare = String.raw`echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED>>"`;
process.stdout.write([
  "isSentinel_good=" + ok(sp.isSentinel(good)),
  "isSentinel_bare=" + ok(sp.isSentinel(bare)),
  "isStrict_good=" + ok(sp.isStrictSentinel(good)),
  "export_dq=" + ok(sp.RUN_TESTS_NOT_NEEDED_RE_DQ instanceof RegExp),
  "export_lookslike=" + ok(sp.RUN_TESTS_NOT_NEEDED_LOOKSLIKE_RE instanceof RegExp),
  "dq_captures_reason=" + ok(sp.RUN_TESTS_NOT_NEEDED_RE_DQ
    && (good.match(sp.RUN_TESTS_NOT_NEEDED_RE_DQ) || [])[1] === "staged set is human-facing docs only"),
].join("\n") + "\n");
' 2>&1)"
  check_contains "R1a site1 isSentinel() recognizes the well-formed sentinel" "isSentinel_good=yes" "$out"
  check_contains "R1b site1 isSentinel() recognizes the malformed (LOOKSLIKE) form" "isSentinel_bare=yes" "$out"
  check_contains "R1c site1 isStrictSentinel() recognizes the well-formed sentinel" "isStrict_good=yes" "$out"
  check_contains "R1d site1 module.exports exposes RUN_TESTS_NOT_NEEDED_RE_DQ" "export_dq=yes" "$out"
  check_contains "R1e site1 module.exports exposes RUN_TESTS_NOT_NEEDED_LOOKSLIKE_RE" "export_lookslike=yes" "$out"
  check_contains "R1f site1 strict regex captures the reason group" "dq_captures_reason=yes" "$out"
}

# Site 2 — SKIPPABLE_STEPS. Without it the commit gate can never accept a
# run_tests recorded as skipped (#926-shaped permanent block).
site2_skippable_steps() {
  local out
  out="$(WFSTATE_MODULE="$WFSTATE_MODULE" run_with_timeout node -e '
const w = require(process.env.WFSTATE_MODULE);
process.stdout.write(
  "static=" + (w.SKIPPABLE_STEPS.indexOf("run_tests") !== -1 ? "yes" : "no") + "\n" +
  "resolved=" + (w.getSkippableSteps("r2-sid").indexOf("run_tests") !== -1 ? "yes" : "no") + "\n"
);
' 2>&1)"
  check_contains "R2a site2 SKIPPABLE_STEPS contains run_tests" "static=yes" "$out"
  check_contains "R2b site2 getSkippableSteps() resolves run_tests as skippable" "resolved=yes" "$out"
}

# Site 3 — settings.json permission entry. docs-only is a machine-verifiable
# fact, so the entry belongs in `allow`; its presence in `ask`/`deny` would mean
# the path was registered under the wrong approval semantics.
site3_settings_permissions() {
  local out
  out="$(SETTINGS="$AGENTS_DIR_N/settings.json" run_with_timeout node -e '
const s = require(process.env.SETTINGS);
const want = "Bash(echo \"<<WORKFLOW_RUN_TESTS_NOT_NEEDED: *>>\")";
const has = (k) => (((s.permissions || {})[k] || []).indexOf(want) !== -1 ? "yes" : "no");
process.stdout.write("allow=" + has("allow") + "\nask=" + has("ask") + "\ndeny=" + has("deny") + "\n");
' 2>&1)"
  check_contains "R3a site3 settings.json permissions.allow carries the sentinel entry" "allow=yes" "$out"
  check_contains "R3b site3 the entry is NOT in permissions.ask" "ask=no" "$out"
  check_contains "R3c site3 the entry is NOT in permissions.deny" "deny=no" "$out"
}

# Site 4 — workflow-gate.js SKILL_MAP.run_tests. Without the guidance line the
# sentinel exists but a blocked session is never told it may emit it.
site4_skill_map() {
  local line
  line="$(grep -n "^    run_tests: " "$AGENTS_DIR/hooks/workflow-gate.js" || true)"
  check_contains "R4 site4 SKILL_MAP.run_tests names the sentinel literal" "$SENTINEL_LITERAL" "$line"
}

# Site 8 — docs/architecture/claude-code/workflow.md, all three places.
site8_docs() {
  local doc="$AGENTS_DIR/docs/architecture/claude-code/workflow.md"
  local skippable_line notskippable_lines run_tests_row
  skippable_line="$(grep -n '^- `skipped`: allowed for the `SKIPPABLE_STEPS` set' "$doc" || true)"
  notskippable_lines="$(grep -n 'cannot be `skipped`' "$doc" || true)"
  run_tests_row="$(grep -n '^| `run_tests` |' "$doc" || true)"
  check_contains "R8a site8 workflow.md SKIPPABLE_STEPS prose lists run_tests" \
    '`run_tests`' "$skippable_line"
  check_not_contains "R8b site8 workflow.md not-allowed list does NOT list run_tests" \
    'run_tests' "$notskippable_lines"
  check_contains "R8c site8 workflow.md run_tests step row documents the skip sentinel" \
    "$SENTINEL_LITERAL" "$run_tests_row"
}

run_static_site_cases() {
  site1_sentinel_patterns
  site2_skippable_steps
  site3_settings_permissions
  site4_skill_map
  site8_docs
}
