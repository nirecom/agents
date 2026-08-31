# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, dispatch-provenance, scope:issue-specific
# Sections 4-9 — write predicates (direct), dispatch-provenance layers, gh argv, segment-checks, fix-1424/1425/1448 mirrors.
# Sourced by feature-2064-enforce-worktree-js-innercommandiswrite.sh.

# Section 4 — isNewlineInjectedWriteIR called DIRECTLY.
# R1: detectWritePredicate returns on the FIRST true predicate, so the other two
# predicates are not observable through it — call each one directly.
# N2a-N2c are EXPECTED-FAIL-BEFORE-FIX (they return true today).
echo "=== Section 4: isNewlineInjectedWriteIR (direct) ==="
table <<'TABLE'
N2a real dispatch reopen/1599 (EXPECTED-FAIL-BEFORE-FIX) | nl | N2a | false
N2b real dispatch sub-of/1249 (EXPECTED-FAIL-BEFORE-FIX) | nl | N2b | false
N2c dispatch + two cat heredocs (EXPECTED-FAIL-BEFORE-FIX) | nl | N2c | false
N2d dispatch + LF rm -rf                                 | nl | N2d | true
N2e dispatch + LF redirect into README.md                | nl | N2e | true
N2f dispatch + LF bash-fronted heredoc                   | nl | N2f | true
N2g dispatch + LF cat heredoc piped to bash              | nl | N2g | true
N2h dispatch + LF unquoted heredoc delimiter             | nl | N2h | true
N2i dispatch + title command substitution rm             | nl | N2i | true
N2j dispatch + LF git commit                             | nl | N2j | true
N2k NON-dispatcher same shape as N2a                     | nl | N2k | true
N2l path-traversal dispatcher path                       | nl | N2l | true
N2m OS-temp dispatcher path                              | nl | N2m | true
TABLE

# Section 5 — the other two predicates, called DIRECTLY.
#
# C2a's firing shape was found by probing isCommandSubstWriteIR on each candidate:
# a COMPLETE `$(cat <<'EOF' ... EOF )` and `$(cat /tmp/f)` are read, `$(rm -rf …)`
# is a narrow file-op write, and the TRUNCATED `$(cat <<'EOF')` — plus its
# backtick sibling — is the minimal input that fires purely because
# innerCommandIsWrite -> classify() sees a truncated cat heredoc opener.
echo ""
echo "=== Section 5: isCommandSubstWriteIR / isExoticExecWriteIR (direct) ==="
table <<'TABLE'
C2a dispatch + $(cat <<EOF) truncated (EXPECTED-FAIL-BEFORE-FIX) | cs  | C2a | false
C2b dispatch + $(rm -rf /tmp/pwn)                               | cs  | C2b | true
C2c NON-dispatcher + $(cat <<EOF) truncated                     | cs  | C2c | true
X2a dispatch + eval "cat <<EOF" (EXPECTED-FAIL-BEFORE-FIX)      | exo | X2a | false
X2b NON-dispatcher + eval "cat <<EOF"                           | exo | X2b | true
X2c dispatch + eval 'rm -rf /tmp/pwn'                           | exo | X2c | true
X2d dispatch + echo f piped to xargs rm                         | exo | X2d | true
TABLE

# Section 6 — provenance unit tests. These require modules/exports that do NOT
# exist yet; each prints MODULE-MISSING / EXPORT-MISSING and FAILs with a
# diagnostic instead of crashing the run. ALL of Section 6 is
# EXPECTED-FAIL-BEFORE-FIX. One case per layer-1 condition 1-3 branch and per
# layer-2 condition.
echo ""
echo "=== Section 6: dispatch provenance (layer 1) — ALL EXPECTED-FAIL-BEFORE-FIX ==="
table <<'TABLE'
P1 L1c1 null ir                        | prov | P1 | null
P2 L1c1 parseFailure ir                | prov | P2 | null
P3 L1c1 empty segments                 | prov | P3 | null
P4 L1c2 no dispatcher / no gh segment  | prov | P4 | null
P5 L1c2 dispatcher segment present     | prov | P5 | cleared
P6 L1c2 gh Group-A segment present     | prov | P6 | cleared
P7 L1c3 dispatcher + rm segment        | prov | P7 | null
P8 L1c3 dispatcher + redirect segment  | prov | P8 | null
P9 L1c3 dispatcher + git write segment | prov | P9 | null
K1 segmentDispatchKind dispatcher/echo | kind | K1 | yes/no
K2 segmentDispatchKind gh issue create | kind | K2 | yes
K3 segmentDispatchKind plain echo      | kind | K3 | no
K4 segmentDispatchKind path traversal  | kind | K4 | no
K5 segmentDispatchKind OS-temp path    | kind | K5 | no
K6 segmentDispatchKind gh read-only    | kind | K6 | no
TABLE

echo ""
echo "=== Section 6b: isTruncatedCatHeredocOnly (layer 2) — ALL EXPECTED-FAIL-BEFORE-FIX ==="
table <<'TABLE'
H1 truncated quoted cat opener alone       | trunc     | H1 | true
H2 ir omitted -> fail-closed               | truncnoir | H1 | false
H3 two segments (cat heredoc piped to bash)| trunc     | H3 | false
H4 unquoted delimiter                      | trunc     | H4 | false
H5 non-cat (bash) fronted opener           | trunc     | H5 | false
H7 opener count mismatch (quoted+unquoted) | trunc     | H7 | false
H9 verbatim measured dispatch fragment     | trunc     | H9 | false
TABLE

# Section 7 — gh provenance argv resolution.
# resolveGhSubArgv (patterns.js) is the SSOT for "which tokens are the gh
# subcommand"; it is module-private, so isGhWriteIR — its only in-repo consumer —
# is the closest observable seam. G1a-G1c pin that a naive "first two non-flag
# tokens" reading (which would yield `owner/repo` + `issue`) is wrong.
echo ""
echo "=== Section 7: gh argv resolution (resolveGhSubArgv SSOT) ==="
table <<'TABLE'
G1a --repo o/r before subcommand           | ghwrite | G1a | true
G1b -R o/r before subcommand               | ghwrite | G1b | true
G1c --repo=o/r attached form               | ghwrite | G1c | true
G1e --repo o/r + read-only subcommand      | ghwrite | G1e | false
G2a env FOO=1 prefix                       | ghwrite | G2a | true
G2b FOO=1 assignment prefix                | ghwrite | G2b | true
TABLE
echo "--- Section 7 provenance rows (EXPECTED-FAIL-BEFORE-FIX) ---"
table <<'TABLE'
G1d gh --repo o/r pr create is Group-A     | kind | G1d | yes
G2c env FOO=1 gh issue comment is Group-A  | kind | G2c | yes
G2d FOO=1 gh issue comment is Group-A      | kind | G2d | yes
TABLE

# Section 8 — consumer-level coverage.
# The three segment-checks.js consumers stay 1-argument, so ctx===undefined and
# each predicate self-derives provenance — dispatcher/gh input behavior can shift
# with NO consumer edit. These rows pin current behavior; all must stay unchanged.

# NOTE: the `\r`/`\n` early bail exists ONLY in isEverySegmentExcluded (:30);
# areAllWriteSegmentsOutsideSessionScope and areAllWriteSegmentsUnderWorkflowDir
# have no such bail — S8d proves it (a newline-bearing command still reaches the
# segment loop there). All three build a SINGLE-SEGMENT IR from seg.rawText, so
# they never traverse stripHeredocBody, but a natively-truncated command
# substitution still reaches them — S8j pins that path.
echo ""
echo "=== Section 8: segment-checks consumers + write-detector ==="
table <<'TABLE'
S8a isEverySegmentExcluded :30 newline bail        | everyExcl    | N2a | false
S8b isEverySegmentExcluded :54 exotic-exec         | everyExcl    | S8b | false
S8c isEverySegmentExcluded :61 command-subst       | everyExcl    | S8c | false
S8i isEverySegmentExcluded positive (excluded tgt) | everyExcl    | S8i | true
S8d outsideSessionScope has NO newline bail        | outsideScope | N2a | true
S8e outsideSessionScope :111 exotic-exec           | outsideScope | S8b | false
S8f outsideSessionScope :119 command-subst         | outsideScope | S8c | false
# S8j's seg[0].rawText is byte-identical to C2a, and isCommandSubstWriteIR is called
# 1-arg, so once C2a returns false no write segment remains -> want=true.
S8j outsideSessionScope dispatcher truncated subst (EXPECTED-FAIL-BEFORE-FIX) | outsideScope | S8j | true
S8g underWorkflowDir :150 exotic-exec              | underWf      | S8b | false
S8h underWorkflowDir :157 command-subst            | underWf      | S8c | false
TABLE
echo "--- write-detector end-to-end ---"
table <<'TABLE'
S8l detectWritePredicate genuine rm                | detect | S8l | isFileOpWriteIR
S8m detectWritePredicate dispatch + LF rm          | detect | S8m | isNewlineInjectedWriteIR
S8n detectWritePredicate read-only git status      | detect | S8n | null
S8k detectWritePredicate real dispatch (EXPECTED-FAIL-BEFORE-FIX) | detect | N2a | null
TABLE

# Section 9 — existing-behavior preservation.
# Mirrors N1a-N1e of tests/fix-1424-1425-1448-write-detector.sh (that file is NOT
# edited; it is run separately and its baseline recorded). Q4 mirrors N1d and Q5
# mirrors N1e — the two the fix is most likely to disturb.
echo ""
echo "=== Section 9: existing behavior preserved (mirrors N1a-N1e) ==="
table <<'TABLE'
Q1 mirrors N1a genuine LF injection        | nl | Q1 | true
Q2 mirrors N1b backslash continuation      | nl | Q2 | false
Q3 mirrors N1c pure read multi-line        | nl | Q3 | false
Q4 mirrors N1d write on second line        | nl | Q4 | true
Q5 mirrors N1e gh DQ body embedded LF      | nl | Q5 | false
TABLE

