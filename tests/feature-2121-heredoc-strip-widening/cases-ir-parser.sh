# Tests: hooks/lib/command-ir.js, hooks/lib/bash-write-patterns.js
# Tags: heredoc, command-ir, parser, write-detector, table-driven, scope:issue-specific
# H13 — #2121 Changes 1 & 2 on the IR path (detail.md S1-8 / S2-8).
# Change 1 (RED until hooks/lib/command-ir/ lands): a heredoc BODY must not reach
# the lexer, so its `;` `&&` `|` `>` never become separators/redirects.
# Change 2 (GREEN today, ratchet): the write verdict for interpreter/body-file
# heredocs stays `write` after that fix — see this suite's H3 constraint note.
# Sourced by feature-2121-heredoc-strip-widening.sh; needs AN + assert_eq +
# pass/fail + run_with_timeout from helpers.sh.

CIR="$AN/hooks/lib/command-ir.js"
BWP="$AN/hooks/lib/bash-write-patterns.js"

# ir_field <field> <cmd> — one scalar per call, "ERROR" on throw (never an
# expected value, so a crash can never be scored as an empty-but-equal result).
#   seps -> comma-joined ir.separators / nseg -> segment count
#   redirops -> comma-joined redirect operators across ALL segments
ir_field() {
    run_with_timeout 30 node -e '
try {
  const {parse}=require(process.argv[1]);
  const ir=parse(process.argv[3]);
  const f=process.argv[2];
  let out;
  if (f==="seps") out=ir.separators.join(",");
  else if (f==="nseg") out=String(ir.segments.length);
  else if (f==="redirops") out=ir.segments.map(s=>s.redirects.map(r=>r.op).join(",")).filter(Boolean).join(",");
  else out="BADFIELD";
  process.stdout.write(out);
} catch (e) { process.stdout.write("ERROR"); }
' "$CIR" "$1" "$(printf '%b' "$2")" 2>/dev/null
}

# wclass <cmd> — classify(parse(cmd)) from the write detector.
wclass() {
    run_with_timeout 30 node -e '
try {
  const {parse}=require(process.argv[1]);
  const {classify}=require(process.argv[2]);
  process.stdout.write(String(classify(parse(process.argv[3]))));
} catch (e) { process.stdout.write("ERROR"); }
' "$CIR" "$BWP" "$(printf '%b' "$1")" 2>/dev/null
}

run_H13() {
    if [ ! -f "$CIR" ] || [ ! -f "$BWP" ]; then
        fail "H13 harness: command-ir.js or bash-write-patterns.js missing — every H13 case would be vacuous"
        return
    fi

    # H13a — heredoc-body operators are NOT separators. Pre-fix measurements:
    # `python3 <<'PY' … x = 1; y = 2 … PY` -> separators [";"]; the node row ->
    # ["(","&&",")",";"]; the gh row -> ["&&",";","|"]. H13d keeps this
    # attributable: the same probe must still report real top-level operators.
    local label cmd got
    while IFS='|' read -r label cmd; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"
        got="$(ir_field seps "$cmd")"
        assert_eq "H13a $label: body operators are not separators" "" "$got"
    done <<'TABLE'
py-semicolon      | python3 <<'PY'\nimport os\nx = 1; y = 2\nPY\n
py-and            | python3 <<'PY'\nos.system("a && b")\nPY\n
py-redirect       | python3 <<'PY'\nprint(1 > 0)\nPY\n
py-parens         | python3 <<'PY'\nprint(1)\nPY\n
py-unquoted-tag   | python3 <<PY\nprint(1)\nPY\n
py-dash-tag       | python3 <<-PY\n\tprint(1)\n\tPY\n
node-and          | node <<'JS'\nconsole.log(1 && 2);\nJS\n
node-or           | node <<'JS'\nconst v = a || b;\nJS\n
node-pipe         | node <<'JS'\nconst r = a | b;\nJS\n
node-redirect     | node <<'JS'\nconst a = 1 > 0;\nJS\n
gh-body-file      | gh issue create --body-file - <<'EOF'\na && b; c | d\nEOF\n
gh-body-file-and  | gh issue create --body-file - <<'EOF'\na && b\nEOF\n
gh-pr-body-file   | gh pr create --body-file - <<'EOF'\nfix: a; b\nEOF\n
cat-and           | cat <<'EOF'\na && b\nEOF\n
tee-and           | tee out.txt <<'EOF'\nfoo && bar\nEOF\n
tee-append-semi   | tee -a out.txt <<'EOF'\nfoo; bar\nEOF\n
sponge-semi       | sponge out.txt <<'EOF'\nfoo; bar\nEOF\n
cat-dotted-delim  | cat <<'EOF-1.2'\na && b; c | d\nEOF-1.2\n
TABLE

    # H13b — independent witness for the same bodies: `(` / `)` also land on
    # `separators`, so a parser could drop them while still splitting. Segment
    # count cannot be satisfied that way.
    while IFS='|' read -r label cmd; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"
        got="$(ir_field nseg "$cmd")"
        assert_eq "H13b $label: body stays inside one segment" "1" "$got"
    done <<'TABLE'
py-semicolon      | python3 <<'PY'\nimport os\nx = 1; y = 2\nPY\n
py-parens         | python3 <<'PY'\nprint(1)\nPY\n
node-and          | node <<'JS'\nconsole.log(1 && 2);\nJS\n
node-pipe         | node <<'JS'\nconst r = a | b;\nJS\n
gh-body-file      | gh issue create --body-file - <<'EOF'\na && b; c | d\nEOF\n
cat-and           | cat <<'EOF'\na && b\nEOF\n
tee-and           | tee out.txt <<'EOF'\nfoo && bar\nEOF\n
sponge-semi       | sponge out.txt <<'EOF'\nfoo; bar\nEOF\n
cat-dotted-delim  | cat <<'EOF-1.2'\na && b; c | d\nEOF-1.2\n
TABLE

    # H13c — a `>` inside the body must not be recorded as a redirect: redirect
    # records feed bash-write-targets.js, so a phantom `>` invents a write TARGET
    # out of program text.
    while IFS='|' read -r label cmd; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"
        got="$(ir_field redirops "$cmd")"
        case "$got" in
            ERROR) fail "H13c $label: probe threw" ;;
            *'>'*) fail "H13c $label: body text produced an output redirect — ops='$got'" ;;
            *) pass "H13c $label: body text produced no output redirect" ;;
        esac
    done <<'TABLE'
py-redirect       | python3 <<'PY'\nprint(1 > 0)\nPY\n
py-append         | python3 <<'PY'\nx = a >> 1\nPY\n
node-redirect     | node <<'JS'\nconst a = 1 > 0;\nJS\n
gh-body-redirect  | gh issue create --body-file - <<'EOF'\nuse a > b\nEOF\n
tee-body-redirect | tee out.txt <<'EOF'\nuse a > b\nEOF\n
sponge-body-redir | sponge out.txt <<'EOF'\nuse a > b\nEOF\n
dotted-body-redir | cat <<'EOF-1.2'\nuse a > b\nEOF-1.2\n
TABLE

    # H13d — attributability controls. Without them H13a/H13b would also pass
    # against a parser that lost EVERY separator, disarming every fail-closed
    # consumer that reads ir.separators.length.
    assert_eq "H13d control: a real top-level && still separates" "&&" \
        "$(ir_field seps "echo a && echo b")"
    assert_eq "H13d control: a real top-level ; still separates" ";" \
        "$(ir_field seps "echo a; echo b")"
    assert_eq "H13d control: a real top-level | still separates" "|" \
        "$(ir_field seps "echo a | grep b")"
    assert_eq "H13d control: an && on the OPENER line still separates" "&&" \
        "$(ir_field seps "python3 <<'PY' && echo done\\nx = 1\\nPY\\n")"
    assert_eq "H13d control: two segments around the opener-line &&" "2" \
        "$(ir_field nseg "python3 <<'PY' && echo done\\nx = 1\\nPY\\n")"

    # H13e — Change 2 ratchet. GREEN on the pre-fix tree (measured); fails only
    # if the parser replacement relaxes the write verdict.
    while IFS='|' read -r label cmd; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"
        got="$(wclass "$cmd")"
        assert_eq "H13e $label: still classifies as write" "write" "$got"
    done <<'TABLE'
py-heredoc        | python3 <<'PY'\nprint(1)\nPY\n
py-heredoc-semi   | python3 <<'PY'\nimport os\nx = 1; y = 2\nPY\n
py-unquoted-tag   | python3 <<PY\nprint(1)\nPY\n
py-dash-tag       | python3 <<-PY\n\tprint(1)\n\tPY\n
node-heredoc      | node <<'JS'\nconsole.log(1)\nJS\n
node-heredoc-and  | node <<'JS'\nconsole.log(1 && 2);\nJS\n
bash-heredoc      | bash <<'EOF'\nrm -rf /repo/x\nEOF\n
gh-body-file      | gh issue create --body-file - <<'EOF'\nhello\nEOF\n
gh-body-file-ops  | gh issue create --body-file - <<'EOF'\na && b; c | d\nEOF\n
TABLE

    # H13f — Change 2 attributability: the classifier is not blanket-write.
    assert_eq "H13f control: python3 -c without heredoc is read" "read" \
        "$(wclass "python3 -c 'print(1)'")"
    assert_eq "H13f control: cat heredoc is read" "read" \
        "$(wclass "cat <<'EOF'\\na && b\\nEOF\\n")"
    assert_eq "H13f control: plain cat is read" "read" \
        "$(wclass "cat file.txt")"
}
