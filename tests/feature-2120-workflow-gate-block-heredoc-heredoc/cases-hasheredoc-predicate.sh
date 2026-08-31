# Tests: hooks/enforce-worktree/shared-cmd-utils.js
# Tags: heredoc, enforce-worktree, parser, regex, table-driven, scope:issue-specific
# M9 — HEREDOC_OPENER_RE / hasHeredoc() at the predicate level, including the
# deliberate over-matches. The end-to-end cost of those over-matches is pinned in
# cases-heredoc-routing.sh (M11).
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh.

# has_heredoc <cmd> → "true"|"false"|"MISSING_EXPORT"|"". The single probe each M9
# row drives, lifted out of the loop so the rows read as data only
# (skills/_shared/test-design/parser-regex-tests.md, Table-Driven Tests).
has_heredoc() {
    run_with_timeout 30 node -e '
const m=require(process.argv[1]);
if(typeof m.hasHeredoc!=="function"){process.stdout.write("MISSING_EXPORT");}
else process.stdout.write(String(m.hasHeredoc(process.argv[2])));
' "$SCU" "$(printf '%b' "$1")" 2>/dev/null
}

run_M9() {
    # M9 (C1, test-review round 2) — HEREDOC_OPENER_RE / hasHeredoc(), the new regex
    # constant in shared-cmd-utils.js; table-driven per
    # skills/_shared/test-design/parser-regex-tests.md. hasHeredoc() ROUTES: true →
    # the narrow plans-dir/scratchpad gate (universal-target-allow.js Guard 6,
    # handle-bash-write.js), false → the broad outside-session-scope allow.
    # Risk is asymmetric — a false negative is a security hole, a false positive is
    # only noise — so the constant deliberately over-matches, and runs on the RAW
    # command (quote-stripping would erase a real `<<'EOF'` tag). Rows marked
    # OVER-MATCH pin that intended behaviour; they are not aspirational.
    local label cmd want got
    # Separator is '~': several payloads contain '|' and quoted text.
    while IFS='~' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(has_heredoc "$cmd")"
        if [ "$got" = "$want" ]; then pass "M9 $label → $want"
        else fail "M9 $label: want '$want', got '$got'"; fi
    done <<'TABLE'
# label                   ~ command                             ~ hasHeredoc?
# --- MUST MATCH: every opener form stripHeredocBody() understands -----------
plain-tag                 ~ cat <<EOF > x                       ~ true
dash-form                 ~ cat <<-EOF > x                      ~ true
single-quoted-tag         ~ cat <<'EOF' > x                     ~ true
double-quoted-tag         ~ cat <<"EOF" > x                     ~ true
dash-plus-quoted-tag      ~ cat <<-'EOF' > x                    ~ true
hyphenated-tag            ~ cat <<END-MARK > x                  ~ true
dotted-tag                ~ cat <<EOF-1.2 > x                   ~ true
underscore-tag            ~ cat <<_TAG9 > x                     ~ true
single-char-tag           ~ cat <<X > x                         ~ true
space-after-operator      ~ cat << EOF > x                      ~ true
no-space-before-operator  ~ cat<<EOF > x                        ~ true
# --- MUST MATCH: shapes stripHeredocBody() deliberately REFUSES to strip.
# The reason a separate predicate exists (#2120/#2121 review r2, F2): never
# stripped, yet must still route to the NARROW gate, not the broad allow.
interpreter-heredoc       ~ bash <<'EOF'\nrm -rf /repo/x\nEOF\n ~ true
pipe-chained-sink         ~ tee out.txt <<'EOF' | bash          ~ true
unquoted-cmdsubst-body    ~ cat <<EOF > x\n$(id)\nEOF\n         ~ true
non-sink-command          ~ mail -s hi u@example.com <<'EOF'    ~ true
# --- MUST NOT MATCH: not a heredoc opener at all ---------------------------
# Delimiter charset is [A-Za-z_][A-Za-z0-9_.-]*: first char is letter/_ only.
leading-digit-tag         ~ cat <<9EOF > x                      ~ false
leading-dot-tag           ~ cat <<.EOF > x                      ~ false
append-redirect           ~ echo hi >> out.txt                  ~ false
truncate-redirect         ~ echo hi > out.txt                   ~ false
input-redirect            ~ sort < in.txt                       ~ false
numeric-left-shift        ~ echo $((1 << 2))                    ~ false
bare-operator-eol         ~ cat <<                              ~ false
mismatched-tag-quotes     ~ cat <<'EOF"                         ~ false
no-heredoc-at-all         ~ echo hello world                    ~ false
empty-string              ~                                     ~ false
# --- OVER-MATCH, deliberate and pinned -------------------------------------
# `<<<WORD` is a here-string; the regex matches its trailing `<<WORD` slice.
# Quoted/commented pseudo-openers match for the same raw-input reason. Both
# only cost a trip through the narrower gate, so both are left as-is.
here-string               ~ grep foo <<<WORD                    ~ true
here-string-eof           ~ grep foo <<<EOF                     ~ true
single-quoted-literal     ~ echo 'cat <<EOF'                    ~ true
double-quoted-literal     ~ echo "cat <<EOF"                    ~ true
commented-out-opener      ~ echo hi # cat <<EOF                 ~ true
arith-shift-by-variable   ~ echo $((x << n))                    ~ true
TABLE

    # Non-string input must never throw out of a PreToolUse hook (a throw is read
    # as "no objection" = fail-OPEN), and must not report a heredoc either.
    got="$(run_with_timeout 30 node -e '
const m=require(process.argv[1]);
const vals=[null,undefined,42,{},[]];
process.stdout.write(vals.map(v=>{try{return String(m.hasHeredoc(v));}catch(e){return "throw";}}).join(","));
' "$SCU" 2>/dev/null)"
    if [ "$got" = "false,false,false,false,false" ]; then
        pass "M9 non-string input returns false and never throws"
    else fail "M9 non-string input: want 'false,false,false,false,false', got '$got'"; fi
}
