# Static cases (R24) for feat-2511-state-root-routing.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

c_r24_static() {
  local hits
  hits="$(grep -rlE '\bgetWorkflowDir\b' "$AGENTS_DIR/hooks" "$AGENTS_DIR/bin" --include='*.js' --include='*.sh' \
    --include='*.cjs' 2>/dev/null || true)"
  eq "R24 no getWorkflowDir remains under hooks/ and bin/" "$hits" ""
  hits="$(grep -rlF 'withStateLock(getStatePath(' "$AGENTS_DIR/hooks/lib/supervisor-state-writer" 2>/dev/null || true)"
  eq "R24 no withStateLock(getStatePath( remains in supervisor-state-writer" "$hits" ""
  eq "R24 state-root.js exists" "$(test -f "$AGENTS_DIR/hooks/workflow-state/state-io/state-root.js" && echo yes)" "yes"
  eq "R24 state-root.js carries one temporary routing block per side (BEGIN/END pairs)" \
    "$(grep -c 'BEGIN temporary: ~/.claude/projects/workflow -> ~/.workflow-state migration' \
      "$AGENTS_DIR/hooks/workflow-state/state-io/state-root.js" 2>/dev/null || true)" "2"
}
