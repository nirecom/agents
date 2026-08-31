# shellcheck shell=bash
# Tests: install/codegraph-mcp.js
# Tags: codegraph, installer, mcp-registration, ownership, fail-safe-off, idempotency, side-effect-absence, TL2, pwsh-not-required, scope:issue-specific
# O1-O19 (#2150 security review): unregister removes ONLY a registration this
# installer wrote. "CODEGRAPH turned off" must never delete a `codegraph` MCP entry
# a person or another tool put there, and an unreadable ~/.claude.json must change
# nothing at all. Sourced by tests/feature-codegraph-bootstrap.sh after cases.sh.

assert_note() {
    local name="$1" needle="$2" out; out="$(cat "$CASE_DIR/out.log" 2>/dev/null || true)"
    if [ "$needle" = "__silent__" ]; then
        assert_eq "$name: stdout says nothing (absent registration is a silent no-op)" "" "$out"
    else
        case "$out" in
            *"$needle"*) pass "$name: stdout explains the decision ($needle)" ;;
            *) fail "$name: stdout does not explain the decision — want substring $(printf '%q' "$needle") got $(printf '%q' "$out")" ;;
        esac
    fi
}

# Pattern 1 (negative assertion): every "not removed" row asserts rm=0 AND that the
# entry is still in ~/.claude.json afterwards. rm=0 is the load-bearing half — the
# `claude` CLI is a recording stub, so it never rewrites the file — while the
# post-state read catches a helper that deleted the entry behind the CLI's back.
# Columns: name | verb | mcp-pre | post-entry | want | stdout-needle.
while IFS='|' read -r name verb mcp_pre post_entry want needle; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"; verb="${verb//[[:space:]]/}"
    mcp_pre="${mcp_pre//[[:space:]]/}"; post_entry="${post_entry//[[:space:]]/}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
    needle="${needle#"${needle%%[![:space:]]*}"}"; needle="${needle%"${needle##*[![:space:]]}"}"

    run_case "$name" "$verb" on present "$mcp_pre" no 0 0 yes file
    assert_eq "$name ($verb on '$mcp_pre'): observable outcome" "$want" "$SUMMARY"
    assert_note "$name ($verb on '$mcp_pre')" "$needle"
    assert_eq "$name: the mcpServers.codegraph entry after the run" "$post_entry" "$MCP_ENTRY_POST"
    assert_eq "$name: post/.claude.json byte-identical (every write is the CLI's)" \
        "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"
    assert_eq "$name: post/no sentinel leak" "" "${SENTINEL_STATE#*leaked=}"
done <<'TABLE'
# --- unregister: the "CODEGRAPH turned off" path ---
O1  | unregister | present     | 1 | rc=0 npmi=0 add=0 rm=1 mcp=1 err=0 | codegraph MCP server unregistered (CODEGRAPH is off).
O2  | unregister | legacy      | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O3  | unregister | badenv      | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O4  | unregister | foreigncmd  | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O5  | unregister | foreignargs | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O6  | unregister | none        | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O7  | unregister | nokey       | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O8  | unregister | missing     | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O9  | unregister | broken      | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
O10 | unregister | nonobject   | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
# --- register: the mirror path, so ownership is not read as "never touch anything" ---
O11 | register   | legacy      | 1 | rc=0 npmi=0 add=1 rm=1 mcp=2 err=0 | codegraph MCP server registered.
O12 | register   | badenv      | 1 | rc=0 npmi=0 add=1 rm=1 mcp=2 err=0 | codegraph MCP server registered.
O13 | register   | foreigncmd  | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
O14 | register   | foreignargs | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
O15 | register   | nokey       | 0 | rc=0 npmi=0 add=1 rm=0 mcp=1 err=0 | codegraph MCP server registered.
O16 | register   | present     | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | codegraph MCP server already registered.
O17 | register   | broken      | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
TABLE

echo "--- O18: the replaceable refresh removes before it adds, with the SSOT env flags ---"
# Order is the contract: an add before the remove would leave the CLI rejecting a
# duplicate name, and the --env pair is what makes the new entry recognisably ours.
run_case "O18" register on present legacy no 0 0 yes file
assert_eq "O18: first claude argv is the removal" "$WANT_MCP_REMOVE" \
    "$(grep -m1 '^mcp ' "$CASE_DIR/claude.log" || true)"
assert_eq "O18: second claude argv is the add, carrying the telemetry opt-out" "$WANT_MCP_ADD" \
    "$(grep '^mcp ' "$CASE_DIR/claude.log" | sed -n 2p || true)"

echo "--- O19: a declined unregister is idempotent, and so is an already-current register ---"
# Re-running the installer must not drift: the second pass has to reach the same
# verdict from the same input, or "leaving it in place" would only hold once.
while IFS='|' read -r case_id verb mcp_pre; do
    [ -n "$case_id" ] || continue
    case_id="${case_id//[[:space:]]/}"; verb="${verb//[[:space:]]/}"; mcp_pre="${mcp_pre//[[:space:]]/}"
    run_case "$case_id-1" "$verb" on present "$mcp_pre" no 0 0 yes file
    first_summary="$SUMMARY"; first_out="$(cat "$CASE_DIR/out.log" 2>/dev/null || true)"
    run_case "$case_id-2" "$verb" on present "$mcp_pre" no 0 0 yes file
    assert_eq "$case_id: the second $verb repeats the first verdict" "$first_summary" "$SUMMARY"
    assert_eq "$case_id: the second $verb repeats the first explanation" \
        "$first_out" "$(cat "$CASE_DIR/out.log" 2>/dev/null || true)"
    assert_eq "$case_id: the first run really did produce a verdict to repeat" \
        "yes" "$([ -n "$first_out" ] && echo yes || echo no)"
done <<'TABLE'
O19-foreign  | unregister | foreigncmd
O19-legacy   | unregister | legacy
O19-current  | register   | present
TABLE
