# shellcheck shell=bash
# Tests: install/codegraph-mcp.js
# Tags: codegraph, installer, mcp-registration, fail-safe-off, idempotency, side-effect-absence, TL2, pwsh-not-required, scope:issue-specific
# O1-O21: readState() answers present/foreign/absent/null (see fixtures.sh
# build_home). A same-named entry matching hasOurShape() is "present" and is
# overwritten (register: remove-then-add) or removed (unregister); a
# different-shaped entry is "foreign" (O20/O21) and both verbs leave it
# untouched. An unreadable ~/.claude.json (null) must change nothing at all.
# Sourced by tests/feature-codegraph-bootstrap.sh after cases.sh.

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

    # with_cg=yes: these rows judge the registration decision, not the CLI version pin, and the
    # register verb probes `codegraph --version` first — a stub answering the pin
    # keeps that probe silent so `err` still measures only the ownership decision.
    run_case "$name" "$verb" on present "$mcp_pre" yes 0 0 yes file
    assert_eq "$name ($verb on '$mcp_pre'): observable outcome" "$want" "$SUMMARY"
    assert_note "$name ($verb on '$mcp_pre')" "$needle"
    assert_eq "$name: the mcpServers.codegraph entry after the run" "$post_entry" "$MCP_ENTRY_POST"
    assert_eq "$name: post/.claude.json byte-identical (every write is the CLI's)" \
        "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"
    assert_eq "$name: post/no sentinel leak" "" "${SENTINEL_STATE#*leaked=}"
done <<'TABLE'
# --- unregister: the "CODEGRAPH turned off" path ---
O1  | unregister | present     | 1 | rc=0 npmi=0 add=0 rm=1 mcp=1 err=0 | codegraph MCP server unregistered (CODEGRAPH is off).
O6  | unregister | none        | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O7  | unregister | nokey       | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O8  | unregister | missing     | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O9  | unregister | broken      | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
O10 | unregister | nonobject   | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
O21 | unregister | foreign     | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
# --- register: the mirror path. An existing entry is this user's own earlier
# install, so it is overwritten (remove-then-add), never left half-refreshed.
O15 | register   | nokey       | 0 | rc=0 npmi=0 add=1 rm=0 mcp=1 err=0 | codegraph MCP server registered.
O16 | register   | present     | 1 | rc=0 npmi=0 add=1 rm=1 mcp=2 err=0 | codegraph MCP server registered.
O17 | register   | broken      | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
TABLE

echo "--- O20: register on a foreign-shaped entry warns and leaves it untouched ---"
# warn() writes to stderr, not stdout — assert_note (generic table loop) only
# reads out.log, so this case needs its own err.log assertion instead.
run_case "O20" register on present foreign yes 0 0 yes file
assert_eq "O20: observable outcome (no add/remove, entry survives)" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
case "$(cat "$CASE_DIR/err.log" 2>/dev/null || true)" in
    *"already registered with a different command/args; leaving it as-is."*) pass "O20: stderr explains the decision" ;;
    *) fail "O20: stderr does not explain the decision — got $(printf '%q' "$(cat "$CASE_DIR/err.log" 2>/dev/null || true)")" ;;
esac
assert_eq "O20: the mcpServers.codegraph entry after the run" "1" "$MCP_ENTRY_POST"
assert_eq "O20: post/.claude.json byte-identical (foreign entry never touched)" \
    "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"

echo "--- O18: the refresh removes before it adds, with the SSOT env flags ---"
# Order is the contract: an add before the remove would leave the CLI rejecting a
# duplicate name, and the --env pair is what carries the shipped telemetry posture
# onto an older entry. `present` is the fixture: any existing entry is refreshed.
run_case "O18" register on present present no 0 0 yes file
assert_eq "O18: first claude argv is the removal" "$WANT_MCP_REMOVE" \
    "$(grep -m1 '^mcp ' "$CASE_DIR/claude.log" || true)"
assert_eq "O18: second claude argv is the add, carrying the telemetry env pair" "$WANT_MCP_ADD" \
    "$(grep '^mcp ' "$CASE_DIR/claude.log" | sed -n 2p || true)"

echo "--- O19: re-registering an existing entry is idempotent ---"
# Re-running the installer must not drift: the second pass has to reach the same
# verdict from the same input.
while IFS='|' read -r case_id verb mcp_pre; do
    [ -n "$case_id" ] || continue
    case_id="${case_id//[[:space:]]/}"; verb="${verb//[[:space:]]/}"; mcp_pre="${mcp_pre//[[:space:]]/}"
    run_case "$case_id-1" "$verb" on present "$mcp_pre" yes 0 0 yes file
    first_summary="$SUMMARY"; first_out="$(cat "$CASE_DIR/out.log" 2>/dev/null || true)"
    run_case "$case_id-2" "$verb" on present "$mcp_pre" yes 0 0 yes file
    assert_eq "$case_id: the second $verb repeats the first verdict" "$first_summary" "$SUMMARY"
    assert_eq "$case_id: the second $verb repeats the first explanation" \
        "$first_out" "$(cat "$CASE_DIR/out.log" 2>/dev/null || true)"
    assert_eq "$case_id: the first run really did produce a verdict to repeat" \
        "yes" "$([ -n "$first_out" ] && echo yes || echo no)"
done <<'TABLE'
O19-current  | register   | present
TABLE
