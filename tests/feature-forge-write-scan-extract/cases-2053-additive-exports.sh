#!/usr/bin/env bash
# Tests: hooks/lib/forge-write-extract.js, hooks/lib/parse-remote-url.js, hooks/lib/bash-write-patterns/segment-utils.js, hooks/lib/bash-write-patterns/patterns.js
# Tags: hook, bin, git, pr, github, ownership, scope:common
# Part of tests/feature-forge-write-scan-extract.sh (rules/coding/file-split.md).
# Section 2053 — additive exports for the forge-target-ownership guard (#2053).
#
# The guard reuses the SAME parse primitives as the existing write-scan
# (CPR-SSOT), so #2053 ADDs strictly-additive exports to four shipped modules.
# Pinned here: sections A/B/C/G (export surface/behaviour); D/E/F/H are
# table-driven in cases-2053-tables.sh. Fail-before-fix: until the exports
# exist the probe prints `THREW:...is not a function` — expected, not a bug.

run_2053_additive_exports() {
    init_2053_probe

    echo ""
    echo "=== 2053-A: additive-only export surface of forge-write-extract.js ==="

    # A removed export silently breaks the outbound scan; an unplanned export
    # means the module grew a second, unreviewed entry point.
    expect_expr "existing 6 exports all still present" "true" \
        '["isForgeScanTarget","isRepoWriteTarget","extractTexts","extractRepoFlag","GH_API_WRITE_REGEX","GH_REPO_WRITE_REGEX"].every(k => k in m)'
    expect_expr "export set is exactly the 6 existing + the 2 new" \
        '"GH_API_WRITE_REGEX,GH_REPO_WRITE_REGEX,extractRepoFlag,extractRepoSelectors,extractTexts,isForgeScanTarget,isGhApiWriteFromFlags,isRepoWriteTarget"' \
        'Object.keys(m).sort().join(",")'
    expect_expr "isForgeScanTarget is still a function" '"function"' 'typeof m.isForgeScanTarget'
    expect_expr "isRepoWriteTarget is still a function" '"function"' 'typeof m.isRepoWriteTarget'
    expect_expr "extractTexts is still a function" '"function"' 'typeof m.extractTexts'
    expect_expr "extractRepoFlag is still a function" '"function"' 'typeof m.extractRepoFlag'
    expect_expr "GH_API_WRITE_REGEX is still a RegExp" "true" 'm.GH_API_WRITE_REGEX instanceof RegExp'
    expect_expr "GH_REPO_WRITE_REGEX is still a RegExp" "true" 'm.GH_REPO_WRITE_REGEX instanceof RegExp'

    echo ""
    echo "=== 2053-B: extractRepoFlag behaviour pins (unchanged by #2053) ==="

    # String-level results the existing callers rely on. The guard adds an
    # ARGV-level selector reader beside them; it must not rewrite these.
    expect_expr "extractRepoFlag --repo <v>" '"someone/else"' \
        'String(m.extractRepoFlag("gh issue create --repo someone/else"))'
    expect_expr "extractRepoFlag --repo=<v>" '"someone/else"' \
        'String(m.extractRepoFlag("gh issue create --repo=someone/else"))'
    expect_expr "extractRepoFlag -R <v>" '"someone/else"' \
        'String(m.extractRepoFlag("gh issue create -R someone/else"))'
    # C47 control: the attached short form is the string-level blind spot that
    # extractRepoSelectors (2053-D) closes. Recorded here so a silent change shows.
    expect_expr "extractRepoFlag -R<v> attached — recorded, not relied on" '"null"' \
        'String(m.extractRepoFlag("gh issue create -Rsomeone/else"))'

    echo ""
    echo "=== 2053-C: GH_*_WRITE_REGEX behaviour pins (unchanged by #2053) ==="

    expect_expr "GH_API_WRITE_REGEX matches -X POST" "true" \
        'new RegExp(m.GH_API_WRITE_REGEX.source, m.GH_API_WRITE_REGEX.flags.replace("g","")).test("gh api -X POST repos/o/r/issues")'
    expect_expr "GH_API_WRITE_REGEX matches --method PATCH" "true" \
        'new RegExp(m.GH_API_WRITE_REGEX.source, m.GH_API_WRITE_REGEX.flags.replace("g","")).test("gh api --method PATCH repos/o/r/issues/1")'
    expect_expr "GH_API_WRITE_REGEX does not match -X GET" "false" \
        'new RegExp(m.GH_API_WRITE_REGEX.source, m.GH_API_WRITE_REGEX.flags.replace("g","")).test("gh api -X GET repos/o/r/issues")'
    expect_expr "GH_REPO_WRITE_REGEX matches gh repo create" "true" \
        'new RegExp(m.GH_REPO_WRITE_REGEX.source, m.GH_REPO_WRITE_REGEX.flags.replace("g","")).test("gh repo create o/r")'
    expect_expr "isRepoWriteTarget(gh repo edit) stays true" "true" \
        'm.isRepoWriteTarget("gh repo edit o/r --description x") === true'
    expect_expr "isRepoWriteTarget(gh repo view) stays false" "true" \
        'm.isRepoWriteTarget("gh repo view o/r") === false'

    echo ""
    echo "=== 2053-G: NEW segment-utils wrapper primitives ==="

    # The guard peels the same wrapper chain the write predicates peel, so that
    # `env -C /elsewhere gh issue create` resolves to `gh` by ONE implementation.
    expect_expr "peelWrappers is exported" '"function"' 'typeof s.peelWrappers'
    expect_expr "peelWrappers sees through env assignments" '"gh"' \
        's.peelWrappers("env", ["GH_REPO=a/b", "gh", "issue", "create"]).cmd0'
    expect_expr "peelWrappers keeps the inner argv" '"issue,create"' \
        's.peelWrappers("env", ["GH_REPO=a/b", "gh", "issue", "create"]).argv.join(",")'
    expect_expr "peelWrappers peels a chain (nice + command)" '"gh"' \
        's.peelWrappers("nice", ["-n", "5", "command", "gh", "issue", "create"]).cmd0'
    expect_expr "peelWrappers fails closed on an unknown option" "true" \
        '(function(){var r=s.peelWrappers("env",["--frobnicate","gh","issue","create"]);return r.ambiguous === true && r.cmd0 === "env";})()'
    expect_expr "peelWrappers leaves a non-wrapper untouched" '"gh"' \
        's.peelWrappers("gh", ["issue", "create"]).cmd0'
    expect_expr "ASSIGN_RE is a RegExp" "true" 's.ASSIGN_RE instanceof RegExp'
    expect_expr "ASSIGN_RE matches GH_REPO=" "true" 'new RegExp(s.ASSIGN_RE.source).test("GH_REPO=a/b")'
    expect_expr "ASSIGN_RE does not match a bare word" "false" 'new RegExp(s.ASSIGN_RE.source).test("gh")'
    expect_expr "WRAPPER_SPECS declares env with eatAssignments" "true" \
        's.WRAPPER_SPECS.env.eatAssignments === true'
    expect_expr "WRAPPER_SPECS env treats -C as value-taking" "true" \
        's.WRAPPER_SPECS.env.valueFlags.has("-C") === true'
    expect_expr "isAttachedShortValue(-oL, stdbuf) is true" "true" \
        's.isAttachedShortValue("-oL", s.WRAPPER_SPECS.stdbuf) === true'
    expect_expr "isAttachedShortValue(-o, stdbuf) is false (separated form)" "true" \
        's.isAttachedShortValue("-o", s.WRAPPER_SPECS.stdbuf) === false'
    expect_expr "isAttachedShortValue rejects a long option" "true" \
        's.isAttachedShortValue("--output", s.WRAPPER_SPECS.stdbuf) === false'
    expect_expr "segment-utils keeps its four pre-2053 exports" "true" \
        '["resolveEffectiveCommand","resolveEffectiveArgv","scanWrappedVerb","commandBasename"].every(k => k in s)'
}
