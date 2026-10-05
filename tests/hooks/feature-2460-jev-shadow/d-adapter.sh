#!/usr/bin/env bash
# Tests: bin/workflow/lib/jev-complexity-adapter.js, skills/_shared/judge-task-complexity.md
# Tags: TL2, jev, adapter, complexity-judge, vocabulary-drift, stage-mapping, scope:issue-specific, pwsh-not-required, artifact-read-cap, multibyte-split, artifact-session-fallback, notes-session-id-priority, notes-session-binding, latest-entered-binding, parser-selected-line, output-sanitize, credential-redaction

# The adapter is the only place Jev's untrusted probabilities become a SIGNALS: line, and
# that line always goes through the unmodified parser. Rows pin the probability mapping,
# the vocabulary drift guard against SIGNAL_IDS and the rubric, request truncation, the
# step-to-stage table, LLM text extraction and the LLM-side status (C3).

# TL3 gap (what this test does NOT catch): a change in the real Agent tool_response shape
# after fixtures/agent-post-payload.json was captured by TL3-hook-agent-jev-shadow.sh.

. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
fx_new d-adapter
SID="jev2460-d-sid"
printf '# Intent\nINTENT-MARK-2460\n' > "$FX/plans/$SID-intent.md"
printf '# Outline\nOUTLINE-MARK-2460\n' > "$FX/plans/$SID-outline.md"
PROBE="$(run_with_timeout 90 node "$(np "$LIBDIR/adapter-probe.js")" "$REPO_N" "$(np "$FX/plans")" "$SID" 2>/dev/null)"
row() { printf '%s\n' "$PROBE" | awk -F '\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }'; }

case_begin "d-adapter-loads" "bin/workflow/lib/jev-complexity-adapter.js"
check "the adapter module loads" "ok" "$(row load)"
case_end

echo "=== probabilities -> SIGNALS: line (status|parser output|shape) ==="
case_begin "d-map-answers" "bin/workflow/lib/jev-complexity-adapter.js"
check "p >= 0.5 ids are selected" "ok|S1-multi-file,S2-architecture|line" "$(row map-two-selected)"
check "S1b alone stays S1b alone (no implication added)" "ok|S1b-wide-change|line" "$(row map-s1b-only-no-implication)"
check "all negative parses to empty" "ok||line" "$(row map-all-negative)"
check "all negative is the literal SIGNALS: none line" "SIGNALS: none" "$(row map-all-negative-rawline)"
check "confidence exactly at the threshold is ok" "ok|S1-multi-file|line" "$(row map-confidence-at-threshold)"
check "p = 0.5 is selected when the threshold admits it" "ok|S1-multi-file|line" "$(row map-p-half-selected)"
check "p = 0 and p = 1 are accepted as-is (status|parser output|p(S1)|p(S2)|minConfidence)" "ok|S1-multi-file|1|0|1" \
  "$(row map-p-endpoints)"
case_end
case_begin "d-map-fallbacks" "bin/workflow/lib/jev-complexity-adapter.js"
check "one signal below the threshold is low-confidence -> S0" "low-confidence|S0-undecidable|line" "$(row map-low-confidence)"
check "low-confidence keeps probabilities and min confidence" "0.6|0.02|0.6" "$(row map-low-confidence-keeps-probs)"
check "a missing answer is unmappable -> S0" "unmappable|S0-undecidable|line" "$(row map-missing-answer)"
check "a string probability is unmappable -> S0" "unmappable|S0-undecidable|line" "$(row map-non-numeric)"
check "p > 1 is unmappable -> S0" "unmappable|S0-undecidable|line" "$(row map-out-of-range)"
check "p < 0 is unmappable -> S0" "unmappable|S0-undecidable|line" "$(row map-negative)"
check "p = -0.000001 (just below 0) is unmappable -> S0" "unmappable|S0-undecidable|line" "$(row map-just-below-zero)"
check "p = 1.000001 (just above 1) is unmappable -> S0" "unmappable|S0-undecidable|line" "$(row map-just-above-one)"
case_end
case_begin "d-map-injection" "bin/workflow/lib/jev-complexity-adapter.js"
check "hostile extra answer keys: parser output in vocabulary, no hostile text, one line" "true|false|1" "$(row map-injection)"
case_end

echo "=== vocabulary drift guard ==="
case_begin "d-questions-match-signal-ids" "bin/workflow/lib/jev-complexity-adapter.js"
check "question keys are exactly SIGNAL_IDS lowercased with - -> _" \
  "s1_multi_file,s1b_wide_change,s2_architecture,s3_security,s4_installer,s5_breaking,s6_long_plan" "$(row questions-keys)"
check "every question is a noul question with non-trivial instructions" "true" "$(row questions-shape)"
check "instructions come from the rubric's ### <id> section" "true" "$(row questions-from-rubric)"
case_end
case_begin "d-rubric-has-every-signal" "skills/_shared/judge-task-complexity.md"
MISSING=""
for id in ${SIGNAL_CSV//,/ }; do grep -qx "### $id" "$AGENTS_DIR/skills/_shared/judge-task-complexity.md" || MISSING="$MISSING $id"; done
check "the rubric has a ### section for every signal id" "" "$MISSING"
case_end

echo "=== request building ==="
case_begin "d-build-request" "bin/workflow/lib/jev-complexity-adapter.js"
check "plans from WORKFLOW_PLANS_DIR, prompt included, not truncated, sources, sha256/bytes of state" \
  "true|true|false|true|true|true" "$(row request-small)"
check "over 16000 chars: truncated, capped, prompt kept" "true|true|true" "$(row request-truncated)"
check "relative WORKFLOW_PLANS_DIR: no throw, no artifacts, prompt kept" "0|true|false" "$(row request-relative-plans-dir)"
case_end

echo "=== secret shapes never reach the state sent to Jev ==="
case_begin "d-build-request-redacts-secrets" "bin/workflow/lib/jev-complexity-adapter.js"
check "prompt: neither token in the state, both replaced in place" "false|false|true" "$(row request-redacts-prompt)"
check "intent/outline/detail: no token in the state, each replaced in place, all three are sources" \
  "false|true|intent,outline,detail" "$(row request-redacts-artifacts)"
check "non-string prompts give an empty prompt section and never leak" "true|true|true|true" "$(row request-non-string-prompt)"
case_end
case_begin "d-build-request-redacts-before-cap" "bin/workflow/lib/jev-complexity-adapter.js"
check "token straddling the cap: 16000 chars, truncated, no key fragment, placeholder last, sha256/bytes of the state" \
  "16000|true|false|true|true|true" "$(row request-secret-straddles-cap)"
check "15990 filler chars then a token: 16000 chars, truncated, no key fragment" "16000|true|false" "$(row request-filler-then-secret)"
case_end
case_begin "d-build-request-redacts-ghp-before-cap" "bin/workflow/lib/jev-complexity-adapter.js"
check "ghp_ token straddling the cap: within cap, no ghp_<alnum>, no body fragment, placeholder last, truncated, bytes of state" \
  "true|false|false|true|true|true" "$(row request-ghp-straddles-cap)"
case_end

echo "=== output-sanitize credential shapes never reach the request (prompt leak|kept|marker|artifact leak|kept|marker|bytes+sha) ==="
case_begin "d-build-request-sanitize-shapes" "bin/workflow/lib/jev-complexity-adapter.js"
while IFS='|' read -r name; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  check "$name: no secret in prompt or artifacts, prose kept, marker in place, size/hash of the sent state" \
    "false|true|true|false|true|true|true" "$(row "sanitize-shape-$name")"
done <<'TABLE'
github-pat
url-userinfo
auth-bearer
auth-basic
password-assign
token-colon
api-key-assign
encrypted-pem
sk-with-assign
TABLE
check "prose glued to a 20+ sk- run (task-…, risk-…_v2, disk-…_final) is redacted in prompt and artifact, marker in place" \
  "false,false,true,true|false,false,true,true|false,false,true,true" "$(row sanitize-prose-sk-glued-redacted)"
check "prose without a 20+ sk- run (short disk-usage, snake_case, tasks-…) survives in prompt and artifact, no marker" \
  "true,true,false,false|true,true,false,false|true,true,false,false" "$(row sanitize-prose-non-sk-kept)"
case_end
case_begin "d-build-request-sanitize-before-cap" "bin/workflow/lib/jev-complexity-adapter.js"
check "github_pat_ straddling the prompt cap: within cap, no prefix fragment, marker kept, truncated, bytes+sha" \
  "true|false|true|true|true" "$(row request-github-pat-straddles-cap)"
check "URL userinfo straddling the prompt cap: no user or password fragment, scheme+marker kept, truncated" \
  "true|false|true|true|true" "$(row request-url-userinfo-straddles-cap)"
check "github_pat_ straddling the cap inside intent.md: no prefix fragment, marker kept, intent only source" \
  "true|false|true|true|true|intent" "$(row request-github-pat-straddles-artifact-cap)"
case_end

echo "=== truncation never splits a surrogate pair (length|lone-high-last|any-lone|bytes|utf8-roundtrip|sha256|truncated) ==="
case_begin "d-build-request-surrogate-prompt-cut" "bin/workflow/lib/jev-complexity-adapter.js"
check "cap falls inside an emoji in the prompt: the pair is dropped whole" \
  "15999|false|false|true|true|true|true" "$(row request-surrogate-at-prompt-cut)"
check "control: cap falls between two emoji: nothing extra is dropped" \
  "16000|false|false|true|true|true|true" "$(row request-surrogate-pair-fits-prompt-cut)"
case_end
case_begin "d-build-request-surrogate-artifact-cut" "bin/workflow/lib/jev-complexity-adapter.js"
check "cap falls inside an emoji in intent.md: pair dropped whole; section offset as probed; intent only source" \
  "15999|false|false|true|true|true|true|true|intent" "$(row request-surrogate-at-artifact-cut)"
case_end
case_begin "d-build-request-input-shape" "bin/workflow/lib/jev-complexity-adapter.js"
check "input keys are exactly bytes,sha256,truncated,sources; hash and byte length describe the redacted state only" \
  "bytes,sha256,truncated,sources|true|true|true|false|false" "$(row request-input-is-of-redacted-state)"
check "a prompt with no secret is passed through byte-identical and hashes the same twice" "true|false|true|0" \
  "$(row request-clean-prompt-identical)"
case_end

echo "=== each artifact read is capped at MAX_ARTIFACT_READ_BYTES ==="
case_begin "d-build-request-artifact-read-cap" "bin/workflow/lib/jev-complexity-adapter.js"
check "intent.md over 1 MiB: read up to the cap only; header counts the read lines; state within 16000 chars" \
  "1048576|1048576|524288|true|true|intent" "$(row request-artifact-read-cap)"
check "a 2- or 3-byte char (1 or 2 bytes in) and a 4-byte char (3 bytes in) at the cap: dropped whole, no U+FFFD" \
  "true,true,false,1|true,true,false,1|true,true,false,1" "$(row request-artifact-cap-splits-multibyte)"
check "a file of exactly the cap, or under it, keeps a literal trailing U+FFFD" "1048574|true|true" \
  "$(row request-artifact-at-cap-not-trimmed)"
case_end
case_begin "d-build-request-artifact-cap-genuine-fffd" "bin/workflow/lib/jev-complexity-adapter.js"
check "over 1 MiB, a complete U+FFFD ending exactly at the cap is kept (length|ends with U+FFFD|lines)" "1048574|true|1" \
  "$(row request-artifact-cap-keeps-genuine-fffd)"
case_end

echo "=== artifacts are found by the cwd's WORKTREE_NOTES Session-ID first, else by the hook session id ==="
case_begin "d-artifacts-notes-sid-wins" "bin/workflow/lib/jev-complexity-adapter.js"
check "notes sid has artifacts: they are read, not the hook sid's partial set (header|hook mark|notes mark|sources)" \
  "intent=present outline=present detail=absent|false|true|intent,outline" "$(row ws-notes-sid-wins)"
case_end
case_begin "d-artifacts-hook-sid-fallback" "bin/workflow/lib/jev-complexity-adapter.js"
check "notes sid has no artifacts: the hook sid's plan is read" \
  "intent=present outline=present detail=absent|true|true|intent,outline" "$(row ws-notes-empty-hook-read)"
check "no notes file, an invalid notes sid, a relative or missing cwd: the hook sid's plan is read" \
  "true,true,true,true" "$(row ws-unusable-notes-hook-read)"
case_end
case_begin "d-notes-session-id" "bin/workflow/lib/jev-complexity-adapter.js"
check "notesSessionId: valid sid; no notes, .., /, relative, undefined, null, number all null" \
  "ws-n-notes,null,null,null,null,null,null,null" "$(row notes-sid-direct)"
if [ "$(row notes-sid-posix-cwd)" = "SKIP-NOT-WIN32" ]; then
  skip "POSIX drive-letter cwd normalization applies on win32 only"
else
  check "notesSessionId: a cwd in /c/... form is normalized and read" "ws-np-notes" "$(row notes-sid-posix-cwd)"
fi
case_end

echo "=== the notes Session-ID counts only when its state is bound to this worktree (sid|notes plan read|hook plan read) ==="
NB="$(run_with_timeout 90 node "$(np "$LIBDIR/notes-bind-probe.js")" "$REPO_N" "$(np "$FX/plans")" 2>/dev/null)"
nb() { printf '%s\n' "$NB" | awk -F '\t' -v k="$1" '$1 == k { sub(/^[^\t]*\t/, ""); print; exit }'; }
NB_HOOK="null|false|true"
case_begin "d-notes-sid-bound-session-worktree" "bin/workflow/lib/jev-complexity-adapter.js"
check "the binding probe loads and notesSessionId is exported" "ok" "$(nb load)"
check "state.session_worktree equals the cwd: the notes sid and its plan are used" "nb-sw|true|false" "$(nb bound-session-worktree)"
case_end
case_begin "d-notes-sid-unbound-start-context-cwd" "bin/workflow/lib/jev-complexity-adapter.js"
check "state.cwd only from session_start_context.cwd (no entered event) equals the cwd: null, the hook plan is read" \
  "true|true|$NB_HOOK" "$(nb unbound-start-context-cwd)"
case_end
case_begin "d-notes-sid-main-checkout-shared-cwd" "bin/workflow/lib/jev-complexity-adapter.js"
check "C12: two sessions started on one main checkout, notes name A, hook sid B: null, B's plan read, A's not" \
  "null|false|true" "$(nb main-checkout-shared-cwd)"
case_end
case_begin "d-notes-sid-bound-entered-cwd" "bin/workflow/lib/jev-complexity-adapter.js"
check "a worktree entered event projects state.cwd equal to the cwd: the notes sid and its plan are used" \
  "true|true|nb-en|true|false" "$(nb bound-entered-cwd)"
check "entered then exited: the binding is not revoked (entered_at set|exited_at set|cwd equal|sid|notes|hook)" \
  "true|true|true|nb-ex|true|false" "$(nb bound-entered-then-exited)"
case_end
case_begin "d-notes-sid-entered-elsewhere" "bin/workflow/lib/jev-complexity-adapter.js"
check "start context names the cwd, the entered event names another dir: null, the hook plan is read" \
  "true|$NB_HOOK" "$(nb unbound-entered-other)"
check "session_worktree equals the cwd, entered event names another dir: the notes sid binds (OR)" \
  "true|nb-or|true|false" "$(nb bound-session-worktree-cwd-elsewhere)"
case_end
case_begin "d-notes-sid-non-string-state-cwd" "bin/workflow/lib/jev-complexity-adapter.js"
check "a non-string state.cwd (entered event cwd 42, or start-context cwd 42) never binds and never throws" \
  "number|true|$NB_HOOK|number|$NB_HOOK" "$(nb non-string-state-cwd)"
case_end
case_begin "d-notes-sid-unbound-other-worktree" "bin/workflow/lib/jev-complexity-adapter.js"
check "state cwd is the fixture project, no session_worktree: null, the hook plan is read" "$NB_HOOK" "$(nb unbound-default-state)"
check "session_worktree and the entered cwd both name another worktree: null, the hook plan is read" "$NB_HOOK" "$(nb unbound-other-worktree)"
case_end
case_begin "d-notes-sid-no-state" "bin/workflow/lib/jev-complexity-adapter.js"
check "the notes sid has no workflow state: null, the hook plan is read" "null|$NB_HOOK" "$(nb no-state)"
case_end
case_begin "d-notes-sid-prefix-not-equal" "bin/workflow/lib/jev-complexity-adapter.js"
check "bound to <d> with cwd <d>-x, bound to <d>-x with cwd <d>, bound to the parent of cwd: all null" \
  "$NB_HOOK,$NB_HOOK,$NB_HOOK" "$(nb prefix-not-equal)"
case_end
case_begin "d-notes-sid-path-normalization" "bin/workflow/lib/jev-complexity-adapter.js"
check "a trailing separator on the stored path or on the cwd still binds" "nb-ts|true|false,nb-ts2|true|false" "$(nb norm-trailing-sep)"
if [ "$(nb norm-win32)" = "SKIP-NOT-WIN32" ]; then
  skip "win32 path-equality variants (separators, case, /c/ form) apply on win32 only"
else
  check "win32: forward slashes, upper/lower case, trailing \\ and the /c/ form (stored or as cwd) all bind" \
    "fwd=nb-w-fwd,upper=nb-w-upper,lower=nb-w-lower,backslash=nb-w-backslash,posix=nb-w-posix,cwdposix=nb-w-cwdposix" \
    "$(nb norm-win32)"
fi
if [ "$(nb norm-posix-case)" = "SKIP-WIN32" ]; then
  skip "case-sensitive path equality applies off win32 only"
else
  check "POSIX: a case-variant stored path does not bind" "$NB_HOOK" "$(nb norm-posix-case)"
fi
case_end
case_begin "d-notes-sid-corrupt-state" "bin/workflow/lib/jev-complexity-adapter.js"
check "a non-string session_worktree (42) never binds and never throws" "42|$NB_HOOK" "$(nb non-string-binding)"
check "a corrupt state file: null, no throw, the hook plan is read" "$NB_HOOK" "$(nb corrupt-state)"
case_end
echo "=== only the latest entered event's own cwd binds (entered_at set|state.cwd equal|sid|notes plan read|hook plan read) ==="
case_begin "d-notes-sid-unbound-entered-null-cwd" "bin/workflow/lib/jev-complexity-adapter.js"
check "start context names the cwd, entered event cwd null (migrated shape): null, the hook plan is read" \
  "true|true|$NB_HOOK" "$(nb unbound-entered-null-cwd)"
case_end
case_begin "d-notes-sid-unbound-entered-missing-cwd" "bin/workflow/lib/jev-complexity-adapter.js"
check "start context names the cwd, entered event has no cwd key: null, the hook plan is read" \
  "true|true|$NB_HOOK" "$(nb unbound-entered-missing-cwd)"
case_end
case_begin "d-notes-sid-unbound-entered-fallback-process-cwd" "bin/workflow/lib/jev-complexity-adapter.js"
check "entered event cwd equals the cwd but path_source is fallback-process-cwd: null, the hook plan is read" \
  "true|true|$NB_HOOK" "$(nb unbound-entered-fallback-process-cwd)"
check "control: an entered event with no path_source key and a matching cwd binds" \
  "true|true|nb-enp|true|false" "$(nb bound-entered-no-path-source)"
case_end
case_begin "d-notes-sid-latest-entered-decides" "bin/workflow/lib/jev-complexity-adapter.js"
check "an earlier entered event matches, the latest names another dir: null, the hook plan is read" \
  "true|false|$NB_HOOK" "$(nb unbound-latest-entered-other)"
check "an earlier entered event matches, the latest has no cwd key: null, the hook plan is read" \
  "true|true|$NB_HOOK" "$(nb unbound-latest-entered-missing-cwd)"
case_end

case_begin "d-artifacts-notes-fallback" "bin/workflow/lib/jev-complexity-adapter.js"
check "the WORKTREE_NOTES sid's plan is read, the header says present, both are sources" \
  "intent=present outline=present detail=absent|true|true|intent,outline" "$(row ws-notes-fallback)"
case_end
case_begin "d-artifacts-notes-fallback-posix-cwd" "bin/workflow/lib/jev-complexity-adapter.js"
if [ "$(row ws-posix-cwd)" = "SKIP-NOT-WIN32" ]; then
  skip "POSIX drive-letter cwd normalization applies on win32 only"
else
  check "cwd in /c/... form, hook sid has none: the plan of the WORKTREE_NOTES sid is read" \
    "intent=present outline=present detail=absent|true" "$(row ws-posix-cwd)"
fi
case_end
case_begin "d-artifacts-no-fallback-source" "bin/workflow/lib/jev-complexity-adapter.js"
check "no WORKTREE_NOTES.md in cwd: no artifacts, no throw" "true" "$(row ws-no-notes-file)"
check "a notes Session-ID with .., / or 129 chars is never used (plans exist under each)" "true,true,true" "$(row ws-invalid-notes-sid)"
check "cwd undefined, relative, a number or null: no artifacts and no process.cwd() fallback" "true,true,true,true" "$(row ws-bad-cwd)"
check "notes in the parent of cwd, or only in a sibling dir: not used" "true,true" "$(row ws-notes-only-beside-cwd)"
case_end

echo "=== step -> stage ==="
case_begin "d-stage-for-step" "bin/workflow/lib/jev-complexity-adapter.js"
check "stageForStep over every relevant step, null and an unknown string" \
  "cos1,cos1,unknown,outline,detail,unknown,write_tests,unknown,write_code,unknown,unknown,unknown" "$(row stage-table)"
check "STEP_TO_STAGE is exported" "true" "$(row stage-table-export)"
case_end

echo "=== LLM text extraction and status ==="
case_begin "d-extract-llm-text" "bin/workflow/lib/jev-complexity-adapter.js"
check "string tool_response is used as-is" "SIGNALS: S2-architecture" "$(row extract-string)"
check "content[] keeps only text blocks" "SIGNALS: S1-multi-file" "$(row extract-content-text-only)"
check "multiple text blocks are joined; non-text dropped" "true|true|false" "$(row extract-content-multi-text)"
check "tool_output is the first fallback" "OUT-A" "$(row extract-tool-output)"
check "tool_output_text is the second fallback" "OUT-B" "$(row extract-tool-output-text)"
check "tool_response wins over tool_output" "RESP" "$(row extract-string-wins)"
check "empty string, empty content and nothing all give null" "null,null,null" "$(row extract-empty)"
case_end
case_begin "d-classify-llm" "bin/workflow/lib/jev-complexity-adapter.js"
check "null->missing, exact S0 line->ok, trailing-garbage S0->parse-fallback, normal->ok" \
  "missing,ok,ok,parse-fallback,ok,ok" "$(row classify)"
case_end
case_begin "d-classify-llm-exact-s0-line" "bin/workflow/lib/jev-complexity-adapter.js"
check "S0 line after preamble (LF/CRLF, padded, any spacing after SIGNALS:)->ok; S0 then prose or no S0 line->parse-fallback; non-S0 parsed->ok; undefined->missing" \
  "ok,ok,parse-fallback,parse-fallback,parse-fallback,parse-fallback,ok,ok,parse-fallback,parse-fallback,ok,missing" \
  "$(row classify-exact-line)"
check "SIGNALS:S0, SIGNALS:<2 spaces>S0 and SIGNALS:<tab>S0<space> are ok and agree with the real parser" \
  "ok:S0-undecidable:true,ok:S0-undecidable:true,ok:S0-undecidable:true" "$(row classify-payload-spacing)"
case_end
case_begin "d-classify-llm-parser-selected-line" "bin/workflow/lib/jev-complexity-adapter.js"
# Shapes: preamble+S0, S0+second SIGNALS, two S0, S0+blank lines, padded S0, S0+prose,
# SIGNALS+prose+S0, preamble+S0+prose. Each value is status:parser output:agrees-with-parser.
check "status follows the line the real parser selects, and agrees with the parser on every shape" \
  "ok:S0-undecidable:true,parse-fallback:S0-undecidable:true,parse-fallback:S0-undecidable:true,ok:S0-undecidable:true,ok:S0-undecidable:true,parse-fallback:S0-undecidable:true,parse-fallback:S0-undecidable:true,parse-fallback:S0-undecidable:true" \
  "$(row classify-parser-rule)"
check "a non-S0 answer after preamble is ok and parses to its signal" "ok:S2-architecture" "$(row classify-parser-rule-non-s0)"
case_end
case_begin "d-real-payload-fixture" "bin/workflow/lib/jev-complexity-adapter.js"
if [ ! -f "$LIBDIR/fixtures/agent-post-payload.json" ]; then
  skip "real Agent payload fixture absent (captured by TL3-hook-agent-jev-shadow.sh, detail plan S13)"
else
  check "the captured Agent PostToolUse payload extracts to S1-multi-file" "S1-multi-file" "$(row real-payload)"
fi
case_end

finish
