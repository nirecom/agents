#!/usr/bin/env bash
# Tests: hooks/lib/forge-write-extract.js, hooks/lib/parse-remote-url.js, hooks/lib/bash-write-patterns/segment-utils.js, hooks/lib/bash-write-patterns/patterns.js
# Tags: hook, bin, git, pr, github, ownership, scope:common
# Part of tests/feature-forge-write-scan-extract.sh (rules/coding/file-split.md).
# Sections 2053-D/E/F/H — the NEW parser and classifier surfaces, table-driven.
#
# WHY table-driven: these are pure functions over a large input domain, and
# the risk is a MISSING row, not a missing assertion style — a table makes the
# domain visible in one screen instead of buried in repeated helper calls.
# Fail-before-fix: until the exports exist every row prints
# `THREW:MODULE-MISSING:...` or `THREW:...is not a function`.

run_2053_tables() {
    init_2053_probe

    echo ""
    echo "=== 2053-D: NEW extractRepoSelectors — every way a target can be named ==="

    # The guard must see EVERY way a target repo can be named on the command
    # line; a form it cannot see is a form that reaches an unowned repo silently.
    # `V` renders the selector values, `N` the count, `NV` count:firstValue —
    # "named but unresolvable" must never read the same as "absent".
    local V='m.extractRepoSelectors(ARGV).map(x => x.value).join(",")'
    local N='String(m.extractRepoSelectors(ARGV).length)'

    _d() { # <name> <want> <argv-js> [expr-template]
        local tmpl="${4:-$V}"
        expect_expr "2053-D [$1]" "$2" "${tmpl//ARGV/$3}"
    }

    _d "--repo <v>"            '"a/b"' '["issue","create","--repo","a/b"]'
    _d "--repo=<v>"            '"a/b"' '["issue","create","--repo=a/b"]'
    _d "-R <v>"                '"a/b"' '["issue","create","-R","a/b"]'
    _d "-R=<v>"                '"a/b"' '["issue","create","-R=a/b"]'
    _d "-R<v> attached (C47-1)" '"a/b"' '["issue","create","-Ra/b"]'
    _d "-R<v> does not eat the next token (C47-2)" '"a/b"' \
        '["issue","create","-Ra/b","--title","T"]'
    _d "host-qualified selector is reported verbatim" '"ghe.example.com/a/b"' \
        '["issue","create","--repo","ghe.example.com/a/b"]'
    _d "a full URL selector is reported verbatim" '"https://github.com/a/b"' \
        '["issue","create","--repo","https://github.com/a/b"]'
    _d "two selectors are both reported (last-wins is the caller job)" '"a/b,c/d"' \
        '["issue","create","-R","a/b","--repo=c/d"]'
    _d "three selectors are all reported" '"a/b,c/d,e/f"' \
        '["issue","create","-R","a/b","--repo=c/d","-Re/f"]'
    _d "a repeated identical selector still reports twice" '"a/b,a/b"' \
        '["issue","create","-R","a/b","--repo","a/b"]'
    _d "no selector -> zero" '"0"' '["issue","create","--title","T"]' "$N"
    _d "empty argv -> zero" '"0"' '[]' "$N"
    _d "tokens after -- are operands, not selectors" '"0"' \
        '["issue","create","--","--repo","attacker/evil"]' "$N"
    _d "--repo text inside one body token is not a selector" '"0"' \
        '["issue","create","--body","see --repo attacker/evil"]' "$N"
    _d "a lookalike long flag is not --repo" '"0"' \
        '["issue","create","--repository","a/b"]' "$N"
    _d "-Rx where x is not a repo is still a selector value" '"notarepo"' \
        '["issue","create","-Rnotarepo"]'
    _d "an uppercase long flag is not --repo" '"0"' \
        '["issue","create","--REPO","a/b"]' "$N"

    # "named but unresolvable" is its own state: one selector whose value is
    # null. Collapsing it to zero selectors is the bug this pins — it would let
    # a dangling -R fall back to origin as though no target had been named.
    local NV='(function(){var sel=m.extractRepoSelectors(ARGV);return sel.length + ":" + String(sel[0] && sel[0].value);})()'
    _d "bare -R at end of argv (C47-3)" '"1:null"' '["issue","create","-R"]' "$NV"
    _d "bare --repo at end of argv" '"1:null"' '["issue","create","--repo"]' "$NV"
    _d "--repo= with an empty value" '"1:"' '["issue","create","--repo="]' "$NV"
    _d "--repo followed by another flag takes no value" '"1:null"' \
        '["issue","create","--repo","--title","T"]' "$NV"
    _d "--repo followed by -- takes no value" '"1:null"' \
        '["issue","create","--repo","--"]' "$NV"

    # The index is what lets a caller apply gh's last-occurrence-wins rule and
    # what lets the guard say WHICH token it objected to.
    local IDX='String(m.extractRepoSelectors(ARGV)[0].index)'
    # --web is a KNOWN BOOLEAN for issue create, so it does not swallow the
    # next token: -R at index 3 still reads as a selector. (A value-taking flag
    # here — --title -R a/b — is the misread pattern the vocab fix closes, and
    # is pinned separately as "no selector" rather than as an index.)
    _d "a selector carries its argv index" '"3"' \
        '["issue","create","--web","-R","a/b"]' "$IDX"
    _d "the index is of the flag token, not the value" '"0"' \
        '["--repo","a/b","issue","create"]' "$IDX"

    echo ""
    echo "=== 2053-E: NEW isGhApiWriteFromFlags — gh effective-method precedence ==="

    # gh's own rule, in order: an explicit -X/--method wins; otherwise any of
    # -f/-F/--field/--raw-field/--input makes the request a POST. A classifier
    # that checks the field flags FIRST lets `-X GET -f x=y` read as a write, and
    # one that only checks -X lets an implicit POST through unseen.
    local E='m.isGhApiWriteFromFlags(FLAGS) === WANT'

    _e() { # <name> <flags-js> <true|false>
        local expr="${E//FLAGS/$2}"
        expect_expr "2053-E [$1]" "true" "${expr//WANT/$3}"
    }

    echo "--- explicit method wins ---"
    _e "-X POST"                   '[{flag:"-X",value:"POST"}]' 'true'
    _e "-X PUT"                    '[{flag:"-X",value:"PUT"}]' 'true'
    _e "-X PATCH"                  '[{flag:"-X",value:"PATCH"}]' 'true'
    _e "-X DELETE"                 '[{flag:"-X",value:"DELETE"}]' 'true'
    _e "--method delete lowercase" '[{flag:"--method",value:"delete"}]' 'true'
    _e "--method=POST attached"    '[{flag:"--method",value:"POST"}]' 'true'
    _e "-X GET"                    '[{flag:"-X",value:"GET"}]' 'false'
    _e "-X HEAD"                   '[{flag:"-X",value:"HEAD"}]' 'false'
    _e "-X get lowercase"          '[{flag:"-X",value:"get"}]' 'false'
    _e "-X with no value"          '[{flag:"-X",value:null}]' 'false'
    _e "-X with an unknown verb"   '[{flag:"-X",value:"FROB"}]' 'true'

    echo "--- implicit POST from a payload flag ---"
    _e "-f with no method"          '[{flag:"-f",value:"title=x"}]' 'true'
    _e "-F with no method"          '[{flag:"-F",value:"n=1"}]' 'true'
    _e "--field with no method"     '[{flag:"--field",value:"a=b"}]' 'true'
    _e "--raw-field with no method" '[{flag:"--raw-field",value:"a=b"}]' 'true'
    _e "--input with no method"     '[{flag:"--input",value:"/tmp/x.json"}]' 'true'
    _e "--input - (stdin)"          '[{flag:"--input",value:"-"}]' 'true'

    echo "--- an explicit read method beats every payload flag ---"
    _e "-X GET with -f"           '[{flag:"-X",value:"GET"},{flag:"-f",value:"a=b"}]' 'false'
    _e "-X GET with --raw-field"  '[{flag:"-X",value:"GET"},{flag:"--raw-field",value:"a=b"}]' 'false'
    _e "-X GET with --input"      '[{flag:"-X",value:"GET"},{flag:"--input",value:"/tmp/x"}]' 'false'
    _e "-f before -X GET (order does not matter)" \
        '[{flag:"-f",value:"a=b"},{flag:"-X",value:"GET"}]' 'false'

    echo "--- repeated methods: pflag keeps the LAST occurrence ---"
    _e "-X GET then -X POST -> write" \
        '[{flag:"-X",value:"GET"},{flag:"-X",value:"POST"}]' 'true'
    _e "-X POST then -X GET -> not a write" \
        '[{flag:"-X",value:"POST"},{flag:"-X",value:"GET"}]' 'false'
    _e "-X POST then --method GET (mixed spellings, still last-wins)" \
        '[{flag:"-X",value:"POST"},{flag:"--method",value:"GET"}]' 'false'
    _e "--method GET then -X POST" \
        '[{flag:"--method",value:"GET"},{flag:"-X",value:"POST"}]' 'true'
    _e "-X GET, -X POST, -f — last method still wins" \
        '[{flag:"-X",value:"GET"},{flag:"-X",value:"POST"},{flag:"-f",value:"a=b"}]' 'true'
    _e "-X POST, -X GET, -f — the trailing GET still wins" \
        '[{flag:"-X",value:"POST"},{flag:"-X",value:"GET"},{flag:"-f",value:"a=b"}]' 'false'

    echo "--- neither ---"
    _e "no flags at all"             '[]' 'false'
    _e "a header flag alone"         '[{flag:"-H",value:"Accept: application/vnd"}]' 'false'
    _e "--paginate alone"            '[{flag:"--paginate",value:null}]' 'false'
    _e "--jq alone"                  '[{flag:"--jq",value:".[]"}]' 'false'
    _e "a header plus --jq"          '[{flag:"-H",value:"A: b"},{flag:"--jq",value:".x"}]' 'false'

    echo ""
    echo "=== 2053-F: NEW owner/repo validators (what may be interpolated) ==="

    # These gate what is interpolated into `gh api repos/<owner>/<repo>` — an
    # AUTHENTICATED call whose path the server normalizes, so a surviving
    # dot-segment reads a repository the caller never named. Both directions
    # matter: over-strict rejects real logins and turns the guard into a nag.
    expr_table "2053-F" <<'TABLE'
owner: a normal login|true|p.isValidOwner("nirecom") === true
owner: hyphens inside|true|p.isValidOwner("a-b-1") === true
owner: digits only|true|p.isValidOwner("123") === true
owner: one character|true|p.isValidOwner("a") === true
owner: exactly 39 characters (the maximum)|true|p.isValidOwner("a".repeat(39)) === true
owner: 40 characters|true|p.isValidOwner("a".repeat(40)) === false
owner: a dot|true|p.isValidOwner("a.b") === false
owner: single dot|true|p.isValidOwner(".") === false
owner: double dot|true|p.isValidOwner("..") === false
owner: a slash|true|p.isValidOwner("a/b") === false
owner: a backslash|true|p.isValidOwner("a\\b") === false
owner: empty|true|p.isValidOwner("") === false
owner: whitespace only|true|p.isValidOwner(" ") === false
owner: a leading hyphen|true|p.isValidOwner("-a") === false
owner: a trailing hyphen|true|p.isValidOwner("a-") === false
owner: consecutive hyphens|true|p.isValidOwner("a--b") === false
owner: an underscore|true|p.isValidOwner("a_b") === false
owner: percent-encoding|true|p.isValidOwner("%2e%2e") === false
owner: a NUL byte|true|p.isValidOwner("a" + String.fromCharCode(0) + "b") === false
owner: a newline|true|p.isValidOwner("a\nb") === false
owner: a shell metacharacter|true|p.isValidOwner("a;b") === false
owner: null input|true|p.isValidOwner(null) === false
owner: undefined input|true|p.isValidOwner(undefined) === false
owner: a non-string|true|p.isValidOwner(42) === false
repo: dots inside|true|p.isValidRepo("my.repo-1_x") === true
repo: a leading dot|true|p.isValidRepo(".config") === true
repo: one character|true|p.isValidRepo("r") === true
repo: exactly 100 characters (the maximum)|true|p.isValidRepo("r".repeat(100)) === true
repo: 101 characters|true|p.isValidRepo("r".repeat(101)) === false
repo: single dot|true|p.isValidRepo(".") === false
repo: double dot|true|p.isValidRepo("..") === false
repo: a slash|true|p.isValidRepo("a/b") === false
repo: a backslash|true|p.isValidRepo("a\\b") === false
repo: empty|true|p.isValidRepo("") === false
repo: a space inside|true|p.isValidRepo("a b") === false
repo: percent-encoding|true|p.isValidRepo("%2e%2e%2f") === false
repo: a NUL byte|true|p.isValidRepo("a" + String.fromCharCode(0) + "b") === false
repo: a newline|true|p.isValidRepo("a\nb") === false
repo: null input|true|p.isValidRepo(null) === false
repo: a non-string|true|p.isValidRepo(42) === false
parse-remote-url keeps its five pre-2053 exports|true|["extractHost","extractRepoId","parseOriginOwnerRepo","redactUserinfo","GITHUB_HOST"].every(k => k in p)
TABLE

    echo ""
    echo "=== 2053-H: NEW patterns.resolveGhSubArgv (gh global-flag skip) ==="

    # O2/C46: the guard reads the subcommand positionally. A leading global flag
    # shifts argv, and an unskipped shift is the #1296 bypass class —
    # `gh -R owner/repo issue create` must still resolve to `issue create`.
    # The skip must know which global flags TAKE a value: treating a value-taking
    # flag as a lone flag leaves its value sitting in the subcommand position.
    expr_table "2053-H" <<'TABLE'
resolveGhSubArgv is exported|"function"|typeof g.resolveGhSubArgv
no global flag -> argv unchanged|"issue,create"|g.resolveGhSubArgv(["issue","create"]).join(",")
-R o/r is skipped as flag+value|"issue,create"|g.resolveGhSubArgv(["-R","a/b","issue","create"]).join(",")
-R=o/r is one token|"issue,create"|g.resolveGhSubArgv(["-R=a/b","issue","create"]).join(",")
-Ro/r attached short is one token|"issue,create"|g.resolveGhSubArgv(["-Ra/b","issue","create"]).join(",")
--repo o/r separated|"issue,create"|g.resolveGhSubArgv(["--repo","a/b","issue","create"]).join(",")
--repo=o/r is one token|"issue,create"|g.resolveGhSubArgv(["--repo=a/b","issue","create"]).join(",")
--hostname is skipped as flag+value|"issue,create"|g.resolveGhSubArgv(["--hostname","github.com","issue","create"]).join(",")
--hostname=H is one token|"issue,create"|g.resolveGhSubArgv(["--hostname=ghe.example.com","issue","create"]).join(",")
two global flags in a row|"issue,create"|g.resolveGhSubArgv(["--hostname","h","-R","a/b","issue","create"]).join(",")
an unknown lone flag skips only itself|"issue,create"|g.resolveGhSubArgv(["--verbose","issue","create"]).join(",")
a lone flag before a value-taking one|"issue,create"|g.resolveGhSubArgv(["--verbose","-R","a/b","issue","create"]).join(",")
the subcommand itself is never eaten|"api"|g.resolveGhSubArgv(["-R","a/b","api","repos/a/b"])[0]
a repo-looking token is not mistaken for a flag|"a/b"|g.resolveGhSubArgv(["a/b","issue"])[0]
empty argv stays empty|"0"|String(g.resolveGhSubArgv([]).length)
only a global flag leaves nothing|"0"|String(g.resolveGhSubArgv(["-R","a/b"]).length)
a dangling value-taking flag leaves nothing|"0"|String(g.resolveGhSubArgv(["-R"]).length)
-- stops the skip|"--,issue"|g.resolveGhSubArgv(["--","issue"]).join(",")
patterns keeps resolveGitSubArgv beside the new gh sibling|true|typeof g.resolveGitSubArgv === "function"
TABLE

    unset -f _d _e
}
