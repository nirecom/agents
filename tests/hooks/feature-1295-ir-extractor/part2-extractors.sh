#!/usr/bin/env bash
# Part 2 — per-verb extractors + collectBashWriteTargets bridge.
# Sections: T (tee), CM (cp-mv), RM (rm), PW (pwsh), B (collectBashWriteTargets
# AT-DP2 bridge). Each extractor gets BOTH:
#   - string-API cases (EXISTING infra; PASS now)
#   - IR-form cases   (NEW post-migration API; expected FAIL pre-impl)
# plus env-prefix, quoted-$VAR, and fail-closed security negatives.
#
# Sourced-lib contract: $1 = WORKTREE. Exits $FAIL.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# EXP_PLANS_TEE — plans-dir path a quoted $HOME/... token resolves to, computed
# the same way the extractor resolves it (via tryResolveEnvUnderPlansDir path).
EXP_PLANS_TEE="$WORKFLOW_PLANS_DIR/f.json"

# ===========================================================================
# Section T: extractTeeTargets — string API (PASS now) + IR form (FAIL pre-impl).
# ===========================================================================
echo "=== Section T: extractTeeTargets (string PASS now; IR form FAIL pre-impl) ==="
# T-string (EXISTING; PASS now):
assert_eq "T1 normal target"                 '["/tmp/foo"]'  "$(call_tee 'echo hello | tee /tmp/foo')"
assert_eq "T2 -a append flag skipped"        '["/tmp/foo"]'  "$(call_tee 'tee -a /tmp/foo')"
assert_eq "T3 SQ literal \$VAR not expanded" '["$HOME/foo"]' "$(call_tee "tee '\$HOME/foo'")"
assert_eq "T4 DQ env plans path resolved"    "[\"$EXP_PLANS_TEE\"]" "$(call_tee "tee \"\$WORKFLOW_PLANS_DIR/f.json\"")"
# T-security (fail-closed → null):
assert_eq "T5 cmd-subst target null"         'null'          "$(call_tee 'tee $(cat /etc/passwd)')"
assert_eq "T6 unresolvable \$VAR null"       'null'          "$(call_tee 'tee $UNSET_XYZ_1295/x')"
# T-IR (NEW; FAIL pre-impl):
assert_eq "T7 IR-form normal target"         '["/tmp/foo"]'  "$(call_extractor_ir tee extractTeeTargets 'echo hello | tee /tmp/foo' tee)"
# T8-IR: tee IR form with cmd-subst target → null (fail-closed). The IR-form
# extractor must return null (not a path) when the raw target token is $(evil).
# PASS now — extractTeeTargets already guards unresolvable tokens at the IR level.
assert_eq "T8-IR tee IR cmd-subst → null (PASS now)" 'null' "$(call_extractor_ir_null_ok tee extractTeeTargets 'tee $(evil)' tee)"
# T-null (C5): null input → null (fail-closed, not a throw). The string-API extractor
# already guards non-string input and returns null TODAY; the post-migration IR-form
# extractor MUST keep returning null (not throw) on a null/garbage SegmentIR. These are
# therefore fail-closed regression pins (PASS now, must keep passing post-migration) —
# the null-safety counterpart to Section BL's caller pins. Shared T-null/CM-null/RM-null/PW10.
assert_eq "T8 null input → null (PASS now)"  'null'          "$(call_ir_null tee extractTeeTargets)"

# ===========================================================================
# Section CM: extractCpMvDestination — string API (PASS now) + IR form (FAIL).
# NOTE: cp/mv returns a single string destination, NOT an array.
# ===========================================================================
echo "=== Section CM: extractCpMvDestination (string PASS now; IR form FAIL pre-impl) ==="
# CM-string (EXISTING; PASS now):
assert_eq "CM1 cp normal dest"               '"/tmp/dest"'   "$(call_cpmv 'cp src /tmp/dest')"
assert_eq "CM2 mv normal dest"               '"b"'           "$(call_cpmv 'mv a b')"
# Relative env-prefix value (out/dest, not /tmp/dest): the test harness converts
# a leading /tmp in a KEY=/abs argv token to a native path, so a relative value
# keeps the env-prefix substitution assertion stable across platforms.
assert_eq "CM3 env-prefix resolved dest"     '"out/dest"'    "$(call_cpmv 'D=out cp src $D/dest')"
assert_eq "CM4 too-few positionals null"     'null'          "$(call_cpmv 'cp /tmp/dest')"
# CM-security (fail-closed):
assert_eq "CM5 SQ \$VAR dest null"           'null'          "$(call_cpmv "cp src '\$HOME/x'")"
assert_eq "CM6 traversal env-prefix null"    'null'          "$(call_cpmv 'D=../../etc cp src \$D/passwd')"
# CM-IR (NEW; FAIL pre-impl):
assert_eq "CM7 IR-form cp dest"              '"/tmp/dest"'   "$(call_extractor_ir cp-mv extractCpMvDestination 'cp src /tmp/dest' cp)"
# CM8-IR: cp-mv IR form with cmd-subst destination → null (fail-closed). The IR-form
# extractor must return null when the destination token is $(evil).
# PASS now — extractCpMvDestination guards unresolvable tokens.
assert_eq "CM8-IR cp IR cmd-subst dest → null (PASS now)" 'null' "$(call_extractor_ir_null_ok cp-mv extractCpMvDestination 'cp src $(evil)' cp)"
# CM-null (C5): null input → null (fail-closed regression pin, PASS now).
assert_eq "CM8 null input → null (PASS now)" 'null'          "$(call_ir_null cp-mv extractCpMvDestination)"

# ===========================================================================
# Section RM: extractRmTargets — string API (PASS now) + IR form (FAIL).
# ===========================================================================
echo "=== Section RM: extractRmTargets (string PASS now; IR form FAIL pre-impl) ==="
# RM-string (EXISTING; PASS now):
assert_eq "RM1 normal target"                '["/tmp/foo"]'                "$(call_rm 'rm /tmp/foo')"
assert_eq "RM2 -rf bundle two targets"       '["/tmp/foo","/tmp/bar"]'     "$(call_rm 'rm -rf /tmp/foo /tmp/bar')"
assert_eq "RM3 SQ literal target"            '["/tmp/f o"]'                "$(call_rm "rm '/tmp/f o'")"
# RM-security (fail-closed → null):
assert_eq "RM4 cmd-subst null"               'null'                        "$(call_rm 'rm "$(evil)"')"
assert_eq "RM5 unresolvable \$VAR null"      'null'                        "$(call_rm 'rm $UNSET_XYZ_1295/../../etc/passwd')"
# RM-IR (NEW; FAIL pre-impl):
assert_eq "RM6 IR-form normal target"        '["/tmp/foo"]'                "$(call_extractor_ir rm extractRmTargets 'rm /tmp/foo' rm)"
# RM7-IR: rm IR form with cmd-subst argument → null (fail-closed). The IR-form
# extractor must return null when a target token is $(evil).
# PASS now — extractRmTargets guards unresolvable tokens.
assert_eq "RM7-IR rm IR cmd-subst → null (PASS now)" 'null'               "$(call_extractor_ir_null_ok rm extractRmTargets 'rm $(evil)' rm)"
# RM-null (C5): null input → null (fail-closed regression pin, PASS now).
assert_eq "RM7 null input → null (PASS now)" 'null'                        "$(call_ir_null rm extractRmTargets)"

# ===========================================================================
# Section PW: extractPwshWriteTargets — string API (PASS now) + IR form (FAIL).
# ===========================================================================
echo "=== Section PW: extractPwshWriteTargets (string PASS now; IR form FAIL pre-impl) ==="
# PW-string (EXISTING; PASS now):
assert_eq "PW1 Out-File -FilePath"           '["/tmp/foo"]'  "$(call_pwsh 'Out-File -FilePath /tmp/foo')"
assert_eq "PW2 Set-Content positional"       '["/tmp/foo"]'  "$(call_pwsh 'Set-Content /tmp/foo -Value x')"
assert_eq "PW3 Copy-Item dest = 2nd pos"     '["/tmp/dest"]' "$(call_pwsh 'Copy-Item src /tmp/dest')"
# C5 — broaden cmdlet + alias coverage (all supported by pwsh.js extractor; PASS now).
# Add-Content (single-target named -Path), New-Item (single-target -Path),
# Move-Item (dest = 2nd positional, distinct from Copy-Item), and one alias (sc →
# Set-Content) to pin alias-table resolution.
assert_eq "PW6 Add-Content -Path"            '["/tmp/foo"]'  "$(call_pwsh 'Add-Content -Path /tmp/foo -Value x')"
assert_eq "PW7 New-Item -Path"               '["/tmp/foo"]'  "$(call_pwsh 'New-Item -Path /tmp/foo')"
assert_eq "PW8 Move-Item dest = 2nd pos"     '["/tmp/dest"]' "$(call_pwsh 'Move-Item src /tmp/dest')"
assert_eq "PW9 sc alias (Set-Content)"       '["/tmp/foo"]'  "$(call_pwsh 'sc /tmp/foo -Value x')"
# PW-security (fail-closed → null): unquoted $ sigil in a token → tokenizer null.
assert_eq "PW4 unquoted \$VAR null"          'null'          "$(call_pwsh 'Out-File -FilePath $env:X/foo')"
# PW-IR (NEW; FAIL pre-impl):
assert_eq "PW5 IR-form Out-File"             '["/tmp/foo"]'  "$(call_extractor_ir pwsh extractPwshWriteTargets 'Out-File -FilePath /tmp/foo' Out-File)"
# PW6-IR: pwsh IR form with unresolvable token in cmdlet argument → null (fail-closed).
# Set-Content with a $(evil) path token: isUnresolvablePwshTok returns true → null.
# PASS now — extractPwshWriteTargets already guards unresolvable tokens.
assert_eq "PW6-IR pwsh IR cmd-subst path → null (PASS now)" 'null' "$(call_extractor_ir_null_ok pwsh extractPwshWriteTargets 'Set-Content $(evil) val' Set-Content)"
# PW10 (C5): null input → null (fail-closed regression pin, PASS now).
assert_eq "PW10 null input → null (PASS now)" 'null'         "$(call_ir_null pwsh extractPwshWriteTargets)"

# ===========================================================================
# Section B: collectBashWriteTargets — AT-DP2 bridge in bash-write-scope.js.
# EXISTING string-input bridge: MUST be preserved → expected to PASS now.
# Contract: {targets, parseFailure}. string in; parseFailure preserved on
# malformed input; rawText passthrough (targets reflect the raw command).
# ===========================================================================
echo "=== Section B: collectBashWriteTargets AT-DP2 bridge (string API; PASS now) ==="
assert_eq "B1 redirect target captured"      '{"targets":[{"resolveVia":"ancestor","path":"/tmp/foo"}],"parseFailure":false}' "$(call_collect_bash 'printf x > /tmp/foo')"
assert_eq "B2 tee non-first-seg captured"    '{"targets":[{"resolveVia":"ancestor","path":"/tmp/foo"}],"parseFailure":false}' "$(call_collect_bash 'cat x | tee /tmp/foo')"
# B3: malformed (cmd-subst redirect target) → parseFailure preserved, targets null.
assert_eq "B3 parseFailure preserved"        '{"targets":null,"parseFailure":true}'          "$(call_collect_bash 'printf x > $(evil)')"
# B4: no write → targets null, parseFailure false (rawText read but nothing to capture).
assert_eq "B4 no-write → null targets"       '{"targets":null,"parseFailure":false}'         "$(call_collect_bash 'printf x')"
# B5: rawText passthrough — multi-verb raw command yields both targets in order.
assert_eq "B5 rawText passthrough multi"     '{"targets":[{"resolveVia":"ancestor","path":"/tmp/a"},{"resolveVia":"ancestor","path":"/tmp/b"}],"parseFailure":false}' "$(call_collect_bash 'printf x > /tmp/a; cat y | tee /tmp/b')"

# B6-B9 (C1): non-first-segment verb coverage. Section B previously covered only
# redirect + tee non-first-segment. collectBashWriteTargets ALSO captures cp/mv/rm
# destinations from any segment (extractCpMvDestination / extractRmTargets scan the
# whole command). pwsh across a pipe is NOT captured — the extractor sees a broken
# fragment and returns null → parseFailure=true (fail-closed). All PASS now (string
# bridge is existing infra). Delimiter is ^ (not |) because commands CONTAIN pipes.
# name^command^want
while IFS='^' read -r b_name b_cmd b_want; do
  [ -z "$b_name" ] && continue
  assert_eq "$b_name" "$b_want" "$(call_collect_bash "$b_cmd")"
done <<'B_TABLE'
B6 cp non-first-seg captured (PASS now)^cat x | cp src /tmp/dest^{"targets":[{"resolveVia":"ancestor","path":"/tmp/dest"}],"parseFailure":false}
B7 mv non-first-seg captured (PASS now)^cat x | mv src /tmp/dest^{"targets":[{"resolveVia":"ancestor","path":"/tmp/dest"}],"parseFailure":false}
B8 rm non-first-seg captured (PASS now)^cat x | rm /tmp/foo^{"targets":[{"resolveVia":"ancestor","path":"/tmp/foo"}],"parseFailure":false}
B9 pwsh pipeline non-first-seg captured (#1069 fix)^Get-Content x | Out-File -FilePath /tmp/foo^{"targets":[{"resolveVia":"ancestor","path":"/tmp/foo"}],"parseFailure":false}
B_TABLE

exit "$FAIL"
