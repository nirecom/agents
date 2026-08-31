# Tests: hooks/lib/strip-quoted-args.js
# Tags: heredoc, strip-quoted-args, security, boundary, table-driven, scope:issue-specific
# H11 — endsWithLineContinuation(): an opener line ending in a backslash carries
# the NEXT line's pipe/chain, so the strip must refuse.
# Sourced by feature-2121-heredoc-strip-widening.sh.

run_H11() {
    # H11 (r5, security review round 5) — SECURITY: the trailing line-continuation gap.
    # H7 refuses when `| bash` sits on the opener line, because restOfLine matches
    # /[|&;]/. A trailing backslash moves that pipe to the NEXT physical line, where
    # restOfLine cannot see it — yet the shell still joins the two, so the sink is
    # piped into an interpreter exactly as in H7. endsWithLineContinuation(restOfLine)
    # closes that gap by refusing whenever the trailing backslash RUN is odd-length.
    # An even run is an escaped literal backslash, not a continuation, so it must
    # still strip — that is the over-blocking control below.
    local label cmd want got
    # Separator is '~': the payloads contain '|' and '&&'. In these rows a table
    # `\\` becomes ONE literal backslash after printf '%b', `\\\\` becomes two.
    while IFS='~' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(stripped "$cmd")"
        assert_eq "H11 $label (stripped=$want)" "$want" "$got"
    done <<'TABLE'
# label                     ~ command                                                     ~ stripped?
# --- THE PoC: one trailing backslash hides the pipe on the next line -------------
poc-tee-cont-pipe-bash      ~ tee out.txt <<'EOF' \\\n| bash\nrm -rf /repo/src\nEOF\n      ~ false
poc-cat-cont-and-chain      ~ cat <<'EOF' > out.txt \\\n&& rm -rf /repo/src\nbody\nEOF\n  ~ false
poc-sponge-cont-pipe-sh     ~ sponge out.txt <<'EOF' \\\n| sh\nrm -rf /repo/src\nEOF\n    ~ false
poc-cont-no-space-before    ~ tee out.txt <<'EOF'\\\n| bash\nrm -rf /repo/src\nEOF\n      ~ false
# Trailing blanks are trimmed before the run is counted, so `\ ` still refuses.
poc-cont-trailing-space     ~ tee out.txt <<'EOF' \\ \n| bash\nbody\nEOF\n                ~ false
poc-cont-three-backslashes  ~ tee out.txt <<'EOF' \\\\\\\n| bash\nbody\nEOF\n             ~ false
# --- EVEN run: an escaped literal backslash is NOT a continuation, so it strips ---
ctl-two-backslashes         ~ tee out.txt <<'EOF' \\\\\nbody\nEOF\n                       ~ true
ctl-four-backslashes        ~ tee out.txt <<'EOF' \\\\\\\\\nbody\nEOF\n                   ~ true
# --- backslash present but not trailing, and the plain baselines ------------------
ctl-backslash-not-trailing  ~ tee out\\ file.txt <<'EOF'\nbody\nEOF\n                     ~ true
base-cat-redirect           ~ cat <<EOF > /tmp/out.md\nbody\nEOF\n                        ~ true
base-tee-clean              ~ tee out.txt <<'EOF'\nbody\nEOF\n                            ~ true
# --- LEADING side of the same escape: isLineContinuedBoundary ---------------------
# The rows above are the trailing side (the opener line continues onward). This is
# its mirror: `bash -s \<NL>cat <<EOF` is ONE logical command, so the newline before
# `cat` is NOT a segment boundary and the sink is an interpreter's ARGUMENT, not a
# head. The lookbehind alone cannot see that — it matches the raw `\n`.
poc-bash-s-cont-cat-head    ~ bash -s \\\ncat <<'EOF' > out.txt\nrm -rf /repo/src\nEOF\n  ~ false
poc-sh-cont-tee-head        ~ sh \\\ntee out.txt <<'EOF'\nrm -rf /repo/src\nEOF\n         ~ false
# Control: the SAME text with a plain newline really is a boundary, so cat is a
# head and the body is stripped — the refusal above is the backslash, not the shape.
ctl-bash-s-plain-newline    ~ bash -s\ncat <<'EOF' > out.txt\nbody\nEOF\n                  ~ true
TABLE

    # Change-detection cannot tell "refused" from "matched nothing": pin that the
    # continued-into payload survives, and that the even-run control's body is gone.
    assert_eq "H11 continued-opener body text survives (stays visible to write detection)" "false" \
        "$(body_gone "tee out.txt <<'EOF' \\\\\\n| bash\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H11 the hidden '| bash' itself survives the refusal" "false" \
        "$(body_gone "tee out.txt <<'EOF' \\\\\\n| bash\\nbody\\nEOF\\n" "| bash")"
    assert_eq "H11 even-run control body IS removed (refusal is attributable to the odd run)" "true" \
        "$(body_gone "tee out.txt <<'EOF' \\\\\\\\\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"

    # The predicate itself, asserted directly: a seam-only test would still pass if
    # some unrelated guard did the refusing. `exports` is part of the contract — the
    # helper is the named unit this round added, so losing the export is a regression.
    local got_u
    got_u="$(run_with_timeout 30 node -e '
try {
  const m=require(process.argv[1]);
  if (typeof m.endsWithLineContinuation !== "function") { process.stdout.write("NOT-A-FUNCTION"); }
  else process.stdout.write(process.argv.slice(2).map(p=>String(m.endsWithLineContinuation(p))).join(","));
} catch (e) { process.stdout.write("ERROR"); }
' "$SQA" \
        " > out.txt" \
        "$(printf '%b' " > out.txt \\\\")" \
        "$(printf '%b' " > out.txt \\\\\\\\")" \
        "$(printf '%b' " > out.txt \\\\\\\\\\\\")" \
        "$(printf '%b' " > out.txt \\\\   ")" \
        "$(printf '%b' " > out.txt \\\\\t")" \
        "$(printf '%b' "\\\\")" \
        "" 2>/dev/null)"
    assert_eq "H11 endsWithLineContinuation: odd backslash runs continue, even runs and blanks do not" \
        "false,true,false,true,true,true,true,false" "$got_u"

    # Non-vacuity for the leading-side rows, and the sibling export pinned directly.
    # The probe strings are built INSIDE node: `$( )` strips the trailing newline
    # these inputs must end with, so argv cannot carry them.
    assert_eq "H11 line-continued boundary: the interpreter's body text survives" "false" \
        "$(body_gone "bash -s \\\\\\ncat <<'EOF' > out.txt\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H11 plain-newline control body IS removed (refusal is attributable to the backslash)" "true" \
        "$(body_gone "bash -s\\ncat <<'EOF' > out.txt\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"

    got_u="$(run_with_timeout 30 node -e '
try {
  const m=require(process.argv[1]);
  if (typeof m.isLineContinuedBoundary !== "function") { process.stdout.write("NOT-A-FUNCTION"); }
  else {
    const cases=["bash -s \\\n","bash -s\n","bash -s \\\\\n","bash -s \\\\\\\n","bash -s ",""];
    process.stdout.write(cases.map(p=>String(m.isLineContinuedBoundary(p))).join(","));
  }
} catch (e) { process.stdout.write("ERROR"); }
' "$SQA" 2>/dev/null)"
    assert_eq "H11 isLineContinuedBoundary: odd backslash runs before the newline continue, even runs and no-newline do not" \
        "true,false,false,true,false,false" "$got_u"
}
