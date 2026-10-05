#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/secret-shape-scanner-parity-cases.sh
# Tests: hooks/workflow-state/complexity-routing/secret-shape.js, bin/scan-outbound.sh
# Tags: complexity, routing, secret-shape, redaction, scanner-parity, ssot, fail-closed, table-driven, security, scope:issue-specific
# Sourced after secret-shape-midword-key-cases.sh; reuses SS_MOD_N, run_node, assert_block and
# TMPDIR_BASE. Why: HARD_SECRET_PATTERNS in bin/scan-outbound.sh is the single source of truth
# for the outbound scanner AND for secret-shape.js, so the two must agree on every input: what
# the scanner flags is exactly what isSecretShaped detects and what redactSecretShaped removes.
# Each side alone is pinned elsewhere (main-hard-secret-scan.sh, SS-2); only this file runs both
# on the same bytes, so a drift between the parser and the bash loop shows up here.

SSP_DIR="$TMPDIR_BASE/ss-parity"
SSP_CFG="$SSP_DIR/cfg"
mkdir -p "$SSP_CFG"
# Empty allow/blocklists: the scanner then judges the hard-secret patterns alone.
: > "$SSP_CFG/.private-info-allowlist"
: > "$SSP_CFG/.private-info-blocklist"
SSP_SAMPLES="$SSP_DIR/samples.txt"
SSP_NEAR="$SSP_DIR/near-miss.txt"
export SSP_SAMPLES_N SSP_NEAR_N SSP_SCAN_N
SSP_SAMPLES_N="$(to_node_path "$SSP_SAMPLES")"
SSP_NEAR_N="$(to_node_path "$SSP_NEAR")"
SSP_SCAN_N="$(to_node_path "$SSP_DIR/scan-out.txt")"

# One row per sample: [name, text, flagged]. Fixtures are built at runtime so no literal key
# shape ever sits in this file. Every label has a positive row and its near-miss (flagged 0).
SSP_ROWS_JS='
const A = (n) => "A".repeat(n);
const SK = "s" + "k-";
const ANT = SK + "ant-api03-" + A(20);
const ROWS = [
  ["anthropic", ANT, 1], ["anthropic-sid", SK + "ant-sid01-" + A(20), 1],
  ["openai", SK + "proj-" + A(20), 1], ["openai-19", SK + A(19), 0],
  ["anthropic-then-openai", ANT + " and " + SK + A(20), 1], ["openai-then-anthropic", SK + A(20) + " and " + ANT, 1],
  ["prose-glued-sk", "tas" + "k-complexity-signals-file-name", 1],
  ["aws", "AKIA" + A(16), 1], ["aws-15", "AKIA" + A(15), 0],
  ["private-key", "-----BEGIN " + "RSA PRIVATE KEY-----", 1], ["public-key", "-----BEGIN " + "PUBLIC KEY-----", 0],
  ["github", "gh" + "p_" + A(36), 1], ["github-35", "gh" + "p_" + A(35), 0],
  ["slack", "xo" + "xb-1-2-abcDEF", 1], ["slack-2-segments", "xo" + "xb-123-abcDEF", 0],
  ["google", "AI" + "za" + A(35), 1], ["google-34", "AI" + "za" + A(34), 0],
  ["huggingface", "hf" + "_" + A(34), 1], ["huggingface-33", "hf" + "_" + A(33), 0],
  ["groq", "gs" + "k_" + A(20), 1], ["groq-19", "gs" + "k_" + A(19), 0],
  ["replicate", "r8" + "_" + A(37), 1], ["replicate-36", "r8" + "_" + A(36), 0],
  ["cohere", "co" + "_" + A(40), 1], ["cohere-39", "co" + "_" + A(39), 0],
  ["clean", "plain prose with no key", 0],
];
'

# ssp_scan <scanner> <file>: run one scan with the empty lists; stdout to scan-out.txt, rc echoed.
ssp_scan() {
    local rc=0
    AGENTS_CONFIG_DIR="$(to_node_path "$SSP_CFG")" run_with_timeout bash "$1" "$2" \
        > "$SSP_DIR/scan-out.txt" 2> "$SSP_DIR/scan-err.txt" || rc=$?
    echo "$rc"
}

# SS-15: per sample, the scanner's [label]@offset+length entries (its exact stdout, parsed),
# isSecretShaped, and redactSecretShaped. Anthropic before OpenAI: an sk-ant key is reported
# once, as [anthropic-key], never again as [openai-key], in either order on the line.
d2099ss_scanner_parity_table() {
    local got rc_all rc_near
    run_node "$SSP_ROWS_JS"'
const fs = require("fs");
fs.writeFileSync(process.env.SSP_SAMPLES_N, ROWS.map((r) => r[1]).join("\n") + "\n");
fs.writeFileSync(process.env.SSP_NEAR_N, ROWS.filter((r) => !r[2]).map((r) => r[1]).join("\n") + "\n");
' > /dev/null
    rc_near="$(ssp_scan "$AGENTS_DIR/bin/scan-outbound.sh" "$SSP_NEAR")"
    rc_near="$rc_near:$(wc -c < "$SSP_DIR/scan-out.txt" | tr -d ' ')"
    rc_all="$(ssp_scan "$AGENTS_DIR/bin/scan-outbound.sh" "$SSP_SAMPLES")"
    got=$(run_node "$SSP_ROWS_JS"'
const fs = require("fs");
const { isSecretShaped, redactSecretShaped } = require(process.env.SS_MOD_N);
const byLine = new Map();
for (const l of fs.readFileSync(process.env.SSP_SCAN_N, "utf8").split("\n").filter(Boolean)) {
  const m = /^(.*):(\d+): \[([a-z-]+)\] (.*)$/.exec(l);
  if (/^Found \d+ hard violation\(s\), 0 warning\(s\)$/.test(l)) { console.log("summary " + l); continue; }
  if (!m) { console.log("UNPARSED " + JSON.stringify(l)); continue; }
  const n = Number(m[2]);
  const sample = ROWS[n - 1][1];
  const at = sample.indexOf(m[4]);
  byLine.set(n, (byLine.get(n) || []).concat(m[3] + "@" + (at < 0 ? "?" : at) + "+" + m[4].length));
}
ROWS.forEach(([name, text], i) => {
  const red = redactSecretShaped(text);
  console.log([name, (byLine.get(i + 1) || ["-"]).join(","), isSecretShaped(text), red === text ? "unchanged" : JSON.stringify(red)].join("|"));
});
')
    assert_eq "SS-15 scanner exit: 1 on the samples, 0 with no stdout on the near-misses alone" "1|0:0" "$rc_all|$rc_near"
    assert_block "SS-15 the scanner, isSecretShaped and redactSecretShaped agree on every hard-secret label" "$got" <<'EOF'
summary Found 17 hard violation(s), 0 warning(s)
anthropic|anthropic-key@0+33|true|"[REDACTED]"
anthropic-sid|anthropic-key@0+33|true|"[REDACTED]"
openai|openai-key@0+28|true|"[REDACTED]"
openai-19|-|false|unchanged
anthropic-then-openai|anthropic-key@0+33,openai-key@38+23|true|"[REDACTED] and [REDACTED]"
openai-then-anthropic|anthropic-key@28+33,openai-key@0+23|true|"[REDACTED] and [REDACTED]"
prose-glued-sk|openai-key@2+31|true|"ta[REDACTED]"
aws|aws-key@0+20|true|"[REDACTED]"
aws-15|-|false|unchanged
private-key|private-key@0+31|true|"[REDACTED]"
public-key|-|false|unchanged
github|github-token@0+40|true|"[REDACTED]"
github-35|-|false|unchanged
slack|slack-token@0+15|true|"[REDACTED]"
slack-2-segments|-|false|unchanged
google|google-key@0+39|true|"[REDACTED]"
google-34|-|false|unchanged
huggingface|huggingface-token@0+37|true|"[REDACTED]"
huggingface-33|-|false|unchanged
groq|groq-key@0+24|true|"[REDACTED]"
groq-19|-|false|unchanged
replicate|replicate-token@0+40|true|"[REDACTED]"
replicate-36|-|false|unchanged
cohere|cohere-key@0+43|true|"[REDACTED]"
cohere-39|-|false|unchanged
clean|-|false|unchanged
EOF
}

# ssp_variant <name> <mode>: a copied tree (bin/scan-outbound.sh + the secret-shape.js beside it
# at its real relative path) whose pattern block is mutated. The real scanner is never touched.
# mode: intact | empty (entries dropped) | malformed (first entry has no group/ERE) |
#       markers (BEGIN/END lines dropped) | missing (no scanner file at all).
ssp_variant() {
    local root="$SSP_DIR/variant-$1" mod="$SSP_DIR/variant-$1/hooks/workflow-state/complexity-routing"
    mkdir -p "$root/bin" "$mod"
    cp "$AGENTS_DIR/hooks/workflow-state/complexity-routing/secret-shape.js" "$mod/secret-shape.js"
    [[ "$2" == missing ]] && return 0
    awk -v mode="$2" '
        { sub(/\r$/, "") }
        /^# BEGIN hard-secret-patterns$/ { inb = 1; if (mode == "markers") next; print; next }
        /^# END hard-secret-patterns$/ { inb = 0; if (mode == "markers") next }
        inb && $0 ~ /^[[:space:]]*\047/ {
            if (mode == "empty") next
            if (mode == "malformed" && !done) { print "    \047badentry\047"; done = 1; next }
        }
        { print }
    ' "$AGENTS_DIR/bin/scan-outbound.sh" > "$root/bin/scan-outbound.sh"
}

# SS-16: fail closed on both sides. A scanner whose pattern block is empty or malformed exits 4
# with nothing on stdout (never 0, never a partial scan); secret-shape.js over the same copy
# throws from both exports rather than reporting "nothing secret".
d2099ss_pattern_load_fails_closed() {
    local got="" v mode rc out js
    for v in intact empty malformed markers missing; do
        mode="$v"
        ssp_variant "$v" "$mode"
        if [[ -f "$SSP_DIR/variant-$v/bin/scan-outbound.sh" ]]; then
            rc="$(ssp_scan "$SSP_DIR/variant-$v/bin/scan-outbound.sh" "$SSP_SAMPLES")"
            out="$(grep -c '\[' "$SSP_DIR/scan-out.txt" || true)"
        else
            rc="n/a"; out="n/a"
        fi
        js=$(SSP_VMOD_N="$(to_node_path "$SSP_DIR/variant-$v/hooks/workflow-state/complexity-routing/secret-shape.js")" run_node '
const m = require(process.env.SSP_VMOD_N);
const t = (f) => { try { return JSON.stringify(f()); } catch (e) { return "throw"; } };
const SK = "s" + "k-";
console.log([t(() => m.isSecretShaped(SK + "A".repeat(24))), t(() => m.redactSecretShaped("x " + SK + "A".repeat(24)))].join(","));
')
        got="${got}${v} scanner-rc=${rc} flagged-lines=${out} js=${js}"$'\n'
    done
    assert_block "SS-16 an empty or malformed pattern block fails closed in the scanner (exit 4) and in secret-shape.js (throw)" "${got%$'\n'}" <<'EOF'
intact scanner-rc=1 flagged-lines=17 js=true,"x [REDACTED]"
empty scanner-rc=4 flagged-lines=0 js=throw,throw
malformed scanner-rc=4 flagged-lines=0 js=throw,throw
markers scanner-rc=1 flagged-lines=17 js=throw,throw
missing scanner-rc=n/a flagged-lines=n/a js=throw,throw
EOF
}

d2099ss_scanner_parity_table
d2099ss_pattern_load_fails_closed
