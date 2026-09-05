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

    # with_cg=yes: these rows judge ownership, not the CLI version pin, and the
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
O2  | unregister | legacy      | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O3  | unregister | nomarker    | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O4  | unregister | foreigncmd  | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O5  | unregister | foreignargs | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O6  | unregister | none        | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O7  | unregister | nokey       | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O8  | unregister | missing     | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | __silent__
O9  | unregister | broken      | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
O10 | unregister | nonobject   | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
# --- register: the mirror path, so ownership is not read as "never touch anything" ---
O11 | register   | legacy      | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
O12 | register   | nomarker    | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
O13 | register   | foreigncmd  | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
O14 | register   | foreignargs | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
O15 | register   | nokey       | 0 | rc=0 npmi=0 add=1 rm=0 mcp=1 err=0 | codegraph MCP server registered.
O16 | register   | present     | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | codegraph MCP server already registered.
O17 | register   | broken      | 0 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=1 | __silent__
# --- ownership-marker fixture families (#2215): the marker is the ONLY evidence of
# authorship, so an entry lacking it is foreign on BOTH verbs however closely it
# resembles ours — legacyowned's exactly-pre-marker env is no longer adoptable, and
# neither are legacyplus/legacyhttp/nomarker/customenv. Only a MARKED entry
# (staleenv refreshable, ourenvplus already current) may be touched at all.
O24 | unregister | legacyowned | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O25 | register   | legacyowned | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
O26 | unregister | staleenv    | 1 | rc=0 npmi=0 add=0 rm=1 mcp=1 err=0 | codegraph MCP server unregistered (CODEGRAPH is off).
O27 | register   | staleenv    | 1 | rc=0 npmi=0 add=1 rm=1 mcp=2 err=0 | codegraph MCP server registered.
O28 | unregister | nomarker    | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O28b| unregister | legacyplus  | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O28c| unregister | legacyhttp  | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O28d| register   | legacyplus  | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
O28e| unregister | ourenvplus  | 1 | rc=0 npmi=0 add=0 rm=1 mcp=1 err=0 | codegraph MCP server unregistered (CODEGRAPH is off).
O28f| register   | ourenvplus  | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | codegraph MCP server already registered.
# --- O31: our exact shape, no marker, and an env that resembles the pre-marker pair
# in NO way at all (a hand-written entry carrying the author's own vars). The old
# env-equality adoption never saw this input; under marker-only ownership it is
# plainly foreign, and both verbs must leave it exactly as the person wrote it.
O31a| unregister | customenv   | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | does not carry this installer's registration marker; leaving it in place.
O31b| register   | customenv   | 1 | rc=0 npmi=0 add=0 rm=0 mcp=0 err=0 | registered with a command this installer did not write; leaving it unchanged.
TABLE

echo "--- O18: the refresh removes before it adds, with the SSOT env flags ---"
# Order is the contract: an add before the remove would leave the CLI rejecting a
# duplicate name, and the --env pair is what makes the new entry recognisably ours.
# staleenv is the fixture because refreshing now requires a MARKED entry (ours-stale)
# — an unmarked one is foreign and spawns nothing at all.
run_case "O18" register on present staleenv no 0 0 yes file
assert_eq "O18: first claude argv is the removal" "$WANT_MCP_REMOVE" \
    "$(grep -m1 '^mcp ' "$CASE_DIR/claude.log" || true)"
assert_eq "O18: second claude argv is the add, carrying the registration env (telemetry pair + owner marker)" "$WANT_MCP_ADD" \
    "$(grep '^mcp ' "$CASE_DIR/claude.log" | sed -n 2p || true)"

echo "--- O19: a declined unregister is idempotent, and so is an already-current register ---"
# Re-running the installer must not drift: the second pass has to reach the same
# verdict from the same input, or "leaving it in place" would only hold once.
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
O19-foreign  | unregister | foreigncmd
O19-legacy   | unregister | legacy
O19-current  | register   | present
TABLE

echo "--- O20/O21: an unreadable codegraph-constants.txt must fail closed, not fall through to 'current' ---"
# telemetryEnv() returns {} when codegraph-constants.txt is missing/malformed; a bare
# Object.keys({}).every(...) is vacuously true, so hasTelemetryOptOut would wrongly
# call ANY same-shape entry "current" — authorizing unregister() to remove a real
# registration it never proved ownership of. Each input class below gets its OWN
# mini installer tree via make_constants_tree(): hooks/lib/codegraph-boundary.js
# resolves the constants file relative to itself, so a shared hooks/lib copy would
# make every tree read the same codegraph-constants.txt and collapse "no constants"
# and "partial constants" into the same input (S2-11, [research: fixture-tree-collision]).
NO_CONSTANTS_JS="$(make_constants_tree fc-no-constants none)"

run_case "O20" unregister on present present no 0 0 yes file "$NO_CONSTANTS_JS"
assert_eq "O20 (unregister, unreadable constants): observable outcome" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
assert_note "O20 (unregister, unreadable constants)" "__silent__"
assert_eq "O20: a real registration survives an unknowable telemetry env" "1" "$MCP_ENTRY_POST"
assert_eq "O20: post/.claude.json byte-identical" "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"

run_case "O21" register on present legacy no 0 0 yes file "$NO_CONSTANTS_JS"
assert_eq "O21 (register, unreadable constants): observable outcome" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
assert_note "O21 (register, unreadable constants)" "__silent__"
assert_eq "O21: an existing entry is left alone, not refreshed on an unknowable env" "1" "$MCP_ENTRY_POST"
assert_eq "O21: post/.claude.json byte-identical" "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"

echo "--- O22/O23: a PARTIAL codegraph-constants.txt (one REGISTRATION_ENV_KEYS entry missing) must also fail closed ---"
# readState guards against an incomplete wantedEnv (S2-6: complete now means all of
# REGISTRATION_ENV_KEYS — the telemetry pair AND the owner marker, not just the
# telemetry pair). A file that yields just one of those three entries is neither
# empty nor complete, and a partial read must not authorize removing a registration
# whose full ownership was never proven.
PARTIAL_CONSTANTS_JS="$(make_constants_tree fc-partial-constants "CODEGRAPH_TELEMETRY=0")"

run_case "O22" unregister on present present no 0 0 yes file "$PARTIAL_CONSTANTS_JS"
assert_eq "O22 (unregister, partial constants): observable outcome" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
assert_note "O22 (unregister, partial constants)" "__silent__"
assert_eq "O22: a real registration survives a partially-unknowable telemetry env" "1" "$MCP_ENTRY_POST"
assert_eq "O22: post/.claude.json byte-identical" "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"

run_case "O23" register on present legacy no 0 0 yes file "$PARTIAL_CONSTANTS_JS"
assert_eq "O23 (register, partial constants): observable outcome" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
assert_note "O23 (register, partial constants)" "__silent__"
assert_eq "O23: an existing entry is left alone, not refreshed on a partially-unknowable env" "1" "$MCP_ENTRY_POST"
assert_eq "O23: post/.claude.json byte-identical" "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"

echo "--- O29: the telemetry pair is complete but the owner marker KEY itself is missing ---"
# S2-6 redefines "complete" as all of REGISTRATION_ENV_KEYS (telemetry pair + owner
# marker), not just the telemetry pair. A constants file that ships both telemetry
# keys but omits the marker key entirely must still fall to null (fail closed),
# proving the redefinition — under the old TELEMETRY_KEYS-only guard this input
# would have read as "complete" and wrongly authorized a same-shape verdict.
MARKER_MISSING_JS="$(make_constants_tree fc-marker-missing "$(printf 'CODEGRAPH_TELEMETRY=%s\nDO_NOT_TRACK=%s' "$CG_TELEMETRY" "$CG_DNT")")"

run_case "O29" unregister on present present no 0 0 yes file "$MARKER_MISSING_JS"
assert_eq "O29 (unregister, marker key missing): observable outcome" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
assert_note "O29 (unregister, marker key missing)" "__silent__"
assert_eq "O29: a real registration survives a marker-missing constants file" "1" "$MCP_ENTRY_POST"
assert_eq "O29: post/.claude.json byte-identical" "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"

echo "--- O29b: the owner marker KEY is present but its VALUE is empty (round-7 codex C8) ---"
# S2-6 also requires every REGISTRATION_ENV_KEYS value to be non-empty. A constants
# file shipping AGENTS_CODEGRAPH_MCP_OWNER= (empty) must fall to null exactly like a
# missing key would — an empty marker is a positive-evidence assertion (S2-5) with
# no evidence in it, and a shipped write of `--env AGENTS_CODEGRAPH_MCP_OWNER=` would
# also misidentify a third party's own empty-marker registration as ours. Exercised
# on BOTH verbs: dropping the empty-value guard from S2-6 turns either one red.
EMPTY_MARKER_JS="$(make_constants_tree fc-empty-marker "$(printf 'CODEGRAPH_TELEMETRY=%s\nDO_NOT_TRACK=%s\n%s=' "$CG_TELEMETRY" "$CG_DNT" "$CG_OWNER_KEY")")"

run_case "O29b-unregister" unregister on present present no 0 0 yes file "$EMPTY_MARKER_JS"
assert_eq "O29b-unregister (empty marker value): observable outcome" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
assert_note "O29b-unregister (empty marker value)" "__silent__"
assert_eq "O29b-unregister: a real registration survives an empty marker value" "1" "$MCP_ENTRY_POST"
assert_eq "O29b-unregister: post/.claude.json byte-identical" "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"

run_case "O29b-register" register on present legacy no 0 0 yes file "$EMPTY_MARKER_JS"
assert_eq "O29b-register (empty marker value): observable outcome" \
    "rc=0 npmi=0 add=0 rm=0 mcp=0 err=1" "$SUMMARY"
assert_note "O29b-register (empty marker value)" "__silent__"
assert_eq "O29b-register: an existing entry is left alone when the marker value is empty" "1" "$MCP_ENTRY_POST"
assert_eq "O29b-register: post/.claude.json byte-identical" "$PRE_JSON_SHA" "$(digest "$FAKE_HOME/.claude.json")"
