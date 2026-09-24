# Tests: hooks/lib/strip-quoted-args.js, hooks/lib/quote-spans.js
# Tags: heredoc, strip-quoted-args, security, quote-aware, fail-closed, table-driven, scope:issue-specific
# H10 — isInsideSubstitution() walks BLANKED quote spans and fails closed.
# Sourced by feature-2121-heredoc-strip-widening.sh.

run_H10() {
    # H10 (r5 C24, security review round 5) — SECURITY: the capture-detection walk.
    # A sink inside `$( )` / `` ` ` `` / `<( )` does not write a file: its stdout is
    # CAPTURED and executed, so the heredoc body is an interpreter's program and must
    # stay visible. The old walk counted `$(`/`)` over RAW text, so a `)` hidden in a
    # quoted literal inside the substitution body cancelled the open frame, the walk
    # concluded "not captured", and the body was stripped away from the write
    # scanners. The fix runs the walk over blankQuoteSpans(prefix).out and fails
    # CLOSED (treat as captured) when the scan throws or reports ok:false.
    local label cmd want got
    # Separator is '~': the payloads contain '|', ';' and quotes.
    while IFS='~' read -r label cmd want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(stripped "$cmd")"
        assert_eq "H10 $label (stripped=$want)" "$want" "$got"
    done <<'TABLE'
# label                     ~ command                                                                  ~ stripped?
# --- THE PoC: a quoted ')' inside the substitution body must not close the frame --
poc-cmdsubst-quoted-paren   ~ eval "$(echo ')'; cat <<'EOF'\nrm -rf /repo/docs\nEOF\n)"                 ~ false
poc-backtick-quoted-paren   ~ eval "`echo ')'; cat <<'EOF'\nrm -rf /repo/docs\nEOF\n`"                  ~ false
poc-procsubst-quoted-paren  ~ bash <(echo ')'; cat <<'EOF'\nrm -rf /repo/docs\nEOF\n)                   ~ false
poc-dq-quoted-paren         ~ eval "$(echo ")"; cat <<'EOF'\nrm -rf /repo/docs\nEOF\n)"                 ~ false
# Baseline the PoC rows are measured against: the same capture with NO decoy paren.
plain-open-cmdsubst         ~ eval "$(cat <<'EOF'\nrm -rf /repo/docs\nEOF\n)"                           ~ false
plain-open-procsubst        ~ bash <(cat <<'EOF'\nrm -rf /repo/docs\nEOF\n)                             ~ false
# --- FAIL-CLOSED: an unparseable prefix (blankQuoteSpans ok:false) refuses --------
failclosed-unclosed-dq      ~ echo "unclosed\ncat <<'EOF' > out.txt\nBODY\nEOF\n                        ~ false
failclosed-unclosed-sq      ~ echo 'unclosed\ncat <<'EOF' > out.txt\nBODY\nEOF\n                        ~ false
# --- NOT captured: quote-awareness must not OVER-block a legitimate file write ----
# Each row has a paren or backtick that a raw walk would miscount; the sink itself
# sits in plain command position, so the strip must still fire.
ctl-closed-subst-quoted-par ~ echo "$(echo ')')"\ncat <<'EOF' > out.txt\nBODY\nEOF\n                    ~ true
ctl-closed-subst-plain      ~ echo "$(date)"\ncat <<'EOF' > out.txt\nBODY\nEOF\n                        ~ true
ctl-sq-literal-backtick     ~ echo 'a`b'\ncat <<'EOF' > out.txt\nBODY\nEOF\n                            ~ true
ctl-sq-literal-open-paren   ~ echo 'x$(y'\ncat <<'EOF' > out.txt\nBODY\nEOF\n                           ~ true
ctl-closed-dq-prefix        ~ echo "closed"\ncat <<'EOF' > out.txt\nBODY\nEOF\n                         ~ true
ctl-plain-subshell-paren    ~ (echo hi)\ncat <<'EOF' > out.txt\nBODY\nEOF\n                             ~ true
# --- PROCESS-SUBSTITUTION WRITE: the OTHER capture direction (r3 guard) ----------
# isInsideSubstitution only sees what precedes the sink. `cat <<EOF > >(bash)` and
# `tee >(sh) <<EOF` open the substitution AFTER it, so the walk above reports
# "not captured" — yet the body still lands in a process that EXECUTES it, not in
# a file. The `/>[ \t]*\(/.test(cmdPart + restOfLine)` guard is the only refusal
# on this path; without it the executed body would be stripped from the scanners.
procsubst-cat-out-exec      ~ cat <<'EOF' > >(bash)\nrm -rf /repo/docs\nEOF\n                           ~ false
procsubst-tee-arg-exec      ~ tee >(sh) <<'EOF'\nrm -rf /repo/docs\nEOF\n                               ~ false
procsubst-out-spaced        ~ cat <<'EOF' > > (bash)\nrm -rf /repo/docs\nEOF\n                          ~ false
procsubst-tee-file-and-exec ~ tee out.txt <<'EOF' > >(sh)\nrm -rf /repo/docs\nEOF\n                     ~ false
# Controls: the identical shapes with the parenthesis removed ARE stripped, so the
# four refusals are attributable to the process substitution and not to the word.
ctl-cat-out-plain-word      ~ cat <<'EOF' > subsh\nBODY\nEOF\n                                          ~ true
ctl-tee-plain-word-arg      ~ tee subsh <<'EOF'\nBODY\nEOF\n                                            ~ true
TABLE

    # Change-detection cannot tell "refused" from "matched nothing": pin that the
    # captured body TEXT survives, and that the control's body really is removed.
    assert_eq "H10 captured body text survives the refusal (stays visible to write detection)" "false" \
        "$(body_gone "eval \"\$(echo ')'; cat <<'EOF'\\nRMPAYLOAD\\nEOF\\n)\"" "RMPAYLOAD")"
    assert_eq "H10 control body text IS removed (the refusal is attributable to the capture)" "true" \
        "$(body_gone "echo \"\$(echo ')')\"\\ncat <<'EOF' > out.txt\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"

    # Same non-vacuity pair for the process-substitution guard: the executed body
    # must still be THERE, and the paren-free control's body must really be gone.
    assert_eq "H10 procsubst write (cat > >(bash)): body text survives (the body is EXECUTED)" "false" \
        "$(body_gone "cat <<'EOF' > >(bash)\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H10 procsubst write (tee >(sh) arg form): body text survives" "false" \
        "$(body_gone "tee >(sh) <<'EOF'\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"
    assert_eq "H10 procsubst control body IS removed (refusal is attributable to the '>(' guard)" "true" \
        "$(body_gone "tee subsh <<'EOF'\\nRMPAYLOAD\\nEOF\\n" "RMPAYLOAD")"

    # The predicate itself, asserted directly: a seam-only test would still pass if
    # some unrelated guard did the refusing. `exports` is part of the contract — the
    # walk is reused by callers, so losing the export is a silent regression.
    local got_u
    got_u="$(run_with_timeout 30 node -e '
try {
  const m=require(process.argv[1]);
  if (typeof m.isInsideSubstitution !== "function") { process.stdout.write("NOT-A-FUNCTION"); }
  else process.stdout.write(process.argv.slice(2).map(p=>String(m.isInsideSubstitution(p))).join(","));
} catch (e) { process.stdout.write("ERROR"); }
' "$SQA" \
        "$(printf '%b' "eval \"\$(echo 'x)x'; ")" \
        "$(printf '%b' "eval \"\`echo 'x)x'; ")" \
        "$(printf '%b' "bash <(echo 'x)x'; ")" \
        "$(printf '%b' "echo \"\$(echo 'x)x')\"\n")" \
        "$(printf '%b' "echo 'a\`b'\n")" \
        "$(printf '%b' "echo 'x\$(y'\n")" \
        "$(printf '%b' "(echo hi)\n")" \
        "$(printf '%b' "echo \"unclosed\n")" \
        "" 2>/dev/null)"
    assert_eq "H10 isInsideSubstitution: open/decoy-paren captured, closed+quoted not, unparseable fails closed" \
        "true,true,true,false,false,false,false,true,false" "$got_u"

    # Non-vacuity for the fail-closed rows: prove the unparseable prefix really is
    # the ok:false path, not some other refusal that happens to agree.
    got_u="$(run_with_timeout 30 node -e '
try {
  const {blankQuoteSpans}=require(process.argv[1]);
  process.stdout.write(String(blankQuoteSpans(process.argv[2]).ok));
} catch (e) { process.stdout.write("ERROR"); }
' "$AN/hooks/lib/quote-spans.js" "$(printf '%b' "echo \"unclosed\n")" 2>/dev/null)"
    assert_eq "H10 fail-closed precondition: blankQuoteSpans reports ok:false for that prefix" "false" "$got_u"

    # Error-injection for the try/catch arm: blankQuoteSpans is forced to THROW, so
    # the only thing that can keep the body visible is the catch returning "captured".
    # The control run (same input, no injection) proves the input is otherwise strippable.
    got_u="$(run_with_timeout 30 node -e '
const path=require("path");
const sqa=process.argv[1], mode=process.argv[2];
const f=require.resolve(path.join(path.dirname(sqa),"quote-spans.js"));
const real=require(f);
if (mode === "throw") require.cache[f]={id:f,filename:f,loaded:true,exports:new Proxy(real,{get(t,k){ if(k==="blankQuoteSpans") return ()=>{ throw new Error("injected scanner failure"); }; return t[k]; }})};
const {stripHeredocBody}=require(sqa);
const s=process.argv[3];
process.stdout.write(String(stripHeredocBody(s)!==s));
' "$SQA" "throw" "$(printf '%b' "cat <<'EOF' > out.txt\\nBODY\\nEOF\\n")" 2>/dev/null)"
    assert_eq "H10 injected throw in blankQuoteSpans: strip is REFUSED (catch arm fails closed)" "false" "$got_u"

    got_u="$(run_with_timeout 30 node -e '
const path=require("path");
const sqa=process.argv[1], mode=process.argv[2];
const f=require.resolve(path.join(path.dirname(sqa),"quote-spans.js"));
const real=require(f);
if (mode === "throw") require.cache[f]={id:f,filename:f,loaded:true,exports:new Proxy(real,{get(t,k){ if(k==="blankQuoteSpans") return ()=>{ throw new Error("injected scanner failure"); }; return t[k]; }})};
const {stripHeredocBody}=require(sqa);
const s=process.argv[3];
process.stdout.write(String(stripHeredocBody(s)!==s));
' "$SQA" "none" "$(printf '%b' "cat <<'EOF' > out.txt\\nBODY\\nEOF\\n")" 2>/dev/null)"
    assert_eq "H10 injection control: without the throw the SAME input is stripped (case is not vacuous)" "true" "$got_u"
}
