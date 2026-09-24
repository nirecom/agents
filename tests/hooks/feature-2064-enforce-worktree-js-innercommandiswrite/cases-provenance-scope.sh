# Tests: hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/dispatch-provenance.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-targets.js
# Tags: worktree, enforce, hook, write-detector, dispatch-provenance, scope:issue-specific
# Sections 17-19 — gh Group-A verb family, narrow predicates that revoke clearance, shell-option injection.
# Sourced by tests/feature-2064-enforce-worktree-js-innercommandiswrite.sh.
# Section 17: segmentDispatchKind tests GH_GROUP_A_REGEX (patterns.js SSOT); all 13 verbs + truncated --body opener.
echo ""
echo "=== Section 17: H1 gh Group-A verb family (GH_GROUP_A_REGEX SSOT) ==="
table <<'TABLE'
GA1 gh pr create is Group-A                | kindstr | GA1  | gh-group-a
GA2 gh pr edit is Group-A                  | kindstr | GA2  | gh-group-a
GA3 gh pr close is Group-A                 | kindstr | GA3  | gh-group-a
GA4 gh pr comment is Group-A               | kindstr | GA4  | gh-group-a
GA5 gh pr review is Group-A                | kindstr | GA5  | gh-group-a
GA6 gh issue create is Group-A             | kindstr | GA6  | gh-group-a
GA7 gh issue edit is Group-A               | kindstr | GA7  | gh-group-a
GA8 gh issue close is Group-A              | kindstr | GA8  | gh-group-a
GA9 gh issue comment is Group-A            | kindstr | GA9  | gh-group-a
GA10 gh repo create is Group-A             | kindstr | GA10 | gh-group-a
GA11 gh repo edit is Group-A               | kindstr | GA11 | gh-group-a
GA12 gh repo rename is Group-A             | kindstr | GA12 | gh-group-a
GA13 gh repo archive is Group-A            | kindstr | GA13 | gh-group-a
TABLE
echo "--- Section 17 truncated-opener verdict must be READ on each Group-A verb ---"
table <<'TABLE'
GA1c pr create + truncated opener -> read  | cs   | GA1  | false
GA2c pr edit + truncated opener -> read    | cs   | GA2  | false
GA3c pr close + truncated opener -> read   | cs   | GA3  | false
GA4c pr comment + truncated opener -> read | cs   | GA4  | false
GA5c pr review + truncated opener -> read  | cs   | GA5  | false
GA6c issue create + truncated -> read      | cs   | GA6  | false
GA7c issue edit + truncated -> read        | cs   | GA7  | false
GA8c issue close + truncated -> read       | cs   | GA8  | false
GA9c issue comment + truncated -> read     | cs   | GA9  | false
GA10c repo create + truncated -> read      | cs   | GA10 | false
GA11c repo edit + truncated -> read        | cs   | GA11 | false
GA1p pr create layer-1 provenance          | prov | GA1  | cleared
GA6p issue create layer-1 provenance       | prov | GA6  | cleared
GA10p repo create layer-1 provenance       | prov | GA10 | cleared
GA12p repo rename layer-1 provenance       | prov | GA12 | cleared
TABLE

# The opposing rows are the destructive verbs the regex deliberately EXCLUDES:
# `gh pr merge` / `gh issue delete` / `gh repo delete` are isGhWriteIR writes, so
# they get NO provenance and the identical truncated-opener shape must still
# classify WRITE. Same shape, opposite verdict — that is what proves the clearance
# is verb-scoped. GA6d rides along because `gh issue create` is itself an
# isGhWriteIR write, so the detector reports isGhWriteCommand even with the opener
# cleared; that is the gh-write path, and GA6c above is the clearance row.
echo "--- Section 17 destructive verbs get NO provenance (same shape stays write) ---"
table <<'TABLE'
GN1 gh pr merge is NOT Group-A             | kindstr | GN1 | null
GN2 gh issue delete is NOT Group-A         | kindstr | GN2 | null
GN3 gh repo delete is NOT Group-A          | kindstr | GN3 | null
GN1p pr merge blocks layer-1 clearance     | prov    | GN1 | null
GN2p issue delete blocks layer-1 clearance | prov    | GN2 | null
GN3p repo delete blocks layer-1 clearance  | prov    | GN3 | null
GN1c pr merge + truncated opener -> write  | cs      | GN1 | true
GN2c issue delete + truncated -> write     | cs      | GN2 | true
GN3c repo delete + truncated -> write      | cs      | GN3 | true
GN1d pr merge via write-detector           | detect  | GN1 | isGhWriteCommand
GN2d issue delete via write-detector       | detect  | GN2 | isGhWriteCommand
GN3d repo delete via write-detector        | detect  | GN3 | isGhWriteCommand
GA6d issue create via write-detector       | detect  | GA6 | isGhWriteCommand
TABLE

# Section 18 — H2. Narrowness of loadNarrowWritePredicates.
# Why: layer 1 (deriveDispatchProvenance condition 3) runs the whole narrow
# predicate list over every segment AND over every command substitution. Drop one
# predicate and a real write riding along with a dispatcher invocation inherits
# the dispatcher's clearance. One paired row per predicate: `a` = write appended
# as a TOP-LEVEL segment, `b` = write embedded INSIDE a `$( ... )`; both must keep
# prov=null and still classify write. Each `a` fixture also carries the sanctioned
# truncated opener, so the row doubles as proof that a genuine write REVOKES the
# clearance the opener would otherwise have earned (contrast C2a: opener alone).
echo ""
echo "=== Section 18: H2 narrow write predicates block layer-1 clearance ==="

# MEASURED (interpreter choice): a Python interpreter given an inline body that
# writes a file does NOT fire isInterpreterCWriteIR — INTERP_NAMES covers POSIX
# shells / pwsh / cmd and a Python body is not inspected. Pre-existing classifier
# scope, not a #2064 regression, so NW3 uses `sh -c 'rm -rf /tmp/pwn'` instead,
# which is the shape isInterpreterCWriteIR actually owns.
table <<'TABLE'
NW1a isPwshWriteIR top-level               | prov | NW1a | null
NW1b isPwshWriteIR inside subst            | prov | NW1b | null
NW2a isPkgMgrWriteIR top-level             | prov | NW2a | null
NW2b isPkgMgrWriteIR inside subst          | prov | NW2b | null
NW3a isInterpreterCWriteIR top-level       | prov | NW3a | null
NW3b isInterpreterCWriteIR inside subst    | prov | NW3b | null
NW4a isEncodedCommandWriteIR top-level     | prov | NW4a | null
NW4b isEncodedCommandWriteIR inside subst  | prov | NW4b | null
NW5a isExtendedFileOpWriteIR top-level     | prov | NW5a | null
NW5b isExtendedFileOpWriteIR inside subst  | prov | NW5b | null
TABLE
echo "--- Section 18 overall verdict must stay WRITE for all ten ---"
table <<'TABLE'
NW1ac pwsh write not laundered             | cs | NW1a | true
NW1bc pwsh write in subst not laundered    | cs | NW1b | true
NW2ac pkg-mgr write not laundered          | cs | NW2a | true
NW2bc pkg-mgr write in subst not laundered | cs | NW2b | true
NW3ac interpreter -c not laundered         | cs | NW3a | true
NW3bc interpreter -c in subst not laundered| cs | NW3b | true
NW4ac encoded command not laundered        | cs | NW4a | true
NW4bc encoded cmd in subst not laundered   | cs | NW4b | true
NW5ac extended file-op not laundered       | cs | NW5a | true
NW5bc extended file-op in subst not laundered | cs | NW5b | true
TABLE
echo "--- Section 18 write-detector names (first-match order) ---"
table <<'TABLE'
NW1ad pwsh write via write-detector        | detect | NW1a | isPwshWriteIR
NW1bd pwsh subst via write-detector        | detect | NW1b | isCommandSubstWriteIR
NW2ad pkg-mgr write via write-detector     | detect | NW2a | isCommandSubstWriteIR
NW4ad encoded cmd via write-detector       | detect | NW4a | isCommandSubstWriteIR
NW5ad extended file-op via write-detector  | detect | NW5a | isCommandSubstWriteIR
TABLE

# Section 19 — H3. Shell-option injection against segmentDispatchKind.
# Why: bash/sh/zsh accept options whose VALUE is a separate following token
# (`--rcfile FILE`, `--init-file FILE`, `-o OPTNAME`). Picking the first argv
# token without a leading `-` would read that VALUE as the script, laundering
# `bash --rcfile <dispatch> /tmp/evil.sh` into a cleared dispatch. These rows PIN
# THE FIX (resolveShellScriptToken + SHELL_BOOLEAN_OPTS): the script token is
# resolved left to right, so a value-taking or unknown option in front of it fails
# closed, and SO7 (laundered evil.sh + sanctioned truncated opener) stays WRITE,
# matching the honest spelling SO8. SOK1-SOK4 prove the fix did not over-tighten.
echo ""
echo "=== Section 19: H3 shell-option injection fails closed ==="
table <<'TABLE'
SO1 bash --rcfile <dispatch> evil.sh       | kindstr | SO1 | null
SO2 bash --init-file <dispatch> evil.sh    | kindstr | SO2 | null
SO3 bash --rcfile=<dispatch> evil.sh       | kindstr | SO3 | null
SO4 bash -o <dispatch> evil.sh             | kindstr | SO4 | null
SO5 sh --rcfile <dispatch> evil.sh         | kindstr | SO5 | null
SO6 zsh --rcfile <dispatch> evil.sh        | kindstr | SO6 | null
SO1p --rcfile form raises no provenance    | prov    | SO1 | null
SO3p attached =value form fails closed     | prov    | SO3 | null
SO4p -o form raises no provenance          | prov    | SO4 | null
SO7 laundered evil.sh + truncated -> write | cs      | SO7 | true
SO7d laundered evil.sh via write-detector  | detect  | SO7 | isCommandSubstWriteIR
SO8 honest bash evil.sh + truncated -> write | cs    | SO8 | true
SO8d honest evil.sh via write-detector     | detect  | SO8 | isCommandSubstWriteIR
TABLE
echo "--- Section 19 benign dispatch forms must still clear ---"
table <<'TABLE'
SOK1 bash <dispatch> --body (no options)   | kindstr | SOK1 | known-dispatch
SOK1p no-option form clears provenance     | prov    | SOK1 | cleared
SOK1c no-option form stays read            | cs      | SOK1 | false
SOK2 boolean option -e before script       | kindstr | SOK2 | known-dispatch
SOK2c boolean option form stays read       | cs      | SOK2 | false
SOK3 -- terminator before script           | kindstr | SOK3 | known-dispatch
SOK3c -- terminator form stays read        | cs      | SOK3 | false
SOK4 --posix -e boolean chain before script| kindstr | SOK4 | known-dispatch
TABLE

# SKIPPED: areAllWriteSegmentsUnderWorkflowDir positive path (returns true)
# Because: it needs a write target physically under the resolved workflow dir,
#   i.e. pinned CLAUDE_WORKFLOW_DIR + WORKFLOW_PLANS_DIR fixtures that this
#   pure-predicate suite otherwise has no need for (rules/test/fixture-isolation.md).
# TL3 gap: only a real session proves the marker-gate allow actually fires.
