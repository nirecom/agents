#!/usr/bin/env bash
# Part 1 — parser / IR / expansion / redirect / segment-collector.
# Sections: P (tokenizeSegmentWithQuotes), IR (buildSegmentIR additive fields),
# E (expandRawToken), R (extractRedirectTargets string API — PASS now),
# R2 (extractRedirectTargets IR API + expandStaticShellTokens pin),
# C (collectWriteTargetsFromSegments + verb sets), D (#1069 routing guard),
# X (collector edge cases).
#
# Sourced-lib contract: $1 = WORKTREE. Exits $FAIL.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ===========================================================================
# Section P: tokenizeSegmentWithQuotes (NEW — pre-impl, EXPECTED TO FAIL)
# Table-driven (command-parser.js is a parser file). Returns {value, raw}[]
# where value == quote-stripped (same as tokenizeSegment) and raw == pre-strip.
# ===========================================================================
echo "=== Section P: tokenizeSegmentWithQuotes (NEW; expected FAIL pre-impl) ==="
# name|input|want  — input/want run through the SAME quoting on the read side.
while IFS='|' read -r p_name p_in p_want; do
  [ -z "$p_name" ] && continue
  assert_eq "$p_name" "$p_want" "$(tok_quotes "$p_in")"
done <<'P_TABLE'
P1 unquoted foo|foo|[{"value":"foo","raw":"foo"}]
P2 single-quoted $HOME/foo|'$HOME/foo'|[{"value":"$HOME/foo","raw":"'$HOME/foo'"}]
P3 double-quoted $HOME/foo|"$HOME/foo"|[{"value":"$HOME/foo","raw":"\"$HOME/foo\""}]
P4 dq env plans path|"$HOME/.workflow-plans/f.json"|[{"value":"$HOME/.workflow-plans/f.json","raw":"\"$HOME/.workflow-plans/f.json\""}]
P5 empty segment||[]
P6 mixed pre'suf'|pre'suf'|[{"value":"presuf","raw":"pre'suf'"}]
P7 adjacent dq+unquoted a"b"c|a"b"c|[{"value":"abc","raw":"a\"b\"c"}]
P8 dq-prefix unquoted-suffix (NEW; FAIL pre-impl)|"$HOME"/foo|[{"value":"$HOME/foo","raw":"\"$HOME\"/foo"}]
P9 sq-prefix unquoted-suffix (NEW; FAIL pre-impl)|'$HOME'/foo|[{"value":"$HOME/foo","raw":"'$HOME'/foo"}]
P_TABLE

# C5 malformed / special-quote cases for tokenizeSegmentWithQuotes (NEW; FAIL pre-impl).
# Behavior derived from detail plan §Section P and the underlying tokenizeSegment:
#  - P10 unterminated single quote: tokenizeSegment does NOT throw — it strips the
#    dangling quote and yields ["unclosed"]. tokenizeSegmentWithQuotes mirrors that
#    fail-soft behavior, returning the raw form WITH the unterminated quote preserved
#    (detail plan P.7: "same fail behavior as tokenizeSegment"). Pre-impl the fn is not
#    exported → tok_quotes returns ERROR:not-exported → FAIL until the migration lands.
#  - P11 ANSI-C $'literal': detail plan P.4 pins value = quote-stripped "literal",
#    raw = the full "$'literal'" ANSI-C form (NOT null — that fail-closed treatment is
#    for the DOWNSTREAM expandRawToken, cf. E5, not the tokenizer).
echo "--- Section P C5: malformed / ANSI-C quote cases (NEW; FAIL pre-impl) ---"
while IFS='|' read -r p_name p_in p_want; do
  [ -z "$p_name" ] && continue
  assert_eq "$p_name" "$p_want" "$(tok_quotes "$p_in")"
done <<'P_C5_TABLE'
P10 unterminated SQ (NEW; FAIL pre-impl)|'unclosed|[{"value":"unclosed","raw":"'unclosed"}]
P11 ANSI-C quoting (NEW; FAIL pre-impl)|$'literal'|[{"value":"literal","raw":"$'literal'"}]
P_C5_TABLE

# ===========================================================================
# Section IR: buildSegmentIR additive fields (NEW — pre-impl, EXPECTED TO FAIL)
# argvRaw[], cmd0Raw, redirects[].targetRaw. Existing fields must stay identical.
# ===========================================================================
echo "=== Section IR: buildSegmentIR additive fields (NEW; expected FAIL pre-impl) ==="
# IR1: argvRaw and argv have the same length (index alignment).
assert_eq "IR1 argvRaw length == argv length" "$(ir_argv_len 'cp a b c')"  "$(ir_argvraw_len 'cp a b c')"
# IR2: env-prefix VAR=val cmd — argvRaw length matches argv length.
assert_eq "IR2 env-prefix argvRaw len == argv len" "$(ir_argv_len 'VAR=val printf x y')" "$(ir_argvraw_len 'VAR=val printf x y')"
# IR3: redirects[0].targetRaw exists for a redirect segment (single-quoted target
# preserves outer quotes in raw form).
assert_eq "IR3 targetRaw present"            '"'\''$HOME/foo'\''"'                          "$(ir_targetraw "printf x > '\$HOME/foo'")"
# IR4: existing fields byte-identical to pre-migration (additive-safe / blast radius zero).
# buildSegmentIR does NOT strip env-prefix — VAR=val stays as cmd0 in the raw IR.
assert_eq "IR4a cmd0 unchanged (env-prefix)" '"VAR=val"'                                    "$(ir_field 'VAR=val printf x > /tmp/foo' cmd0)"
assert_eq "IR4b argv unchanged (env-prefix)" '["printf","x"]'                               "$(ir_field 'VAR=val printf x > /tmp/foo' argv)"
assert_eq "IR4c redirects unchanged"         '[{"op":">","fd":"1","target":"/tmp/foo"}]'    "$(ir_field 'printf x > /tmp/foo' redirects)"
assert_eq "IR4d kind unchanged"              '"simple"'                                     "$(ir_field 'printf x > /tmp/foo' kind)"
# IR5 (C6): multiple redirects — targetRaw must align index-for-index with target.
# Existing target[i] pins (PASS now) anchor the alignment; targetRaw[i] pins are NEW
# (FAIL pre-impl). Post-impl each raw field carries the pre-expansion token for its
# own redirect slot, never a neighbor's.
assert_eq "IR5a target[0] anchor (PASS)"     '"/tmp/a"'                                     "$(ir_target_at 'printf x > /tmp/a 2>>/tmp/b' 0)"
assert_eq "IR5b target[1] anchor (PASS)"     '"/tmp/b"'                                     "$(ir_target_at 'printf x > /tmp/a 2>>/tmp/b' 1)"
assert_eq "IR5c targetRaw[0] aligns (NEW)"   '"/tmp/a"'                                     "$(ir_targetraw_at 'printf x > /tmp/a 2>>/tmp/b' 0)"
assert_eq "IR5d targetRaw[1] aligns (NEW)"   '"/tmp/b"'                                     "$(ir_targetraw_at 'printf x > /tmp/a 2>>/tmp/b' 1)"
# IR5e/IR5f (C3): attached-redirect targetRaw alignment — no space between the
# operator and the path. target[0] anchors (EXISTING; PASS now); targetRaw[0] is NEW
# (FAIL pre-impl) and must carry the same attached path for its own slot.
# IR5e: printf x >/tmp/a (attached `>`, no space).
assert_eq "IR5e target[0] attached (PASS)"   '"/tmp/a"'                                     "$(ir_target_at 'printf x >/tmp/a' 0)"
assert_eq "IR5e targetRaw[0] attached (NEW)" '"/tmp/a"'                                     "$(ir_targetraw_at 'printf x >/tmp/a' 0)"
# IR5f: printf x 2>>/tmp/b (attached FD append `2>>`, no space).
assert_eq "IR5f target[0] attached FD (PASS)"   '"/tmp/b"'                                  "$(ir_target_at 'printf x 2>>/tmp/b' 0)"
assert_eq "IR5f targetRaw[0] attached FD (NEW)" '"/tmp/b"'                                  "$(ir_targetraw_at 'printf x 2>>/tmp/b' 0)"

# ---------------------------------------------------------------------------
# IR6 (C4): blast-radius snapshot — table-driven pins across command shapes for the
# EXISTING segment fields (cmd0, argv, redirects, kind, rawText). These are the
# additive-safe / blast-radius-zero regression guard: the IR migration must not
# perturb any of these for any shape. All EXISTING → PASS now and must keep passing.
# Shapes: simple (no redirect), redirect, env-prefix + redirect, subshell inline.
# Delimiter is ^ (commands contain no ^). name^cmd^field^want
# ---------------------------------------------------------------------------
echo "--- IR6 (C4): buildSegmentIR existing-field snapshots across shapes (PASS now) ---"
while IFS='^' read -r ir_name ir_cmd ir_field_name ir_want; do
  [ -z "$ir_name" ] && continue
  assert_eq "$ir_name" "$ir_want" "$(ir_field "$ir_cmd" "$ir_field_name")"
done <<'IR6_TABLE'
IR6a simple cmd0^printf x^cmd0^"printf"
IR6b simple argv^printf x^argv^["x"]
IR6c simple redirects empty^printf x^redirects^[]
IR6d simple kind^printf x^kind^"simple"
IR6e simple rawText^printf x^rawText^"printf x"
IR6f redirect cmd0^printf x > /tmp/foo^cmd0^"printf"
IR6g redirect argv^printf x > /tmp/foo^argv^["x"]
IR6h redirect redirects^printf x > /tmp/foo^redirects^[{"op":">","fd":"1","target":"/tmp/foo"}]
IR6i redirect kind^printf x > /tmp/foo^kind^"simple"
IR6j redirect rawText^printf x > /tmp/foo^rawText^"printf x > /tmp/foo"
IR6k env-prefix+redirect cmd0^VAR=val printf x > /tmp/foo^cmd0^"VAR=val"
IR6l env-prefix+redirect argv^VAR=val printf x > /tmp/foo^argv^["printf","x"]
IR6m env-prefix+redirect redirects^VAR=val printf x > /tmp/foo^redirects^[{"op":">","fd":"1","target":"/tmp/foo"}]
IR6n env-prefix+redirect rawText^VAR=val printf x > /tmp/foo^rawText^"VAR=val printf x > /tmp/foo"
IR6_TABLE

# IR7 (C4): parse().separators — top-level field, NOT a segment field (own bridge).
# Distinguishes single-segment (no separator), pipe, and semicolon command shapes.
# EXISTING infra → PASS now.
echo "--- IR7 (C4): parse().separators across command shapes (PASS now) ---"
assert_eq "IR7a single segment no separator" '[]'    "$(ir_separators 'printf x')"
assert_eq "IR7b pipe separator"              '["|"]' "$(ir_separators 'printf x | cat')"
assert_eq "IR7c semicolon separator"         '[";"]' "$(ir_separators 'printf x; cat y')"

# IR8 (C4): parseFailure — unclosed-quote commands set the TOP-LEVEL parse().parseFailure
# to true (segments comes back empty, so segments[0].parseFailure is undefined — the
# whole-parse flag is the one that carries the signal). EXISTING behavior → PASS now.
# IR8b control: a well-formed command has parseFailure false.
echo "--- IR8 (C4): parse().parseFailure on unclosed quote (PASS now) ---"
assert_eq "IR8a unclosed quote parseFailure" 'true'  "$(ir_parsefailure "printf '\''x")"
assert_eq "IR8b well-formed parseFailure"    'false' "$(ir_parsefailure 'printf x > /tmp/foo')"

# IR_MF1 (C5): buildSegmentIR malformed-quote pin — a bare unclosed single quote at
# command start still yields parseFailure=true (fail-closed at the parse boundary).
# EXISTING behavior → PASS now; the migration's additive fields must not regress it.
echo "--- IR_MF1 (C5): buildSegmentIR parseFailure on unclosed quote (PASS now) ---"
assert_eq "IR_MF1 unclosed quote parseFailure (PASS now)" 'true' "$(ir_parsefailure "'\''unclosed")"

# ---------------------------------------------------------------------------
# IR.cmd0 (C4): cmd0Raw field coverage — table-driven cases via ir_field bridge.
# cmd0Raw is the raw form of cmd0 (pre-strip, pre-quote). For simple unquoted tokens
# cmd0Raw == cmd0. For env-prefix commands cmd0Raw carries the first token (the
# assignment). PASS now (cmd0Raw is emitted by buildSegmentIR in the current impl).
# name^cmd^want
# ---------------------------------------------------------------------------
echo "--- IR.cmd0Raw (C4): cmd0Raw field table-driven cases (PASS now) ---"
while IFS='^' read -r ir_name ir_cmd ir_want; do
  [ -z "$ir_name" ] && continue
  assert_eq "$ir_name" "$ir_want" "$(ir_field "$ir_cmd" cmd0Raw)"
done <<'IR_CMD0_TABLE'
IR.cmd0a cp unquoted^cp src dst^"cp"
IR.cmd0b env-prefix A=1 — cmd0Raw is the assignment^A=1 cp src dst^"A=1"
IR.cmd0c cat with redirect^cat > /dev/null^"cat"
IR.cmd0d tee^tee out.txt^"tee"
IR_CMD0_TABLE

# ===========================================================================
# Section E: expandRawToken (NEW — pre-impl, EXPECTED TO FAIL)
# Determines quote context from the RAW form and expands accordingly.
# ===========================================================================
echo "=== Section E: expandRawToken (NEW; expected FAIL pre-impl) ==="
assert_eq "E1 SQ literal no expand"          '"$HOME/foo"'                       "$(expand_raw "'\$HOME/foo'")"
assert_eq "E2 DQ env plans path expanded"    "\"$EXP_HOME_PLANS\""               "$(expand_raw '"$HOME/.workflow-plans/f.json"')"
assert_eq "E3 unquoted tilde expanded"       "\"$EXP_HOME_FOO_TXT\""             "$(expand_raw '~/foo.txt')"
assert_eq "E4 cmd-subst null (fail-closed)"  'null'                              "$(expand_raw '$(cmd)')"
assert_eq "E5 ANSI-C quoting null"           'null'                              "$(expand_raw "\$'literal'")"
# E6 (C4): partially-quoted token — DQ prefix + unquoted suffix ("$HOME"/foo) is NOT
# a simple double-quote form (does not end in "), so it falls to the mixed-token
# branch → null (conservative fail-closed per expandRawToken rule 6). NEW; FAIL pre-impl.
assert_eq "E6 mixed-DQ prefix → null (NEW)"  'null'                              "$(expand_raw '"$HOME"/foo')"
# E7: backtick substitution → null (fail-closed, same as \$(cmd)). PASS now (backtick
# check is in the first guard of expandRawToken, covered by existing infra).
assert_eq "E7 backtick subst null (fail-closed)" 'null'                          "$(expand_raw '`cmd`')"

# ===========================================================================
# Section R: extractRedirectTargets string API — fix-793 Cases 1-5 preservation.
# EXISTING infrastructure: expected to PASS NOW and after migration (regression pins).
# ===========================================================================
echo "=== Section R: extractRedirectTargets string API (existing infra; PASS now) ==="
assert_eq "R1 unquoted > /tmp/foo"           '["/tmp/foo"]'                                 "$(call_redirect 'printf x > /tmp/foo')"
assert_eq "R2 DQ env plans path expanded"    "[\"$EXP_HOME_PLANS\"]"                        "$(call_redirect 'printf x > "$HOME/.workflow-plans/f.json"')"
assert_eq "R3 SQ literal preserved (Case 5)" '["$HOME/foo"]'                                "$(call_redirect "printf x > '\$HOME/foo'")"
assert_eq "R4 append >> captured"            '["/tmp/foo"]'                                 "$(call_redirect 'printf x >> /tmp/foo')"
assert_eq "R5 no redirect"                   '[]'                                           "$(call_redirect 'printf x')"
# C6 redirect edge cases (string API, PASS now):
assert_eq "R6 attached >/tmp/x"              '["/tmp/x"]'                                   "$(call_redirect 'printf x >/tmp/x')"
assert_eq "R7 2>> DQ HOME target"            "[\"$HOME_DIR/x\"]"                            "$(call_redirect 'printf x 2>>"$HOME/x"')"
assert_eq "R8 empty redirect target"         '[]'                                          "$(call_redirect 'printf x > ')"
assert_eq "R9 multi-redirect segment"        '["/tmp/a","/tmp/b"]'                          "$(call_redirect 'printf x > /tmp/a 2> /tmp/b')"
# C7 security negatives (string API, PASS now — fail-closed → null):
assert_eq "R10 cmd-subst target null"        'null'                                         "$(call_redirect 'printf x > $(cat /etc/passwd)')"
assert_eq "R11 traversal unresolvable null"  'null'                                         "$(call_redirect 'printf x > $UNSET_XYZ_1295/../../etc/passwd')"
# C1 read-only redirect pins (PASS now): `<` and `<<<` must NOT appear in write
# targets. extractRedirectTargets filters by write ops (>, >>) only.
assert_eq "R12 read redirect < no target (PASS now)"      '[]'                             "$(call_redirect 'cat < ~/.bashrc')"
assert_eq "R13 herestring <<< no target (PASS now)"       '[]'                             "$(call_redirect 'cat <<< hello')"

# ===========================================================================
# Section R2: extractRedirectTargets IR API + expandStaticShellTokens pin.
# (a) IR form: build SegmentIR via parse(cmd).segments[<redir>], call with IR.
#     NEW API — expected to FAIL pre-impl (string-only extractor → ERROR:not-ir-api).
# (b) expandStaticShellTokens direct pin — EXISTING infra, PASS now.
# ===========================================================================
echo "=== Section R2: extractRedirectTargets IR API (NEW; FAIL) + expandStaticShellTokens pin (PASS) ==="
assert_eq "R2a IR-form unquoted target"      '["/tmp/foo"]'                                 "$(call_redirect_ir 'printf x > /tmp/foo')"
assert_eq "R2b IR-form DQ env plans path"    "[\"$EXP_HOME_PLANS\"]"                        "$(call_redirect_ir 'printf x > "$HOME/.workflow-plans/f.json"')"
# expandStaticShellTokens behavior pinned directly (EXISTING infra; PASS now):
assert_eq "R2c expandStatic DQ HOME"         "\"$HOME_DIR/x\""                              "$(call_expand_static '$HOME/x' double)"
assert_eq "R2d expandStatic unquoted tilde"  "\"$EXP_HOME_FOO_TXT\""                        "$(call_expand_static '~/foo.txt' unquoted)"
assert_eq "R2e expandStatic SQ ctx no-tilde" '"~/foo.txt"'                                  "$(call_expand_static '~/foo.txt' double)"
assert_eq "R2f expandStatic unresolvable null" 'null'                                       "$(call_expand_static '$UNSET_XYZ_1295/x' unquoted)"

# ===========================================================================
# Section C: collectWriteTargetsFromSegments + verb sets (NEW — pre-impl, FAIL)
# SHELL_CONFIG_VERB_SET = {redirect,tee,pwsh,cp,mv} (NO rm). FULL_VERB_SET adds rm.
# ===========================================================================
echo "=== Section C: collectWriteTargetsFromSegments + verb sets (NEW; expected FAIL pre-impl) ==="
assert_eq "C1 SHELL_CONFIG excludes rm"      "false" "$(has_verb SHELL_CONFIG_VERB_SET rm)"
assert_eq "C2 FULL includes rm"              "true"  "$(has_verb FULL_VERB_SET rm)"
assert_eq "C3 piped tee captured (#1069)"    '["/tmp/foo"]' "$(collect_targets 'echo hello | tee /tmp/foo | cat' SHELL_CONFIG_VERB_SET)"

# C4 — FULL_VERB_SET captures rm; SHELL_CONFIG_VERB_SET must NOT (rm excluded).
# The verb set is the sole switch between "shell-config guard" and "full write scan":
# the SAME command must yield the rm target under FULL and nothing under SHELL_CONFIG.
assert_eq "C4a FULL captures rm target"      '["/tmp/foo"]' "$(collect_targets 'rm /tmp/foo' FULL_VERB_SET)"
assert_eq "C4b SHELL_CONFIG excludes rm"     'null'         "$(collect_targets 'rm /tmp/foo' SHELL_CONFIG_VERB_SET)"

# C5 (resolveEffectiveCommand/argv routing) — env-prefixed verbs resolve through
# the collector. A=1 must not derail verb detection; the env-prefix value must feed
# cp/mv destination expansion the same way the string extractor does.
assert_eq "C5a env-prefix tee target"        '["/tmp/foo"]' "$(collect_targets 'A=1 tee /tmp/foo' SHELL_CONFIG_VERB_SET)"
assert_eq "C5b env-prefix cp dest expanded"  '["out/dest"]' "$(collect_targets 'D=out cp src $D/dest' SHELL_CONFIG_VERB_SET)"
# C1 read-only redirect IR path (NEW; FAIL pre-impl): read redirects must NOT
# produce write targets when routed through collectWriteTargetsFromSegments.
# FAIL pre-impl because collectWriteTargetsFromSegments is not yet exported; post-impl
# must return null (not a path) to ensure `<`/`<<<` are invisible to write guards.
assert_eq "C6 read redirect < not captured (NEW; FAIL pre-impl)" 'null' "$(collect_targets 'cat < ~/.bashrc' SHELL_CONFIG_VERB_SET)"
assert_eq "C7 herestring <<< not captured (NEW; FAIL pre-impl)"  'null' "$(collect_targets 'cat <<< hello' SHELL_CONFIG_VERB_SET)"

# C2 env-prefix routing completeness (NEW; FAIL pre-impl): collector must route
# env-prefix mv and pwsh the same way as tee (C5a) and cp (C5b).
assert_eq "C8 env-prefix mv dest expanded (NEW; FAIL pre-impl)" '["out/dest"]' "$(collect_targets 'D=out mv src $D/dest' SHELL_CONFIG_VERB_SET)"
assert_eq "C9 env-prefix pwsh Set-Content (NEW; FAIL pre-impl)" '["/tmp/foo"]'  "$(collect_targets 'A=1 Set-Content -Path /tmp/foo' SHELL_CONFIG_VERB_SET)"

# C10: process substitution in redirect target → fail-closed → parseFailure=true.
# collectWriteTargetsFromSegments sees a null from extractRedirectTargets and sets
# parseFailure. PASS now (extractRedirectTargets already returns null on cmd-subst).
assert_eq "C10 cmd-subst redirect → parseFailure true (PASS now)" 'true' "$(collect_parsefailure 'cmd > $(evil)')"
# C11: normal tee command → parseFailure=false (control case).
assert_eq "C11 tee normal → parseFailure false (PASS now)" 'false' "$(collect_parsefailure 'tee out.txt')"

# ===========================================================================
# Section D: #1069 direct-caller regression guard (NEW routing — pre-impl, FAIL)
#
# L2 GAP (documented per C3 reviewer note): these cases call
# collectWriteTargetsFromSegments DIRECTLY — they validate the segment-scanning
# HELPER in isolation. They do NOT exercise the real callers
# (hooks/enforce-worktree/block-shell-config.js and siblings) that must route
# every segment through this helper. If a caller failed to pass all segments,
# these tests would still PASS. Actual caller wiring (PreToolUse hook fires,
# full command flows through the enforce-worktree allow-chain into the helper)
# is L3 (hook-registration) and is covered at the WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.
# ===========================================================================
echo "=== Section D: #1069 direct-caller regression guard (NEW routing; expected FAIL pre-impl) ==="
assert_eq "D1 non-first-seg tee captured"    '["/tmp/foo"]' "$(collect_targets 'cat x | tee /tmp/foo' SHELL_CONFIG_VERB_SET)"

# C2 — #1069 multi-write-verb pipelines: EVERY writing segment contributes its
# target, in pipeline order. One tee-only case was insufficient; these span the
# tee/cp+mv/redirect verb families to prove the collector unions across segments.
# Delimiter is ^ (not |) because these commands CONTAIN pipes.
# name^command^verb-set^want
while IFS='^' read -r d_name d_cmd d_set d_want; do
  [ -z "$d_name" ] && continue
  assert_eq "$d_name" "$d_want" "$(collect_targets "$d_cmd" "$d_set")"
done <<'D_TABLE'
D2 dual tee both targets^tee /tmp/a | tee /tmp/b^SHELL_CONFIG_VERB_SET^["/tmp/a","/tmp/b"]
D3 cp then mv both dests^cp a /tmp/dest | mv b /tmp/dest2^SHELL_CONFIG_VERB_SET^["/tmp/dest","/tmp/dest2"]
D4 dual redirect both targets^printf x > /tmp/a | printf y > /tmp/b^SHELL_CONFIG_VERB_SET^["/tmp/a","/tmp/b"]
D_TABLE

# ===========================================================================
# Section BL: block-*.js direct-caller integration (C1) — L2 subprocess, PASS now.
#
# Coverage: the 3 in-scope callers (block-shell-config / block-history-direct /
# block-memory-direct) are process-exit hook scripts with NO exported function, so
# the only L2-viable seam is spawning each as a subprocess with a PreToolUse Bash
# event on stdin and reading its {decision} (call_hook bridge). These assert the
# END-TO-END caller decision for a piped later-segment write to a protected target
# (block) plus a control non-protected case (approve).
#
# Why PASS pre-impl (not FAIL): the string-API extractors already scan the whole
# command, so a non-first-segment tee/redirect/cp to a protected path is caught
# TODAY. These are therefore MIGRATION REGRESSION PINS — the IR/per-segment routing
# refactor is additive and MUST keep every one of these blocking. They are the
# caller-level counterpart to Section D's isolated collectWriteTargetsFromSegments
# checks (which validate the helper but cannot prove the callers invoke it).
#
# L3 gap (NOT covered here): real PreToolUse registration + firing inside a live
# claude session; the full enforce-worktree allow-chain feeding the command in.
# That remains the dispatcher-header L3 gap (hook-registration), checked at the
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh.
# ===========================================================================
echo "=== Section BL: block-*.js direct-caller integration (C1; L2 subprocess; PASS now) ==="
# Delimiter is ^ (not |) because these commands CONTAIN pipes.
# name^hook^command^want-decision
while IFS='^' read -r bl_name bl_hook bl_cmd bl_want; do
  [ -z "$bl_name" ] && continue
  assert_eq "$bl_name" "$bl_want" "$(call_hook "$bl_hook" "$bl_cmd")"
done <<'BL_TABLE'
BL1 shell-config block piped redirect^block-shell-config.js^cat > ~/.bashrc | grep x^block
BL2 shell-config block piped tee non-last^block-shell-config.js^echo hi | tee ~/.bashrc | cat^block
BL3 shell-config control approve /tmp^block-shell-config.js^echo hi | tee /tmp/foo | cat^approve
BL4 history block piped redirect^block-history-direct.js^echo hi | cat > docs/history.md^block
BL5 history control approve /tmp^block-history-direct.js^echo hi > /tmp/x^approve
BL8 shell-config block piped cp^block-shell-config.js^cat x | cp src ~/.bashrc^block
BL9 shell-config block piped mv^block-shell-config.js^cat x | mv src ~/.bashrc^block
BL10 shell-config control cp /tmp approve^block-shell-config.js^cat x | cp src /tmp/foo^approve
BL11 history block piped cp^block-history-direct.js^cat x | cp src docs/history.md^block
BL_TABLE
# BL6/BL7: 3rd caller (block-memory-direct). Memory dir is homedir-relative, so the
# path is built from HOME_DIR (computed in lib.sh) rather than the literal heredoc.
assert_eq "BL6 memory block piped redirect" "block"   "$(call_hook block-memory-direct.js "echo hi | cat > $HOME_DIR/.claude/projects/c--git-agents/memory/foo.md")"
assert_eq "BL7 memory control approve /tmp" "approve" "$(call_hook block-memory-direct.js 'echo hi > /tmp/x')"

# BL12-BL14 (C6): pwsh write-cmdlet in a NON-FIRST pipeline segment.
# FINDING: all three block-*.js hooks handle pwsh write cmdlets via
# extractPwshWriteTargets, but that extractor only sees the FIRST pipeline fragment —
# for `echo x | Set-Content -Path ~/.bashrc` it returns null, so the hooks currently
# APPROVE (verified: non-piped `Set-Content -Path ~/.bashrc` blocks; the piped form
# does not). Per-segment IR routing must fix this so the piped write blocks. These are
# NEW (FAIL pre-impl) — kept OUT of the PASS-now BL table and asserted directly.
# BL15/BL16 controls: the non-piped write blocks (PASS now) / a /tmp piped write approves.
echo "--- BL C6: pwsh write-cmdlet in non-first pipeline segment (NEW; FAIL pre-impl) ---"
assert_eq "BL12 shell-config block piped pwsh (NEW)"  "block"   "$(call_hook block-shell-config.js 'echo x | Set-Content -Path ~/.bashrc')"
assert_eq "BL13 history block piped pwsh (NEW)"       "block"   "$(call_hook block-history-direct.js 'echo x | Set-Content -Path docs/history.md')"
assert_eq "BL14 memory block piped pwsh (NEW)"        "block"   "$(call_hook block-memory-direct.js "echo x | Set-Content -Path $HOME_DIR/.claude/projects/c--git-agents/memory/foo.md")"
assert_eq "BL15 shell-config non-piped pwsh (PASS now)" "block" "$(call_hook block-shell-config.js 'Set-Content -Path ~/.bashrc -Value x')"
assert_eq "BL16 shell-config piped pwsh /tmp control"   "approve" "$(call_hook block-shell-config.js 'echo x | Set-Content -Path /tmp/foo')"

# BL17-BL18 (C1): read-only redirects must approve even on protected paths.
# `<` and `<<<` are read ops — hooks must treat them as non-writes (PASS now).
assert_eq "BL17 shell-config approve read redirect (PASS now)" "approve" "$(call_hook block-shell-config.js 'cat < ~/.bashrc')"
assert_eq "BL18 shell-config approve herestring (PASS now)"    "approve" "$(call_hook block-shell-config.js 'cat <<< hello')"

# BL19-BL27 (C4): fail-open on malformed hook input — each block-*.js must return
# {decision:"approve"} (not throw) on unparseable JSON, missing tool_input.command,
# or non-string command. These pin the fail-open guard at the direct-caller layer
# across all 3 hooks × 3 bad-input scenarios (PASS now).
echo "--- BL C4: fail-open on bad hook input (PASS now) ---"
assert_eq "BL19 shell-config approve malformed JSON"      "approve" "$(call_hook_raw block-shell-config.js 'NOT_JSON_{')"
assert_eq "BL20 shell-config approve missing command"     "approve" "$(call_hook_raw block-shell-config.js '{"tool_name":"Bash","tool_input":{}}')"
assert_eq "BL21 shell-config approve non-string command"  "approve" "$(call_hook_raw block-shell-config.js '{"tool_name":"Bash","tool_input":{"command":42}}')"
assert_eq "BL22 history approve malformed JSON"           "approve" "$(call_hook_raw block-history-direct.js 'NOT_JSON_{')"
assert_eq "BL23 history approve missing command"          "approve" "$(call_hook_raw block-history-direct.js '{"tool_name":"Bash","tool_input":{}}')"
assert_eq "BL24 history approve non-string command"       "approve" "$(call_hook_raw block-history-direct.js '{"tool_name":"Bash","tool_input":{"command":42}}')"
assert_eq "BL25 memory approve malformed JSON"            "approve" "$(call_hook_raw block-memory-direct.js 'NOT_JSON_{')"
assert_eq "BL26 memory approve missing command"           "approve" "$(call_hook_raw block-memory-direct.js '{"tool_name":"Bash","tool_input":{}}')"
assert_eq "BL27 memory approve non-string command"        "approve" "$(call_hook_raw block-memory-direct.js '{"tool_name":"Bash","tool_input":{"command":42}}')"

# BL28-BL31 (C4): security — blocked hook output must not echo command content.
# Verifies that output JSON contains ONLY expected keys (no "command" echo-back).
# Block path: {decision, reason}; approve path: {decision} only.
echo "--- BL C4 security: hook output keys (PASS now) ---"
assert_eq "BL28 shell-config block output keys"  "decision,reason" "$(call_hook_output_keys block-shell-config.js 'cat > ~/.bashrc')"
assert_eq "BL29 history block output keys"       "decision,reason" "$(call_hook_output_keys block-history-direct.js 'echo x > docs/history.md')"
assert_eq "BL30 memory block output keys"        "decision,reason" "$(call_hook_output_keys block-memory-direct.js "echo x > $HOME_DIR/.claude/projects/c--git-agents/memory/foo.md")"
assert_eq "BL31 shell-config approve output keys" "decision"       "$(call_hook_output_keys block-shell-config.js 'echo x')"

# ===========================================================================
# Section X: collectWriteTargetsFromSegments edge cases (C8) (NEW — FAIL pre-impl)
# ===========================================================================
echo "=== Section X: collector edge cases (NEW; expected FAIL pre-impl) ==="
# X1: empty segments array → no targets (null, empty array, or ERROR pre-impl).
assert_eq "X1 empty segments → no targets"   'null' "$(collect_targets_segs SHELL_CONFIG_VERB_SET '[]')"
# X2: single non-write segment (plain read) → no targets.
assert_eq "X2 single non-write segment"      'null' "$(collect_targets 'cat somefile' SHELL_CONFIG_VERB_SET)"
# X3 (C7): two segments writing the SAME path. The collector is a guard feeding
# targets.some(isProtected), so preserving the duplicate (no dedup) is the safe,
# order-stable post-impl behavior — one hit still trips the guard. Pinned as the
# expected post-impl shape (FAIL pre-impl); if the implementation dedups instead,
# this pin is the checkpoint that surfaces the decision for review.
assert_eq "X3 duplicate path preserved"      '["/tmp/dup","/tmp/dup"]' "$(collect_targets 'tee /tmp/dup | tee /tmp/dup' SHELL_CONFIG_VERB_SET)"

# ===========================================================================
# Section H: tryResolveEnvUnderPlansDir traversal boundary (helpers.js).
# PASS now — the traversal guard is existing infra.
# Uses the already-exported WORKFLOW_PLANS_DIR (set in lib.sh to $HOME/.workflow-plans)
# so no MSYS path-conversion issues from inline env-var prefix on Windows.
# ===========================================================================
echo "=== Section H: tryResolveEnvUnderPlansDir boundary cases (PASS now) ==="
# Compute expected H1 path via node (same as lib.sh shared-expansion pattern).
H1_EXPECTED="$( ( cd "$WORKTREE" && node -e '
  process.stdout.write(process.env.WORKFLOW_PLANS_DIR + "/f.json");
' ) 2>/dev/null )"
# H1: WORKFLOW_PLANS_DIR var itself points into plans dir → resolved path.
H1_RESULT="$(try_resolve_plans WORKFLOW_PLANS_DIR /f.json)"
assert_eq "H1 plans-dir var resolves to path (PASS now)" "$H1_EXPECTED" "$H1_RESULT"
# H2: traversal suffix /../etc/passwd → null (path.resolve escapes plans-dir).
H2_RESULT="$(try_resolve_plans WORKFLOW_PLANS_DIR /../etc/passwd)"
assert_eq "H2 traversal blocked → null (PASS now)" 'null' "$H2_RESULT"
# H3: unset env var → null (fail-closed on missing value).
assert_eq "H3 unset var → null (PASS now)" 'null' "$(try_resolve_plans NONEXISTENT_VAR_XYZ_1295 /f.json)"

exit "$FAIL"
