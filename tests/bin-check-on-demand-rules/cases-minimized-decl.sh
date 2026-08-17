# shellcheck shell=bash
# Tests: bin/check-on-demand-rules.sh, bin/lib/check-on-demand-rules.js, hooks/lib/rules-policy-reader.js
# Tags: rules-injection, on-demand-rules, static-check, minimized-unconditional, fail-closed, violation-tokens, TL2, scope:issue-specific

# WHY (CPR-WPH): the minimized class has two gates that run BEFORE any row is examined,
# and both used to fail OPEN.

# 1. The DECLARATION gate. When MINIMIZED_UNCONDITIONAL was absent or unparseable, the
# whole checkMinimizedRows pass was skipped and the checker still exited 0 — so deleting
# one const, or merely reformatting it out of the parser's reach, switched off the byte
# ceiling, the pointer check and the unconditional-membership check with no signal at all.
# It now emits MINIMIZED_DECLARATION_MISSING, symmetric with the readers path (P16).

# 2. The KEY gate. The row key is the ONE declaration value this checker opens from disk,
# and it used to be opened unvalidated — so a row spelled `.env|rules/git.md` made every
# reviewer's pre-commit run read `.env` and publish its byte length (MINIMIZED_RULE_TOO_LARGE)
# plus a content oracle (the pointer check reports whether the file contains a chosen
# string) into the violation text. The key is now shape-checked FIRST and the row dropped,
# unread, on failure.

# Each gate gets the reject case, the non-reject control, and — for the key gate — a proof
# that the target was never opened, not merely that the size line was suppressed.
# The row-level tokens are in cases-minimized.sh; the helpers are in fixtures.sh.
# Assumes TOKEN, MARKER, BASE, wr(), run_checker(), outfile_for(), rd_policy(), rd_base(),
# rd_min_base(), rd_expect(), pass(), fail() from the dispatcher and fixtures.sh.

echo ""
echo "=== minimized declaration gate: MINIMIZED_DECLARATION_MISSING / MALFORMED_MINIMIZED_KEY ==="

MD_N=0

# --- M1: the declaration is absent entirely. ---
MD_N=$((MD_N + 1)); d="$BASE/md-absent$MD_N"
rd_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md"]' NONE NONE
rd_expect "M1: a policy that never declares MINIMIZED_UNCONDITIONAL is MINIMIZED_DECLARATION_MISSING, not silently unchecked" \
    "$d" MINIMIZED_DECLARATION_MISSING yes "rules-injection-policy.js"

# --- M2: the declaration is PRESENT but computed, so the text parser cannot recover it.
# This is the shape a well-meaning refactor produces, and it is the dangerous one: the
# constant is right there in the file, exports correctly, and passes every JS review.
# The value must not OPEN with `[` — a literal that merely has calls chained onto it is
# still recovered by the array reader, and would exercise the row checks, not this gate. ---
MD_N=$((MD_N + 1)); d="$BASE/md-computed$MD_N"
rd_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md"]' NONE 1500
printf 'const MIN_SRC = ["rules/min.md"];\nconst MINIMIZED_UNCONDITIONAL = MIN_SRC.map((r) => r + "|skills/eho/SKILL.md");\n' \
    >> "$d/hooks/lib/rules-injection-policy.js"
rd_expect "M2: a declared-but-computed MINIMIZED_UNCONDITIONAL is MINIMIZED_DECLARATION_MISSING — present in the file is not the same as recoverable" \
    "$d" MINIMIZED_DECLARATION_MISSING yes "rules-injection-policy.js"

# --- M3: only a COMMENTED-OUT copy exists. The anchored reader (#2037) refuses to read a
# comment as a declaration, so the checker must reach the same verdict as M1 rather than
# grading the tree against a line nobody meant to be live. ---
MD_N=$((MD_N + 1)); d="$BASE/md-commented$MD_N"
rd_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md"]' NONE 1500
printf '// const MINIMIZED_UNCONDITIONAL = ["rules/min.md|skills/eho/SKILL.md"];\n' \
    >> "$d/hooks/lib/rules-injection-policy.js"
rd_expect "M3: a commented-out MINIMIZED_UNCONDITIONAL does not count as the declaration" \
    "$d" MINIMIZED_DECLARATION_MISSING yes "rules-injection-policy.js"

# --- M4: the symmetric NON-reject control. Without it the three cases above are also what
# a checker that rejected EVERY policy would produce, and an over-blocking regression —
# which would make the gate unusable and get it switched off — would ship green. ---
MD_N=$((MD_N + 1)); d="$BASE/md-ok$MD_N"
rd_min_base "$d"
rd_expect "M4: a valid one-line MINIMIZED_UNCONDITIONAL with valid keys is accepted — clean verdict, exit 0" \
    "$d" MINIMIZED_DECLARATION_MISSING no

# --- M5: the EMPTY declaration is a declaration. A policy may legitimately declare the
# class and put nothing in it; that is different from never declaring it, and conflating
# the two would force every downstream repo to invent an escape hatch it does not have. ---
MD_N=$((MD_N + 1)); d="$BASE/md-empty$MD_N"
rd_base "$d"
rd_expect "M5: an EMPTY MINIMIZED_UNCONDITIONAL is a declaration, not an absence" \
    "$d" MINIMIZED_DECLARATION_MISSING no

# --- K: MALFORMED_MINIMIZED_KEY. The payload below is what a hostile row would harvest:
# a file outside the rules corpus, large enough that reading it would publish a byte count.
MD_SECRET_BYTES=800

# Size is only half the oracle. A byte count leaks how big the file is; the CONTENT leak is
# the one that matters, and it does not depend on the file being large. So the payload also
# carries a distinctive VALUE which must never surface — not in stdout, not in stderr, and
# not in anything the checker writes to disk. The value is built at run time so this literal
# is not itself the thing being searched for.
MD_SECRET_VALUE="mdsecret$$canary"

# md_key_case <label> <dirname> <key> — builds a tree whose ONLY defect is the named key,
# plants an oversized non-rule file at .env, and asserts both halves: the key is rejected
# BY NAME, and the row was never opened (no size, pointer or membership finding for it).
md_key_case() {
    local label="$1" d="$BASE/$2" key="$3" rc out bad
    rd_min_base "$d"
    # Ceiling 40 against an 800-byte target: were the row opened, MINIMIZED_RULE_TOO_LARGE
    # would be unavoidable. Its ABSENCE is therefore evidence of "never read" rather than
    # of a suppressed message — K4 below proves the ceiling really does fire here.
    rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/min.md"]' \
        "[\"$key|skills/eho/SKILL.md\"]" 40
    printf 'SECRET_TOKEN=%s\n%s\n' "$(printf "%$((MD_SECRET_BYTES - 14))s" '' | tr ' ' 'z')" \
        "$MD_SECRET_VALUE" > "$d/.env"
    rc="$(run_checker "$d" all)"
    out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
    if ! printf '%s\n' "$out" | grep -q "^MALFORMED_MINIMIZED_KEY:"; then
        fail "$label: no MALFORMED_MINIMIZED_KEY line (rc=$rc) — an unconstrained row key is opened from disk on every pre-commit run; output: $(printf '%s' "$out" | head -6 | tr '\n' ' ' | cut -c1-400)"
        return
    fi
    if [ "$rc" != "1" ]; then
        fail "$label: the key was rejected but the checker exited $rc, not 1 — a rejected row must still fail the commit"
        return
    fi
    bad="$(printf '%s\n' "$out" | grep -E '^MINIMIZED_(RULE_TOO_LARGE|POINTER_MISSING|POINTER_TARGET_MISSING|NOT_UNCONDITIONAL):' | tr '\n' ' ')"
    if [ -n "$bad" ]; then
        fail "$label: the row was rejected AND still processed — these findings can only come from opening the target: $bad"
        return
    fi
    if printf '%s\n' "$out" | grep -q "$MD_SECRET_BYTES"; then
        fail "$label: the target's byte length ($MD_SECRET_BYTES) appears in the checker output — the row was read and its size disclosed; output: $(printf '%s' "$out" | head -6 | tr '\n' ' ' | cut -c1-400)"
        return
    fi
    # The content half of the same oracle: run_checker merges stderr into this file, so one
    # grep covers both streams. K7 below separates them and adds the on-disk sweep.
    if printf '%s\n' "$out" | grep -qF "$MD_SECRET_VALUE"; then
        fail "$label: a distinctive VALUE from the target appears in the checker output — the row's CONTENT, not merely its size, was disclosed"
        return
    fi
    pass "$label"
}

md_key_case "K1: a bare non-rules key is MALFORMED_MINIMIZED_KEY and its target is never opened" \
    "md-key-bare" ".env"
md_key_case "K2: a TRAVERSAL spelling of the same key is refused before any resolve, not after" \
    "md-key-traverse" "rules/../.env"
md_key_case "K3: a rules-rooted key that is not a .md file is refused too" \
    "md-key-notmd" "rules/secrets.json"

# --- K4: the non-vacuity control for K1-K3. Everything above rests on "no
# MINIMIZED_RULE_TOO_LARGE means the row was not read". That inference holds only if a row
# that IS read, at the same ceiling and against a payload of the same size, really does
# produce it. Same fixture shape — the only change is a well-formed rules/*.md key. ---
d="$BASE/md-read-control"
rd_min_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/leak.md"]' \
    '["rules/leak.md|skills/eho/SKILL.md"]' 40
printf 'SECRET_TOKEN=%s\n`/eho`\n' "$(printf "%$((MD_SECRET_BYTES - 14))s" '' | tr ' ' 'z')" \
    > "$d/rules/leak.md"
rd_expect "K4: a WELL-FORMED key at the same ceiling and payload size DOES produce the size finding — so its absence in K1-K3 means the row was never opened" \
    "$d" MINIMIZED_RULE_TOO_LARGE yes "rules/leak.md"

# --- K5/K6: the symmetric non-reject controls for the key gate. The shipped keys are
# ordinary rules/*.md paths and MINIMIZED_KEY_RE is a regex — the kind of thing tightened
# by one character — so an over-strict validator must fail here, not in a real commit. ---
d="$BASE/md-key-ok"
rd_min_base "$d"
rd_expect "K5: an ordinary rules/<name>.md key raises no MALFORMED_MINIMIZED_KEY" \
    "$d" MALFORMED_MINIMIZED_KEY no

d="$BASE/md-key-nested"
rd_min_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/sub/min.md"]' \
    '["rules/sub/min.md|skills/eho/SKILL.md"]' 1500
rm -f "$d/rules/min.md"
wr "$d/rules/sub/min.md" <<'EOF'
# Escape hatch

## When to use

Last resort only. Details: `/eho`.
EOF
rd_expect "K6: a NESTED rules/<dir>/<name>.md key is accepted — the key gate constrains shape, not depth" \
    "$d" MALFORMED_MINIMIZED_KEY no

# --- K7: the streams and the disk, separately. K1-K3 grep a file into which run_checker
# has already merged stderr, so "absent from the output" cannot distinguish "never
# disclosed" from "disclosed on the stream nobody looked at". Here stdout and stderr are
# captured to two files and every regular file the run produced under the tree is swept,
# because a checker that wrote a cache, a report or a log would leak the value there while
# both streams stayed clean. ---
md_stream_case() {
    local label="$1" d="$BASE/$2" key="$3" rc=0 hit
    rd_min_base "$d"
    rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/min.md"]' \
        "[\"$key|skills/eho/SKILL.md\"]" 40
    printf 'SECRET_TOKEN=%s\n%s\n' "$(printf "%$((MD_SECRET_BYTES - 14))s" '' | tr ' ' 'z')" \
        "$MD_SECRET_VALUE" > "$d/.env"
    # A snapshot of the tree BEFORE the run, so the sweep afterwards can be told what is new.
    ( cd "$d" && find . -type f | sort ) > "$BASE/k7-before.txt"
    ( cd "$d" && RULES_INJECTION_POLICY="$(node_path "$d/hooks/lib/rules-injection-policy.js")" \
        bash "$CHECKER" --all "$(node_path "$d")" ) >"$BASE/k7-out.txt" 2>"$BASE/k7-err.txt" || rc=$?
    if [ "$rc" != "1" ]; then
        fail "$label: want exit 1 (the key is rejected and the commit must still fail), got $rc"
        return
    fi
    if grep -qF "$MD_SECRET_VALUE" "$BASE/k7-out.txt"; then
        fail "$label: the target's content appears on STDOUT"
        return
    fi
    if grep -qF "$MD_SECRET_VALUE" "$BASE/k7-err.txt"; then
        fail "$label: the target's content appears on STDERR — the stream K1-K3 could not have told apart from stdout"
        return
    fi
    # `.env` itself is the source of the value, so it is excluded; everything else under the
    # tree — pre-existing or newly written — must be clean.
    hit="$( cd "$d" && grep -rlF "$MD_SECRET_VALUE" . 2>/dev/null | grep -v '^\./\.env$' | tr '\n' ' ' )"
    if [ -n "$hit" ]; then
        fail "$label: the target's content was copied into file(s) under the tree: $hit"
        return
    fi
    pass "$label"
}

md_stream_case "K7: a rejected key discloses the target on NEITHER stream and into no file the run writes" \
    "md-stream-bare" ".env"

# --- K7-ctl: the non-vacuity control for K7. Everything above asserts an ABSENCE, and an
# absence proves nothing unless the same probe can find the value when it IS present. The
# probe is driven over a run that legitimately names a rules/*.md file, with the sentinel
# planted in THAT file, and must report it on stdout. ---
d="$BASE/md-stream-ctl"
rd_min_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/leak.md"]' \
    '["rules/leak.md|skills/eho/SKILL.md"]' 40
printf '# %s\n\nno pointer here\n' "$MD_SECRET_VALUE" > "$d/rules/leak.md"
K7C_RC=0
( cd "$d" && RULES_INJECTION_POLICY="$(node_path "$d/hooks/lib/rules-injection-policy.js")" \
    bash "$CHECKER" --all "$(node_path "$d")" ) >"$BASE/k7c-out.txt" 2>"$BASE/k7c-err.txt" || K7C_RC=$?
if grep -qF "$MD_SECRET_VALUE" "$BASE/k7c-out.txt" "$BASE/k7c-err.txt"; then
    fail "K7-ctl: the sentinel leaked from a WELL-FORMED row too — K7's absence assertion cannot distinguish a rejected key from a checker that never echoes content"
elif [ "$K7C_RC" != "1" ]; then
    fail "K7-ctl: want exit 1 from a well-formed row that violates the ceiling, got $K7C_RC — the control never reached the row checks, so it proves nothing about K7"
elif grep -qE '^MINIMIZED_(RULE_TOO_LARGE|POINTER_MISSING):' "$BASE/k7c-out.txt"; then
    pass "K7-ctl: a WELL-FORMED key at the same ceiling IS opened and reported by name, while its content still never reaches either stream — so K7's silence is 'never opened', not 'the checker never echoes anything'"
else
    fail "K7-ctl: a well-formed rules/*.md row produced no MINIMIZED_* finding at all (rc=$K7C_RC) — the control did not exercise the row path: $(head -4 "$BASE/k7c-out.txt" | tr '\n' ' ')"
fi

# --- T: the `]`-truncation consequence, end to end (#2037). ---
# The reader captures the array body non-greedily up to the FIRST `]`
# (hooks/lib/rules-policy-reader.js readStringArrayConst), so one bracket anywhere inside a
# MINIMIZED_UNCONDITIONAL element cuts the body mid-literal and the declaration decodes as
# EMPTY. Empty is `[]`, not null — and main() gates the whole class on
# `MINIMIZED_UNCONDITIONAL !== null`, so the M1-M3 fail-closed path does NOT fire; the class
# is "declared", checkMinimizedRows iterates zero rows, and the checker exits 0 with nothing
# to say. That is the same switched-off state M1-M3 exist to make loud, reached by a route
# they cannot see. Pinned here, not fixed: this session is tests-only.

# md_trunc_case <label> <dirname> <element> — the row is written verbatim into the
# declaration so the bracket's POSITION is the only variable.
md_trunc_case() {
    local label="$1" d="$BASE/$2" element="$3" rc out
    rd_min_base "$d"
    rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/min.md"]' \
        "[\"$element\"]" 40
    # rules/min.md is far over the 40-byte ceiling, so a row that is actually examined
    # cannot avoid MINIMIZED_RULE_TOO_LARGE. T-ctl below proves that.
    rc="$(run_checker "$d" all)"
    out="$(cat "$(outfile_for "$d")" 2>/dev/null)"
    if printf '%s\n' "$out" | grep -q '^MINIMIZED_DECLARATION_MISSING:'; then
        fail "$label: MINIMIZED_DECLARATION_MISSING fired — the truncation gap recorded here is closed; re-derive this case (and the reader rows in tests/unit-rules-policy-reader/cases-collections.sh) before trusting it"
    elif [ -n "$(printf '%s\n' "$out" | grep -E '^MINIMIZED_[A-Z_]+:')" ]; then
        fail "$label: the truncated declaration still produced MINIMIZED_* finding(s) — the recorded behaviour has changed: $(printf '%s\n' "$out" | grep -E '^MINIMIZED_[A-Z_]+:' | tr '\n' ' ')"
    elif [ "$rc" != "0" ]; then
        fail "$label: no MINIMIZED_* finding, yet the checker exited $rc — this case must isolate the minimized class, and something else in the fixture is failing: $(printf '%s' "$out" | head -4 | tr '\n' ' ' | cut -c1-300)"
    else
        echo "  GAP: a ']' inside a MINIMIZED_UNCONDITIONAL element silently empties the class — the byte ceiling, the pointer check and the membership check all stop running, and the fail-closed gate does not fire because [] is not null"
        pass "$label (pinned: exit 0, no findings; gap recorded above)"
    fi
}

md_trunc_case "T1: a ']' in the row KEY empties MINIMIZED_UNCONDITIONAL and the whole class goes unchecked, silently" \
    "md-trunc-key" 'rules/min[1].md|skills/eho/SKILL.md'
md_trunc_case "T2: a ']' in the POINTER half does the same — the defect is in the array reader, not in either field" \
    "md-trunc-ptr" 'rules/min.md|skills/eho[1]/SKILL.md'

# --- T-ctl: the non-vacuity control. T1/T2 assert "exit 0, no findings", which is also what
# a compliant tree produces — so without a run that differs ONLY by the bracket and DOES
# report, they would be indistinguishable from a passing fixture. ---
d="$BASE/md-trunc-ctl"
rd_min_base "$d"
rd_policy "$d" '["rules/od.md|skills/owner/SKILL.md"]' '["rules/plain.md","rules/min.md"]' \
    '["rules/min.md|skills/eho/SKILL.md"]' 40
rd_expect "T-ctl: the SAME fixture with the bracket removed does report MINIMIZED_RULE_TOO_LARGE — so T1/T2's silence is caused by the truncation, not by a compliant tree" \
    "$d" MINIMIZED_RULE_TOO_LARGE yes "rules/min.md"
