# Tests: hooks/lib/strip-quoted-args.js
# Tags: heredoc, strip-quoted-args, negative-control, table-driven, scope:issue-specific
# H9 — commands OUTSIDE the cat|tee|sponge sink list, plus bare openers.
# Sourced by feature-2121-heredoc-strip-widening.sh.

run_H9() {
    # H9 (C2, test-review round 2) — NEGATIVE CONTROL for the sink list itself.
    # H1/H7 prove cat|tee|sponge ARE stripped; nothing yet proved a command OUTSIDE
    # that list is not, so the widening could have landed as "any command before
    # <<TAG" with every positive case still green. `dd`/`xargs` are the plausible
    # non-granted additions (xargs EXECUTES its stdin); `mail` was deliberately
    # dropped in security review round 1 (F4 — outbound channel, not a file sink).
    # The bare-opener rows pin behaviour read off the source, not assumed: the
    # regex's cmdPart is mandatory, so `<<EOF` with no command never matches.
    local label cmd got
    while IFS='|' read -r label cmd; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"
        got="$(stripped "$cmd")"
        assert_eq "H9 $label: NOT a recognized sink — command left unchanged" "false" "$got"
    done <<'TABLE'
# --- dd: writes files, but is not on the cat|tee|sponge list ----------------
dd-of-redirect     | dd of=out.txt <<'EOF'\nfoo; bar\nEOF\n
dd-bare-unquoted   | dd <<EOF\nfoo; bar\nEOF\n
# --- xargs: consumes stdin and EXECUTES it as arguments ---------------------
xargs-bare         | xargs <<'EOF'\nfoo; bar\nEOF\n
xargs-rm           | xargs rm <<'EOF'\n/repo/x\nEOF\n
# --- mail: DROPPED sink (F4) — outbound channel, body must stay visible -----
mail-plain         | mail user@x <<'EOF'\nfoo; bar\nEOF\n
mail-subject-flag  | mail -s hi user@x <<EOF\nfoo; bar\nEOF\n
# --- ORDINARY filters: read stdin, write no file, execute nothing -----------
# The rows above are all commands with a REASON to be excluded (dd writes, xargs
# executes, mail exfiltrates). Nothing yet covered the plain, boring case: a
# harmless non-interpreter that is simply not on the cat|tee|sponge list. It must
# be left alone for the same reason, and its body must stay visible — the strip
# is a whitelist, so a filter is a non-sink by default, not by exception.
wc-lines           | wc -l <<'EOF'\nfoo; bar\nEOF\n
wc-with-redirect   | wc -l <<'EOF' > count.txt\nfoo; bar\nEOF\n
sort-bare          | sort <<'EOF'\nfoo; bar\nEOF\n
grep-pattern       | grep foo <<'EOF'\nfoo; bar\nEOF\n
# --- no command at all before the opener (pinned from the source) -----------
bare-opener-quoted | <<'EOF'\nfoo; bar\nEOF\n
bare-opener-plain  | <<EOF\nfoo; bar\nEOF\n
bare-opener-redir  | <<'EOF' > x\nfoo; bar\nEOF\n
TABLE

    # Change-detection cannot tell "nothing stripped" from "something else stripped":
    # pin that each non-sink form's BODY TEXT is still present afterwards.
    assert_eq "H9 dd body text survives (stays visible to write detection)" "false" \
        "$(body_gone "dd of=out.txt <<'EOF'\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H9 xargs body text survives (xargs EXECUTES its stdin)" "false" \
        "$(body_gone "xargs rm <<'EOF'\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H9 mail body text survives (outbound channel, info-leak visibility)" "false" \
        "$(body_gone "mail user@x <<'EOF'\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H9 bare-opener body text survives (no sink owns the redirection)" "false" \
        "$(body_gone "<<'EOF' > x\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H9 ordinary-filter body text survives (wc is not a write sink)" "false" \
        "$(body_gone "wc -l <<'EOF'\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H9 ordinary filter WITH a redirect still survives (the sink list, not the '>', decides)" "false" \
        "$(body_gone "wc -l <<'EOF' > count.txt\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"

    # Control: the identical body under a recognized sink IS stripped, so every
    # "false" above is attributable to the command name, not to a matcher that
    # simply failed on this payload shape.
    assert_eq "H9 control: the same body under a recognized sink (cat) IS stripped" "true" \
        "$(body_gone "cat <<'EOF' > x\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
}
