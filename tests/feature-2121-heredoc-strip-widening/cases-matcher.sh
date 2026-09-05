# Tests: hooks/lib/strip-quoted-args.js
# Tags: heredoc, strip-quoted-args, regex, table-driven, scope:issue-specific
# H1/H2 — which openers the widened matcher accepts, and proof the strip really
# removes the body rather than merely altering the string.
# Sourced by feature-2121-heredoc-strip-widening.sh.

# ── H1 — the widened matcher: which openers get their body stripped.
run_H1() {
    local label cmd want got
    while IFS='|' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(stripped "$cmd")"
        assert_eq "H1 $label (stripped=$want)" "$want" "$got"
    done <<'TABLE'
# --- case 10: today's behaviour, preserved ---------------------------------
cat-quoted-redirect    | cat <<'EOF' > x\na; b\nEOF\n                    | true
cat-dq-delim           | cat <<"EOF" > x\na; b\nEOF\n                     | true
cat-dash-form          | cat <<-'EOF' > x\na; b\nEOF\n                    | true
cat-unquoted-plain     | cat <<EOF > x\nplain text\nEOF\n                 | true
cat-nospace-opener     | cat<<'EOF' > x\na; b\nEOF\n                      | true
# --- case 11: non-cat command before a quoted heredoc ----------------------
# The sink list is cat|tee|sponge only. F4 (security review round 1): `mail` is an
# outbound channel, not a file sink — its body must stay visible, so NOT stripped.
tee-quoted             | tee out.txt <<'EOF'\nfoo && bar\nEOF\n           | true
tee-append-quoted      | tee -a out.txt <<'EOF'\nfoo; bar\nEOF\n          | true
sponge-quoted          | sponge out.txt <<'EOF'\nfoo; bar\nEOF\n          | true
mail-quoted            | mail -s hi u@example.com <<'EOF'\nfoo; bar\nEOF\n | false
# --- case 12: delimiter charset beyond \w+ ---------------------------------
delim-dotted           | cat <<'EOF-1.2' > x\na; b\nEOF-1.2\n             | true
delim-hyphen           | cat <<'END-OF-BODY' > x\na; b\nEND-OF-BODY\n     | true
delim-leading-under    | cat <<'_TAG9' > x\na; b\n_TAG9\n                 | true
delim-plain-word       | cat <<'EOF9' > x\na; b\nEOF9\n                   | true
delim-single-char      | cat <<'X' > x\na; b\nX\n                        | true
# --- C5 (test-review round 1): delimiter first-char boundary --------------
# The widened delimiter charset is [A-Za-z_][A-Za-z0-9_.-]*: only the FIRST
# character is restricted to a letter/underscore. A regex that instead widened
# to [A-Za-z0-9_.-]+ (digit/dot/hyphen legal in first position too) would
# wrongly strip these -- they must stay unstripped both before AND after #2121.
delim-leading-digit    | cat <<'9EOF' > x\na; b\n9EOF\n                   | false
delim-leading-dot      | cat <<'.EOF' > x\na; b\n.EOF\n                   | false
delim-leading-hyphen   | cat <<'-EOF' > x\na; b\n-EOF\n                   | false
# --- case 13 + edges: what must still NOT be stripped ----------------------
unquoted-cmdsubst      | cat <<EOF > x\n$(echo hi); bar\nEOF\n            | false
unquoted-backtick      | cat <<EOF > x\n`id`; bar\nEOF\n                  | false
unterminated-heredoc   | cat <<'EOF' > x\na; b\n                          | false
# EOFTAIL is not the delimiter: a prefix match must not close the heredoc.
false-terminator-prefix| cat <<'EOF' > x\na; b\nEOFTAIL\n                  | false
no-heredoc-at-all      | echo hello world                                | false
empty-string           |                                                 | false
TABLE
}

# ── H2 — the strip must actually remove the body, not merely alter the string.
run_H2() {
    assert_eq "H2 cat: body text is gone after the strip" "true" \
        "$(body_gone "cat <<'EOF' > x\\nSECRETBODY\\nEOF\\n" "SECRETBODY")"
    assert_eq "H2 tee: body text is gone after the strip" "true" \
        "$(body_gone "tee out.txt <<'EOF'\\nSECRETBODY\\nEOF\\n" "SECRETBODY")"
    assert_eq "H2 dotted delimiter: body text is gone after the strip" "true" \
        "$(body_gone "cat <<'EOF-1.2' > x\\nSECRETBODY\\nEOF-1.2\\n" "SECRETBODY")"
    # Rest-of-line after the opener is preserved (safety constraint 2): an external
    # redirect must stay visible to target extraction. The needle is deliberately
    # relative — MSYS/Git-Bash rewrites a lone /abs/path argv into a Windows path,
    # which would make this assertion pass or fail for the wrong reason.
    assert_eq "H2 redirect target on the opener line survives the strip" "false" \
        "$(body_gone "cat <<'EOF' > keepme.txt\\nSECRETBODY\\nEOF\\n" "keepme.txt")"
    assert_eq "H2 the opener itself survives the strip (here-doc detection still fires)" "false" \
        "$(body_gone "cat <<'EOF' > x\\nSECRETBODY\\nEOF\\n" "<<'EOF'")"
}
