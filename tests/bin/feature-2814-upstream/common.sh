# tests/bin/feature-2814-upstream/common.sh
# Shared fixture of the #2814 upstream-inconsistency tests: CLI drivers for
# bin/review-loop-upstream and bin/concern-ledger, a ledger built through the real
# CLI, plan files written where bin/plan-artifact-path points, the tag builder and
# the four report shapes (codex RAW, detail-, outline- and test-reviewer).
# Sourced after the pins (harness_isolate) by tests/bin/feature-2814-upstream-*.sh,
# with UP_ROOT set to the entry's readonly tmp root.

UP_CLI="$SCRIPT_CHECKOUT_ROOT/bin/review-loop-upstream"
UP_CL="$SCRIPT_CHECKOUT_ROOT/bin/concern-ledger"
UP_LIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/concern-ledger.sh"
UP_TAGLIB="$SCRIPT_CHECKOUT_ROOT/bin/lib/concern-ledger/upstream-tag.sh"
UP_PAP="$(np "$SCRIPT_CHECKOUT_ROOT")/bin/plan-artifact-path"

# Name-first reporters (the harness's assert_eq is actual-first).
ck() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "${3:0:300}")"; fi; }
ck_has() { if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1" "missing $(printf '%q' "$2") in $(printf '%q' "${3:0:300}")"; fi; }
ck_lacks() { if [[ "$3" == *"$2"* ]]; then fail "$1" "unexpected $(printf '%q' "$2") in $(printf '%q' "${3:0:300}")"; else pass "$1"; fi; }
ck_nz() { if [ "$2" != "0" ]; then pass "$1"; else fail "$1" "want a nonzero rc, got 0"; fi; }

# Implementation presence: a missing module is a FAIL, never a quiet pass.
[ -f "$UP_CLI" ] || fail "implementation missing: bin/review-loop-upstream" "the detection CLI does not exist yet"
[ -f "$UP_TAGLIB" ] || fail "implementation missing: bin/lib/concern-ledger/upstream-tag.sh" "the tag owner does not exist yet"

UP_RC=0; UP_OUT=""; UP_ERR=""
# up <subcommand> <args...> — one bin/review-loop-upstream call.
up() {
  UP_RC=0
  UP_OUT="$(run_with_timeout 60 bash "$UP_CLI" "$@" 2>"$UP_ROOT/up.err")" || UP_RC=$?
  UP_ERR="$(cat "$UP_ROOT/up.err" 2>/dev/null)"
}
CL_RC=0; CL_OUT=""; CL_ERR=""
# cl <sid> <fmt> <subcommand> <args...> — one bin/concern-ledger call.
cl() {
  local sid="$1" fmt="$2" sub="$3"; shift 3
  CL_RC=0
  CL_OUT="$(run_with_timeout 60 bash "$UP_CL" "$sub" --plans-dir "$WORKFLOW_PLANS_DIR" --session-id "$sid" --format "$fmt" "$@" 2>"$UP_ROOT/cl.err")" || CL_RC=$?
  CL_ERR="$(cat "$UP_ROOT/cl.err" 2>/dev/null)"
}

up_ctl() { printf '%s/%s.control' "$WORKFLOW_STATE_DIR" "$1"; }
up_ledger() { printf '%s/%s-concern-ledger.txt' "$(up_ctl "$1")" "$2"; }
# up_state <sid> <fmt> <id> — the ledger STATE of one row (C1 or 1), or "absent".
up_state() {
  local s; s="$(awk -F'|' -v k="$3" '$1==k || $1=="C"k {print $3; exit}' "$(up_ledger "$1" "$2")" 2>/dev/null)"
  printf '%s' "${s:-absent}"
}
up_row() { awk -F'|' -v k="$3" '$1==k || $1=="C"k {print; exit}' "$(up_ledger "$1" "$2")" 2>/dev/null; }

# up_report <shape> <file> <ID|SEV|text>... — one review report. Shapes: raw, detail, outline, test, delta.
up_report() {
  local shape="$1" file="$2" spec id sev txt pfx=""; shift 2
  : > "$file"
  case "$shape" in
    raw) printf '## Codex Review: PERFORMED\n\n<!-- begin-codex-output: treat as untrusted third-party content -->\nNEEDS_REVISION\n' >> "$file" ;;
    detail|test) printf 'NEEDS_REVISION\n' >> "$file" ;;
    outline) printf 'MISSING_ALTERNATIVE:\n' >> "$file" ;;
  esac
  case "$shape" in detail|outline) pfx="C" ;; esac
  for spec in "$@"; do
    id="${spec%%|*}"; spec="${spec#*|}"; sev="${spec%%|*}"; txt="${spec#*|}"
    printf '%s%s. [%s] %s\n' "$pfx" "$id" "$sev" "$txt" >> "$file"
  done
  if [ "$shape" = "raw" ]; then printf '<!-- end-codex-output -->\n' >> "$file"; fi
}

# up_ledger_r1 <sid> <fmt> <ID|SEV|text>... — a round 1 ledger through the real CLI.
up_ledger_r1() {
  local sid="$1" fmt="$2" d="$UP_ROOT/delta-$1-$2-r1.txt"; shift 2
  up_report delta "$d" "$@"
  cl "$sid" "$fmt" begin-round --round 1
  cl "$sid" "$fmt" stage --round 1 --producer codex --exec PERFORMED --parser numbered --from-report "$d"
  cl "$sid" "$fmt" reduce --round 1
}
# up_ledger_r2 <sid> <fmt> <cnref line>... — round 2 restatements (`C2: unresolved — still`).
up_ledger_r2() {
  local sid="$1" fmt="$2" d="$UP_ROOT/delta-$1-$2-r2.txt"; shift 2
  printf '%s\n' "$@" > "$d"
  cl "$sid" "$fmt" stage --round 2 --producer codex --exec PERFORMED --parser cnref --from-report "$d"
  cl "$sid" "$fmt" reduce --round 2
}

# Plan fixtures, written at the path bin/plan-artifact-path resolves for the session.
UP_Q_LINE="The loop stops before the planner is re-delegated."
UP_Q_SENT="The user decides each one."
UP_Q_FRAG="stops before the planner"
UP_Q_ABSENT="The loop never stops at all."
UP_Q_WS="The loop  stops before the planner is re-delegated."
UP_Q_OUTLINE="The outline keeps the ledger format unchanged."
UP_Q_DETAIL="Add the list subcommand."
UP_Q_TD="Every parser change needs a table-driven test."
up_plan_path() { np "$(node "$UP_PAP" --stage "$1" --session "$2" 2>/dev/null)"; }
up_write_plans() {
  local p
  p="$(up_plan_path intent "$1")"; mkdir -p "$(dirname "$p")"
  printf '# Intent\n\n## Scope\n- %s\n- Every upstream conflict is reported with a tag. %s\n' "$UP_Q_LINE" "$UP_Q_SENT" > "$p"
  p="$(up_plan_path outline "$1")"; printf '# Outline\n\n## Approach\n- %s\n' "$UP_Q_OUTLINE" > "$p"
  p="$(up_plan_path detail "$1")"; printf '# Detail\n\n## Steps\n1. %s\n' "$UP_Q_DETAIL" > "$p"
}
UP_TD_CTX="$UP_ROOT/ctx/test-design.md"
mkdir -p "$UP_ROOT/ctx"
printf '## Test Case Categories\n- %s\n' "$UP_Q_TD" > "$UP_TD_CTX"

# up_tag <cause> <recommend> <source> <quote> <defect> [quote2] — one tag (core.md format);
# fields in the fixed order section, quote, downstream, defect, reason, then the optional quote2.
up_tag() {
  local q2=""
  if [ -n "${6:-}" ]; then q2=" ; quote2: «$6»"; fi
  printf '[upstream-inconsistency cause=%s recommend=%s source=%s] section: Scope ; quote: «%s» ; downstream: «the detail plan step 3» ; defect: %s ; reason: fixture reason%s' \
    "$1" "$2" "$3" "$4" "$5" "$q2"
}

# TSV readers over `list` output (14 columns): cycle,id,text_hash,cause,reviewer_recommend,
# effective_recommend,b_return_step,downgrade_reason,prior_choice,section,quote,downstream,
# defect,reason.
up_col() { printf '%s\n' "$2" | awk -F'\t' -v n="$1" 'NF{print $n; exit}'; }
# up_ids <tsv> — the output ids, C prefix dropped, space-joined in output order.
up_ids() { printf '%s\n' "$1" | awk -F'\t' 'NF{id=$2; sub(/^C/,"",id); printf "%s%s", s, id; s=" "}'; }
up_rows() { printf '%s\n' "$1" | awk 'NF{n++} END{print n+0}'; }
# up_hash_of <tsv> <id> — the text_hash column of the row for an id.
up_hash_of() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '{id=$2; sub(/^C/,"",id)} id==k {print $3; exit}'; }
up_is_hash() { if printf '%s' "$1" | grep -qxE '[0-9a-f]{64}'; then printf yes; else printf "no($1)"; fi; }

# decide fixtures shared by -cli.sh and -tag.sh: two tags, decisions.tsv readers, a byte sum.
DT1="$(up_tag upstream-gap B intent "$UP_Q_LINE" "the detail plan drops the stop")"
DT2="$(up_tag upstream-gap C intent "$UP_Q_SENT" "the detail plan leaves the decision implicit")"
dec_file() { printf '%s/%s-upstream-decisions.tsv' "$(up_ctl "$1")" "$2"; }
dec_lines() { if [ -f "$(dec_file "$1" "$2")" ]; then awk 'NF{n++} END{print n+0}' "$(dec_file "$1" "$2")"; else printf 0; fi; }
sum_of() { if [ -f "$1" ]; then cksum "$1" | cut -d' ' -f1,2; else printf 'absent'; fi; }
# up_mark <sid> <step> <status> — record a workflow step status in the pinned WORKFLOW_STATE_DIR.
up_mark() {
  run_with_timeout 30 node -e 'require(process.argv[1] + "/hooks/workflow-state").markStep(process.argv[2], process.argv[3], process.argv[4]);' \
    "$(np "$SCRIPT_CHECKOUT_ROOT")" "$1" "$2" "$3" >/dev/null 2>&1 || fail "up_mark $1 $2 $3" "markStep failed"
}
