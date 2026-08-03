#!/usr/bin/env bash
# tests/lib/examiner-stub.sh — shared builder for the fake `codex` examiner PATH stub.
#
# WHY THIS EXISTS
# bin/request-off-clearance authenticates the examiner's verdict with a per-invocation
# nonce: it mints 128 bits of randomness, embeds it in the prompt it sends on the
# examiner's stdin, and passes it out-of-band to the parser via CODEX_NONCE. The parser
# keeps ONLY objects whose "nonce" equals the expected value, and takes the LAST such
# object. Objects without the nonce (or with a wrong one) are discarded; if no object
# authenticates, the parser exits 2 and the request is REJECTed.
#
# A stub that just echoes {"verdict":"ALLOW",...} therefore never authenticates, and
# every downstream assertion in a suite that drives a real mint becomes vacuous. Each
# stub must READ ITS PROMPT and echo back the nonce it was handed.
#
# This helper does NOT weaken the source contract: it never invents a nonce. If the
# prompt carries none (i.e. bin/request-off-clearance regressed and stopped minting
# one), the stub emits an empty nonce, the parser discards it, and the suite fails —
# which is exactly the signal a nonce regression should produce.
#
# Sourced by: tests/feat-1608-off-clearance-mint.sh,
#             tests/fix-1626-claim-consume/{cases-claim,cases-recovery}.sh,
#             tests/fix-1780-round4-mint-schema.sh,
#             tests/fix-1780-round10-verdict-nonce.sh

# examiner_nonce_preamble — shell lines (for injection into a stub) that consume the
# prompt on stdin and leave the invocation nonce in $_n. Prefers the labelled
# "nonce":"<hex>" spelling from the prompt's output template, then falls back to the
# first bare 32-hex run.
examiner_nonce_preamble() {
    cat <<'PREAMBLE'
_prompt="$(cat)"
_n="$(printf '%s' "$_prompt" | grep -oE '"nonce":"[0-9a-f]{32}"' | head -1 | grep -oE '[0-9a-f]{32}')"
[ -n "$_n" ] || _n="$(printf '%s' "$_prompt" | grep -oE '[0-9a-f]{32}' | head -1)"
PREAMBLE
}

# examiner_verdict_line <ALLOW|REJECT> <reason> [nonce-expr] [redirect]
# Prints ONE shell line that emits a verdict object when the stub runs.
#   nonce-expr  '$_n' for an authentic object; a literal hex for a forged one;
#               omitted/empty for an object carrying NO nonce field at all.
#   redirect    e.g. '>&2' to put the object on stderr.
examiner_verdict_line() {
    local verdict="$1" reason="$2" nonce="${3-}" redirect="${4-}"
    local body="\\\"verdict\\\":\\\"$verdict\\\",\\\"reason\\\":\\\"$reason\\\""
    [ -n "$nonce" ] && body="$body,\\\"nonce\\\":\\\"$nonce\\\""
    printf 'echo "{%s}" %s\n' "$body" "$redirect"
}

# examiner_stub_body <line>... — prints a complete stub script: shebang, nonce
# preamble, the given lines, `exit 0`.
examiner_stub_body() {
    echo '#!/usr/bin/env bash'
    examiner_nonce_preamble
    local line
    for line in "$@"; do printf '%s\n' "$line"; done
    echo 'exit 0'
}

# write_examiner_stub <dest> <ALLOW|REJECT> <reason>
# The common case: one authentic verdict object, exit 0.
write_examiner_stub() {
    local dest="$1" verdict="$2" reason="$3"
    examiner_stub_body "$(examiner_verdict_line "$verdict" "$reason" '$_n')" > "$dest"
    chmod +x "$dest"
}
