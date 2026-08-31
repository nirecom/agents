# Tests: hooks/lib/strip-quoted-args.js
# Tags: heredoc, strip-quoted-args, security, boundary, table-driven, scope:issue-specific
# H7/H8 — what sits on the opener line (pipes, chains) and where the closing
# delimiter is allowed to sit.
# Sourced by feature-2121-heredoc-strip-widening.sh.

run_H7() {
    # H7 (C3, test-review round 2) — SECURITY SEAM: the opener line pipes/chains on.
    # `tee out <<'EOF' | bash` writes the body to a file AND feeds it to an interpreter;
    # `cat <<'EOF' > x; rm -rf y` puts a real command on the opener line. The sink owns
    # the redirection in both, so the cmdPart anchor alone would happily strip — the
    # restOfLine `/[|&;]/` refusal in stripHeredocBody() is the only thing stopping it.
    # H3 covers interpreter-PREFIXED openers; this is the orthogonal case where the
    # interpreter sits AFTER the opener, and it is asserted against the function
    # directly (not through the hook seam) so the guard cannot be lost silently.
    local label cmd want got
    # Separator is '~': the payload under test contains '|' and '&&'.
    while IFS='~' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(stripped "$cmd")"
        assert_eq "H7 $label (stripped=$want)" "$want" "$got"
    done <<'TABLE'
# label                    ~ command                                                    ~ stripped?
tee-pipe-to-bash           ~ tee out.txt <<'EOF' | bash\nrm -rf /repo/x\nEOF\n           ~ false
cat-pipe-to-bash           ~ cat <<'EOF' | bash\nrm -rf /repo/x\nEOF\n                   ~ false
sponge-pipe-to-sh          ~ sponge out.txt <<'EOF' | sh\nrm -rf /repo/x\nEOF\n          ~ false
tee-semi-chained           ~ tee out.txt <<'EOF'; rm -rf /repo/x\nbody\nEOF\n            ~ false
cat-semi-chained           ~ cat <<'EOF' > x; rm -rf /repo/x\nbody\nEOF\n                ~ false
tee-and-chained            ~ tee out.txt <<'EOF' && rm -rf /repo/x\nbody\nEOF\n          ~ false
cat-or-chained             ~ cat <<'EOF' > x || rm -rf /repo/x\nbody\nEOF\n              ~ false
tee-background-amp         ~ tee out.txt <<'EOF' &\nbody\nEOF\n                          ~ false
# Control: the same sinks with a CLEAN opener line must still be stripped, so the
# refusal above is attributable to the pipe/chain and not to a blanket regression.
tee-clean-opener-line      ~ tee out.txt <<'EOF'\nbody\nEOF\n                             ~ true
cat-clean-redirect-only    ~ cat <<'EOF' > x\nbody\nEOF\n                                ~ true
TABLE

    # Change-detection alone would pass a strip that fires but leaves the payload:
    # pin that the executed body text is still THERE for the write scanners.
    assert_eq "H7 piped-sink body text survives (stays visible to write detection)" "false" \
        "$(body_gone "tee out.txt <<'EOF' | bash\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H7 semi-chained opener: the chained command survives" "false" \
        "$(body_gone "tee out.txt <<'EOF'; RMPAYLOAD\\nbody\\nEOF\\n" "RMPAYLOAD")"
}

run_H8() {
    # H8 (C6, test-review round 2) — BOUNDARY: indented closing delimiter.
    # The closing branch of the regex is `\n\s*\4\s*(?:\n|$)` — `\s*` accepts leading
    # whitespace on the terminator line for EVERY opener form. POSIX only allows an
    # indented terminator after the `<<-` form; a plain `<<EOF` requires the tag flush
    # at column 0. These cases PIN THE ACTUAL BEHAVIOUR (they do not assert the POSIX
    # rule) so a future re-anchor of that branch is a deliberate, visible change.
    # Divergence direction (why this is pinned, not fixed here): the hook's terminator
    # is always at or BEFORE the shell's, so it strips a SUBSET of the real body —
    # text the shell would swallow as data stays VISIBLE to the write scanners. That
    # is the fail-safe direction; see the final two assertions.
    local label cmd want got
    while IFS='~' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(stripped "$cmd")"
        assert_eq "H8 $label (stripped=$want)" "$want" "$got"
    done <<'TABLE'
# label                     ~ command                                  ~ stripped? (ACTUAL, pinned)
# POSIX-legal: <<- strips leading TABS from the terminator line.
dash-form-tab-indented      ~ cat <<-EOF > x\nbody\n\tEOF\n            ~ true
dash-form-space-indented    ~ cat <<-EOF > x\nbody\n  EOF\n            ~ true
# POSIX-ILLEGAL for a plain <<: a real shell does NOT terminate here. The current
# regex accepts it anyway. Pinned as-is -- suspected over-acceptance, fail-safe.
plain-form-space-indented   ~ cat <<EOF > x\nbody\n  EOF\n             ~ true
plain-form-tab-indented     ~ cat <<EOF > x\nbody\n\tEOF\n             ~ true
quoted-form-space-indented  ~ cat <<'EOF' > x\nbody\n  EOF\n           ~ true
# Baseline: the flush terminator every form agrees on.
plain-form-flush            ~ cat <<EOF > x\nbody\nEOF\n               ~ true
TABLE

    # Fail-safe direction, asserted rather than assumed: with a plain `<<EOF` and an
    # indented terminator, a real shell treats the trailing line as heredoc DATA,
    # while the hook ends the body early -- so the trailing command stays visible to
    # the write scanners. Over-visibility is the safe side of this divergence.
    assert_eq "H8 text after an indented terminator stays VISIBLE (over-visible = fail-safe)" "false" \
        "$(body_gone "cat <<EOF > x\\nbody\\n  EOF\\nRMPAYLOAD\\n" "RMPAYLOAD")"
    # And the body before it is genuinely removed, so the case above is not passing
    # merely because nothing was stripped at all.
    assert_eq "H8 indented-terminator body IS removed (the strip really fired)" "true" \
        "$(body_gone "cat <<EOF > x\\nSECRETBODY\\n  EOF\\nRMPAYLOAD\\n" "SECRETBODY")"
}
