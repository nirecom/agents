# tests/enforce-off-emergency-provenance/cases-p1-invocation.sh
# P1: the marker is written ONLY for a real skill invocation - variants,
# near-misses, and the stdin-buffer-boundary straddle/clear/idempotency cases.
# Sourced by ../enforce-off-emergency-provenance.sh; relies on that file's
# shared helpers (submit_prompt, marker_of, assert_*, MODES_OK, etc.).
# Tests: hooks/record-off-skill-invocation.js, hooks/lib/off-emergency-provenance.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js, hooks/lib/protected-basenames.js, hooks/block-clearance-token-write.js, settings.json
# Tags: off-clearance, emergency-off, provenance, audit, userpromptsubmit, session-marker, security, scope:common, pwsh-not-required, TL2, hook-registration

run_P1_invocation() {
sid=pv1sid
submit_prompt "$sid" "/enforce-workflow-off PRIVATEPROMPTTEXT"
assert_file "P1 slash command writes the provenance marker" "$(marker_of "$sid")"
body=$(cat "$(marker_of "$sid")" 2>/dev/null)
assert_contains "P1 marker records source=user_skill_invocation" '"source":"user_skill_invocation"' "$body"
assert_contains "P1 marker records invoked_at" '"invoked_at"' "$body"
# The prompt text itself must never be persisted - prompts carry private content
# and the FACT of invocation is the entire signal.
assert_not_contains "P1 marker does not persist the prompt text" 'PRIVATEPROMPTTEXT' "$body"
# ...and neither may the recorder's own streams. A hook that echoed the prompt
# would leak it into the transcript and the CLI's hook log, which the marker's
# own discretion would then be powerless to undo.
assert_not_contains "P1 recorder stdout does not echo the prompt text" 'PRIVATEPROMPTTEXT' "$LAST_RECORDER_OUT"
assert_not_contains "P1 recorder stderr does not echo the prompt text" 'PRIVATEPROMPTTEXT' "$LAST_RECORDER_ERR"
assert_eq "P1 recorder exits 0 on the invocation path" "0" "$LAST_RECORDER_STATUS"
assert_eq "P1 recorder emits exactly the empty UserPromptSubmit JSON" "$RECORDER_OK_STDOUT" "$LAST_RECORDER_OUT"
# The marker is written into a state directory other processes can reach, so
# owner-only is part of the evidence claim, not housekeeping.
assert_owner_only "P1 marker is owner-only (0600)" "$(marker_of "$sid")"

# Table-driven per skills/_shared/test-design/parser-regex-tests.md: the subject is
# a regex constant, so each case carries its own name. `\n` in the prompt column is
# expanded - a multi-line prompt is exactly what the `m` flag and the wrapper
# tolerance exist for, and a heredoc row cannot hold a raw newline. Fields split on
# `|` ONLY, so the prompt starts at the very next character: a row with a space
# after the pipe is testing a LEADING-SPACE prompt.
p1_prompt_of() { printf '%b' "$1"; }

# The `-still-matches` rows PIN OBSERVED BEHAVIOUR: lookahead `(?![\w-])` lets
# `.`/`/`/`:` suffixes through, the regex never requires/inspects a closing
# `</command-name>`, so a missing close or trailing junk before one still
# attributes, and it has no markdown awareness, so a bare command that is the WHOLE
# of a fenced line attributes too (the near-miss table's
# `backticked-inside-a-code-fence` covers only a PREFIXED line inside a fence).
# Positives deliberately (over-attribution is safe - marker is
# evidence, never a gate: P3/P4/P5/P11). `expanded-command-name-wrapper` is the
# real TYPED-slash-command shape pre-7c40bf48 missed (#1780 M-2); live
# counterpart: tests/TL3-hook-record-off-skill-invocation.sh.
while IFS='|' read -r name raw; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"
    sid=pv1v; rm -f "$(marker_of "$sid")"
    submit_prompt "$sid" "$(p1_prompt_of "$raw")"
    assert_file "P1 variant writes marker: $name" "$(marker_of "$sid")"
done <<'P1_VARIANTS'
with-trailing-arguments|/enforce-workflow-off examiner is broken
plugin-namespaced|/agents:enforce-workflow-off
leading-whitespace|  /enforce-workflow-off
expanded-command-name-wrapper|<command-message>enforce-workflow-off</command-message>\n<command-name>/enforce-workflow-off</command-name>
bare-command-on-a-later-line|please read this note first\n/enforce-workflow-off
dot-suffixed-still-matches|/enforce-workflow-off.evil
slash-suffixed-still-matches|/enforce-workflow-off/evil
colon-suffixed-still-matches|/enforce-workflow-off:evil
unclosed-wrapper-tag-still-matches|<command-name>/enforce-workflow-off
trailing-content-before-close-still-matches|<command-name>/enforce-workflow-off some junk</command-name>
bare-command-alone-in-a-fenced-block-still-matches|here is a snippet:\n```\n/enforce-workflow-off\n```\ncan you review it?
P1_VARIANTS
rm -f "$(marker_of pv1v)"

# `bare-command-on-a-later-line` pins the `m` flag's deliberate cost: a bare command
# line anywhere in the prompt attributes, even when pasted. Over-attribution is the
# safe direction - the marker is evidence, never a gate (P3/P4/P5/P11) - and it is
# the CONTROL proving the multi-line near-misses below are not vacuous.
# Near-misses must NOT write. Three families, separated deliberately (CPR-SC):
# prose or a different command; a mention not at the START of its line (the `m`
# flag widened matching to every LINE, not to every POSITION); a broken or foreign
# <command-name> wrapper (exactly ONE well-formed opening tag is tolerated).
while IFS='|' read -r name raw; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    name="${name//[[:space:]]/}"
    sid=pv1n; rm -f "$(marker_of "$sid")"
    submit_prompt "$sid" "$(p1_prompt_of "$raw")"
    assert_absent "P1 near-miss writes no marker: $name" "$(marker_of "$sid")"
done <<'P1_NEAR_MISSES'
prose-mention|please enforce-workflow-off for me
longer-command-offline|/enforce-workflow-offline
longer-command-off-now|/enforce-workflow-off-now
unrelated-command|/workflow-init
doc-path-mention|read rules/workflow-off.md
quoted-mid-line|the transcript says "/enforce-workflow-off examiner broken" was typed
backticked-inside-a-code-fence|here is a snippet:\n```\nrun `/enforce-workflow-off` when the examiner dies\n```\ncan you review it?
blockquoted-line|please review this excerpt:\n> /enforce-workflow-off\nis that the right escape hatch?
comment-prefixed-line|review this doc:\n# /enforce-workflow-off\nwhat does it do?
wrapper-names-another-skill|<command-name>/some-other-skill</command-name>
closing-tag-before-the-command|</command-name>/enforce-workflow-off
foreign-wrapper-tag|<command-message>/enforce-workflow-off</command-message>
doubled-wrapper-tag|<command-name><command-name>/enforce-workflow-off</command-name>
P1_NEAR_MISSES

# The recorder reads stdin into ONE reused 4096-byte buffer, so a prompt longer
# than a single read is reassembled - or silently truncated. The command is placed
# to STRADDLE the first boundary: its head lands in chunk 1 and its tail in chunk
# 2, which is what a lost slice or a reused-buffer aliasing bug mangles.
# KNOWN-RED (#2157): readStdin() collects `buf.slice(0, n)`, a VIEW over the same
# memory, so read 2 overwrites read 1's bytes. Every payload over 4096 bytes then
# fails JSON.parse and the hook does NOTHING - no marker, and no CLEARING of a
# stale one - while still exiting 0 with `{}`. These cases assert the CORRECT
# behaviour instead of freezing the defect; they go green once readStdin() copies.
BUF_BYTES=4096
sid=pv1buf
_pfx=$(printf '{"session_id":"%s","prompt":"' "$sid")
# `\n` occupies two bytes in the JSON literal; land the command's `/` six bytes
# before the boundary so the 21-character command name spans both chunks.
_pad_len=$(( BUF_BYTES - 6 - ${#_pfx} - 2 ))
if [ "$_pad_len" -le 0 ]; then
    fail "P1 straddle case is misconfigured - prefix already exceeds the buffer"
else
    _pad=$(printf '%*s' "$_pad_len" ''); _pad="${_pad// /x}"
    rm -f "$(marker_of "$sid")"
    submit_prompt "$sid" "$_pad
/enforce-workflow-off straddles the stdin buffer boundary"
    assert_file "P1 command straddling the 4096-byte stdin boundary still writes the marker" "$(marker_of "$sid")"
    body=$(cat "$(marker_of "$sid")" 2>/dev/null)
    assert_contains "P1 straddled read yields an intact payload" '"source":"user_skill_invocation"' "$body"
    assert_eq "P1 straddled read does not fail the recorder" "0" "$LAST_RECORDER_STATUS"
    rm -f "$(marker_of "$sid")"
fi

# ...and the CONTROL for it: a payload several buffers long with the command only
# at the very end. A reader that stops after the first chunk passes the straddle
# case by accident but cannot pass this one.
sid=pv1multibuf
_pad=$(printf '%*s' $(( BUF_BYTES * 3 )) ''); _pad="${_pad// /x}"
rm -f "$(marker_of "$sid")"
submit_prompt "$sid" "$_pad
/enforce-workflow-off arrives after three full buffers"
assert_file "P1 command after three full stdin buffers still writes the marker" "$(marker_of "$sid")"
assert_eq "P1 multi-buffer read does not fail the recorder" "0" "$LAST_RECORDER_STATUS"
rm -f "$(marker_of "$sid")"

# The security-bearing half of the same read: an oversized LATER prompt must still
# CLEAR an unconsumed marker (P2). A dropped payload leaves the marker alive, so a
# single long follow-up prompt buys a stale marker the rest of its 10-minute
# freshness window - attribution for an emission the user never asked for.
sid=pv1bufclear
submit_prompt "$sid" "/enforce-workflow-off"
assert_file "P1 precondition: marker present before the oversized prompt" "$(marker_of "$sid")"
submit_prompt "$sid" "now please refactor the parser $_pad"
assert_absent "P1 an oversized later prompt still clears the stale marker" "$(marker_of "$sid")"
rm -f "$(marker_of "$sid")"

# Idempotency: a repeated invocation in the same session refreshes the marker in
# place. The writer mints via write-then-rename, so a second pass must leave one
# intact payload and no observable `.tmp` intermediate - a stranded one is a
# forgery target of its own (P10 protects that basename too).
sid=pv1twice
submit_prompt "$sid" "/enforce-workflow-off first emission"
submit_prompt "$sid" "/enforce-workflow-off second emission"
assert_file "P1 repeat invocation still leaves the marker" "$(marker_of "$sid")"
body=$(cat "$(marker_of "$sid")" 2>/dev/null)
assert_contains "P1 repeat invocation leaves an intact payload" '"source":"user_skill_invocation"' "$body"
assert_absent "P1 repeat invocation strands no .tmp intermediate" "$(marker_of "$sid").tmp"
rm -f "$(marker_of "$sid")"
}
