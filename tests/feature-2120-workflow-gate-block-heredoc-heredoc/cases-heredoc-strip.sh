# Tests: hooks/lib/strip-quoted-args.js, hooks/lib/bash-write-targets.js, hooks/enforce-worktree/shared-cmd-utils.js, hooks/lib/bash-write-patterns/classify.js
# Tags: heredoc, strip-quoted-args, write-detector, enforce-worktree, scope:issue-specific
# M7-M8b — the #2121 seam: which heredoc bodies may be stripped before the write
# scanners run, and the sequencing predicates that consume the stripped text.
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh.

run_M7() {
    # M7 (#2121 case 14) — THE INVARIANT THE WIDENING MUST NOT BREAK.
    # The issue says "drop the \bcat\s* prefix". Literally, that is unsafe: an
    # INTERPRETER heredoc EXECUTES its body, and bash-write-targets.js
    # isNewlineInjectedWriteIR() strips heredoc bodies BEFORE splitting on newlines
    # to find injected writes. Strip `bash <<'EOF' ... rm -rf x ... EOF` and the
    # write goes invisible — a silent security regression, not a false-positive fix.
    # → The safe widening drops the cat-ONLY restriction but still refuses to strip
    #   when an INTERPRETER precedes the heredoc. A quoted delimiter only stops the
    #   SHELL expanding the body; it does not stop the interpreter running it. Reuse
    #   the list in shared-cmd-utils.js rejectInterpreterAndChaining().
    local label cmd got
    while IFS='|' read -r label cmd; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"
        got="$(run_with_timeout 30 node -e '
const {parse}=require(process.argv[1]);
const {isNewlineInjectedWriteIR}=require(process.argv[2]);
process.stdout.write(String(isNewlineInjectedWriteIR(parse(process.argv[3]))));
' "$IRJS" "$TARGETS" "$(printf '%b' "$cmd")" 2>/dev/null)"
        if [ "$got" = "true" ]; then pass "M7 $label: interpreter-heredoc body write stays VISIBLE to write-detection"
        else fail "M7 $label: expected true (write visible), got '$got' — the widening over-stripped an EXECUTED body"; fi
    done <<'TABLE'
bash-quoted     | bash <<'EOF'\nrm -rf /repo/x\nEOF
sh-quoted       | sh <<'EOF'\nrm -rf /repo/x\nEOF
zsh-quoted      | zsh <<'EOF'\nrm -rf /repo/x\nEOF
python3-quoted  | python3 <<'PY'\nrm -rf /repo/x\nPY
node-quoted     | node <<'JS'\nrm -rf /repo/x\nJS
perl-quoted     | perl <<'PL'\nrm -rf /repo/x\nPL
bash-unquoted   | bash <<EOF\nrm -rf /repo/x\nEOF
bash-dash-form  | bash <<-'EOF'\nrm -rf /repo/x\nEOF
command-bash    | command bash <<'EOF'\nrm -rf /repo/x\nEOF
after-semi-bash | echo hi; bash <<'EOF'\nrm -rf /repo/x\nEOF
TABLE

    # CPR-ORTH, other direction: a DATA heredoc (tee writes the body to a file and
    # never executes it) must stop being reported as a newline-injected write.
    got="$(run_with_timeout 30 node -e '
const {parse}=require(process.argv[1]);
const {isNewlineInjectedWriteIR}=require(process.argv[2]);
process.stdout.write(String(isNewlineInjectedWriteIR(parse(process.argv[3]))));
' "$IRJS" "$TARGETS" "$(printf '%b' "tee /tmp/z <<'EOF'\\nrm -rf /repo/x\\nEOF")" 2>/dev/null)"
    if [ "$got" = "false" ]; then pass "M7 tee-data-heredoc: body is DATA, not an injected write"
    else fail "M7 tee-data-heredoc: expected false, got '$got' (stripHeredocBody still cat-only — #2121)"; fi

    # Demoting the BODY must not demote the COMMAND: tee is still a write, so its
    # target still reaches the scope check. GREEN before and after.
    got="$(run_with_timeout 30 node -e '
const {classify}=require(process.argv[1]);
process.stdout.write(classify(process.argv[2]));
' "$CLASSIFY" "$(printf '%b' "tee /tmp/z <<'EOF'\\nfoo\\nEOF")" 2>/dev/null)"
    if [ "$got" = "write" ]; then pass "M7 tee-still-write: the tee command itself stays classified 'write'"
    else fail "M7 tee-still-write: expected 'write', got '$got'"; fi
}

# M8 (#2121 case 16) — hasCommandSequencingOutsideHeredoc must stop reading the
# body-internal operators of a NON-cat quoted heredoc as real sequencing.
# Table-driven per skills/_shared/test-design/parser-regex-tests.md.
run_M8() {
    local label cmd want got
    # Separator is '~', not '|': the `foo || bar` row is precisely the payload
    # under test, and a '|' separator would split it into a bogus third field.
    while IFS='~' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(run_with_timeout 30 node -e '
const m=require(process.argv[1]);
if(typeof m.hasCommandSequencingOutsideHeredoc!=="function"){process.stdout.write("MISSING_EXPORT");}
else process.stdout.write(String(m.hasCommandSequencingOutsideHeredoc(process.argv[2])));
' "$SCU" "$(printf '%b' "$cmd")" 2>/dev/null)"
        if [ "$got" = "$want" ]; then pass "M8 $label → $want"
        else fail "M8 $label: want '$want', got '$got'"; fi
    done <<'TABLE'
# label                ~ command                                        ~ want
tee-body-and           ~ tee out.txt <<'EOF'\nfoo && bar\nEOF\n          ~ false
tee-body-semi          ~ tee out.txt <<'EOF'\nfoo; bar\nEOF\n            ~ false
tee-body-or            ~ tee out.txt <<'EOF'\nfoo || bar\nEOF\n          ~ false
tee-body-pipe          ~ tee out.txt <<'EOF'\nfoo | bar\nEOF\n           ~ false
sponge-body-semi       ~ sponge out.txt <<'EOF'\nfoo; bar\nEOF\n         ~ false
cat-body-semi          ~ cat <<'EOF' > out.txt\nfoo; bar\nEOF\n          ~ false
dotted-delim-body-semi ~ cat <<'EOF-1.2' > out.txt\nfoo; bar\nEOF-1.2\n  ~ false
real-seq-no-heredoc    ~ echo a && echo b                               ~ true
real-seq-or            ~ echo a || echo b                               ~ true
seq-after-terminator   ~ tee out.txt <<'EOF'\nfoo\nEOF\n; rm -rf x       ~ true
seq-before-opener      ~ rm -rf x; tee out.txt <<'EOF'\nfoo\nEOF\n       ~ true
unquoted-subst-body    ~ cat <<EOF > out.txt\n$(echo hi); bar\nEOF\n     ~ true
quoted-semicolon-arg   ~ echo "hello; world"                            ~ false
TABLE
}

# M8b (C2, test-review round 1) — #2121 Change 1 edits hasCommandSequencing()
# ITSELF to strip the heredoc body before scanning for separators, so a patch
# that only widens stripHeredocBody() and leaves this function parsing the raw
# cmd would still pass M8 (which only calls the wrapper). Calls the function
# DIRECTLY to pin that. RED before the #2121 fix, GREEN after.
run_M8b() {
    local label cmd want got
    while IFS='~' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(run_with_timeout 30 node -e '
const m=require(process.argv[1]);
if(typeof m.hasCommandSequencing!=="function"){process.stdout.write("MISSING_EXPORT");}
else process.stdout.write(String(m.hasCommandSequencing(process.argv[2])));
' "$SCU" "$(printf '%b' "$cmd")" 2>/dev/null)"
        if [ "$got" = "$want" ]; then pass "M8b $label → $want"
        else fail "M8b $label: want '$want', got '$got'"; fi
    done <<'TABLE'
# label                     ~ command                                        ~ want
direct-tee-body-and         ~ tee out.txt <<'EOF'\nfoo && bar\nEOF\n          ~ false
direct-tee-body-semi        ~ tee out.txt <<'EOF'\nfoo; bar\nEOF\n            ~ false
direct-cat-body-or          ~ cat <<'EOF' > out.txt\nfoo || bar\nEOF\n        ~ false
direct-real-seq-no-heredoc  ~ echo a && echo b                               ~ true
direct-seq-after-terminator ~ tee out.txt <<'EOF'\nfoo\nEOF\n; rm -rf x       ~ true
direct-seq-before-opener    ~ rm -rf x; tee out.txt <<'EOF'\nfoo\nEOF\n       ~ true
TABLE
}
