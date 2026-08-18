#!/usr/bin/env bash
# Tests: skills/, CLAUDE.md, docs/architecture/claude-code/workflow.md, bin/workflow/lib/next-step/verdict.js, bin/workflow/lib/next-step/state-ops.js, bin/workflow/lib/next-step/advance-args.js
# Tags: tl1, static, workflow, skills, argv, scope:issue-specific

# #1947 regression guard: no model-executed instruction may put a bare `complete`
# argv token on a next-step / set-workflow-type command line — the worktree
# isolation classifier reads it as the bash builtin and blocks the whole call.
# Why here and not only at the four observed call sites: the ban is a property of
# the FILE CLASS (everything a model reads and re-types), so the scan is
# recursive and regex-based and catches a re-introduction in any new file.

# Residual gap. The `# TL3 gap` block that skills/_shared/test-design.md mandates
# is for a TL2-instead-of-TL3 choice and does not apply: this file is TL1 by
# nature (it reads repo text; there is no environment to make more real). What
# the scan still cannot see, recorded because silence would read as a coverage
# claim: a command assembled by SHELL CONCATENATION or a heredoc that never puts
# the pieces adjacent (`--status "$st"` with `st` set elsewhere) — indirection
# defeats any textual scan. Backslash continuations are NO LONGER a gap: every
# detector runs over logical lines (see join_continuations). The runtime half of
# the ban is tests/fix-1947-advance-status-flag.sh; the external EnterWorktree
# classifier is out of reach of both (see that file's `# TL3 gap`).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$AGENTS_DIR" || exit 1

CTRL_DIR="$(mktemp -d)"
trap 'rm -rf "$CTRL_DIR"' EXIT

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check_eq() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }

# --- scan scope --------------------------------------------------------------
# Include: every *.md a model reads as instruction. skills/** is NOT narrowed to
# SKILL.md — skills/_shared/** is read the same way. agents/** and rules/** carry
# zero hits today; the guard sits there so the first one is caught on arrival.
INCLUDE_ROOTS="skills agents rules docs"
# Exclude (explicit list, never an implicit glob gap), with the reason inline:
#   docs/history.md, docs/history/** — append-only history; records what the
#     command line WAS at the time, so rewriting it would falsify the record.
#   changelog/**                    — same append-only stream record.
#   .claude/worktrees/**            — other agents' linked-worktree snapshots,
#     not files this repo owns.
# (changelog/ and .claude/ are outside INCLUDE_ROOTS today; they are listed so
# the exclusion survives a future widening of the roots.)
EXCLUDE_PATHS="docs/history.md docs/history changelog .claude/worktrees"

is_excluded() {
  local f="$1" p
  for p in $EXCLUDE_PATHS; do
    case "$f" in "$p"|"$p"/*) return 0 ;; esac
  done
  return 1
}

scan_files() {
  local f
  {
    find $INCLUDE_ROOTS -type f -name '*.md' 2>/dev/null
    echo "CLAUDE.md"
  } | sort | while IFS= read -r f; do
    [ -f "$f" ] || continue
    is_excluded "$f" && continue
    echo "$f"
  done
}

SCAN_LIST="$(scan_files)"

# --- logical-line reconstruction ---------------------------------------------
# The banned thing is the argv the SHELL finally assembles, and a `\` at end of
# line makes the next physical line part of the same command. A physical-line
# grep therefore sees `next-step ...` and `--status complete` as two unrelated
# lines and waves the violation through. Every detector below runs over the
# JOINED text instead, tagged with the line the logical line started on.
join_continuations() {
  awk '
    {
      if (buf == "") { start = NR; cur = $0 } else { cur = buf " " $0 }
      if (cur ~ /\\[[:space:]]*$/) { sub(/[[:space:]]*\\[[:space:]]*$/, "", cur); buf = cur; next }
      print start ": " cur; buf = ""
    }
    END { if (buf != "") print start ": " buf }
  ' "$1"
}

# --- detectors ---------------------------------------------------------------
# S1 needs BOTH halves on one LOGICAL line: a next-step/set-workflow-type
# invocation and a settling status supplied as an option VALUE. The optional
# quote character covers `--status "complete"`, the same argv token once the
# shell is done with it.
RE_CLI='(next-step|set-workflow-type)'
RE_STATUS_VALUE='--status[[:space:]]+["'"'"']?(complete|skipped|pending|<status>)'
# S2: the positional status token on --mark. The step slot is ANY non-space run,
# not a [a-z_<] spelling: `--mark "$step" complete` and `--mark $CURRENT complete`
# produce exactly the banned argv, and a step-name-shaped character class would
# wave both through. The optional quote before `complete` is there for the same
# reason it is on RE_STATUS_VALUE: quoting is source-text decoration the shell
# strips, so `--mark "$step" "complete"` yields the identical banned argv token.
# One optional character only — that keeps the canonical `--complete` (quoted or
# not) out, since the `-` after the quote cannot match. Verified against the repo:
# neither widening adds a hit beyond the legacy call sites this PR migrates.
RE_MARK_TOKEN='--mark[[:space:]]+[^[:space:]]+[[:space:]]+["'"'"']?complete'
# S1c: a `--status` still dangling at end of a LOGICAL line means the value is
# not adjacent by any mechanism this file can follow — reported separately so a
# reader can tell "no violation" from "unreadable".
RE_STATUS_DANGLING='--status[[:space:]]*$'

detect_status_hits() { join_continuations "$1" | grep -E -- "$RE_STATUS_VALUE" | grep -E -- "$RE_CLI" || true; }
detect_mark_hits()   { join_continuations "$1" | grep -E -- "$RE_MARK_TOKEN" || true; }
detect_dangling()    { join_continuations "$1" | grep -E -- "$RE_STATUS_DANGLING" || true; }

scan_with() {
  local fn="$1" f hits acc=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hits="$($fn "$f")"
    [ -n "$hits" ] && acc="$acc
$f: $hits"
  done <<EOF
$SCAN_LIST
EOF
  printf '%s' "$acc"
}

echo "=== S0: the scan scope is non-empty and honours the exclusion list ==="
SCAN_COUNT="$(printf '%s\n' "$SCAN_LIST" | grep -c '.' || true)"
if [ "$SCAN_COUNT" -gt 0 ]; then pass "S0: the include scope resolved $SCAN_COUNT files"
else fail "S0: the include scope resolved no files -- the scan would be vacuous"; fi
if printf '%s\n' "$SCAN_LIST" | grep -qE '^(docs/history|changelog/|\.claude/worktrees/)'; then
  fail "S0b: an excluded append-only path leaked into the scan scope"
else
  pass "S0b: no excluded append-only path is in the scan scope"
fi

echo ""
echo "=== S1/S1c/S2: the ban, applied to logical lines across the whole scope ==="
S1_HITS="$(scan_with detect_status_hits)"
if [ -z "$S1_HITS" ]; then pass "S1: no legacy --status <status> call form remains in scope"
else fail "S1: legacy --status <status> call form still present:$S1_HITS"; fi
S1C_HITS="$(scan_with detect_dangling)"
if [ -z "$S1C_HITS" ]; then pass "S1c: no --status is left without an adjacent value"
else fail "S1c: a --status value is unreachable by the scan, hiding it from S1:$S1C_HITS"; fi
S2_HITS="$(scan_with detect_mark_hits)"
if [ -z "$S2_HITS" ]; then pass "S2: no legacy --mark <step> complete form remains in scope"
else fail "S2: legacy --mark <step> complete form still present:$S2_HITS"; fi

echo ""
echo "=== S3: the detectors are not vacuous (table-driven, single- and multi-line) ==="
# A ban proves nothing unless the same regex fires on a known positive, and it is
# worse than nothing if it also fires on the migrated form. Every row is written
# to a real fixture file and pushed through the SAME detector the scan uses, so
# the control cannot drift away from the production path. `\n` in the content
# column becomes a real newline and `\\` a real backslash (printf %b), which is
# what makes the continuation cases genuinely multi-line.
# Columns: name|detector(status|mark)|expectation(hit|miss)|content
CTRL_N=0
run_detector_matrix() {
  local name det want content f hits
  while IFS='|' read -r name det want content; do
    case "$name" in ''|'#'*) continue ;; esac
    CTRL_N=$((CTRL_N + 1)); f="$CTRL_DIR/ctrl$CTRL_N.md"
    printf '%b\n' "$content" > "$f"
    case "$det" in
      status) hits="$(detect_status_hits "$f")" ;;
      mark)   hits="$(detect_mark_hits "$f")" ;;
      *)      fail "S3/$name: unknown detector [$det]"; continue ;;
    esac
    if [ "$want" = "hit" ]; then
      if [ -n "$hits" ]; then pass "S3/$name: the $det detector fires"
      else fail "S3/$name: the $det detector MISSES the banned form -- it would escape the ban"; fi
    else
      if [ -n "$hits" ]; then fail "S3/$name: the $det detector wrongly fires -- $hits"
      else pass "S3/$name: the $det detector stays silent"; fi
    fi
  done
}

run_detector_matrix <<'MATRIX'
legacy --status complete|status|hit|node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step detail --status complete --next
legacy --status quoted value|status|hit|node bin/workflow/next-step --advance --step detail --status "complete"
legacy --status skipped|status|hit|node bin/workflow/next-step --advance --step run_tests --status skipped
legacy --status placeholder|status|hit|node bin/workflow/next-step --advance --step <step> --status <status> --next
legacy set-workflow-type --status|status|hit|node bin/workflow/set-workflow-type --session X --type wf-code --advance --step workflow_init --status complete
canonical --complete stays clean|status|miss|node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --advance --step detail --complete --next
canonical set-workflow-type stays clean|status|miss|node bin/workflow/set-workflow-type --session X --type wf-code --advance --step workflow_init --complete
--status with no advance CLI on the line|status|miss|some-other-tool --status complete
multiline: CLI line continues into --status complete|status|hit|node bin/workflow/next-step --advance --step detail \\\n  --status complete --next
multiline: --status dangles and the value is on the next line|status|hit|node bin/workflow/next-step --advance --step detail --status \\\n  complete --next
multiline: three-way split still reassembles|status|hit|node bin/workflow/next-step \\\n  --advance --step detail \\\n  --status complete
multiline: canonical form split the same way stays clean|status|miss|node bin/workflow/next-step --advance --step detail \\\n  --complete --next
legacy --mark <step> complete|mark|hit|node bin/workflow/next-step --session $CLAUDE_SESSION_ID --mark <step> complete
legacy --mark quoted step|mark|hit|node bin/workflow/next-step --session "$SID" --mark "$step" complete
legacy --mark interpolated step|mark|hit|node bin/workflow/next-step --mark $CURRENT_STEP complete
legacy --mark double-quoted status token|mark|hit|node bin/workflow/next-step --session "$SID" --mark "$step" "complete"
legacy --mark single-quoted status token|mark|hit|node bin/workflow/next-step --mark "$step" 'complete'
legacy --mark quoted step and quoted status|mark|hit|node bin/workflow/next-step --mark 'outline' 'complete'
canonical quoted --complete is NOT a status token|mark|miss|node bin/workflow/next-step --mark "$step" "--complete"
canonical single-quoted --complete is NOT a status token|mark|miss|node bin/workflow/next-step --mark 'outline' '--complete'
canonical --mark <step> stays clean|mark|miss|node bin/workflow/next-step --session $CLAUDE_SESSION_ID --mark <step>
migrated prose sentence stays clean|mark|miss|`--mark <step>` marks one step complete without touching others
multiline: --mark <step> continues into complete|mark|hit|node bin/workflow/next-step --mark docs \\\n  complete
multiline: --mark continues into <step> complete|mark|hit|node bin/workflow/next-step --mark \\\n  docs complete
adjacent lines with NO continuation are not joined|mark|miss|node bin/workflow/next-step --mark docs\ncomplete
MATRIX

# The exclusion list is load-bearing only if the excluded class really carries
# hits: changelog/2026.md records the legacy --mark form as historical fact.
if [ -f changelog/2026.md ] && [ -n "$(detect_mark_hits changelog/2026.md)" ]; then
  pass "S3e: an excluded append-only file genuinely carries a legacy literal (exclusion is not a no-op)"
else
  fail "S3e: no excluded append-only file carries a legacy literal -- the exclusion list may be stale"
fi

echo ""
echo "=== S4: the migrated call sites carry the NEW form (table-driven) ==="
# Fixed-string pins, symmetric to feature-1644-no-prose-in-advance.sh S1: the ban
# above says what must be gone, these say what must be there. The count column is
# not decoration — make-outline-plan and run-tests each carry the same migrated
# literal TWICE (prose + call), and a bare grep -q would go green after only one
# of each pair was migrated. `1+` means "at least once".
# Columns: file|literal|want(1+ or an exact count)
run_pin_matrix() {
  local f t want got
  while IFS='|' read -r f t want; do
    case "$f" in ''|'#'*) continue ;; esac
    if [ ! -f "$f" ]; then fail "S4: $f exists -- file not found"; continue; fi
    got="$(grep -cF -- "$t" "$f" || true)"
    if [ "$want" = "1+" ]; then
      if [ "$got" -ge 1 ]; then pass "S4: $f carries [$t]"
      else fail "S4: $f does not carry the migrated literal [$t]"; fi
    else
      check_eq "S4: $f carries [$t] exactly $want time(s)" "$want" "$got"
    fi
  done
}

run_pin_matrix <<'MATRIX'
skills/make-detail-plan/SKILL.md|--advance --step detail --complete --next|1+
skills/make-outline-plan/SKILL.md|--advance --step outline --complete --next|2
skills/run-tests/SKILL.md|--advance --step run_tests --skipped --skip-reason "<reason>" --next|1+
skills/run-tests/SKILL.md|--advance --step run_tests --complete --next|2
skills/workflow-init/SKILL.md|--type wf-meta --advance --step workflow_init --complete|1+
skills/workflow-init/SKILL.md|next-step" --advance --step workflow_init --complete|1+
CLAUDE.md|--advance --step <step> --complete|1+
docs/architecture/claude-code/workflow.md|--advance --step run_tests --skipped|1+
docs/architecture/claude-code/workflow.md|**`--mark <step>`**|1+
docs/architecture/claude-code/workflow.md|--mark <step>` marks one step complete|1+
MATRIX

echo ""
echo "=== S5/S9: the CLI-GENERATED command strings carry the new form ==="
# verdict.js NEXT_HINT is a string the model executes verbatim, so a trailing
# `complete` token there re-creates #1947 inside the recovery path itself.
# state-ops.js echoes the form back in its refusal, which teaches the same shape.
# Both are built by `+` concatenation across wrapped source lines, so a physical
# -line grep can neither confirm the new form nor deny the old one. js_effective
# joins the concatenation and collapses `" + expr + "` to a single <X> token, so
# what the assertions see is the RUNTIME sentence, not its source layout.
js_effective() {
  awk '
    {
      if (buf == "") cur = $0; else cur = buf " " $0
      if (cur ~ /\+[[:space:]]*$/) { buf = cur; next }
      print cur; buf = ""
    }
    END { if (buf != "") print buf }
  ' "$1" \
  | sed -E 's/"[[:space:]]*\+[[:space:]]*[A-Za-z_$][A-Za-z0-9_$.()]*[[:space:]]*\+[[:space:]]*"/<X>/g'
}

VERDICT="bin/workflow/lib/next-step/verdict.js"
STATE_OPS="bin/workflow/lib/next-step/state-ops.js"
# Exact sentences, per the plan's Step 5. Substring needles are NOT enough here:
# `--mark docs` is a substring of BOTH `--mark docs complete` and `--mark docs`,
# so a contains-check would stay green against the un-migrated string.
HINT_NEW='Recovery: node <X> --mark <X> (session-global; no cd needed).'
HINT_OLD='--mark <X> complete (session-global'
REFUSE_NEW='next-step: --mark <X> refused — '
REFUSE_OLD='next-step: --mark <X> complete refused'

js_pin() {
  local desc="$1" file="$2" needle="$3" want="$4" eff
  if [ ! -f "$file" ]; then fail "$desc: $file exists -- file not found"; return; fi
  eff="$(js_effective "$file")"
  if printf '%s' "$eff" | grep -qF -- "$needle"; then
    if [ "$want" = "present" ]; then pass "$desc"; else fail "$desc -- [$needle] is still there"; fi
  else
    if [ "$want" = "absent" ]; then pass "$desc"; else fail "$desc -- [$needle] not found in the effective strings"; fi
  fi
}

js_pin "S5: verdict.js builds the exact new recovery sentence" "$VERDICT" "$HINT_NEW" present
js_pin "S5b: verdict.js no longer builds the old ' complete (session-global' sentence" "$VERDICT" "$HINT_OLD" absent
js_pin "S9: state-ops.js refuses with the new '--mark <step> refused' wording" "$STATE_OPS" "$REFUSE_NEW" present
js_pin "S9b: state-ops.js no longer echoes '--mark <step> complete refused'" "$STATE_OPS" "$REFUSE_OLD" absent
# Non-vacuity for the pair above: the same normaliser + the S2 regex must FIRE on
# a synthetic copy of the pre-migration source. Without this, a js_effective that
# silently produced nothing would make every `absent` assertion green forever.
printf '%s\n' '          "Artifact for " + currentStep + " exists. Recovery: node " + ENTRYPOINT_PATH +' \
              '          " --mark " + currentStep + " complete (session-global; no cd needed).";' \
  > "$CTRL_DIR/verdict-old.js"
CTRL_EFF="$(js_effective "$CTRL_DIR/verdict-old.js")"
if printf '%s' "$CTRL_EFF" | grep -qE -- "$RE_MARK_TOKEN"; then
  pass "S5c: the normaliser + S2 regex fire on the pre-migration verdict.js literal (not vacuous)"
else
  fail "S5c: the normaliser produced nothing the S2 regex can see [$CTRL_EFF] -- S5/S9 are vacuous"
fi
if printf '%s' "$CTRL_EFF" | grep -qF -- "$HINT_OLD"; then
  pass "S5d: the HINT_OLD needle matches the pre-migration sentence (needle is real)"
else
  fail "S5d: HINT_OLD [$HINT_OLD] does not match the pre-migration sentence -- S5b is vacuous"
fi
# ...and the whole file, normalised, must carry no `--mark <tok> complete` at all.
if [ -f "$VERDICT" ]; then
  V_HITS="$(js_effective "$VERDICT" | grep -E -- "$RE_MARK_TOKEN" || true)"
  if [ -z "$V_HITS" ]; then pass "S5e: no effective string in verdict.js concatenates a trailing complete onto --mark"
  else fail "S5e: verdict.js still builds '--mark ... complete':$V_HITS"; fi
fi

echo ""
echo "=== S6: VALID_STATUSES.filter is derived in exactly one file under bin/ ==="
S6_FILES="$(grep -rlF -- 'VALID_STATUSES.filter' bin/ 2>/dev/null | sort || true)"
S6_COUNT="$(printf '%s\n' "$S6_FILES" | grep -c '.' || true)"
if [ "$S6_COUNT" = "1" ]; then pass "S6: exactly one derivation site under bin/"
else fail "S6: expected exactly 1 derivation site under bin/, got $S6_COUNT: $(printf '%s' "$S6_FILES" | tr '\n' ' ')"; fi
if [ "$S6_FILES" = "bin/workflow/lib/next-step/advance-args.js" ]; then
  pass "S6b: the single derivation site is advance-args.js"
else
  fail "S6b: the derivation site is not advance-args.js -- got [$S6_FILES]"
fi

echo ""
echo "=== S7: RESERVED_ARGV_FLAGS covers every existing argv branch name ==="
# The status flags are generated from ADVANCE_STATUSES, so a future settling
# status named like an existing flag would silently fall into the shadow of an
# earlier === branch. advance-args.js throws on load; this pins the same
# invariant statically, for the case where nobody runs that CLI.
ARGS_MOD="bin/workflow/lib/next-step/advance-args.js"
if [ ! -f "$ARGS_MOD" ]; then
  fail "S7: $ARGS_MOD exists -- file not found"
  fail "S7b: RESERVED_ARGV_FLAGS does not intersect STATUS_FLAGS -- module missing"
else
  BRANCH_FLAGS="$(grep -hoE 'a === "(-{1,2}[a-z][a-z-]*)"' \
      bin/workflow/lib/next-step/cli.js bin/workflow/set-workflow-type 2>/dev/null \
    | sed -E 's/^a === "//; s/"$//' | sort -u)"
  MISSING=""
  for fl in $BRANCH_FLAGS; do
    grep -qF -- "\"$fl\"" "$ARGS_MOD" || MISSING="$MISSING $fl"
  done
  if [ -z "$MISSING" ]; then pass "S7: RESERVED_ARGV_FLAGS lists every === branch flag of both CLIs"
  else fail "S7: RESERVED_ARGV_FLAGS is missing:$MISSING"; fi

  INTERSECT="$(node -e '
    const m = require("./bin/workflow/lib/next-step/advance-args.js");
    const res = m.RESERVED_ARGV_FLAGS || [];
    const keys = Object.keys(m.STATUS_FLAGS || {});
    process.stdout.write(keys.filter((k) => res.indexOf(k) !== -1).join(","));
  ' 2>&1 || echo "MODULE_LOAD_FAILED")"
  if [ -z "$INTERSECT" ]; then pass "S7b: RESERVED_ARGV_FLAGS and STATUS_FLAGS do not intersect"
  else fail "S7b: status flags collide with reserved argv flags: $INTERSECT"; fi
fi

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
