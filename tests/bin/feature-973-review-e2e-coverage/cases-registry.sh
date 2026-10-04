# Case 18 (#2500): E2E candidates are the registry's test files, not a literal *.sh list.
# The fixture repo's bash entry is re-patterned to *.bash: a compliant tests/*.bash file then
# covers its hook, and a compliant tests/*.sh file no longer counts.

repo_native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

REPO18=$(make_repo)
git -C "$REPO18" checkout -q -b feature18
node -e 'const f=require("fs");const t=JSON.parse(f.readFileSync(process.argv[1],"utf8"));
  const e=t.entries.find((x)=>x.patterns.includes("*.sh"));
  e.patterns=["*.bash"];e.nameStrip.suffix=".bash";
  if(e.diagnostics&&e.diagnostics.nameLabel)e.diagnostics.nameLabel=".bash";
  f.writeFileSync(process.argv[1],JSON.stringify(t,null,2));' "$(repo_native "$REPO18/hooks/lib/test-language-registry.json")"
if node "$(repo_native "$REPO18/bin/test-language-registry")" --format shell >/dev/null 2>&1; then
    pass "Case 18: re-patterned fixture registry validates"
else
    fail "Case 18: re-patterned fixture registry does not validate"
fi
write_hook_stub "$REPO18" "stop-confirm-plan-guard.js"
write_e2e_test_for_hook "$REPO18/tests/feature-18-stop-confirm-plan-guard-e2e.bash" "stop-confirm-plan-guard"
write_hook_stub "$REPO18" "subagent-start.js"
write_e2e_test_for_hook "$REPO18/tests/feature-18-subagent-start-e2e.sh" "subagent-start"
git -C "$REPO18" add -A
git -C "$REPO18" commit -q -m "two hooks; E2E as *.bash (registry pattern) and *.sh (no longer one)"

EXIT_CODE=0
OUTPUT=$(run_script "$REPO18" --base main) || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Case 18: exits 0"
else
    fail "Case 18: expected exit 0, got $EXIT_CODE. Output: $OUTPUT"
fi
if echo "$OUTPUT" | grep -q "WARN.*stop-confirm-plan-guard"; then
    fail "Case 18: E2E file matching the registry pattern (*.bash) not counted as coverage. Output: $OUTPUT"
else
    pass "Case 18: E2E file matching the registry pattern counts as coverage"
fi
if echo "$OUTPUT" | grep -q "WARN.*subagent-start"; then
    pass "Case 18: *.sh file outside the registry patterns is not an E2E candidate"
else
    fail "Case 18: *.sh file counted although the registry no longer lists *.sh. Output: $OUTPUT"
fi
