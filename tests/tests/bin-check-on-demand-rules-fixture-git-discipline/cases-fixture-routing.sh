# shellcheck shell=bash
# Tests: tests/bin-check-on-demand-rules/fixtures.sh
# Tags: rules-injection, on-demand-rules, fixtures, git-discipline, static-check, positive-control, TL2, scope:common
# fixtures.sh is the one file allowed to name git, so D1 exempts it. D2 and D9 are what
# stands in for D1 inside that exemption: every git call must sit in a function, and
# every such function must reach fx_ensure_git before the git call it makes.

echo ""
echo "=== D2: fixtures.sh routes every git call through fx_ensure_git ==="
# The named exceptions (CPR-UNV: an exception gets a name and a boundary, never an
# implicit pass). Both OWN the git primitive instead of consuming it — _fx_git_template
# builds the template repo, fx_ensure_git is the entry point and cannot precede itself.
FX_GIT_OWNERS="_fx_git_template fx_ensure_git"

d2_missing=""
for _need in fx_ensure_git fx_stage mk_tree; do
    grep -qx -- "$_need" "$FX_NAMES" || d2_missing="$d2_missing $_need"
done
if [[ -z "$d2_missing" ]]; then
    pass "D2a: fixtures.sh defines fx_ensure_git, fx_stage and mk_tree"
else
    fail "D2a: fixtures.sh is missing:$d2_missing — the entry points D1 redirects callers to do not exist yet"
fi

d2_bad=""
d2_checked=0
while IFS= read -r _fn; do
    [[ -n "$_fn" ]] || continue
    case " $FX_GIT_OWNERS " in *" $_fn "*) continue ;; esac
    fx_body "$_fn" > "$FX_BODY"
    _gi="$(first_line_matching "$FX_BODY" "$GIT_CALL_RE")"
    if [[ "$_gi" != "0" ]]; then
        d2_checked=$((d2_checked + 1))
        _ei="$(first_line_matching "$FX_BODY" 'fx_ensure_git')"
        if [[ "$_ei" == "0" ]]; then
            d2_bad="$d2_bad $_fn(never-calls-fx_ensure_git)"
        elif [[ "$_ei" -gt "$_gi" ]]; then
            d2_bad="$d2_bad $_fn(fx_ensure_git@$_ei-after-git@$_gi)"
        fi
    fi
done < "$FX_NAMES"
if [[ "$d2_checked" -eq 0 ]]; then
    fail "D2b: no git-calling function was found in fixtures.sh at all — the dump is empty or the scan is broken, so this check would pass vacuously"
elif [[ -z "$d2_bad" ]]; then
    pass "D2b: all $d2_checked git-calling function(s) in fixtures.sh reach fx_ensure_git first"
else
    fail "D2b: git reached before fx_ensure_git in:$d2_bad (exempt by name: $FX_GIT_OWNERS)"
fi

echo ""
echo "=== D9: fixtures.sh calls git only from inside a function ==="
# The blind spot between D1 and D2: D1 exempts fixtures.sh outright and D2 reads only
# function bodies, so a git call written outside every function is seen by neither.
# scan_file_scope_git lives in scanners.sh; D9t pins its nesting states row by row.
d9_real="$(scan_file_scope_git "$FIXTURES")"
if [[ ! -f "$FIXTURES" ]]; then
    fail "D9a: fixtures.sh does not exist, so the file-scope scan reads nothing"
elif [[ -z "$d9_real" ]]; then
    pass "D9a: fixtures.sh calls git only from inside functions"
else
    fail "D9a: git at file scope in fixtures.sh — invisible to D1 (which exempts this file) and to D2 (which reads function bodies only): $(brief "$d9_real")"
fi

D9="$WORK/fx-scope"
mkdir -p "$D9"
cat > "$D9/planted.sh" <<'EOF'
mk_tree() { mkdir -p "$1"; }
git init -q "$BASE/.fx-git-template"
run_checker() {
    git -C "$1" add -A >/dev/null 2>&1
}
EOF
d9_n="$(scan_file_scope_git "$D9/planted.sh" | grep -c . || true)"
if [[ "$d9_n" == "1" ]]; then
    pass "D9b: the file-scope scan fires on exactly the one planted top-level git call"
else
    fail "D9b: want exactly 1 file-scope hit on the planted file, got $d9_n (0 = the scan is blind and D9a is a false green; >1 = the in-function calls leaked in)"
fi

cat > "$D9/clean.sh" <<'EOF'
_fx_git_template() {
    git init -q "$1"
}
fx_stage() { fx_ensure_git "$1"; git -C "$1" add "$2"; }
function git_commit_all {
    git -C "$1" commit -q -m baseline
}
EOF
d9_clean="$(scan_file_scope_git "$D9/clean.sh")"
if [[ -z "$d9_clean" ]]; then
    pass "D9c: git inside a one-liner, a paren-form and a function-keyword body all stay out of the file-scope scan"
else
    fail "D9c: the file-scope scan mistook an in-function git call for a top-level one: $(brief "$d9_clean")"
fi
