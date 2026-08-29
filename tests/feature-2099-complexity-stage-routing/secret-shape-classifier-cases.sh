#!/bin/bash
# tests/feature-2099-complexity-stage-routing/secret-shape-classifier-cases.sh
# Tests: hooks/workflow-state/complexity-routing/secret-shape.js, hooks/workflow-state/complexity-routing.js, bin/scan-outbound.sh
# Tags: complexity, routing, secret-shape, classifier, table-driven, security, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.
# Why: isSecretShaped is the filter that decides whether a judge-authored token is
# echoed back into the persisted signal list (canonicalizeSignalsForPersistence).
# The sibling suites only observe it through that consumer, where a pattern that
# stopped matching is invisible unless the exact provider shape is exercised.
# Every row below is the classifier's OWN verdict on one token.

SS_MOD_N="$(to_node_path "$AGENTS_DIR/hooks/workflow-state/complexity-routing/secret-shape.js")"
export SS_MOD_N

# SS-1: the module surface. Without this a renamed export would make every row
# below report the same "false" and the table would look green-by-absence.
d2099ss_export_surface() {
    local got
    got=$(run_node '
const m = require(process.env.SS_MOD_N);
const keys = Object.keys(m).sort().join(",");
console.log(keys + " " + typeof m.isSecretShaped);
')
    assert_eq "SS-1 secret-shape.js exports isSecretShaped and nothing else" \
        "isSecretShaped function" "$got"
}

# SS-2: the provider table. One row per shape the module actually implements,
# read off SECRET_SHAPE_PATTERNS, plus the near-miss that shares its prefix.
# Token bodies are BUILT from repeat() so a length boundary is exact rather than
# eyeballed, and the expectation column is the assert_block table below.
d2099ss_provider_table() {
    local got
    got=$(run_node '
const { isSecretShaped } = require(process.env.SS_MOD_N);
const A = (n) => "A".repeat(n);
const a = (n) => "a".repeat(n);
const CASES = [
  // --- Anthropic: sk-ant-(api|sid)NN- + 20 or more --------------------------
  ["anthropic-api", "sk-ant-api03-" + A(20)],
  ["anthropic-sid", "sk-ant-sid01-" + A(20)],
  // --- OpenAI: sk- optionally proj-/svcacct- + 20 or more -------------------
  ["openai-plain", "sk-" + A(20)],
  ["openai-proj", "sk-proj-" + A(20)],
  ["openai-svcacct", "sk-svcacct-" + A(20)],
  ["openai-boundary-20", "sk-" + A(20)],
  ["openai-boundary-19", "sk-" + A(19)],
  // --- AWS access key id: AKIA + exactly 16 uppercase/digit -----------------
  ["aws-boundary-16", "AKIA" + A(16)],
  ["aws-boundary-17", "AKIA" + A(17)],
  ["aws-boundary-15", "AKIA" + A(15)],
  ["aws-lowercase-body", "AKIA" + a(16)],
  ["aws-lowercase-prefix", "akia" + A(16)],
  // --- PEM private-key headers ---------------------------------------------
  ["pem-plain", "-----BEGIN PRIVATE KEY-----"],
  ["pem-rsa", "-----BEGIN RSA PRIVATE KEY-----"],
  ["pem-ec", "-----BEGIN EC PRIVATE KEY-----"],
  ["pem-openssh", "-----BEGIN OPENSSH PRIVATE KEY-----"],
  ["pem-dsa", "-----BEGIN DSA PRIVATE KEY-----"],
  ["pem-public", "-----BEGIN PUBLIC KEY-----"],
  ["pem-unknown-algo", "-----BEGIN FOO PRIVATE KEY-----"],
  ["pem-lowercase", "-----begin private key-----"],
  ["pem-end-marker", "-----END PRIVATE KEY-----"],
  // --- GitHub: gh[pousr]_ + 36 or more alphanumerics ------------------------
  ["github-ghp", "ghp_" + A(36)],
  ["github-gho", "gho_" + A(36)],
  ["github-ghu", "ghu_" + A(36)],
  ["github-ghs", "ghs_" + A(36)],
  ["github-ghr", "ghr_" + A(36)],
  ["github-boundary-35", "ghp_" + A(35)],
  ["github-wrong-letter", "ghx_" + A(40)],
  ["github-nonalnum-body", "ghp_" + "-".repeat(40)],
  ["github-hyphen-separator", "ghp-" + A(36)],
  // --- Slack: xox[baprs]-digits-digits-alnum --------------------------------
  ["slack-xoxb", "xoxb-1-2-abcDEF"],
  ["slack-xoxp", "xoxp-123456-789012-aB0"],
  ["slack-xoxa", "xoxa-1-2-Z9"],
  ["slack-xoxr", "xoxr-1-2-Z9"],
  ["slack-xoxs", "xoxs-1-2-Z9"],
  ["slack-wrong-letter", "xoxz-1-2-abcDEF"],
  ["slack-missing-segment", "xoxb-123-abcDEF"],
  ["slack-empty-tail", "xoxb-123-456-"],
  ["slack-uppercase-prefix", "XOXB-1-2-abcDEF"],
  // --- Google API key: AIza + exactly 35 of [0-9A-Za-z_-] -------------------
  ["google-boundary-35", "AIza" + A(35)],
  ["google-boundary-34", "AIza" + A(34)],
  ["google-lowercase", "aiza" + A(35)],
  ["google-underscore-body", "AIza" + "_".repeat(35)],
  // --- HuggingFace: hf_ + 34 or more alphanumerics --------------------------
  ["hf-boundary-34", "hf_" + A(34)],
  ["hf-boundary-33", "hf_" + A(33)],
  ["hf-uppercase-prefix", "HF_" + A(40)],
  ["hf-hyphen-body", "hf_" + "-".repeat(40)],
];
for (const c of CASES) { console.log(c[0] + " " + String(isSecretShaped(c[1]))); }
')
    assert_block "SS-2 every implemented provider shape classifies, and its near-miss does not" "$got" <<'EOF'
anthropic-api true
anthropic-sid true
openai-plain true
openai-proj true
openai-svcacct true
openai-boundary-20 true
openai-boundary-19 false
aws-boundary-16 true
aws-boundary-17 true
aws-boundary-15 false
aws-lowercase-body false
aws-lowercase-prefix false
pem-plain true
pem-rsa true
pem-ec true
pem-openssh true
pem-dsa true
pem-public false
pem-unknown-algo false
pem-lowercase false
pem-end-marker false
github-ghp true
github-gho true
github-ghu true
github-ghs true
github-ghr true
github-boundary-35 false
github-wrong-letter false
github-nonalnum-body false
github-hyphen-separator false
slack-xoxb true
slack-xoxp true
slack-xoxa true
slack-xoxr true
slack-xoxs true
slack-wrong-letter false
slack-missing-segment false
slack-empty-tail false
slack-uppercase-prefix false
google-boundary-35 true
google-boundary-34 false
google-lowercase false
google-underscore-body true
hf-boundary-34 true
hf-boundary-33 false
hf-uppercase-prefix false
hf-hyphen-body false
EOF
}

# SS-3: the patterns are UNANCHORED (mirroring bin/scan-outbound.sh's line
# scanner, which reads whole lines). A judge token is not a whole line, so where
# the secret sits inside the token decides nothing: prefix, suffix and embedded
# forms must all classify. The last row is the deliberate consequence of that
# looseness — "sk-" occurs inside ordinary words, so an over-detection is
# possible. The fail-safe direction is over-detection: a dropped token only
# costs a routing signal, while a kept one persists a credential (#2099
# Finding A / LI-3), so this is pinned as intended behaviour, not a defect.
d2099ss_position_independence() {
    local got
    got=$(run_node '
const { isSecretShaped } = require(process.env.SS_MOD_N);
const A = (n) => "A".repeat(n);
const AKIA = "AKIA" + A(16);
const GHP = "ghp_" + A(36);
const CASES = [
  ["bare", AKIA],
  ["suffix-appended", AKIA + "-tail"],
  ["prefix-prepended", "head-" + AKIA],
  ["embedded-middle", "before " + AKIA + " after"],
  ["embedded-in-csv", "S1-multi-file," + GHP],
  ["embedded-in-prose", "the key is " + GHP + " please rotate it"],
  ["newline-wrapped", "line1\n" + AKIA + "\nline3"],
  ["substring-sk-inside-word", "task-" + A(20)],
];
for (const c of CASES) { console.log(c[0] + " " + String(isSecretShaped(c[1]))); }
')
    assert_block "SS-3 an unanchored match fires wherever the shape sits in the token" "$got" <<'EOF'
bare true
suffix-appended true
prefix-prepended true
embedded-middle true
embedded-in-csv true
embedded-in-prose true
newline-wrapped true
substring-sk-inside-word true
EOF
}

# SS-4: the classifier's OTHER verdict on sanctioned input (test-design.md
# "Classifier / guard cases"). Every real signal id, the reserved undecidable
# token and the ordinary non-secret inputs must come back false, or the filter
# would silently strip the very tokens the routing table needs. The signal ids
# are read from the module's SSOT, never re-listed here.
d2099ss_sanctioned_input_is_not_secret() {
    local got
    got=$(run_node '
const { isSecretShaped } = require(process.env.SS_MOD_N);
const cr = require(process.env.CR_MOD_N);
const ids = cr.SIGNAL_IDS.concat([cr.UNDECIDABLE_SIGNAL]);
const flagged = ids.filter(isSecretShaped);
console.log("signal_ids=" + ids.length + " flagged=" + (flagged.length ? flagged.join(",") : "0"));
')
    assert_eq "SS-4 no real signal id (nor the undecidable token) is classified secret-shaped" \
        "signal_ids=8 flagged=0" "$got"

    got=$(run_node '
const { isSecretShaped } = require(process.env.SS_MOD_N);
const CASES = [
  ["empty-string", ""],
  ["single-char", "x"],
  ["whitespace", "   "],
  ["plain-word", "architecture"],
  ["hyphenated-prose", "a-multi-file-change-across-the-repo"],
  ["long-alnum-no-prefix", "A".repeat(200)],
  ["path-like", "/home/user/.claude/settings.json"],
  ["url-like", "https://example.com/v1/models"],
  ["null", null],
  ["undefined", undefined],
  ["number", 1234567890],
  ["empty-object", {}],
];
for (const c of CASES) {
  let v;
  try { v = String(isSecretShaped(c[1])); } catch (e) { v = "THREW:" + (e && e.name); }
  console.log(c[0] + " " + v);
}
')
    assert_block "SS-5 benign and non-string inputs are neither classified nor thrown on" "$got" <<'EOF'
empty-string false
single-char false
whitespace false
plain-word false
hyphenated-prose false
long-alnum-no-prefix false
path-like false
url-like false
null false
undefined false
number false
empty-object false
EOF
}

# SS-6: the classifier's one consumer. A verdict that never changed what gets
# persisted would be an unused function; this pins the wiring in both
# directions — a secret-shaped unrecognized token is DROPPED, a benign
# unrecognized token beside it is KEPT verbatim.
d2099ss_reaches_persistence_filter() {
    local got
    got=$(run_node '
const cr = require(process.env.CR_MOD_N);
const A = (n) => "A".repeat(n);
const out = cr.canonicalizeSignalsForPersistence([
  "benign-unknown-token",
  "AKIA" + A(16),
  "ghp_" + A(36),
  "another-benign-token",
]);
console.log(out.join("|"));
')
    assert_eq "SS-6 canonicalizeSignalsForPersistence drops the secret-shaped tokens and keeps the benign ones" \
        "benign-unknown-token|another-benign-token" "$got"
}

d2099ss_export_surface
d2099ss_provider_table
d2099ss_position_independence
d2099ss_sanctioned_input_is_not_secret
d2099ss_reaches_persistence_filter
