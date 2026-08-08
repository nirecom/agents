#!/usr/bin/env bash
# tests/fix-1273-output-sanitize-secret-gaps.sh
# Tests: hooks/lib/output-sanitize.js
# Tags: security, redaction, secrets, hooks, lib, TL1, scope:common
#
# WHY (CPR-WPH): redactSecrets() exists because hooks/workflow-run-tests.js now
# copies the DEMOTING COMMAND into the workflow-state file as `trigger_command`,
# and bin/worker-dispatch/* renders untrusted worker output back into a Claude
# Code transcript. Both destinations are durable and both outlive the session,
# so a credential that survives the copy is a credential written to disk in
# plain text. The module's own header states the intended failure direction: "a
# false positive costs a few characters of diagnostics and a false negative
# costs a leak."
#
# A security review of the landed module found the current shape coverage misses
# credential forms that appear in ordinary, everyday commands. This file is the
# RED-FIRST regression set: each case asserts the secret is ABSENT from the
# redacted output, so today's leak reports FAIL and the fix turns it green.
#
# Three independent gaps are separated here (CPR-SC), because each needs a
# different repair and conflating them hides whichever is fixed last:
#   S1  SPACE-SEPARATED option values — SECRET_ASSIGN_RE requires `[=:]`, so
#       `--token=X` is redacted but `--token X` is not, although both are the
#       same option carrying the same secret.
#   S2  `Authorization: Bearer <token>` — the key alternation matches "auth"
#       inside "Authorization" and the value capture then takes the next `\S+`,
#       which is the literal word "Bearer". The scheme name is redacted and the
#       actual token is left standing — worse than a plain miss, because the
#       output LOOKS redacted.
#   S3  Shapes absent from SECRET_VALUE_PATTERNS entirely — a PEM private key
#       block, a Google API key / service-account key id, and the modern
#       `github_pat_` fine-grained token (the existing rule only covers the
#       short-form `gh[pousr]_`).
#
# Both directions are pinned (test-design classifier rule / CPR-ORTH): every
# gap group is followed by CONTROL rows asserting the already-covered shapes
# stay redacted and that ordinary non-secret text is left intact. A fix that
# redacts everything would otherwise pass every red row above.
#
# TL2 gap (what this TL1 test does NOT catch):
#   - Whether the two real consumers actually route their text through
#     redactSecrets before persisting it (workflow-run-tests.js sanitizeTrigger,
#     bin/worker-dispatch/emit.js). tests/main-workflow-run-tests/*.sh and
#     tests/feature-1643-worker-dispatch-sentinel-stdout.sh are that tier.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
SANITIZE_JS="$(nodepath "$AGENTS_DIR")/hooks/lib/output-sanitize.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

# The module is the subject; its absence is a FAIL, never a skip.
if [ ! -f "$AGENTS_DIR/hooks/lib/output-sanitize.js" ]; then
    fail "0/module-present" "missing: hooks/lib/output-sanitize.js"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

# redact <input> → redacted output (or the literal ERR on a module fault)
redact() {
    run_with_timeout 30 node -e '
try {
  const m = require(process.argv[1]);
  if (typeof m.redactSecrets !== "function") { process.stdout.write("ERR"); process.exit(0); }
  process.stdout.write(m.redactSecrets(process.argv[2]));
} catch (e) { process.stdout.write("ERR"); }
' "$SANITIZE_JS" "$1" 2>/dev/null
}

# assert_absent <name> <secret-substring> <input>
# The redacted output must not contain the secret anywhere.
assert_absent() {
    local name="$1" needle="$2" input="$3" out
    out="$(redact "$input")"
    if [ "$out" = "ERR" ]; then fail "$name" "module fault"; return; fi
    if printf '%s' "$out" | grep -qF -- "$needle"; then
        fail "$name" "secret survived redaction: $out"
    else
        pass "$name"
    fi
}

# assert_present <name> <substring> <input>
# Attribution must survive: the redacted line still has to say WHICH option or
# field was elided, and ordinary text must not be eaten.
assert_present() {
    local name="$1" needle="$2" input="$3" out
    out="$(redact "$input")"
    if [ "$out" = "ERR" ]; then fail "$name" "module fault"; return; fi
    if printf '%s' "$out" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name" "expected substring missing: want=$needle got=$out"
    fi
}

# ===========================================================================
# S1 — space-separated CLI option values
#
# `--token=X` and `--token X` are the same option carrying the same secret;
# only the shell's quoting convention differs. SECRET_ASSIGN_RE's mandatory
# `[=:]` separator makes the space form invisible, and the space form is the
# one people actually type.
# ===========================================================================
assert_absent "S1/space-token" "SPACESEP0secret1value2" \
    'gh api --token SPACESEP0secret1value2 /repos/x'
assert_absent "S1/space-api-key" "SPACEAPIKEY0123456789" \
    'mytool --api-key SPACEAPIKEY0123456789 run'
assert_absent "S1/space-api-key-dashless" "SPACEAPIKEY0123456789" \
    'mytool --apikey SPACEAPIKEY0123456789 run'
assert_absent "S1/space-password" "SPACEPASSWORD0123456789" \
    'psql --password SPACEPASSWORD0123456789 -h db'
assert_absent "S1/space-secret-single-dash" "SPACESECRET0123456789" \
    'tool -secret SPACESECRET0123456789'
assert_absent "S1/space-auth-token-quoted" "SPACEQUOTED0123456789" \
    'curl --auth-token "SPACEQUOTED0123456789" https://example.com'
# Boundary: the option is the LAST token, so there is no value to consume. The
# redactor must not crash or swallow the option name itself.
assert_present "S1/boundary-trailing-option-name-kept" "--token" \
    'mytool --token'
# Boundary: the next token is another option, not a value — `--token --verbose`
# has no secret in it, and eating `--verbose` would destroy attribution.
assert_present "S1/boundary-next-token-is-option" "--verbose" \
    'mytool --token --verbose'

# CONTROL (already covered — must stay redacted):
assert_absent "S1/control-equals-form-still-redacted" "KEEPWORKING01234567890" \
    'mytool --token=KEEPWORKING01234567890'
assert_absent "S1/control-env-assignment-still-redacted" "ENVASSIGN01234567890" \
    'API_KEY=ENVASSIGN01234567890 mytool run'
assert_present "S1/control-attribution-kept" "--token" \
    'mytool --token=KEEPWORKING01234567890'
# CONTROL (non-secret text must survive intact — over-redaction is its own bug):
assert_present "S1/control-benign-option-untouched" "--verbose" \
    'bash tests/run-all.sh --verbose --jobs 4'
assert_present "S1/control-benign-value-untouched" "tests/run-all.sh" \
    'bash tests/run-all.sh --verbose --jobs 4'

# ===========================================================================
# S2 — `Authorization: Bearer <token>`
#
# This is the most common credential shape there is, and today it produces
# `Authorization: <redacted> <the-real-token>`: the value capture stops at the
# first `\S+` after the separator, which is the scheme word "Bearer", never the
# token behind it. The output reads as redacted while carrying the secret, so
# the failure is silent to a human reviewing the state file.
# ===========================================================================
assert_absent "S2/bearer-token-value" "AUTHTOKENVALUE0123456789" \
    'curl -H "Authorization: Bearer AUTHTOKENVALUE0123456789" https://example.com'
assert_absent "S2/bearer-token-unquoted" "AUTHTOKENVALUE0123456789" \
    'Authorization: Bearer AUTHTOKENVALUE0123456789'
assert_absent "S2/basic-scheme-value" "BASICB64VALUE0123456789" \
    'curl -H "Authorization: Basic BASICB64VALUE0123456789" https://example.com'
assert_absent "S2/proxy-authorization-bearer" "PROXYTOKENVALUE0123456789" \
    'Proxy-Authorization: Bearer PROXYTOKENVALUE0123456789'
# CONTROL: `X-Api-Key: <token>` is ALREADY redacted today, and the contrast is
# what isolates the defect: the name matches the same alternation, the separator
# is the same `:`, and the value capture lands on the token because no scheme
# word sits between them. So the bug is not "headers are unhandled" — it is
# specifically the scheme word consuming the value slot.
assert_absent "S2/control-x-api-key-header-already-redacted" "HEADERAPIKEY0123456789" \
    'curl -H "X-Api-Key: HEADERAPIKEY0123456789" https://example.com'
# CONTROL: attribution — the header name must still be readable afterwards.
assert_present "S2/control-header-name-kept" "Authorization" \
    'curl -H "Authorization: Bearer AUTHTOKENVALUE0123456789" https://example.com'
# CONTROL: a header with no credential in it must survive untouched.
assert_present "S2/control-benign-header-untouched" "application/json" \
    'curl -H "Content-Type: application/json" https://example.com'

# ===========================================================================
# S3 — shapes absent from SECRET_VALUE_PATTERNS
#
# SECRET_VALUE_PATTERNS covers Anthropic / OpenAI / AWS / short-form GitHub /
# Slack. The three below are equally high-signal, equally unambiguous, and
# equally likely to land in a command line or a worker log tail.
# ===========================================================================

# (a) PEM private key block. Multi-line by nature; the body is the secret. Note
#     the two consumers differ in whether newlines survive — workflow-run-tests
#     collapses control bytes BEFORE redacting, so both the multi-line and the
#     collapsed single-line spelling must be covered.
PEM_BODY='MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQPEMSECRETBODY64'
PEM_MULTILINE="-----BEGIN PRIVATE KEY-----
${PEM_BODY}
-----END PRIVATE KEY-----"
PEM_COLLAPSED="-----BEGIN PRIVATE KEY----- ${PEM_BODY} -----END PRIVATE KEY-----"
RSA_BODY='MIIEpAIBAAKCAQEArsaSECRETBODY64MIIEpAIBAAKCAQEArsaSECRETBODY64'
RSA_MULTILINE="-----BEGIN RSA PRIVATE KEY-----
${RSA_BODY}
-----END RSA PRIVATE KEY-----"

assert_absent "S3/pem-private-key-multiline" "$PEM_BODY" "$PEM_MULTILINE"
assert_absent "S3/pem-private-key-collapsed" "$PEM_BODY" "$PEM_COLLAPSED"
assert_absent "S3/pem-rsa-private-key" "$RSA_BODY" "$RSA_MULTILINE"
assert_absent "S3/pem-inside-json-payload" "$PEM_BODY" \
    "{\"type\":\"service_account\",\"private_key\":\"-----BEGIN PRIVATE KEY----- ${PEM_BODY} -----END PRIVATE KEY-----\"}"

# (b) Google / GCP service-account credential material. The `AIzaSy…` API key is
#     the fixed-prefix form; `private_key_id` is the service-account JSON field
#     whose NAME contains "key" but matches none of the secret-word alternation
#     (token|secret|password|api[_-]?key|apikey|credential|auth).
GCP_API_KEY='AIzaSyA1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q'
assert_absent "S3/gcp-api-key-bare" "$GCP_API_KEY" \
    "curl https://maps.googleapis.com/maps/api/geocode/json?key=${GCP_API_KEY}"
assert_absent "S3/gcp-api-key-in-log-line" "$GCP_API_KEY" \
    "worker log: using ${GCP_API_KEY} for geocoding"
GCP_KEY_ID='9f8e7d6c5b4a39281706fedcba9876543210abcd'
assert_absent "S3/gcp-service-account-private-key-id" "$GCP_KEY_ID" \
    "{\"type\":\"service_account\",\"private_key_id\":\"${GCP_KEY_ID}\"}"

# (c) GitHub fine-grained PAT. Distinct prefix from the covered short form:
#     `gh[pousr]_` cannot match `github_pat_` ("i" is not in the character
#     class), so the modern token shape passes straight through.
GH_PAT='github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGH'
assert_absent "S3/github-fine-grained-pat-bare" "$GH_PAT" \
    "gh auth login --with-token ${GH_PAT}"
assert_absent "S3/github-fine-grained-pat-in-url" "$GH_PAT" \
    "git clone https://${GH_PAT}@github.com/owner/repo.git"
assert_absent "S3/github-fine-grained-pat-in-log-line" "$GH_PAT" \
    "worker log: authenticated with ${GH_PAT}"

# CONTROL (already-covered vendor shapes must stay redacted — a fix that
# rewrites SECRET_VALUE_PATTERNS must not drop an existing rule):
assert_absent "S3/control-github-short-form-token" "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123" \
    'git clone https://ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123@github.com/o/r.git'
assert_absent "S3/control-aws-access-key-id" "AKIAIOSFODNN7EXAMPLE" \
    'aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE'
assert_absent "S3/control-anthropic-key" "sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345" \
    'export ANTHROPIC_API_KEY=sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345'
assert_absent "S3/control-slack-token" "xoxb-1234567890-ABCDEFGHIJKL" \
    'curl -d token=xoxb-1234567890-ABCDEFGHIJKL https://slack.com/api/x'
# CONTROL: a base64-looking blob that is NOT credential material must survive —
# over-redacting ordinary log output destroys the only diagnostic a human gets.
assert_present "S3/control-plain-text-untouched" "RUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3" \
    'RUN_CONTRACT: PASS=2 FAIL=0 SKIP=1 EXECUTED=3'
assert_present "S3/control-commit-sha-untouched" "50b3812" \
    'git show 50b3812 -- tests/run-all.sh'

# ===========================================================================
# Edge cases shared by all three groups (test-design: edge / error categories)
# ===========================================================================
if [ -z "$(redact '')" ]; then
    pass "E/empty-input-is-empty"
else
    fail "E/empty-input-is-empty" "got=$(redact '')"
fi
if [ "$(redact 'plain text with no secrets')" = "plain text with no secrets" ]; then
    pass "E/no-secret-input-unchanged"
else
    fail "E/no-secret-input-unchanged" "got=$(redact 'plain text with no secrets')"
fi
# Idempotency: redacting an already-redacted string must be a no-op, otherwise a
# second pass over durable state text keeps rewriting it.
ONCE="$(redact 'mytool --token=IDEMPOTENT0123456789 run')"
TWICE="$(redact "$ONCE")"
if [ "$ONCE" = "$TWICE" ]; then
    pass "E/idempotent-second-pass"
else
    fail "E/idempotent-second-pass" "once=$ONCE twice=$TWICE"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
