#!/usr/bin/env bash
# tests/install/installer-system-ops-self-assign-guard.sh
# Tests: hooks/enforce-system-ops.js, bin/lib/codex-core.sh, install/linux/rtk.sh, install/win/shellcheck.ps1
# Tags: scope:common, system-ops, installer, security, regression-guard, static, table-driven, TL2, pwsh-not-required
# WHY (#2200): enforce-system-ops.js honours SYSTEM_OPS_APPROVED only as inherited by Claude Code itself; a script setting it on its own process never helps its children, but sourced/dot-run it leaks the bypass into the caller's shell. This file IS the guard: tracked product code never assigns the flag.
# Boundary: all tracked files except tests/** (fixtures set the flag inside their own child process), docs/** and *.md (prose). The sanctioned bypass — the operator exporting the flag before launching Claude Code — never appears in the repo as code.
# Not flagged: a leading `SYSTEM_OPS_APPROVED=1 cmd` prefix (reaches that one child only), reads/comparisons, comment lines. A statement-level assignment followed by `;`, `&&`, `||` or end of line IS flagged: it sets the caller's shell variable.
# TL3 gap: the scan is lexical; an assignment built dynamically (eval, computed names) is not seen.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

_GUARD_TMP_ROOT="$(make_tmp)"; readonly _GUARD_TMP_ROOT
harness_isolate "$_GUARD_TMP_ROOT/iso"
trap 'cd / 2>/dev/null; rm -rf "$_GUARD_TMP_ROOT"' EXIT
cd "$_GUARD_TMP_ROOT" || exit 1

GUARD_SELF="tests/install/installer-system-ops-self-assign-guard.sh"

# Assignment forms (ERE, matched case-insensitively: PowerShell env names are case-insensitive).
GUARD_PATTERNS=()
while IFS= read -r _p; do
    [ -n "$_p" ] && GUARD_PATTERNS+=(-e "$_p")
done <<'PATTERNS'
(^|[^A-Za-z0-9_])export[[:space:]]+(-[A-Za-z]+[[:space:]]+)*([A-Za-z_][A-Za-z0-9_]*(=[^[:space:]]*)?[[:space:]]+)*SYSTEM_OPS_APPROVED([^A-Za-z0-9_]|$)
(^|[^A-Za-z0-9_])(declare|typeset)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*x[^;&|]*SYSTEM_OPS_APPROVED
(^|[;&|(]|[[:space:]](then|do|else))[[:space:]]*SYSTEM_OPS_APPROVED=("[^"]*"|'[^']*'|[^[:space:];&|]*)[[:space:]]*(;|&&|\|\||$)
\$env:SYSTEM_OPS_APPROVED[[:space:]]*=([^=]|$)
SetEnvironmentVariable\([[:space:]]*['"]SYSTEM_OPS_APPROVED['"]
(Set|New)-Item[[:space:]]+(-Path[[:space:]]+|-LiteralPath[[:space:]]+)?['"]?env:\\?SYSTEM_OPS_APPROVED
process\.env\.SYSTEM_OPS_APPROVED[[:space:]]*=([^=]|$)
process\.env\[[[:space:]]*['"`]SYSTEM_OPS_APPROVED['"`][[:space:]]*\][[:space:]]*=([^=]|$)
os\.environ\[[[:space:]]*['"]SYSTEM_OPS_APPROVED['"][[:space:]]*\][[:space:]]*=([^=]|$)
os\.environ\.setdefault\([[:space:]]*['"]SYSTEM_OPS_APPROVED['"]
PATTERNS

# scan_tree <repo-root> — prints `path:line:text` for every tracked, in-scope, non-comment
# line that assigns the flag. Returns 2 (fail closed) when <repo-root> is not a git work tree.
scan_tree() {
    local root="$1" out rc
    git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 2
    out="$(git -C "$root" grep -n -I -i -E "${GUARD_PATTERNS[@]}" -- . \
        ':(exclude,glob)tests/**' ':(exclude,glob)docs/**' ':(exclude,glob)**/*.md' \
        ":(exclude)$GUARD_SELF" 2>&1)"
    rc=$?
    [ "$rc" -gt 1 ] && { printf '%s\n' "$out" >&2; return 2; }
    [ -z "$out" ] && return 0
    printf '%s\n' "$out" | awk '{
        t = $0; sub(/^[^:]*:[0-9]+:/, "", t); sub(/^[[:space:]]+/, "", t)
        if (t ~ /^(#|\/\/|\/\*|\*|<#)/) next
        print
    }'
}

# Fixture repo: one file per verdict row, all staged so `git grep` sees them as tracked.
FIX="$_GUARD_TMP_ROOT/fixture"
mkdir -p "$FIX"
harness_git_init "$FIX"
git -C "$FIX" config core.autocrlf false

declare -a ROW_NAME=() ROW_WANT=() ROW_PATH=()
while IFS='|' read -r name want path content; do
    name="$(printf '%s' "$name" | sed 's/[[:space:]]*$//')"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    want="$(printf '%s' "$want" | tr -d '[:space:]')"
    path="$(printf '%s' "$path" | tr -d '[:space:]')"
    content="${content# }"; content="${content//<tab>/	}"
    mkdir -p "$FIX/$(dirname "$path")"
    printf '%s\n' "$content" > "$FIX/$path"
    ROW_NAME+=("$name"); ROW_WANT+=("$want"); ROW_PATH+=("$path")
done <<'TABLE'
sh-export-hooks-lib       | FLAG | hooks/lib/x.sh                    | export SYSTEM_OPS_APPROVED=1
sh-export-indented-quoted | FLAG | bin/github-issues/lib/x.sh        | <tab>export SYSTEM_OPS_APPROVED="1"
sh-export-bare            | FLAG | bin/tool.d/bare.sh                | export SYSTEM_OPS_APPROVED
sh-export-after-other     | FLAG | bin/tool.d/multi.sh               | export PATH="$PATH" SYSTEM_OPS_APPROVED=1
sh-export-after-semicolon | FLAG | bin/tool.d/semi.sh                | cd /tmp; export SYSTEM_OPS_APPROVED=1
sh-declare-x              | FLAG | install/linux/declare.sh          | declare -x SYSTEM_OPS_APPROVED=1
sh-declare-gx             | FLAG | install/linux/declare-gx.sh       | declare -g -x SYSTEM_OPS_APPROVED=1
sh-typeset-x              | FLAG | bin/tool.d/x.sh                   | typeset -x SYSTEM_OPS_APPROVED=1
sh-whole-line-assign      | FLAG | skills/s/scripts/lib/whole.sh     | SYSTEM_OPS_APPROVED=1
sh-whole-line-quoted      | FLAG | skills/s/scripts/lib/quoted.sh    | SYSTEM_OPS_APPROVED='1'
sh-assign-then-semicolon  | FLAG | bin/tool.d/stmt-semi.sh           | SYSTEM_OPS_APPROVED=1; next_command
sh-assign-then-and        | FLAG | bin/tool.d/stmt-and.sh            | SYSTEM_OPS_APPROVED=1 && cmd
sh-assign-then-or         | FLAG | bin/tool.d/stmt-or.sh             | SYSTEM_OPS_APPROVED="1" || true
sh-assign-mid-chain       | FLAG | bin/tool.d/stmt-mid.sh            | cd /tmp && SYSTEM_OPS_APPROVED=1; cmd
sh-assign-after-then      | FLAG | bin/tool.d/stmt-then.sh           | if true; then SYSTEM_OPS_APPROVED=1; fi
sh-prefix-mid-chain       | PASS | bin/tool.d/prefix-mid.sh          | cd /tmp && SYSTEM_OPS_APPROVED=1 cmd
extensionless-script      | FLAG | bin/some-tool                     | export SYSTEM_OPS_APPROVED=1
ps1-env-assign            | FLAG | install/lib/x.ps1                 | $env:SYSTEM_OPS_APPROVED = "1"
ps1-env-assign-mixed-case | FLAG | install/lib/case.ps1              | $Env:system_ops_approved="1"
ps1-env-restore-prior     | FLAG | install/lib/restore.ps1           | $env:SYSTEM_OPS_APPROVED = $_priorSystemOpsApproved
ps1-setenv-single-quote   | FLAG | install/win/setenv1.ps1           | [Environment]::SetEnvironmentVariable('SYSTEM_OPS_APPROVED', '1')
ps1-setenv-double-quote   | FLAG | install/win/setenv2.ps1           | [System.Environment]::SetEnvironmentVariable("SYSTEM_OPS_APPROVED", "1", "User")
ps1-set-item              | FLAG | install/win/setitem.ps1           | Set-Item env:SYSTEM_OPS_APPROVED 1
ps1-set-item-path         | FLAG | install/win/setitem-path.ps1      | Set-Item -Path Env:SYSTEM_OPS_APPROVED -Value 1
js-dot-assign             | FLAG | hooks/lib/x.js                    | process.env.SYSTEM_OPS_APPROVED = "1";
js-bracket-assign         | FLAG | bin/lib/y.js                      | process.env["SYSTEM_OPS_APPROVED"] = "1";
js-bracket-single-quote   | FLAG | bin/lib/z.js                      | process.env['SYSTEM_OPS_APPROVED']="1"
py-environ-assign         | FLAG | bin/lib/x.py                      | os.environ["SYSTEM_OPS_APPROVED"] = "1"
py-environ-setdefault     | FLAG | skills/s/scripts/y.py             | os.environ.setdefault("SYSTEM_OPS_APPROVED", "1")
comment-sh                | PASS | hooks/lib/c1.sh                   | # export SYSTEM_OPS_APPROVED=1
comment-ps1               | PASS | install/lib/c2.ps1                | <tab># $env:SYSTEM_OPS_APPROVED = "1"
comment-js                | PASS | hooks/lib/c3.js                   | // process.env.SYSTEM_OPS_APPROVED = "1";
ps1-read-compare          | PASS | install/lib/r1.ps1                | if ($env:SYSTEM_OPS_APPROVED -eq "1") { Write-Output ok }
ps1-read-into-var         | PASS | install/lib/r2.ps1                | $x = $env:SYSTEM_OPS_APPROVED
ps1-remove-item           | PASS | install/lib/r3.ps1                | Remove-Item Env:SYSTEM_OPS_APPROVED -ErrorAction SilentlyContinue
js-strict-compare         | PASS | hooks/r4.js                       | if (process.env.SYSTEM_OPS_APPROVED === "1") process.exit(0);
js-loose-compare          | PASS | hooks/r5.js                       | if (process.env.SYSTEM_OPS_APPROVED == "1") process.exit(0);
py-read-compare           | PASS | bin/lib/r6.py                     | ok = os.environ["SYSTEM_OPS_APPROVED"] == "1"
py-get                    | PASS | bin/lib/r7.py                     | ok = os.environ.get("SYSTEM_OPS_APPROVED")
sh-read-test              | PASS | hooks/lib/r8.sh                   | if [ "${SYSTEM_OPS_APPROVED:-}" = "1" ]; then :; fi
sh-unset                  | PASS | hooks/lib/r9.sh                   | unset SYSTEM_OPS_APPROVED
sh-leading-child-prefix   | PASS | bin/tool.d/prefix.sh              | SYSTEM_OPS_APPROVED=1 winget install jq
sh-env-child-prefix       | PASS | bin/tool.d/envprefix.sh           | env SYSTEM_OPS_APPROVED=1 node x.js
excluded-tests-tree       | PASS | tests/hooks/fixture.sh            | export SYSTEM_OPS_APPROVED=1
excluded-docs-tree        | PASS | docs/example.sh                   | export SYSTEM_OPS_APPROVED=1
excluded-markdown-anywhere| PASS | bin/lib/README.md                 | export SYSTEM_OPS_APPROVED=1
TABLE

printf 'export SYSTEM_OPS_APPROVED=1\n' > "$FIX/hooks/lib/untracked.sh"
git -C "$FIX" add -- . ':(exclude)hooks/lib/untracked.sh'

FIX_HITS="$(scan_tree "$FIX")"; FIX_RC=$?

case_begin "fixture-scan-runs-clean" "hooks/enforce-system-ops.js"
if [ "$FIX_RC" -eq 0 ]; then
    pass "fixture-scan-runs-clean: scan_tree exits 0 on the fixture repo"
else
    fail "fixture-scan-runs-clean" "scan_tree rc=$FIX_RC"
fi
case_end

# Every verdict row: FLAG rows must appear in the scan, PASS rows must not.
case_begin "verdict-table" "hooks/enforce-system-ops.js"
for i in "${!ROW_NAME[@]}"; do
    got=PASS
    printf '%s\n' "$FIX_HITS" | grep -qF -- "${ROW_PATH[$i]}:" && got=FLAG
    if [ "$got" = "${ROW_WANT[$i]}" ]; then
        pass "verdict ${ROW_NAME[$i]}: ${ROW_WANT[$i]}"
    else
        fail "verdict ${ROW_NAME[$i]}" "want=${ROW_WANT[$i]} got=$got (${ROW_PATH[$i]})"
    fi
done
case_end

case_begin "untracked-file-out-of-scope" "hooks/enforce-system-ops.js"
if printf '%s\n' "$FIX_HITS" | grep -qF 'hooks/lib/untracked.sh:'; then
    fail "untracked-file-out-of-scope" "an untracked file was scanned"
else
    pass "untracked-file-out-of-scope: only tracked files are scanned"
fi
case_end

case_begin "non-git-root-fails-closed" "hooks/enforce-system-ops.js"
mkdir -p "$_GUARD_TMP_ROOT/not-a-repo"
scan_tree "$_GUARD_TMP_ROOT/not-a-repo" >/dev/null 2>&1; NG_RC=$?
if [ "$NG_RC" -eq 2 ]; then
    pass "non-git-root-fails-closed: scan_tree returns 2 outside a git work tree"
else
    fail "non-git-root-fails-closed" "want rc=2 got rc=$NG_RC"
fi
case_end

# Real tree. Counter-anchor first: the real tree must have tracked in-scope files,
# or an empty scan result below would prove nothing.
REAL_COUNT="$(git -C "$SCRIPT_CHECKOUT_ROOT" ls-files -- 'install/*' 'bin/*' 'hooks/*' 2>/dev/null | grep -c .)"
REAL_HITS="$(scan_tree "$SCRIPT_CHECKOUT_ROOT")"; REAL_RC=$?

case_begin "real-tree-scan-sees-files" "hooks/enforce-system-ops.js"
if [ "$REAL_RC" -eq 0 ] && [ "${REAL_COUNT:-0}" -gt 100 ]; then
    pass "real-tree-scan-sees-files: scan ran over $REAL_COUNT tracked install/bin/hooks files"
else
    fail "real-tree-scan-sees-files" "rc=$REAL_RC tracked=$REAL_COUNT"
fi
case_end

# real_tree_clean <case> <path-prefix> — no assignment site under the prefix.
real_tree_clean() {
    local hits
    hits="$(printf '%s\n' "$REAL_HITS" | grep -F -- "$2" || true)"
    if [ -z "$hits" ]; then
        pass "$1: no SYSTEM_OPS_APPROVED self-assignment under ${2:-the repo}"
    else
        fail "$1" "$(printf '%s\n' "$hits" | grep -c .) site(s): $(printf '%s' "$hits" | tr '\n' ' ' | cut -c1-600)"
    fi
}

case_begin "real-tree-bin-lib-clean" "bin/lib/codex-core.sh"
real_tree_clean "real-tree-bin-lib-clean" "bin/lib/"
case_end

case_begin "real-tree-install-linux-clean" "install/linux/rtk.sh"
real_tree_clean "real-tree-install-linux-clean" "install/linux/"
case_end

case_begin "real-tree-install-win-clean" "install/win/shellcheck.ps1"
real_tree_clean "real-tree-install-win-clean" "install/win/"
case_end

case_begin "real-tree-whole-repo-clean" "hooks/enforce-system-ops.js"
real_tree_clean "real-tree-whole-repo-clean" ":"
case_end

# Runtime counterpart of the lexical scan: source a real library twice in a fresh shell and
# report the caller's flag. LOADED proves the source succeeded (else an unset flag proves nothing).
SOURCE_PROBE=""
IFS= read -r -d '' SOURCE_PROBE <<'PROBE' || true
source "$1" >/dev/null 2>&1; source "$1" >/dev/null 2>&1
declare -F "$2" >/dev/null && printf "LOADED "
printf "%s|%s" "${SYSTEM_OPS_APPROVED-<unset>}" "$(printenv SYSTEM_OPS_APPROVED || echo "<unset>")"
PROBE
readonly SOURCE_PROBE

# source_probe <lib> <function> <caller flag or -> — prints `LOADED <shell value>|<env value>`.
source_probe() (
    unset SYSTEM_OPS_APPROVED
    [ "$3" = "-" ] || export SYSTEM_OPS_APPROVED="$3"
    run_with_timeout 30 bash -c "$SOURCE_PROBE" _ "$SCRIPT_CHECKOUT_ROOT/$1" "$2" 2>/dev/null
)

case_begin "sourced-library-leaves-caller-flag-alone" "bin/lib/codex-core.sh"
while IFS='|' read -r lib fn caller want; do
    lib="${lib//[[:space:]]/}"; fn="${fn//[[:space:]]/}"
    caller="${caller//[[:space:]]/}"; want="${want//[[:space:]]/}"
    [ -z "$lib" ] && continue
    got="$(source_probe "$lib" "$fn" "$caller")"
    if [ "$got" = "LOADED $want|$want" ]; then
        pass "sourced twice: $lib keeps caller flag ($caller)"
    else
        fail "sourced twice: $lib keeps caller flag ($caller)" "want=[LOADED $want|$want] got=[$got]"
    fi
done <<'TABLE'
bin/lib/codex-core.sh  | codex_core_init  | -        | <unset>
bin/lib/codex-core.sh  | codex_core_init  | operator | operator
bin/lib/gemini-core.sh | gemini_core_init | -        | <unset>
bin/lib/gemini-core.sh | gemini_core_init | operator | operator
TABLE
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
