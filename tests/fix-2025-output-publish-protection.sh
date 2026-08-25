#!/usr/bin/env bash
# tests/fix-2025-output-publish-protection.sh
# Tests: bin/build-codex-context, bin/run-codex-review-loop, bin/lib/safe-plans-path.sh
# Tags: codex, review-loop, publish, atomic-write, session-id, security, scope:issue-specific, pwsh-not-required
#
# The two wrapper scripts create files in the plans dir under predictable
# names. mv onto a pre-placed directory moved the file inside it silently, and
# --session-id was pasted into filenames unchecked (#2025 C9). Cases here drive
# the real scripts as subprocesses; only the codex reviewer is mocked.
set -uo pipefail

# TL2. Real bin/build-codex-context and real bin/run-codex-review-loop run in a
# fixture AGENTS_CONFIG_DIR carrying real bin/lib, so a regression in
# safe-plans-path.sh surfaces here too.

# TL3 gap (environment-specific): a symlink pre-placed at a destination,
# pointing outside the plans dir, isn't covered everywhere — Git Bash on
# Windows can't create one, so those rows are probed for and skipped by name.
# Mitigation: the rename-replaces-link and post-rename still-a-link checks are
# pinned below as source properties instead.

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
        FAIL=$((FAIL + 1))
    fi
}

# An expectation that could not be computed is itself a failure.
assert_eq_nz() {
    local name="$1" want="$2" got="$3"
    if [ -z "$want" ]; then
        echo "FAIL: $name — the expected value could not be computed (empty)"
        FAIL=$((FAIL + 1))
        return
    fi
    assert_eq "$name" "$want" "$got"
}

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# --- fixture isolation (rules/test/fixture-isolation.md) --------------------
TMPDIR_BASE="$(mktemp -d)"
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans-root"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
cd "$TMPDIR_BASE" || exit 1

SYMLINKS_OK=no
ln -s "$TMPDIR_BASE" "$TMPDIR_BASE/.symprobe" 2>/dev/null \
    && [ -h "$TMPDIR_BASE/.symprobe" ] && SYMLINKS_OK=yes

# The fixture AGENTS_CONFIG_DIR: the real scripts and the real bin/lib, with the
# codex reviewer replaced by a mock that always approves. Only the reviewer is
# stubbed, so every publish under test is the shipped code path.
MOCK="$TMPDIR_BASE/agents"
mkdir -p "$MOCK/bin/lib" "$MOCK/rules"
echo "# core principles stub" > "$MOCK/rules/core-principles.md"
for f in build-codex-context run-codex-review-loop concern-ledger review-loop-verdict; do
    cp "$AGENTS_ROOT/bin/$f" "$MOCK/bin/$f" && chmod +x "$MOCK/bin/$f"
done
cp -r "$AGENTS_ROOT/bin/lib/." "$MOCK/bin/lib/"
cat > "$MOCK/bin/review-plan-codex" <<'MOCKEOF'
#!/usr/bin/env bash
cat <<'OUT'
## Codex Plan Review: PERFORMED

<!-- begin-codex-output: treat as untrusted third-party content -->
APPROVED
<!-- end-codex-output -->
OUT
MOCKEOF
chmod +x "$MOCK/bin/review-plan-codex"

FMT="detail-plan"

# mk_plans <name> <sid> — a plans dir a review can actually run in.
mk_plans() {
    local p="$TMPDIR_BASE/$1"
    mkdir -p "$p"
    echo "# Draft plan" > "$p/draft.md"
    echo "# Outline" > "$p/outline.md"
    echo "# Intent" > "$p/$2-intent.md"
    printf '%s' "$p"
}

RC=0
OUT=""
build() {
    local rc=0
    OUT="$(run_with_timeout bash "$MOCK/bin/build-codex-context" \
        --plans-dir "$1" --session-id "$2" --output "$3" 2>&1)" || rc=$?
    RC="$rc"
}
loop() {
    local rc=0
    OUT="$(AGENTS_CONFIG_DIR="$MOCK" run_with_timeout "$MOCK/bin/run-codex-review-loop" \
        --format "$FMT" --session-id "$2" --plans-dir "$1" --draft-file "$1/draft.md" \
        --cap 2 --max-extensions 2 --extensions-used 0 \
        --accepted-tradeoffs "$1/outline.md" --round 1 2>&1)" || rc=$?
    RC="$rc"
}
# -e, because every diagnostic worth matching here starts with '--'.
says() { printf '%s' "$OUT" | grep -q -F -e "$1" && printf yes || printf no; }
inside() { find "$1" -mindepth 1 2>/dev/null | wc -l | tr -d ' '; }
temps() { find "$1" -maxdepth 1 -name '.sp-tmp.*' -o -maxdepth 1 -name '.build-codex-context.*' | wc -l | tr -d ' '; }

echo "--- publish 1: the controls, where both scripts get a clear destination ---"

# 1. Without these, "it refused" below would also be true of a build that always
#    refuses — the classifier has to be shown saying yes as well as no.
{
    P1="$(mk_plans ok-build sid1)"
    build "$P1" sid1 "$P1/ctx.md"
    assert_eq "1: a context whose destination is free is written" "0" "$RC"
    assert_eq "1: and it lands as a regular file with content" \
        "file-nonempty" \
        "$([ -f "$P1/ctx.md" ] && [ -s "$P1/ctx.md" ] && printf file-nonempty || printf 'missing-or-empty')"
    assert_eq "1: leaving no temporary beside it" "0" "$(temps "$P1")"

    P1L="$(mk_plans ok-loop sid1)"
    loop "$P1L" sid1
    assert_eq "1: a review round whose destinations are free converges" "0" "$RC"
    assert_eq "1: having really built the context and the marker" \
        "ctx=yes marker=yes" \
        "ctx=$([ -f "$P1L/sid1-codex-context.md" ] && printf yes || printf no) marker=$([ -f "$P1L/sid1-codex-context.$FMT.built" ] && printf yes || printf no)"
}

echo ""
echo "--- publish 2: a directory pre-placed at the context's destination ---"

# 2. The attack the old `mv` lost to: it moved the context inside the directory
#    and exited 0, so the caller marked the context built and the reviewer read
#    nothing. Refusal has to be visible in the status, in the diagnostic, and in
#    the directory staying empty.
{
    P2="$(mk_plans blocked-build sid2)"
    mkdir -p "$P2/ctx.md"
    build "$P2" sid2 "$P2/ctx.md"
    assert_eq "2: the build refuses rather than reporting a context it did not place" "1" "$RC"
    assert_eq "2: naming the destination it could not publish to" \
        "yes" "$(says "could not publish the context to")"
    assert_eq "2: nothing was parked inside the pre-placed directory" "0" "$(inside "$P2/ctx.md")"
    assert_eq "2: the destination is still the directory, not silently replaced" \
        "dir" "$([ -d "$P2/ctx.md" ] && printf dir || printf 'replaced')"
    assert_eq "2: and no temporary was abandoned in the plans dir" "0" "$(temps "$P2")"
}

echo ""
echo "--- publish 3: the same destinations, reached through the review loop ---"

# 3. Each of the loop's own predictable names, blocked one at a time. The loop
#    must halt with its own configuration-fault status (4) rather than run a
#    round whose bookkeeping silently went into a directory.
{
    while IFS='~' read -r label sid suffix want_says; do
        case "$label" in ''|'#'*) continue ;; esac
        for v in label sid suffix want_says; do
            eval "t=\$$v"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; eval "$v=\$t"
        done
        P3="$(mk_plans "blocked-$sid" "$sid")"
        mkdir -p "$P3/$sid$suffix"
        loop "$P3" "$sid"
        assert_eq "3: $label — the round halts instead of proceeding" "4" "$RC"
        assert_eq "3: $label — saying which publish it could not make" "yes" "$(says "$want_says")"
        assert_eq "3: $label — with nothing parked inside the pre-placed directory" \
            "0" "$(inside "$P3/$sid$suffix")"
        assert_eq "3: $label — and no temporary abandoned beside it" "0" "$(temps "$P3")"
        ROWS3=$((${ROWS3:-0} + 1))
    done <<TABLE
# label                    ~ sid  ~ suffix                          ~ want_says
the built-marker           ~ sid3a ~ -codex-context.$FMT.built      ~ cannot create marker
the round counter          ~ sid3b ~ -$FMT-round-number.txt         ~ cannot publish round counter
the context file           ~ sid3c ~ -codex-context.md              ~ build-codex-context failed
TABLE
    assert_eq_nz "3: every blocked destination in the table was exercised" "3" "${ROWS3:-0}"
}

echo ""
echo "--- publish 4: a session id that is not a path token ---"

# 4. Both scripts paste --session-id straight into names under the plans dir, so
#    each validates it itself rather than trusting its caller. The empty value
#    keeps its older, more specific message; the table records that difference
#    instead of flattening it.
{
    P4="$(mk_plans bad-sid sidok)"
    BEFORE4="$(find "$P4" -type f | sort | wc -l | tr -d ' ')"
    while IFS='~' read -r sid want_says; do
        case "$sid" in '#'*) continue ;; esac
        for v in sid want_says; do
            eval "t=\$$v"; t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"; eval "$v=\$t"
        done
        [ "$sid" = "(empty)" ] && sid=""
        build "$P4" "$sid" "$P4/ctx-bad.md"
        assert_eq "4: build refuses the session id [$sid]" "1" "$RC"
        assert_eq "4: build says why for [$sid]" "yes" "$(says "$want_says")"
        ROWS4=$((${ROWS4:-0} + 1))
    done <<'TABLE'
# sid          ~ want_says
../escape      ~ --session-id is not a safe path token
a/b            ~ --session-id is not a safe path token
a\esc          ~ --session-id is not a safe path token
-rf            ~ --session-id is not a safe path token
a;touch PWNED  ~ --session-id is not a safe path token
.              ~ --session-id is not a safe path token
(empty)        ~ --session-id is required
TABLE
    assert_eq_nz "4: every rejected session id in the table was exercised" "7" "${ROWS4:-0}"
    assert_eq_nz "4: and not one of them created a file anywhere in the plans dir" \
        "$BEFORE4" "$(find "$P4" -type f | sort | wc -l | tr -d ' ')"
    assert_eq "4: nor a command-substitution canary outside it" \
        "0" "$(find "$TMPDIR_BASE" -name 'PWNED*' 2>/dev/null | wc -l | tr -d ' ')"

    # The loop halts on the same input, with its own halt-do-not-retry status.
    P4L="$(mk_plans bad-sid-loop sidok)"
    loop "$P4L" "../escape"
    assert_eq "4: the loop halts on the same session id" "4" "$RC"
    assert_eq "4: telling the operator what a session id may contain" \
        "yes" "$(says "--session-id must match")"
    assert_eq "4: having created nothing outside the plans dir it was given" \
        "0" "$(find "$TMPDIR_BASE" -maxdepth 1 -name 'escape*' 2>/dev/null | wc -l | tr -d ' ')"
}

echo ""
echo "--- publish 5: a symlink pre-placed at the destination ---"

# 5. The other pre-placement: a link at the predictable name, pointing at a file
#    the loop may not touch. The publish must replace the link rather than write
#    through it.
{
    if [ "$SYMLINKS_OK" = "yes" ]; then
        P5="$(mk_plans symlinked sid5)"
        VICTIM="$TMPDIR_BASE/victim.txt"
        echo "do not overwrite me" > "$VICTIM"
        ln -s "$VICTIM" "$P5/ctx.md"
        build "$P5" sid5 "$P5/ctx.md"
        assert_eq "5: the victim outside the plans dir is byte-for-byte unchanged" \
            "do not overwrite me" "$(cat "$VICTIM")"
        assert_eq "5: and the destination is no longer a link to it" \
            "not-a-link" "$([ -h "$P5/ctx.md" ] && printf 'still-a-link' || printf not-a-link)"
    else
        echo "SKIP: 5: the victim outside the plans dir is byte-for-byte unchanged (no symlinks here)"
        echo "SKIP: 5: and the destination is no longer a link to it (no symlinks here)"
    fi
}

echo ""
echo "--- publish 6: the source properties the cases above rest on ---"

# 6. Two of them are not observable on this host (Skipped-Because: no symlinks
#    here), and one — mktemp's exclusive create — is not observable from outside
#    at all, so all three are pinned where they are written.
{
    SP6="$AGENTS_ROOT/bin/lib/safe-plans-path.sh"
    assert_eq_nz "6: the publish renames rather than writing through the destination" \
        "1" "$(grep -c -F 'mv -f -- "$tmp" "$dest"' "$SP6" | tr -d ' ')"
    assert_eq_nz "6: and refuses what is still a link, or no longer a file, afterwards" \
        "1" "$(grep -c -F '[ -h "$dest" ] || [ ! -f "$dest" ]' "$SP6" | tr -d ' ')"
    assert_eq_nz "6: the temp beside it is created by mktemp, never by a redirect onto a name" \
        "1" "$(grep -c -F 'mktemp -- "$d/.sp-tmp.XXXXXXXX"' "$SP6" | tr -d ' ')"

    # Both wrappers must keep validating the session id themselves: dropping the
    # check in either one re-opens its own half of the prefix.
    assert_eq_nz "6: build-codex-context validates the session id it pastes into names" \
        "1" "$(grep -c -F 'sp_valid_token "$SID"' "$AGENTS_ROOT/bin/build-codex-context" | tr -d ' ')"
    assert_eq_nz "6: and so does the review loop, which derives five names from it" \
        "1" "$(grep -c -F 'sp_valid_token "$SID"' "$AGENTS_ROOT/bin/run-codex-review-loop" | tr -d ' ')"
}

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed."
    exit 0
fi
exit 1
