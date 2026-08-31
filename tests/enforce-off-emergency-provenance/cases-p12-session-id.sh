# tests/enforce-off-emergency-provenance/cases-p12-session-id.sh
# P12: the session id decides the marker's PATH, so it is attacker surface -
# traversal, malformed-character rejection, the well-formed control, and the
# env-fallback resolution route. Sourced by ../enforce-off-emergency-provenance.sh;
# relies on that file's shared helpers (submit_prompt, submit_prompt_env,
# submit_prompt_sidless, marker_of, TMP, MARKER_KIND, etc.).
# Tests: hooks/record-off-skill-invocation.js, hooks/lib/off-emergency-provenance.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js, settings.json
# Tags: off-clearance, emergency-off, provenance, audit, userpromptsubmit, session-marker, security, scope:common, pwsh-not-required, TL2, hook-registration

run_P12_session_id() {
# P12a: an empty session id must not become the dotfile `.off-emergency-invoked`.
# It is falsy, so the recorder falls back to env resolution instead - pinned with
# the env var SET, so the case cannot wander into the transcript-scan last resort
# and resolve whichever session the host happened to run most recently.
sid=pv12empty
rm -f "$(marker_of "$sid")"
submit_prompt_env CLAUDE_CODE_SESSION_ID "$sid" "" "/enforce-workflow-off empty session id"
assert_absent "P12a an empty session id mints no bare .$MARKER_KIND" "$TMP/.$MARKER_KIND"
assert_file "P12a an empty session id falls back to the resolved one" "$(marker_of "$sid")"
assert_eq "P12a an empty session id does not crash the recorder" "0" "$LAST_RECORDER_STATUS"
rm -f "$(marker_of "$sid")"

# P12b: traversal. SID_RE (^[A-Za-z0-9_-]+$) is the only thing between a hostile
# payload and an arbitrary path, so both separator spellings are pinned - a
# Windows host resolves `\` as a separator too (a filesystem-root write from a
# path.resolve-style regression on `/evil` is out of scope: scanning real root
# is impractical in a test suite). The recorder runs from a leaf nested INSIDE
# $TMP, so the swept ancestor tree stays fixture-owned per
# rules/test/fixture-isolation.md instead of walking the real filesystem root.
P12B_LEAF="$TMP/p12b-nest/a/b"
mkdir -p "$P12B_LEAF"
P12B_WF="$(node_path "$P12B_LEAF")"
P12B_GRANDPARENT="$(cd "$P12B_LEAF/../.." && pwd)"

# submit_prompt_p12b <sid>: same synthetic UserPromptSubmit as submit_prompt,
# but run from the nested leaf so a `../` payload resolves inside the fixture.
submit_prompt_p12b() {
    printf '%s' "$(printf '{"session_id":"%s","prompt":"%s"}' "$(json_escape "$1")" "$(json_escape "/enforce-workflow-off traversal attempt")")" | \
        (cd "$P12B_LEAF" && CLAUDE_WORKFLOW_DIR="$P12B_WF" WORKFLOW_PLANS_DIR="$P12B_WF" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
            "$RWT" 15 node "$RECORDER" >"$CAP_OUT" 2>"$CAP_ERR")
    LAST_RECORDER_STATUS=$?
}

# The sweep is a BEFORE/AFTER snapshot pair, not a name filter: filtering on the
# single name `evil.$MARKER_KIND` missed a recorder that wrongly accepted
# `..\evil` on a POSIX filesystem, where the backslash is a filename character
# and the stray file's literal name is `..\evil.$MARKER_KIND`. Comparing full
# recursive listings pins "the tree did not change" - any stray, under any name.

# p12b_snapshot <phase>: sorted recursive file list into $CAPDIR/p12b-<phase>,
# find's own stderr into $CAPDIR/p12b-find-err-<phase> (own files, not a command
# substitution - the caller needs both streams without a subshell swallowing the
# error one): a failed walk must not read the same as an unchanged tree. $CAPDIR
# sits outside $P12B_GRANDPARENT, so a snapshot never enters its own listing.
p12b_snapshot() {
    find "$P12B_GRANDPARENT" -maxdepth 3 -type f 2>"$CAPDIR/p12b-find-err-$1" \
        | LC_ALL=C sort >"$CAPDIR/p12b-$1"
}

# p12b_sweep_diff: differing snapshot lines to $CAPDIR/p12b-diff-out, diff's own
# stderr to $CAPDIR/p12b-diff-err - same two-stream reason as above.
p12b_sweep_diff() {
    diff "$CAPDIR/p12b-before" "$CAPDIR/p12b-after" \
        >"$CAPDIR/p12b-diff-out" 2>"$CAPDIR/p12b-diff-err"
}

# p12b_sweep_err: every way the sweep itself could have failed, in one string.
p12b_sweep_err() {
    cat "$CAPDIR/p12b-find-err-before" "$CAPDIR/p12b-find-err-after" "$CAPDIR/p12b-diff-err" 2>/dev/null
}

# Positive control: prove the snapshot pair sees a planted stray file before
# trusting an unchanged result below. The plant is `..evil.$MARKER_KIND` in the
# LEAF - neither the stem nor the directory the old filter looked for - so a
# green control also demonstrates the escape class that filter missed. (The raw
# `..\evil` spelling is not a creatable filename on a Windows host, so this is
# the portable stand-in for it.)
p12b_snapshot before
: > "$P12B_LEAF/..evil.$MARKER_KIND"
p12b_snapshot after
p12b_sweep_diff
control_hit=$(cat "$CAPDIR/p12b-diff-out")
control_err=$(p12b_sweep_err)
if [ -n "$control_hit" ] && [ -z "$control_err" ]; then
    pass "P12b positive control: the sweep detects a planted stray file"
else
    fail "P12b positive control: the sweep detects a planted stray file" "hit=[$control_hit] sweep_err=[$control_err]"
fi
rm -f "$P12B_LEAF/..evil.$MARKER_KIND"

# The snapshot pair compares NAMES, so it is blind to the other traversal outcome:
# an ancestor file that already exists being overwritten IN PLACE. Per case, plant
# a sentinel at the exact path this payload would hit - joined by node's own
# path.join on the same workflow dir markerPathFor() joins, so the tested target
# can never drift from the real one - and read those bytes back afterwards. The
# plant precedes the BEFORE snapshot, so it is a constant member of both listings.
while IFS='|' read -r name sid; do
    [ -z "$name" ] && continue
    target=$("$RWT" 10 node -e \
        "process.stdout.write(require('path').join(process.argv[1], process.argv[2] + '.' + process.argv[3]))" \
        "$P12B_WF" "$sid" "$MARKER_KIND")
    # node returns the host's own path spelling; bash needs the POSIX one here.
    if command -v cygpath >/dev/null 2>&1; then target=$(cygpath -u "$target"); fi
    mkdir -p "$(dirname "$target")"
    printf '%s' "SENTINEL-$name-UNCHANGED" > "$target"
    p12b_snapshot before
    submit_prompt_p12b "$sid"
    p12b_snapshot after
    p12b_sweep_diff
    stray=$(cat "$CAPDIR/p12b-diff-out")
    sweep_err=$(p12b_sweep_err)
    if [ -n "$sweep_err" ]; then
        fail "P12b traversal writes nothing in the ancestor tree: $name" "the sweep itself failed: $sweep_err"
    elif [ -n "$stray" ]; then
        fail "P12b traversal writes nothing in the ancestor tree: $name" "tree changed: $stray"
    else
        pass "P12b traversal writes nothing in the ancestor tree: $name"
    fi
    assert_eq "P12b traversal does not crash the recorder: $name" "0" "$LAST_RECORDER_STATUS"
    assert_eq "P12b traversal overwrites no existing ancestor file at its real target: $name" \
        "SENTINEL-$name-UNCHANGED" "$(cat "$target" 2>/dev/null)"
    rm -f "$target"
done <<'P12_TRAVERSAL'
posix-parent|../evil
posix-parent-twice|../../evil
windows-parent|..\evil
absolute-ish|/evil
P12_TRAVERSAL
rm -rf "$TMP/p12b-nest" 2>/dev/null || true

# P12c: characters SID_RE excludes. `.` is the load-bearing one - `pv12.dot`
# would otherwise mint `pv12.dot.off-emergency-invoked`, whose TAIL still reads
# as a protected marker to every suffix-matching reader.
while IFS='|' read -r name sid; do
    [ -z "$name" ] && continue
    submit_prompt "$sid" "/enforce-workflow-off malformed session id"
    assert_absent "P12c malformed session id mints no marker: $name" "$(marker_of "$sid")"
    assert_eq "P12c malformed session id does not crash the recorder: $name" "0" "$LAST_RECORDER_STATUS"
done <<'P12_MALFORMED'
dot-in-the-stem|pv12.dot
space-in-the-stem|pv12 space
colon-in-the-stem|pv12:colon
P12_MALFORMED

# P12d: CONTROL for P12b/P12c - the same code path with a WELL-FORMED id does
# write, so the rejections above are rejections and not a dead branch.
sid=pv12ok
rm -f "$(marker_of "$sid")"
submit_prompt "$sid" "/enforce-workflow-off well-formed session id"
assert_file "P12d control: a well-formed session id still mints the marker" "$(marker_of "$sid")"
rm -f "$(marker_of "$sid")"

# P12e: the env fallback. A payload without `session_id` is not a malformed
# payload - the recorder resolves the session from the environment exactly as
# hooks/workflow-state/session-id.js documents, and provenance must survive that
# route, or every such turn would silently under-attribute.
for var in CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID; do
    sid="pv12env"
    rm -f "$(marker_of "$sid")"
    submit_prompt_sidless "$var" "$sid" "/enforce-workflow-off resolved from the environment"
    assert_file "P12e sidless payload resolves the session from $var" "$(marker_of "$sid")"
    body=$(cat "$(marker_of "$sid")" 2>/dev/null)
    assert_contains "P12e $var route writes the current-contract payload" '"skill":"enforce-workflow-off"' "$body"
    assert_eq "P12e $var route exits cleanly" "0" "$LAST_RECORDER_STATUS"
    rm -f "$(marker_of "$sid")"
done
}
