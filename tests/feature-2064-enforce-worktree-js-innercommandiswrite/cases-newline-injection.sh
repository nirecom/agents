# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, newline-injection, scope:issue-specific
# Sections 10-10e — newline-injected writes through command substitution, innerCommandIsWrite OR-chain, frame-interior dangling-opener, unquoted expanding-frame injection.
# Sourced by tests/feature-2064-enforce-worktree-js-innercommandiswrite.sh.

# Section 10 — security-scan regression: exotic-exec write hidden on a
# NEWLINE-INJECTED line INSIDE a `$( ... )` whose body opens with a quoted `cat`
# here-doc. The complete here-doc satisfies isSafeHeredocOnly, so the injected
# line after the EOF terminator escaped classification before the fix.
# W5 is the CPR-ORTH negative control and the point of #2064: the SAME shape
# carrying prose after EOF must stay a non-write.
echo ""
echo "=== Section 10: newline-injected exotic exec inside cat-heredoc \$( ) ==="

# MEASURED first-match order: detectWritePredicate returns on the FIRST true
# predicate and isCommandSubstWriteIR precedes isNewlineInjectedWriteIR, so every
# W row settles as isCommandSubstWriteIR — the injected line lives INSIDE a `$( )`,
# which is that predicate's territory. Both names are WRITE; the `W*n` rows below
# are the ones that pin isNewlineInjectedWriteIR's own verdict.
table <<'TABLE'
W1 dispatch subst + injected eval rm -rf   | detect | W1 | isCommandSubstWriteIR
W2 dispatch subst + injected find -exec rm | detect | W2 | isCommandSubstWriteIR
W3 dispatch subst + injected xargs rm -rf  | detect | W3 | isCommandSubstWriteIR
W4 dispatch subst + injected plain rm -rf  | detect | W4 | isCommandSubstWriteIR
W5 NEGATIVE same shape harmless prose      | detect | W5 | null
W6 gh Group-A subst + injected eval rm -rf | detect | W6 | isCommandSubstWriteIR
W1n same payload direct predicate          | nl     | W1 | true
W2n same payload direct predicate          | nl     | W2 | true
W3n same payload direct predicate          | nl     | W3 | true
W4n same payload direct predicate          | nl     | W4 | true
W5n NEGATIVE direct predicate              | nl     | W5 | false
W6n gh Group-A direct predicate            | nl     | W6 | true
TABLE

echo ""
echo "=== Section 10b: innerCommandIsWrite -> isExoticExecWriteIR (via subst) ==="
table <<'TABLE'
E1 subst wrapping eval rm -rf              | cs     | E1 | true
E2 subst wrapping xargs rm -rf             | cs     | E2 | true
E3 subst wrapping find -exec rm -rf        | cs     | E3 | true
E4 dispatch + subst wrapping eval rm -rf   | cs     | E4 | true
E5 NEGATIVE subst wrapping read-only cat   | cs     | E5 | false
E1d detectWritePredicate on E1             | detect | E1 | isCommandSubstWriteIR
E5d detectWritePredicate on E5             | detect | E5 | null
TABLE

# Section 10c — codex HIGH-1: isNewlineInjectedWriteIR joined innerCommandIsWrite's
# OR chain. An inner body is itself a command string, so an unquoted newline
# separates commands there exactly as at top level. The payload rides inside a
# SINGLE-quoted eval argument, so the outer newline split cannot see it and only
# the inner re-parse can — Y1/Y2 fail open without the fix. Y3/Y4 are the
# read-only twins, and Y5/Y6 are the CPR-ORTH clearance pair: the identical
# newline-injected-inside-`$( )` shape carrying only a sanctioned truncated `cat`
# opener stays READ under a cleared dispatcher ctx (Y5) and stays WRITE without
# one (Y6). That pair is what proves the ctx is threaded, not discarded.
echo ""
echo "=== Section 10c: HIGH-1 newline injection inside an inner command body ==="
table <<'TABLE'
Y1 eval body with injected rm -rf          | exo    | Y1 | true
Y1d eval body via write-detector           | detect | Y1 | isExoticExecWriteIR
Y2 same eval body wrapped in a subst       | cs     | Y2 | true
Y2d wrapped eval body via write-detector   | detect | Y2 | isCommandSubstWriteIR
Y3 NEGATIVE read-only eval body            | exo    | Y3 | false
Y3d NEGATIVE read-only via write-detector  | detect | Y3 | null
Y4 NEGATIVE wrapped read-only eval body    | cs     | Y4 | false
Y4d NEGATIVE wrapped via write-detector    | detect | Y4 | null
Y5 dispatcher-cleared truncated opener     | cs     | Y5 | false
Y5n cleared ctx direct predicate           | nl     | Y5 | false
Y5p cleared ctx layer-1 provenance         | prov   | Y5 | cleared
Y5d cleared ctx via write-detector         | detect | Y5 | null
Y6 NON-dispatch control same shape         | cs     | Y6 | true
Y6n NON-dispatch direct predicate          | nl     | Y6 | true
Y6p NON-dispatch raises no provenance      | prov   | Y6 | null
Y6d NON-dispatch via write-detector        | detect | Y6 | isCommandSubstWriteIR
TABLE

# Section 10d — frame-interior split boundary. The split is INCLUSIVE, and
# isSplitArtifactHeredocLine may SKIP (never rewrite) a split line only under
# all three of: dispatch clearance, a trailing quote-delimited `cat <<'\w+'`
# opener, and a remainder that innerCommandIsWrite judges non-write.
# See hooks/lib/bash-write-targets.js (isNewlineInjectedWriteIR).
# M3 (DISPATCH) reads via clearance; M4 (non-dispatch) has no clearance, so the
# truncated opener surviving the split stays WRITE; M6: a real injected `rm -rf`
# inside a substitution still does not read.
# Top-level lines are judged unchanged — T4/T5 write, T6 read; T7 pins the
# pre-existing fail-closed direction for a surviving top-level opener.
echo ""
echo "=== Section 10d: frame-interior dangling-opener split boundary ==="
table <<'TABLE'
M3n nested COMPLETE heredoc dispatch path  | nl     | M3 | false
M4n nested COMPLETE heredoc non-dispatch   | nl     | M4 | false
M4d non-dispatch complete nested detector  | detect | M4 | isCommandSubstWriteIR
M6n injected rm inside subst stays write   | nl     | M6 | true
T4 top-level heredoc then rm -rf           | nl     | T4 | true
T4d top-level heredoc then rm via detector | detect | T4 | isNewlineInjectedWriteIR
T5 top-level echo then rm -rf              | nl     | T5 | true
T5d top-level echo then rm via detector    | detect | T5 | isNewlineInjectedWriteIR
T6 NEGATIVE top-level two reads            | nl     | T6 | false
T6d NEGATIVE two reads via write-detector  | detect | T6 | null
T7 heredoc opener + read tail fail-closed  | nl     | T7 | true
TABLE

# Section 10e — UNQUOTED expanding-frame newline injection (HIGH fail-open).
# A frame-respecting split stops inside EVERY EXPANDING_KINDS frame, and the IR
# keeps no newline-crossing `$(` token for isCommandSubstWriteIR to recurse into,
# so the inclusive raw split is the only detector for these shapes.
# MEASURED detect names: U5 settles as isPosixRedirWriteIR and U6 as `classify`
# (WRITE_PATTERNS) — both precede isNewlineInjectedWriteIR in the chain; all are
# WRITE, and the `nl` rows pin isNewlineInjectedWriteIR's own verdict.
# The READ boundary of Section 10d is already pinned by M3n above — not duplicated.
echo ""
echo "=== Section 10e: unquoted expanding-frame newline injection ==="
table <<'TABLE'
U1 unquoted cmd subst + injected rm -rf    | nl     | U1  | true
U1d same via write-detector                | detect | U1  | isNewlineInjectedWriteIR
U2 bare subshell + injected rm -rf         | nl     | U2  | true
U2d same via write-detector                | detect | U2  | isNewlineInjectedWriteIR
U3 process subst + injected rm -rf         | nl     | U3  | true
U3d same via write-detector                | detect | U3  | isNewlineInjectedWriteIR
U4b nested unquoted subst depth 2          | nl     | U4b | true
U4bd depth 2 via write-detector            | detect | U4b | isNewlineInjectedWriteIR
U4c nested unquoted subst depth 3          | nl     | U4c | true
U4cd depth 3 via write-detector            | detect | U4c | isNewlineInjectedWriteIR
U4d nested unquoted subst depth 4          | nl     | U4d | true
U4dd depth 4 via write-detector            | detect | U4d | isNewlineInjectedWriteIR
U4e nested unquoted subst depth 5          | nl     | U4e | true
U4ed depth 5 via write-detector            | detect | U4e | isNewlineInjectedWriteIR
U4f nested unquoted subst depth 6          | nl     | U4f | true
U4fd depth 6 via write-detector            | detect | U4f | isNewlineInjectedWriteIR
U5 injected redirect inside unquoted subst | nl     | U5  | true
U5d redirect shape settles as posix-redir  | detect | U5  | isPosixRedirWriteIR
U6 dangling opener + real redirect write   | nl     | U6  | true
U6d dangling-opener line still judged      | detect | U6  | classify
U7 NEGATIVE read-only injected in subst    | nl     | U7  | false
U7d NEGATIVE read-only via write-detector  | detect | U7  | null
U8 NEGATIVE read-only in bare subshell     | nl     | U8  | false
U8d NEGATIVE subshell via write-detector   | detect | U8  | null
TABLE

# Section 10f — round-4 scan: the three shapes stripDanglingHeredocOpeners
# rewrote wrongly before it was removed. F1 = the opener IS the write
# (`cat <<'X' | bash`), so it is not trailing and no clearance may demote it;
# F2 = a single-quoted `'<<'` is not a here-doc operator (the old regex was
# quote-blind and dropped the co-located `rm -rf`); F3 = `<<<` is a here-STRING.
# MEASURED detect names: F1* settle as isNewlineInjectedWriteIR, F2* as
# isFileOpWriteIR, F3* as classify — all WRITE; the `nl` rows pin
# isNewlineInjectedWriteIR's own verdict.
echo ""
echo "=== Section 10f: round-4 fail-open shapes (opener-is-write / quote-blind / here-string) ==="
table <<'TABLE'
F1a opener piped to bash in cmd subst      | nl     | F1a | true
F1ad same via write-detector               | detect | F1a | isNewlineInjectedWriteIR
F1b opener piped to bash in bare subshell  | nl     | F1b | true
F1bd same via write-detector               | detect | F1b | isNewlineInjectedWriteIR
F1c opener piped to bash in process subst  | nl     | F1c | true
F1cd same via write-detector               | detect | F1c | isNewlineInjectedWriteIR
F1d opener piped to sh twin                | nl     | F1d | true
F1dd same via write-detector               | detect | F1d | isNewlineInjectedWriteIR
F1e opener at nested subst depth 3         | nl     | F1e | true
F1ed same via write-detector               | detect | F1e | isNewlineInjectedWriteIR
F1f DISPATCH twin cmd subst                | nl     | F1f | true
F1fd DISPATCH twin via write-detector      | detect | F1f | isNewlineInjectedWriteIR
F1g DISPATCH twin bare subshell            | nl     | F1g | true
F1gd DISPATCH subshell via write-detector  | detect | F1g | isNewlineInjectedWriteIR
F1h DISPATCH twin process subst            | nl     | F1h | true
F1hd DISPATCH procsubst via write-detector | detect | F1h | isNewlineInjectedWriteIR
F1i DISPATCH twin piped to sh              | nl     | F1i | true
F1id DISPATCH sh twin via write-detector   | detect | F1i | isNewlineInjectedWriteIR
F1j DISPATCH twin nested depth 3           | nl     | F1j | true
F1jd DISPATCH depth 3 via write-detector   | detect | F1j | isNewlineInjectedWriteIR
F2a quoted '<<' beside rm in cmd subst     | nl     | F2a | true
F2ad same via write-detector               | detect | F2a | isFileOpWriteIR
F2b quoted '<<' beside rm in subshell      | nl     | F2b | true
F2bd same via write-detector               | detect | F2b | isFileOpWriteIR
F2c DISPATCH twin quoted '<<' beside rm    | nl     | F2c | true
F2cd DISPATCH twin via write-detector      | detect | F2c | isFileOpWriteIR
F3a here-string feeding rm -rf to bash     | nl     | F3a | true
F3ad same via write-detector               | detect | F3a | classify
F3b DISPATCH twin here-string              | nl     | F3b | true
F3bd DISPATCH here-string via detector     | detect | F3b | classify
TABLE

# Section 10g — the two conditions of isSplitArtifactHeredocLine. Condition 1
# (opener must be TRAILING) is pinned by F1 above; condition 2 (the line minus
# the opener must itself read) is pinned here, in the REAL dispatch frame.
# Delimiter shape: D9 (complete `<<'END-MARK'` under DISPATCH, WRITE) covers it
# in cases-shape-variants.sh; the READ positive control is N2a/N2b in
# cases-direct.sh. Both referenced, not duplicated.
echo ""
echo "=== Section 10g: split-artifact skip conditions ==="

# Round-4 bypass these rows caught: condition 2 originally asked classify(),
# which is WRITE_PATTERNS-only and blind to file-ops and git writes, so
# `rm -rf docs; cat <<'X'` under dispatch clearance read as READ. The source now
# runs the full innerCommandIsWrite chain on the remainder. F4c pins the
# redirect remainder; F4d/F4e are the EVIL twins showing clearance is the axis.
table <<'TABLE'
F4a rm before trailing opener DISPATCH     | nl     | F4a | true
F4ad rm before opener via write-detector   | detect | F4a | isCommandSubstWriteIR
F4b git before trailing opener DISPATCH    | nl     | F4b | true
F4bd git before opener via write-detector  | detect | F4b | isCommandSubstWriteIR
F4c redirect before trailing opener        | nl     | F4c | true
F4cd redirect before opener via detector   | detect | F4c | isCommandSubstWriteIR
F4d EVIL twin of F4a has no clearance      | nl     | F4d | true
F4dd EVIL twin via write-detector          | detect | F4d | isCommandSubstWriteIR
F4e EVIL twin of F4b has no clearance      | nl     | F4e | true
F4ed EVIL twin via write-detector          | detect | F4e | isCommandSubstWriteIR
TABLE

# Section 10h — TOP-LEVEL `cat <<'X' | bash` (round-4 finding 82df8d25).
# KNOWN PRE-EXISTING FAIL-OPEN: TP1/TP2/TP3/TP6 measure READ. TP3t/TP6t (EVIL)
# and TP3n/TP6n (no dispatcher) are the in-suite control: the twins measure
# IDENTICALLY to the dispatch forms, so dispatch clearance is not the deciding
# axis — the fail-open is dispatch-independent, hence pre-existing rather than
# PR-introduced (also byte-identical on baseline 633935d2), filed separately.
# The rows assert the CURRENT value so an accidental behavior change is still
# caught; they FLIP TO WRITE TOGETHER when that separate defect is fixed.
# TP4 (single-line opener, no body) and TP5 (`bash <<'X'` interpreter heredoc)
# are the WRITE controls bounding the gap on both baseline and this branch.
echo ""
echo "=== Section 10h: top-level cat-heredoc piped to a shell (pre-existing gap) ==="
table <<'TABLE'
TP1 top-level piped to bash + rm body      | nl     | TP1 | false
TP1d same via write-detector               | detect | TP1 | null
TP2 top-level piped to sh + git push body  | nl     | TP2 | false
TP2d same via write-detector               | detect | TP2 | null
TP3 DISPATCH chained then top-level piped  | nl     | TP3 | false
TP3d chained shape via write-detector      | detect | TP3 | null
TP6 DISPATCH --body subst piped to bash    | nl     | TP6 | false
TP6d subst shape via write-detector        | detect | TP6 | null
TP3t CONTROL EVIL twin of TP3              | detect | TP3t | null
TP3n CONTROL bare no-dispatcher twin of TP3| detect | TP3n | null
TP6t CONTROL EVIL twin of TP6              | detect | TP6t | null
TP6n CONTROL bare no-dispatcher twin of TP6| detect | TP6n | null
TP4 CONTROL single-line opener no body     | detect | TP4 | classify
TP5 CONTROL interpreter heredoc bash <<X   | nl     | TP5 | true
TP5d CONTROL via write-detector            | detect | TP5 | classify
TABLE
