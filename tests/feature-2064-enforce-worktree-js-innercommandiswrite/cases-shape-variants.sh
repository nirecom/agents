# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, dispatch-provenance, scope:issue-specific
# Sections 11-16 — input-shape variants: line continuations, backticks, heredoc delimiter forms, nested substitutions, deep nesting, CRLF twins.
# Sourced by tests/feature-2064-enforce-worktree-js-innercommandiswrite.sh.

# Section 11 — C1. The VERBATIM production dispatch, with real backslash line
# continuations, so `--body "$(cat <<'EOF'` and the closing `)" \` sit on their
# own physical lines. Sections 4-6 use a single-line spelling of the same
# command; this row proves the fold step (`\<LF>` -> space) does not change the
# verdict for the shape a user actually types. Both seams are asserted.
echo ""
echo "=== Section 11: C1 verbatim production dispatcher command ==="
table <<'TABLE'
V1 verbatim dispatch direct predicate      | nl     | V1 | false
V1d verbatim dispatch write-detector       | detect | V1 | null
V1p verbatim dispatch layer-1 provenance   | prov   | V1 | cleared
TABLE

# Section 12 — C2. Backtick command substitution, the CPR-ORTH sibling of the
# `$( ... )` rows in Section 5.
# MEASURED DEVIATION (B1/B2): an UNQUOTED backtick span does not hide its
# contents from the tokenizer — `<<'EOF'` inside it attaches to the OUTER segment
# as a heredoc redirect, so classify() fires on the WRITE_PATTERNS here-doc entry
# and layer 1 sees isPosixRedirWriteIR on the segment itself, so provenance is
# never raised. Dispatcher and non-dispatcher therefore agree: write. That is
# fail-closed, and it is why the DQ-wrapped form (B4/B5) is the one that actually
# exercises the clearance.
echo ""
echo "=== Section 12: C2 backtick command substitution ==="
table <<'TABLE'
B1 dispatch + bare backtick truncated cat  | cs     | B1 | true
B1d same via write-detector (classify)     | detect | B1 | classify
B1p bare backtick blocks layer-1 clearance | prov   | B1 | null
B2 NON-dispatch + bare backtick truncated  | cs     | B2 | true
B3 dispatch + bare backtick rm -rf docs    | cs     | B3 | true
B4 dispatch + DQ backtick truncated cat    | cs     | B4 | false
B4d DQ backtick dispatch write-detector    | detect | B4 | null
B4p DQ backtick layer-1 provenance         | prov   | B4 | cleared
B5 NON-dispatch + DQ backtick truncated    | cs     | B5 | true
B5d NON-dispatch DQ backtick detector      | detect | B5 | isCommandSubstWriteIR
B6 dispatch + DQ backtick rm -rf docs      | cs     | B6 | true
B6d real write in backticks not cleared    | detect | B6 | isCommandSubstWriteIR
TABLE

# Section 13 — C3. Heredoc delimiter variants beyond the `\w+` shape.
# D1/D2 are the `\w+` baseline: dispatcher -> read, non-dispatch -> write.
# MEASURED DEVIATION (D3/D4, D9/D10): the opener regexes accept only `\w+`
# delimiter words, so `END-MARK` matches NO opener, layer 2 returns false and the
# command stays a write EVEN on the dispatcher path despite layer 1 clearing it
# (D3p) — fail-closed, pinned so a later widening is a visible change.
# MEASURED DEVIATION (D5/D6): `<<"END.MARK"` nests a double quote inside a DQ
# argument, the span scanner extracts no substitution and both paths report read
# — pre-existing classifier behavior, not a #2064 clearance. D7/D8 are the
# indented `<<-` form; D11/D12 are its complete-heredoc twin, read on both paths.
echo ""
echo "=== Section 13: C3 heredoc delimiter variants ==="
table <<'TABLE'
D1 dispatch + truncated <<ENDMARK baseline | cs     | D1  | false
D1d baseline dispatcher via detector       | detect | D1  | null
D2 NON-dispatch + truncated <<ENDMARK      | cs     | D2  | true
D3 dispatch + <<END-MARK hyphen fail-closed| cs     | D3  | true
D3p layer 1 still clears the hyphen form   | prov   | D3  | cleared
D4 NON-dispatch + <<END-MARK hyphen        | cs     | D4  | true
D5 dispatch + DQ <<END.MARK no subst found | cs     | D5  | false
D6 NON-dispatch + DQ <<END.MARK symmetric  | cs     | D6  | false
D7 dispatch + truncated <<- indented form  | cs     | D7  | false
D7d indented dispatcher via detector       | detect | D7  | null
D8 NON-dispatch + truncated <<- indented   | cs     | D8  | true
D9 dispatch + COMPLETE <<END-MARK heredoc  | nl     | D9  | true
D9d complete hyphen heredoc via detector   | detect | D9  | isCommandSubstWriteIR
D10 NON-dispatch + COMPLETE <<END-MARK     | nl     | D10 | true
D11 dispatch + COMPLETE <<- heredoc        | nl     | D11 | false
D11d complete indented heredoc detector    | detect | D11 | null
D12 NON-dispatch + COMPLETE <<- heredoc    | nl     | D12 | false
TABLE

# Section 14 — C4. Nested command substitution `$(echo $(cat <<'EOF' ... ))`.
# MEASURED DEVIATION (M1/M2): layer 1 DOES clear the dispatcher form (M1p), yet
# the command still classifies write — with the INNER substitution unquoted the
# re-parsed fragment splits into TWO segments and isTruncatedCatHeredocOnly
# requires exactly one, so layer 2 refuses even with a cleared ctx. Fail-closed,
# symmetric with M2. M3/M4 are the COMPLETE nested heredoc: M3 (DISPATCH) reads
# via clearance, M4 (non-dispatch) has none, so the truncated opener surviving
# the split stays fail-closed — matching N2k/D10/C2c/SO8. M5/M6 are the attack twins — a real write in the inner
# substitution (M5) and one injected after the inner EOF (M6) — and both stay
# write on the dispatcher path, which is the narrowness guarantee #2064 owes.
echo ""
echo "=== Section 14: C4 nested command substitution ==="
table <<'TABLE'
M1 dispatch + nested truncated opener      | cs     | M1 | true
M1p layer 1 clears but layer 2 refuses     | prov   | M1 | cleared
M2 NON-dispatch + nested truncated opener  | cs     | M2 | true
M3 dispatch + nested COMPLETE heredoc      | cs     | M3 | false
M3d nested complete heredoc via detector   | detect | M3 | null
M3p nested complete heredoc clearance      | prov   | M3 | cleared
M4 NON-dispatch + nested COMPLETE heredoc  | cs     | M4 | true
M5 dispatch + rm -rf in inner substitution | cs     | M5 | true
M5d inner rm not cleared by dispatch       | detect | M5 | isCommandSubstWriteIR
M6 dispatch + rm injected after inner EOF  | nl     | M6 | true
M6d injected rm via write-detector         | detect | M6 | isCommandSubstWriteIR
TABLE

# Section 15 — C8. substHasNarrowWrite's `depth > 4` fail-closed guard.
# MEASURED: the guard is DEFENSIVE ONLY — no string fixture reaches it. Unquoted
# nesting (Z1, 8 levels) never recurses: parse() splits at every `$(`, and
# extractCommandSubstitutions already returns all nested spans FLAT from the top
# fragment, so every level is inspected at depth 0-1 and the ladder clears on its
# merits. DQ-per-level nesting (Z3) fails earlier: the span scanner returns
# ok:false on a double quote nested inside a double quote and both
# substHasNarrowWrite and isCommandSubstWriteIR fail closed on !ok. So these rows
# assert the fail-closed OUTCOME — a deep nest either resolves honestly (Z1/Z2)
# or is refused (Z3/Z4, Z4 being the non-dispatch control).
echo ""
echo "=== Section 15: C8 deep substitution nesting fail-closed ==="
table <<'TABLE'
Z1 dispatch + 8-level bare nest harmless   | cs     | Z1 | false
Z1p 8-level bare nest layer-1 clearance    | prov   | Z1 | cleared
Z1d 8-level bare nest via write-detector   | detect | Z1 | null
Z2 dispatch + rm -rf at 5-level bare nest  | cs     | Z2 | true
Z2p deep rm blocks layer-1 clearance       | prov   | Z2 | null
Z3 dispatch + 5-level DQ nest fail-closed  | cs     | Z3 | true
Z3p DQ nest span-scan failure blocks clear | prov   | Z3 | null
Z4 NON-dispatch 5-level DQ nest control    | cs     | Z4 | true
TABLE

# Section 16 — C9. CRLF twins of the newline-injection cases.
# isNewlineInjectedWriteIR gates on /[\r\n]/ and spanAwareNewlineSplit, so a CR
# must not change any verdict: R1/R7/R9 stay read, injected writes stay write.
# MEASURED DEVIATION (R4): with CRLF the redirect on the injected line resolves
# as a top-level segment redirect, so detectWritePredicate reports
# isPosixRedirWriteIR — which precedes isNewlineInjectedWriteIR in its first-match
# order. The direct `nl` predicate still returns true (R4n); both names are WRITE.
echo ""
echo "=== Section 16: C9 CRLF newline variants ==="
table <<'TABLE'
R1 CRLF real dispatch heredoc body         | nl     | R1 | false
R1d CRLF real dispatch via write-detector  | detect | R1 | null
R1p CRLF real dispatch layer-1 provenance  | prov   | R1 | cleared
R2 CRLF NON-dispatcher same shape          | nl     | R2 | true
R3 CRLF dispatch + injected rm -rf         | nl     | R3 | true
R3d CRLF injected rm via write-detector    | detect | R3 | isNewlineInjectedWriteIR
R4n CRLF dispatch + injected redirect      | nl     | R4 | true
R4d CRLF injected redirect via detector    | detect | R4 | isPosixRedirWriteIR
R5 CRLF dispatch + injected git commit     | nl     | R5 | true
R6 CRLF subst + injected eval rm -rf       | nl     | R6 | true
R6d CRLF subst injected eval via detector  | detect | R6 | isCommandSubstWriteIR
R7 NEGATIVE CRLF subst harmless prose      | nl     | R7 | false
R7d NEGATIVE CRLF subst via write-detector | detect | R7 | null
R8 CRLF mirror of N1d write on line two    | nl     | R8 | true
R9 CRLF backslash continuation stays read  | nl     | R9 | false
TABLE
