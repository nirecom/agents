#!/usr/bin/env bash
# Tests: bin/workflow/jev-judge
# Tags: TL2, bin, jev, two-stage, idempotent, done-marker, owner-marker, superseded, scope:issue-specific, pwsh-not-required
# Fragment of tests/bin/feature-2460-jev-judge.sh, sourced after _lib.sh (not standalone):
# a second finalize of a settled ticket replays the done marker byte for byte and touches
# nothing downstream, including after a fail-safe first run. A recorded SETTLE=ok is re-checked
# against the owner marker: once a newer ticket owns it, the re-run prints the superseded form.

echo "=== jev-judge: finalize twice ==="
need_mod bin/workflow/jev-judge || return 0

mtime_of() { if [ -f "$1" ]; then stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; else echo absent; fi; }

case_begin "jj-finalize-twice" "bin/workflow/jev-judge"
jj_fx twice
mock_p 0.01 S2-architecture 0.99
jj_query complexity
jj finalize --session "$SID" --ticket "$TICKET"
FIRST="$(out_text)"; N1="$(log_count)"
SIGF="$(ctl complexity-signals.txt)"; OWNF="$(ctl complexity-signals-owner.json)"
S1="$(pb sha "$SIGF")|$(pb sha "$OWNF")"; M1="$(mtime_of "$SIGF")|$(mtime_of "$OWNF")"
sleep 1.1
jj finalize --session "$SID" --ticket "$TICKET"
check "second finalize: exit 0" "0" "$JJ_RC"
check "second finalize: stdout byte-equal to the first" "$FIRST" "$(out_text)"
check "second finalize: decision log unchanged in size" "$N1" "$(log_count)"
check "second finalize: fixed file and owner marker content unchanged" "$S1" "$(pb sha "$SIGF")|$(pb sha "$OWNF")"
check "second finalize: fixed file and owner marker mtime unchanged" "$M1" "$(mtime_of "$SIGF")|$(mtime_of "$OWNF")"
case_end

# ticket_files_sig <ticket>: count and combined sha256 of every broker file named after the
# ticket (done marker, claim). Re-output must leave them byte-identical.
ticket_files_sig() {
  local list; list="$(find "$JEVDIR" -name "*$1*" -type f 2>/dev/null | sort)"
  if [ -z "$list" ]; then echo "0|none"; return 0; fi
  printf '%s\n' "$list" | wc -l | tr -d ' '
  printf '%s\n' "$list" | xargs cat 2>/dev/null | sha256sum | cut -c1-64
}

case_begin "jj-finalize-rerun-after-newer-owner" "bin/workflow/jev-judge"
jj_fx rerun-newer
mock_p 0.01 S2-architecture 0.99
jj_query complexity
TA="$TICKET"
jj finalize --session "$SID" --ticket "$TA"
check "A's first finalize: SETTLE=ok with its CSV" "ok|S2-architecture" "$(kv SETTLE)|$(kv SIGNALS_CSV)"
SIG_A="$(ticket_files_sig "$TA" | paste -sd'|' -)"
check "A leaves at least one broker file named after it (done marker)" "1" "$([ "${SIG_A%%|*}" -ge 1 ] 2>/dev/null && echo 1 || echo 0)"
# S5 (not S3) so B settles from Jev alone: S3 is not decisive at complexity.
mock_p 0.01 S5-breaking 0.99
jj_query complexity
TB="$TICKET"
jj finalize --session "$SID" --ticket "$TB"
check "B's finalize: SETTLE=ok" "ok" "$(kv SETTLE)"
FIX_B="$(pb sha "$(ctl complexity-signals.txt)")|$(pb sha "$(ctl complexity-signals-owner.json)")"
N_B="$(log_count)"
jj finalize --session "$SID" --ticket "$TA"
check "A re-run: exit 0" "0" "$JJ_RC"
check "A re-run after newer owner B: SETTLE=superseded" "superseded" "$(kv SETTLE)"
check "A re-run after newer owner B: SIGNALS_CSV=-" "-" "$(kv SIGNALS_CSV)"
check "A re-run: done marker not rewritten" "$SIG_A" "$(ticket_files_sig "$TA" | paste -sd'|' -)"
check "A re-run: fixed file and owner marker unchanged (B stays)" "$FIX_B" \
  "$(pb sha "$(ctl complexity-signals.txt)")|$(pb sha "$(ctl complexity-signals-owner.json)")"
check "A re-run: owner stays B" "\"$TB\"" "$(pb json-get "$(ctl complexity-signals-owner.json)" owner_id)"
check "A re-run: decision log unchanged in size" "$N_B" "$(log_count)"
check "B's fixed file content is B's result" "S5-breaking" "$(fixed_csv complexity)"
case_end

case_begin "jj-failsafe-first-run-replayed" "bin/workflow/jev-judge"
jj_fx twice-fs
mock_p 0.01 S2-architecture 0.5
jj_query complexity
AF="$(kv ANSWER_FILE)"
jj finalize --session "$SID" --ticket "$TICKET"
FIRST="$(out_text)"
check "first run without an answer: S0" "S0-undecidable" "$(kv SIGNALS_CSV)"
if [ "$AF" != "-" ] && [ "$AF" != "<none>" ]; then printf 'SIGNALS: none\n' > "$AF"; fi
jj finalize --session "$SID" --ticket "$TICKET"
check "answer placed after the fail-safe: second run still replays S0" "$FIRST" "$(out_text)"
case_end
