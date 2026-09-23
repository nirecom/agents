# codex-parse.sh — fragment of tests/feature-929-agents.sh (no frontmatter).
# Source: hooks/lib/supervisor-codex-parse.js (C4). Table-driven + mutation probe.
# NOTE: RED until write-code creates hooks/lib/supervisor-codex-parse.js (#929);
#   require() fails now, so the probe emits no CASE lines and asserts fail.
# Pins the CLI contract: OUTFILE holds FINDING lines only (no verdict/markers);
#   audit verdict is conveyed on a separate `VERDICT: <V>` stdout line so the
#   file stays compatible with `supervisor-write-audit-verdict --findings-jsonl`.

_cp_assert_line() {
    local name="$1" needle="$2" out="$3" ln
    ln="$(printf '%s\n' "$out" | grep "^$name|" 2>/dev/null || true)"
    assert_contains "cp: $name" "$ln" "$needle"
}

_cp_node_exists() { run_with_timeout 20 node -e 'process.exit(require("fs").existsSync(process.argv[1])?0:1)' "$1" 2>/dev/null; }
_cp_node_read() { run_with_timeout 20 node -e 'process.stdout.write(require("fs").readFileSync(process.argv[1],"utf8"))' "$1" 2>/dev/null; }

_cp_run() {
    echo ""
    echo "--- codex-parse (C4) ---"

    # Function-level table (all verdict values + every reject rule; CPR-ORTH).
    local probe="$TMPDIR_BASE/cp-cases.js"
    cat > "$probe" <<'JS'
const mod = require(process.argv[2]);
const B = "<!-- begin-codex-output -->";
const E = "<!-- end-codex-output -->";
const vf = '{"categories":["workflow"],"severity":"warning","detail":"transcript lacks step evidence around WF-CODE-2"}';
const vf2 = '{"categories":["code"],"severity":"notice","detail":"naming drift in helper foo"}';
const mj = '{"categories":["workflow"],"severity":"warning","detail":';
const ms = '{"categories":["workflow"],"detail":"no severity key present"}';
const bs = '{"categories":["workflow"],"severity":"critical","detail":"severity out of range"}';
const vC = '{"verdict":"CONTINUE","summary":"stages cohere across intent and detail"}';
const vW = '{"verdict":"WARN","summary":"minor scope drift noted"}';
const iv = '{"verdict":"PROCEED","summary":"not an allowed verdict token"}';
const lc = '{"verdict":"continue","summary":"lowercase must not match"}';
const px = 'x{"verdict":"CONTINUE","summary":"prefixed must not match"}';
const wrap = (lines) => B + "\n" + lines.join("\n") + "\n" + E;
const cases = [
  ["A1_alert_two_valid", "alert", wrap([vf, vf2])],
  ["A2_alert_zero", "alert", wrap([])],
  ["A3_alert_malformed", "alert", wrap([vf, mj])],
  ["A4_alert_missing_sev", "alert", wrap([vf, ms])],
  ["A5_alert_bad_sev", "alert", wrap([vf, bs])],
  ["A6_alert_no_end", "alert", B + "\n" + vf],
  ["A7_alert_no_begin", "alert", vf + "\n" + E],
  ["A8_alert_reversed", "alert", E + "\n" + vf + "\n" + B],
  ["D1_audit_verdict_find", "audit", wrap([vC, vf])],
  ["D2_audit_verdict_only", "audit", wrap([vW])],
  ["D3_audit_no_verdict", "audit", wrap([vf])],
  ["D4_audit_two_verdicts", "audit", wrap([vC, vW, vf])],
  ["D5_audit_invalid_verdict", "audit", wrap([iv, vf])],
  ["D6_audit_verdict_malformed_find", "audit", wrap([vC, mj])],
  ["D7_audit_verdict_bad_sev", "audit", wrap([vC, bs])],
  ["M1_audit_lowercase_verdict", "audit", wrap([lc, vf])],
  ["M2_audit_prefixed_verdict", "audit", wrap([px, vf])],
];
for (const [name, mode, input] of cases) {
  let r;
  try { r = mod.parseSupervisorFindings(input, mode); }
  catch (e) { r = { ok: "ERR" }; }
  const ok = r && r.ok;
  const verdict = (r && r.verdict) || "-";
  const nfind = (r && Array.isArray(r.findings)) ? r.findings.length : -1;
  console.log(name + "|ok=" + ok + "|verdict=" + verdict + "|nfind=" + nfind);
}
JS
    local out
    out="$(run_with_timeout 30 node "$probe" "$PARSE_MODULE" 2>/dev/null)"

    _cp_assert_line "A1_alert_two_valid" "ok=true|verdict=-|nfind=2" "$out"
    _cp_assert_line "A2_alert_zero" "ok=true|verdict=-|nfind=0" "$out"
    _cp_assert_line "A3_alert_malformed" "ok=false" "$out"
    _cp_assert_line "A4_alert_missing_sev" "ok=false" "$out"
    _cp_assert_line "A5_alert_bad_sev" "ok=false" "$out"
    _cp_assert_line "A6_alert_no_end" "ok=false" "$out"
    _cp_assert_line "A7_alert_no_begin" "ok=false" "$out"
    _cp_assert_line "A8_alert_reversed" "ok=false" "$out"
    _cp_assert_line "D1_audit_verdict_find" "ok=true|verdict=CONTINUE|nfind=1" "$out"
    _cp_assert_line "D2_audit_verdict_only" "ok=true|verdict=WARN|nfind=0" "$out"
    _cp_assert_line "D3_audit_no_verdict" "ok=false" "$out"
    _cp_assert_line "D4_audit_two_verdicts" "ok=false" "$out"
    _cp_assert_line "D5_audit_invalid_verdict" "ok=false" "$out"
    _cp_assert_line "D6_audit_verdict_malformed_find" "ok=false" "$out"
    _cp_assert_line "D7_audit_verdict_bad_sev" "ok=false" "$out"
    _cp_assert_line "M1_audit_lowercase_verdict" "ok=false" "$out"
    _cp_assert_line "M2_audit_prefixed_verdict" "ok=false" "$out"

    # CLI: os.tmpdir writeout contract (R3-C2/C4).
    local B='<!-- begin-codex-output -->'
    local E='<!-- end-codex-output -->'
    local VF='{"categories":["workflow"],"severity":"warning","detail":"transcript lacks step evidence around WF-CODE-2"}'
    local VF2='{"categories":["code"],"severity":"notice","detail":"naming drift in helper foo"}'
    local MJ='{"categories":["workflow"],"severity":"warning","detail":'
    local VC='{"verdict":"CONTINUE","summary":"stages cohere across intent and detail"}'

    # alert ok:true -> OUTFILE line, file has finding lines only, no markers/STATUS.
    local cli_ok of fc
    cli_ok="$(printf '%s\n%s\n%s\n%s\n' "$B" "$VF" "$VF2" "$E" | run_with_timeout 30 node "$PARSE_MODULE" --mode alert 2>/dev/null)"
    of="$(printf '%s\n' "$cli_ok" | sed -n 's/^OUTFILE: //p' | head -1)"
    if [ -n "$of" ] && _cp_node_exists "$of"; then
        fc="$(_cp_node_read "$of")"
        assert_contains "cp CLI alert ok: OUTFILE holds finding detail" "$fc" "transcript lacks step evidence"
        assert_not_contains "cp CLI alert ok: OUTFILE has no begin marker" "$fc" "begin-codex-output"
        assert_not_contains "cp CLI alert ok: OUTFILE has no STATUS line" "$fc" "STATUS:"
    else
        fail "cp CLI alert ok: OUTFILE path missing/unreadable (RED until module exists)"
    fi

    # alert ok:false (malformed finding) -> no OUTFILE line, no file.
    local cli_bad
    cli_bad="$(printf '%s\n%s\n%s\n%s\n' "$B" "$VF" "$MJ" "$E" | run_with_timeout 30 node "$PARSE_MODULE" --mode alert 2>/dev/null)"
    assert_not_contains "cp CLI alert bad: no OUTFILE on {ok:false}" "$cli_bad" "OUTFILE:"

    # audit ok:true -> VERDICT line + OUTFILE with finding-only lines (no verdict).
    local cli_aud of_a fc_a
    cli_aud="$(printf '%s\n%s\n%s\n%s\n' "$B" "$VC" "$VF" "$E" | run_with_timeout 30 node "$PARSE_MODULE" --mode audit 2>/dev/null)"
    assert_contains "cp CLI audit ok: VERDICT conveyed on its own line" "$cli_aud" "VERDICT: CONTINUE"
    of_a="$(printf '%s\n' "$cli_aud" | sed -n 's/^OUTFILE: //p' | head -1)"
    if [ -n "$of_a" ] && _cp_node_exists "$of_a"; then
        fc_a="$(_cp_node_read "$of_a")"
        assert_contains "cp CLI audit ok: OUTFILE holds finding detail" "$fc_a" "transcript lacks step evidence"
        assert_not_contains "cp CLI audit ok: OUTFILE excludes verdict line" "$fc_a" "verdict"
    else
        fail "cp CLI audit ok: OUTFILE path missing/unreadable (RED until module exists)"
    fi
}

_cp_run
