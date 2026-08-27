#!/usr/bin/env bash
# Tests: hooks/confirm-forge-target-ownership.js, hooks/confirm-forge-target-ownership/
# Tags: hook, pre-tool-use, github, gh, ownership, security, scope:issue-specific
# Part of tests/feature-2053-forge-target-ownership.sh (rules/coding/file-split.md).
# Block C8 — gh api effective-method precedence, table-driven.
#
# WHY: `gh api` has no verb — write is decided by flags whose meaning depends
# on ORDER: any of -f/-F/--field/--raw-field/--input defaults the method to
# POST, an explicit -X/--method overrides that, and pflag makes the LAST
# occurrence of a repeated flag effective. Reading only "is there a -X POST"
# lets an implicit POST through past a stale -X GET.

run_block_c8() {
    echo ""
    echo "=== C8-1: field flags that imply POST, on a FOREIGN issues endpoint ==="

    # Every row targets the foreign repo, so the expected verdict is the
    # write/read classification itself: ask = classified as a write in scope,
    # silent = classified as a read. The owned mirror follows in C8-2, which is
    # what keeps a row from passing on a guard that simply asks at every gh api.
    local name want cmd
    _c8_row() { # <id> <want> <command>
        reset_env
        run_case "$FX_OWNED" "$3"
        assert_decision "$1" "$2"
    }

    while IFS='|' read -r name want cmd; do
        [ -z "$name" ] && continue
        _c8_row "C8-1 [$name]" "$want" "$cmd"
    done <<TABLE
--raw-field implies POST|ask|gh api repos/$FOREIGN/r/issues --raw-field title=x
--field implies POST|ask|gh api repos/$FOREIGN/r/issues --field title=x
--field= attached|ask|gh api repos/$FOREIGN/r/issues --field=title=x
--input file implies POST|ask|gh api repos/$FOREIGN/r/issues --input /tmp/body.json
--input - implies POST|ask|gh api repos/$FOREIGN/r/issues --input -
--input= attached|ask|gh api repos/$FOREIGN/r/issues --input=/tmp/body.json
-f implies POST|ask|gh api repos/$FOREIGN/r/issues -f title=x
-F implies POST|ask|gh api repos/$FOREIGN/r/issues -F n=1
no flags at all is a GET|silent|gh api repos/$FOREIGN/r/issues
only -H is a GET|silent|gh api -H "Accept: x" repos/$FOREIGN/r/issues
only --jq is a GET|silent|gh api --jq .x repos/$FOREIGN/r/issues
only --paginate is a GET|silent|gh api --paginate repos/$FOREIGN/r/issues
TABLE

    echo ""
    echo "=== C8-2: the method flag AFTER the endpoint still decides ==="

    while IFS='|' read -r name want cmd; do
        [ -z "$name" ] && continue
        _c8_row "C8-2 [$name]" "$want" "$cmd"
    done <<TABLE
-X POST after endpoint|ask|gh api repos/$FOREIGN/r/issues -X POST -f title=x
--method POST after endpoint|ask|gh api repos/$FOREIGN/r/issues --method POST
--method=POST after endpoint|ask|gh api repos/$FOREIGN/r/issues --method=POST
-XPOST attached after endpoint|ask|gh api repos/$FOREIGN/r/issues -XPOST
-X PATCH after endpoint|ask|gh api repos/$FOREIGN/r/issues/1 -X PATCH -f state=closed
-X PUT after endpoint|ask|gh api repos/$FOREIGN/r/issues/1 -X PUT
-X DELETE after endpoint|ask|gh api repos/$FOREIGN/r/issues/1 -X DELETE
explicit GET beats implied POST|silent|gh api repos/$FOREIGN/r/issues -f title=x -X GET
explicit GET before fields|silent|gh api -X GET repos/$FOREIGN/r/issues -f title=x
lowercase get beats fields|silent|gh api repos/$FOREIGN/r/issues -f title=x --method get
-X HEAD is a read|silent|gh api repos/$FOREIGN/r/issues -X HEAD
TABLE

    echo ""
    echo "=== C8-3: repeated and conflicting method flags — last occurrence wins ==="

    # pflag overwrites on repeat, so the EFFECTIVE method is the last one. A
    # classifier using "any write method present" fails row 1; one using "the
    # first method" fails row 2. Both rows must hold at once.
    while IFS='|' read -r name want cmd; do
        [ -z "$name" ] && continue
        _c8_row "C8-3 [$name]" "$want" "$cmd"
    done <<TABLE
-X GET then -X POST -> POST|ask|gh api -X GET -X POST repos/$FOREIGN/r/issues
-X POST then -X GET -> GET|silent|gh api -X POST -X GET repos/$FOREIGN/r/issues
--method GET then -X POST|ask|gh api --method GET -X POST repos/$FOREIGN/r/issues
-X POST then --method=GET|silent|gh api -X POST --method=GET repos/$FOREIGN/r/issues
-X POST twice|ask|gh api -X POST -X POST repos/$FOREIGN/r/issues
unknown method value|ask|gh api -X FROBNICATE repos/$FOREIGN/r/issues -f t=x
method value missing|ask|gh api repos/$FOREIGN/r/issues -X
method value is a flag|ask|gh api -X -f title=x repos/$FOREIGN/r/issues
TABLE

    echo ""
    echo "=== C8-4: the owned mirror — the same classifications, proven target ==="

    # Same rows, owned repo. A write classification here must end in a silent
    # ALLOW that actually spent a probe, which is what separates "in scope and
    # proven" from "never classified as in scope at all".
    local probes
    while IFS='|' read -r name want cmd; do
        [ -z "$name" ] && continue
        reset_env
        run_case "$FX_OWNED" "$cmd"
        assert_decision "C8-4 [$name] -> silent" "silent"
        probes="$want"
        assert_probes "C8-4 [$name] probe budget" "api user" "$probes"
    done <<TABLE
--raw-field owned is proven|1|gh api repos/$OWNER/agents/issues --raw-field title=x
--field owned is proven|1|gh api repos/$OWNER/agents/issues --field title=x
--input owned is proven|1|gh api repos/$OWNER/agents/issues --input /tmp/body.json
-X POST after endpoint owned|1|gh api repos/$OWNER/agents/issues -X POST
-X GET owned is out of scope|0|gh api repos/$OWNER/agents/issues -X GET -f t=x
no flags owned is out of scope|0|gh api repos/$OWNER/agents/issues
TABLE

    unset -f _c8_row
}
