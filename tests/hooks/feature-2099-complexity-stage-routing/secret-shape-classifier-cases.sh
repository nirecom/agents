#!/bin/bash
# tests/hooks/feature-2099-complexity-stage-routing/secret-shape-classifier-cases.sh
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
console.log(keys + " " + [typeof m.isSecretShaped, typeof m.redactSecretShaped, typeof m.REDACTED_PLACEHOLDER].join(" "));
')
    assert_eq "SS-1 secret-shape.js exports isSecretShaped, redactSecretShaped, REDACTED_PLACEHOLDER and nothing else" \
        "REDACTED_PLACEHOLDER,isSecretShaped,redactSecretShaped function function string" "$got"
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

# SS-6: the classifier's one consumer under the #2148 allowlist. isSecretShaped is
# now a defense-in-depth layer, not the deciding filter: persistence is allowlist-
# only, so EVERY unrecognized token — secret-shaped or benign — collapses into the
# single UNRECOGNIZED(N) count rather than being echoed back. Here all four inputs
# are unrecognized (no SIGNAL_IDS member among them), so N=4 and nothing persists
# verbatim; the secret-shaped pair can no longer leak through the benign siblings.
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
    assert_eq "SS-6 allowlist collapses every unrecognized token (secret-shaped or not) to UNRECOGNIZED(N)" \
        "UNRECOGNIZED(4)" "$got"
}

# SS-7..SS-9: redactSecretShaped (#2460) is what scrubs the dispatch prompt and the plan
# artifacts before they leave the machine for Jev. Rows print "<name> <JSON of the output>"
# so a newline is visible, or "<name> unchanged" when the text came back identical. Every
# fixture is built at runtime: the outbound scan matches these shapes unanchored.
SS_REDACT_PRELUDE='
const { redactSecretShaped: red, REDACTED_PLACEHOLDER: PH } = require(process.env.SS_MOD_N);
const A = (n) => "A".repeat(n);
const GHP = "gh" + "p_" + A(36);
const AKIA = "AK" + "IA" + A(16);
const SK = "s" + "k-" + A(20);
const pem = (word, kind) => "-----" + word + " " + kind + "PRIVATE KEY-----";
const show = (CASES) => { for (const c of CASES) {
  let v;
  try { v = red(c[1]); v = v === c[1] ? "unchanged" : JSON.stringify(v); } catch (e) { v = "THREW:" + (e && e.name); }
  console.log(c[0] + " " + v);
} };
'

d2099ss_redact_provider_table() {
    local got
    got=$(run_node "$SS_REDACT_PRELUDE"'
console.log("placeholder " + JSON.stringify(PH));
show([
  ["two-shapes", "x " + GHP + " y " + AKIA + " z"],
  ["same-shape-twice", GHP + " and " + GHP],
  ["anthropic-api", "x s" + "k-ant-api03-" + A(20) + " y"],
  ["anthropic-sid", "x s" + "k-ant-sid01-" + A(20) + " y"],
  ["openai-plain", "x " + SK + " y"],
  ["openai-proj", "x s" + "k-proj-" + A(20) + " y"],
  ["openai-svcacct", "x s" + "k-svcacct-" + A(20) + " y"],
  ["aws", "x " + AKIA + " y"],
  ["github-ghp", "x " + GHP + " y"],
  ["github-ghs", "x gh" + "s_" + A(36) + " y"],
  ["slack", "x xo" + "xb-1-2-abc y"],
  ["google", "x AI" + "za" + A(35) + " y"],
  ["huggingface", "x h" + "f_" + A(34) + " y"],
  ["near-miss-openai-19", "x s" + "k-" + A(19) + " y"],
  ["near-miss-aws-15", "x AK" + "IA" + A(15) + " y"],
  ["near-miss-github-35", "x gh" + "p_" + A(35) + " y"],
  ["near-miss-google-34", "x AI" + "za" + A(34) + " y"],
  ["near-miss-hf-33", "x h" + "f_" + A(33) + " y"],
  ["pem-block", "pre\n" + pem("BEGIN", "RSA ") + "\nMIIB\nAAAA\n" + pem("END", "RSA ") + "\npost"],
  ["pem-block-plain-kind", "pre\n" + pem("BEGIN", "") + "\nMIIB\n" + pem("END", "") + "\npost"],
  ["pem-without-end", "pre\n" + pem("BEGIN", "EC ") + "\nMIIB\nmore"],
  ["pem-two-blocks", pem("BEGIN", "") + "\nK1\n" + pem("END", "") + "\nmid\n" + pem("BEGIN", "DSA ") + "\nK2\n" + pem("END", "DSA ")],
  ["pem-public-untouched", "-----BEGIN PUBLIC KEY-----\nabc\n-----END PUBLIC KEY-----"],
]);
')
    assert_block "SS-7 every provider shape is replaced by the placeholder; a PEM key goes as one block" "$got" <<'EOF'
placeholder "[REDACTED]"
two-shapes "x [REDACTED] y [REDACTED] z"
same-shape-twice "[REDACTED] and [REDACTED]"
anthropic-api "x [REDACTED] y"
anthropic-sid "x [REDACTED] y"
openai-plain "x [REDACTED] y"
openai-proj "x [REDACTED] y"
openai-svcacct "x [REDACTED] y"
aws "x [REDACTED] y"
github-ghp "x [REDACTED] y"
github-ghs "x [REDACTED] y"
slack "x [REDACTED] y"
google "x [REDACTED] y"
huggingface "x [REDACTED] y"
near-miss-openai-19 unchanged
near-miss-aws-15 unchanged
near-miss-github-35 unchanged
near-miss-google-34 unchanged
near-miss-hf-33 unchanged
pem-block "pre\n[REDACTED]\npost"
pem-block-plain-kind "pre\n[REDACTED]\npost"
pem-without-end "pre\n[REDACTED]"
pem-two-blocks "[REDACTED]\nmid\n[REDACTED]"
pem-public-untouched unchanged
EOF
}

# SS-8: redaction equals the scanner: a generic sk- match is redacted wherever it sits,
# so prose such as "task-..." / "risk-..." holding a 20+ sk- run is redacted too (accepted
# over-redaction). SS-10 pins the same for every other shape and every preceding character.
d2099ss_redact_token_start_rule() {
    local got
    got=$(run_node "$SS_REDACT_PRELUDE"'
show([
  ["prose-task", "tas" + "k-complexity-signals-file-name"],
  ["prose-risk", "ris" + "k-assessment-of-the-whole-plan"],
  ["mid-word-sk", "tas" + "k-" + A(20)],
  ["after-space", " " + SK],
  ["after-equals", "KEY=" + SK],
  ["in-quotes", "\"" + SK + "\""],
  ["text-start", SK + " tail"],
  ["after-newline", "a\n" + SK],
  ["after-hyphen", "head-" + AKIA],
]);
')
    assert_block "SS-8 the generic sk- shape is redacted wherever it sits, prose included" "$got" <<'EOF'
prose-task "ta[REDACTED]"
prose-risk "ri[REDACTED]"
mid-word-sk "ta[REDACTED]"
after-space " [REDACTED]"
after-equals "KEY=[REDACTED]"
in-quotes "\"[REDACTED]\""
text-start "[REDACTED] tail"
after-newline "a\n[REDACTED]"
after-hyphen "head-[REDACTED]"
EOF
}

# SS-9: the edges. A non-string never throws and yields "", clean text is returned
# identical, and a second pass (or a repeated call on the same /g patterns) changes nothing.
d2099ss_redact_edges() {
    local got
    got=$(run_node "$SS_REDACT_PRELUDE"'
const cr = require(process.env.CR_MOD_N);
const clean = "Judge the task complexity.\nSignals: " + cr.SIGNAL_IDS.join(",") + " path /home/user/x.json";
const dirty = "a " + GHP + "\nb " + SK + " c";
show([["null", null], ["undefined", undefined], ["number", 42], ["object", {}], ["array", [GHP]], ["empty-string", ""]]);
console.log("clean-identical " + String(red(clean) === clean));
console.log("second-pass-stable " + String(red(red(dirty)) === red(dirty)));
console.log("repeat-call-stable " + [red(dirty), red(dirty), red(dirty)].every((s) => s === "a [REDACTED]\nb [REDACTED] c"));
console.log("placeholder-survives " + JSON.stringify(red(PH + " " + PH)));
')
    assert_block "SS-9 non-strings give an empty string, clean text is untouched, redaction is idempotent" "$got" <<'EOF'
null ""
undefined ""
number ""
object ""
array ""
empty-string unchanged
clean-identical true
second-pass-stable true
repeat-call-stable true
placeholder-survives "[REDACTED] [REDACTED]"
EOF
}

# SS-10: the state sent to Jev is JSON-stringified text, so a key often sits right after
# an escape whose last character is a letter or digit ("\n" as backslash + n, "%3D").
# No shape has a token-start rule any more: every shape, the generic OpenAI one included,
# is redacted whatever precedes it. Below, "\\n" in the fixtures is backslash, n.
d2099ss_redact_after_escape_or_word() {
    local got
    got=$(run_node "$SS_REDACT_PRELUDE"'
const HF = "h" + "f_" + A(34);
const ANT = "s" + "k-ant-api03-" + A(20);
show([
  ["aws-after-json-newline", "a\\n" + AKIA],
  ["github-after-json-tab", "a\\t" + GHP],
  ["github-after-percent", "k%3D" + GHP],
  ["aws-mid-word", "abc" + AKIA],
  ["hf-mid-word", "x9" + HF],
  ["anthropic-mid-word", "x" + ANT],
  ["generic-after-json-newline", "a\\n" + SK],
  ["generic-after-json-cr", "a\\r" + SK],
  ["generic-after-json-tab", "a\\t" + SK],
  ["generic-after-percent-upper", "k%3D" + SK],
  ["generic-after-percent-lower", "k%3d" + SK],
  ["generic-text-start", SK],
  ["generic-after-space", "a " + SK],
  ["generic-mid-word", "ta" + SK],
  ["prose-after-json-newline", "a\\ntas" + "k-complexity-signals-file-name"],
  ["prose-after-percent", "%20tas" + "k-complexity-signals-file-name"],
  ["generic-after-other-escape", "a\\b" + SK],
  ["generic-after-upper-escape", "a\\N" + SK],
  ["generic-after-bare-n", "an" + SK],
  ["generic-after-percent-one-hex", "k%3" + SK],
  ["generic-after-percent-non-hex", "k%G0" + SK],
]);
')
    assert_block "SS-10 every shape is redacted whatever precedes it: escape, %XX, word character" "$got" <<'EOF'
aws-after-json-newline "a\\n[REDACTED]"
github-after-json-tab "a\\t[REDACTED]"
github-after-percent "k%3D[REDACTED]"
aws-mid-word "abc[REDACTED]"
hf-mid-word "x9[REDACTED]"
anthropic-mid-word "x[REDACTED]"
generic-after-json-newline "a\\n[REDACTED]"
generic-after-json-cr "a\\r[REDACTED]"
generic-after-json-tab "a\\t[REDACTED]"
generic-after-percent-upper "k%3D[REDACTED]"
generic-after-percent-lower "k%3d[REDACTED]"
generic-text-start "[REDACTED]"
generic-after-space "a [REDACTED]"
generic-mid-word "ta[REDACTED]"
prose-after-json-newline "a\\nta[REDACTED]"
prose-after-percent "%20ta[REDACTED]"
generic-after-other-escape "a\\b[REDACTED]"
generic-after-upper-escape "a\\N[REDACTED]"
generic-after-bare-n "an[REDACTED]"
generic-after-percent-one-hex "k%3[REDACTED]"
generic-after-percent-non-hex "k%G0[REDACTED]"
EOF
}

# SS-11: a second pass over text redacted after an escape changes nothing, and the
# unanchored classifier still flags the mid-word generic shape.
d2099ss_redact_after_escape_idempotent() {
    local got
    got=$(run_node "$SS_REDACT_PRELUDE"'
const { isSecretShaped } = require(process.env.SS_MOD_N);
const dirty = "a\\n" + SK + " k%3D" + SK + " b\\t" + GHP + " abc" + AKIA;
const once = red(dirty);
console.log("first-pass " + JSON.stringify(once));
console.log("second-pass-identical " + String(red(once) === once));
console.log("classifier-mid-word-generic " + String(isSecretShaped("ta" + SK)));
')
    assert_block "SS-11 re-redacting redacted text is a no-op; isSecretShaped stays unanchored" "$got" <<'EOF'
first-pass "a\\n[REDACTED] k%3D[REDACTED] b\\t[REDACTED] abc[REDACTED]"
second-pass-identical true
classifier-mid-word-generic true
EOF
}

d2099ss_export_surface
d2099ss_provider_table
d2099ss_position_independence
d2099ss_sanctioned_input_is_not_secret
d2099ss_reaches_persistence_filter
d2099ss_redact_provider_table
d2099ss_redact_token_start_rule
d2099ss_redact_edges
d2099ss_redact_after_escape_or_word
d2099ss_redact_after_escape_idempotent
