# ════════════════════════════════════════════════════════════════════
case_begin "control-dir-bash-blocked" "hooks/block-clearance-token-write/placement-guard.js"

CTL="$WFN/$SID.control"
expect_block "b-redirect"    "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "echo x > $CTL/detail-plan-round-number.txt")")")"
expect_block "b-tee"         "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "echo x | tee $CTL/detail-plan-round-number.txt")")")"
expect_block "b-touch"       "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "touch $CTL/detail-plan-terminal.txt")")")"
expect_block "b-rm"          "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "rm -f $CTL/detail-plan-terminal.txt")")")"
expect_block "b-mv-to-bak"   "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "mv $CTL/x.txt $CTL/x.bak")")")"
expect_block "b-mv-from-bak" "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "mv $CTL/x.bak $CTL/x.txt")")")"
expect_block "b-move-item"   "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "Move-Item $CTL/x.txt $CTL/y.txt")")")"
expect_block "b-remove-item" "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "Remove-Item $CTL/detail-plan-terminal.txt")")")"
expect_block "b-Write-ctl"   "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Write "$CTL/worker-x-1.json")")")"
expect_block "b-Edit-ctl"    "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Edit  "$CTL/detail-risk-signal.txt")")")"
expect_block "b-sid-json-1814" "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Write "$WFN/$SID.json")")")"

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "control-dir-read-allowed" "hooks/block-clearance-token-write/placement-guard.js"

CTL="$WFN/$SID.control"
expect_approve "b-cat"      "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "cat $CTL/detail-plan-round-number.txt")")")"
expect_approve "b-Read-ctl" "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Read "$CTL/detail-plan-round-number.txt")")")"

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "plans-blocked" "hooks/block-clearance-token-write/placement-guard.js"

# (c) Control and unregistered kinds in PLANS_DIR must be blocked.
# Expand SID values into local vars to keep the while-loop body simple.
C1="$SID-security-code-terminal.txt"
C2="$SID-test-review-concern-carrier.md"
C3="$SID-foo.md"
C4="$SID-worker-x-1.json"
C5="$SID-detail-risk-signal.txt"
C6="$DATE_SID-detail-plan-terminal.txt"
C7="$DERIVED_SID-test-review-round-number.txt"

for bn in "$C1" "$C2" "$C3" "$C4" "$C5" "$C6" "$C7"; do
    expect_block "c-block $bn" "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Write "$PLDN/$bn")")")"
    expect_absent "c-block $bn left no file" "$WORKFLOW_PLANS_DIR/$bn"
done
# The Bash face of the same rule, spelled through the plans-dir variable.
expect_block "c-block bash-plansvar-control" \
    "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "echo x > \${WORKFLOW_PLANS_DIR}/$SID-security-code-terminal.txt")")")"
expect_block "c-block bash-plansvar-unregistered" \
    "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "echo x > \$WORKFLOW_PLANS_DIR/$SID-foo.md")")")"
expect_absent "c-block bash-plansvar-unregistered left no file" "$WORKFLOW_PLANS_DIR/$SID-foo.md"

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "plans-allowed" "hooks/block-clearance-token-write/placement-guard.js"

# (c) Artifact and note kinds in PLANS_DIR must be allowed.
A1="$SID-detail.md"
A2="$SID-worker-x-1.draft.json"
A3="$SID-note-x.md"
A4="$SID-sweep-issues-survivors.tsv"
A5="some-random-file.txt"

for bn in "$A1" "$A2" "$A3" "$A4" "$A5"; do
    expect_approve "c-allow $bn" "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Write "$PLDN/$bn")")")"
done

# Bash write to ${WORKFLOW_PLANS_DIR:-default}/<sid>-decisions.tsv must allow
DECISIONS_CMD="echo x > \${WORKFLOW_PLANS_DIR:-$WORKFLOW_PLANS_DIR}/$SID-sweep-issues-decisions.tsv"
expect_approve "c-allow bash-decisions-tsv" "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "$DECISIONS_CMD")")")"
# Sanctioned-artifact counterpart of c-block bash-plansvar-control.
expect_approve "c-allow bash-plansvar-artifact" \
    "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "echo x > \${WORKFLOW_PLANS_DIR}/$SID-detail.md")")")"

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "workflow-off-bypasses" "hooks/block-clearance-token-write/placement-guard.js"

# WORKFLOW=off: (b)(c) allowed; (a) .off-clearance still blocked.
touch "$WORKFLOW_STATE_DIR/$SID.workflow-off"
CTL="$WFN/$SID.control"

expect_approve "wf-off b-ctl-redirect"  "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "echo x > $CTL/detail-plan-terminal.txt")")")"
expect_approve "wf-off c-control-kind"  "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Write "$PLDN/$SID-security-code-terminal.txt")")")"
expect_block   "wf-off a-off-clearance" "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Write "$WFN/$SID.off-clearance")")")"

rm -f "$WORKFLOW_STATE_DIR/$SID.workflow-off"

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "alias-forms-blocked" "hooks/block-clearance-token-write/placement-guard.js"

# Alias forms for control dir must be blocked; each has a sanctioned counterpart.
fake_home_enter

while IFS='|' read -r name want cmd; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name// /}"; want="${want// /}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
    cmd="${cmd//__SID__/$SID}"
    verdict="$(local_classify "$(local_run_hook "$WFNA" "$(mk_bash_in "$cmd")")")"
    if [ "$want" = "block" ]; then expect_block "$name" "$verdict"; else expect_approve "$name" "$verdict"; fi
done <<'TABLE'
alias-tilde-ctl          | block   | echo x > ~/.claude/projects/workflow/__SID__.control/x
alias-home-ctl           | block   | echo x > $HOME/.claude/projects/workflow/__SID__.control/x
alias-home-brace-ctl     | block   | echo x > ${HOME}/.claude/projects/workflow/__SID__.control/x
alias-cwdvar-ctl         | block   | echo x > ${WORKFLOW_STATE_DIR}/__SID__.control/x
alias-cwdvar-plain-ctl   | block   | echo x > $WORKFLOW_STATE_DIR/__SID__.control/x
alias-unresolved-plus    | block   | echo x > ${WORKFLOW_STATE_DIR:+x}/__SID__.control/x
alias-unresolved-suffix  | block   | echo x > ${WORKFLOW_STATE_DIR%/}/__SID__.control/x
alias-unresolved-plans   | block   | echo x > ${WORKFLOW_PLANS_DIR/a/b}/__SID__-detail.md
alias-home-unrelated     | approve | echo x > $HOME/scratch-notes.txt
alias-tilde-unrelated    | approve | echo x > ~/scratch-notes.txt
alias-unknown-var-op     | approve | echo x > ${_CERTAINLY_UNSET_VAR_XYZ99:+x}/notes.txt
TABLE

fake_home_leave

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "sid-json-protected" "hooks/block-clearance-token-write/placement-guard.js"

# <sid>.json (#1814): Edit, Bash delete and a source-only rename out of the
# workflow dir are all writes to the state file, in every path spelling. The
# state file must be byte-identical afterwards; an unrelated JSON is allowed.
fake_home_enter
SJ="$WORKFLOW_STATE_DIR/$SID.json"
SJ_BEFORE="$(sum_of "$SJ")"
OUTSIDE="$(np "$(make_tmp)")"

expect_block "sid-json Edit"          "$(local_classify "$(local_run_hook "$WFNA" "$(mk_file_in Edit "$WFNA/$SID.json")")")"
expect_block "sid-json Write"         "$(local_classify "$(local_run_hook "$WFNA" "$(mk_file_in Write "$WFNA/$SID.json")")")"
while IFS='|' read -r name cmd; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name// /}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}"
    cmd="${cmd//__SID__/$SID}"; cmd="${cmd//__WF__/$WFNA}"; cmd="${cmd//__OUT__/$OUTSIDE}"
    expect_block "$name" "$(local_classify "$(local_run_hook "$WFNA" "$(mk_bash_in "$cmd")")")"
done <<'TABLE'
sid-json-rm-abs          | rm -f __WF__/__SID__.json
sid-json-rm-home         | rm -f $HOME/.claude/projects/workflow/__SID__.json
sid-json-rm-tilde        | rm -f ~/.claude/projects/workflow/__SID__.json
sid-json-rm-cwdvar       | rm -f ${WORKFLOW_STATE_DIR}/__SID__.json
sid-json-remove-item     | Remove-Item $HOME/.claude/projects/workflow/__SID__.json
sid-json-mv-out-abs      | mv __WF__/__SID__.json __OUT__/stash.json
sid-json-mv-out-home     | mv $HOME/.claude/projects/workflow/__SID__.json __OUT__/stash.json
sid-json-mv-out-tilde    | mv ~/.claude/projects/workflow/__SID__.json __OUT__/stash.json
sid-json-mv-out-cwdvar   | mv ${WORKFLOW_STATE_DIR}/__SID__.json __OUT__/stash.json
sid-json-move-item-out   | Move-Item ${WORKFLOW_STATE_DIR}/__SID__.json __OUT__/stash.json
sid-json-redirect-tilde  | echo {} > ~/.claude/projects/workflow/__SID__.json
TABLE
expect_unchanged "sid-json byte-identical after every blocked attempt" "$SJ" "$SJ_BEFORE"
expect_absent "sid-json no stash appeared outside" "$OUTSIDE/stash.json"

expect_approve "unrelated-json Write" "$(local_classify "$(local_run_hook "$WFNA" "$(mk_file_in Write "$OUTSIDE/unrelated.json")")")"
expect_approve "unrelated-json rm"    "$(local_classify "$(local_run_hook "$WFNA" "$(mk_bash_in "rm -f $OUTSIDE/unrelated.json")")")"

rm -rf "$OUTSIDE" 2>/dev/null || true
fake_home_leave

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "control-dir-symlink-escape" "hooks/block-clearance-token-write/placement-guard.js"

# <sid>.control as a symlink to an outside directory: a write through it must be
# refused and nothing may appear in the outside directory.
LSID="aa000000-0000-4000-8000-00000000abcd"
printf '{}' > "$WORKFLOW_STATE_DIR/$LSID.json"
ESC="$(make_tmp)"
MSYS=winsymlinks:nativestrict ln -s "$ESC" "$WORKFLOW_STATE_DIR/$LSID.control" 2>/dev/null || true
if [ ! -L "$WORKFLOW_STATE_DIR/$LSID.control" ]; then
    skip "control-dir-symlink-escape (platform cannot create a symlink here)"
else
    LCTL="$WFN/$LSID.control"
    SAVED_SID="$SID"; SID="$LSID"
    expect_block "symlink Write"    "$(local_classify "$(local_run_hook "$WFN" "$(mk_file_in Write "$LCTL/detail-plan-terminal.txt")")")"
    expect_block "symlink redirect" "$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "echo x > $LCTL/detail-plan-terminal.txt")")")"
    SID="$SAVED_SID"
    expect_absent "symlink escape wrote nothing outside" "$ESC/detail-plan-terminal.txt"
fi
rm -f "$WORKFLOW_STATE_DIR/$LSID.control" 2>/dev/null || true
rm -rf "$ESC" 2>/dev/null || true

case_end
