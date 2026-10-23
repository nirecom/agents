#!/usr/bin/env bash
# tests/hooks/feature-2631-precommit-size-gate/cases-core.sh — the core verdict bodies of
# tests/hooks/feature-2631-precommit-size-gate.sh (the case markers stay in the entry file).
# Sourced by lane.sh after fixture.sh (new_cfg, stage, run_pc, expect_*). Over HARD blocks, exactly
# HARD passes, an over-HARD HEAD file may only shrink, exempt stream records pass, a changed SSOT
# limit moves the verdict, and odd file names survive the NUL-delimited route.
# Tables are read on fd 3: run_pc's hook must never consume a table row from stdin.

core_case_fixture_premise() {
  local cfg
  cfg="$(new_cfg)"
  stage "$cfg" src/small.js 10
  run_pc "$cfg" "$cfg"
  expect_pass "premise: a 10-line staged .js passes every other gate of the fixture install"
}

core_case_new_file_over_hard_blocks_exactly_hard_passes() {
  local kind path hard cfg
  # kind | path | HARD
  while IFS='|' read -r -u 3 kind path hard; do
    [[ -z "$kind" || "$kind" =~ ^[[:space:]]*# ]] && continue
    cfg="$(new_cfg)"
    stage "$cfg" "$path" $((hard + 1))
    run_pc "$cfg" "$cfg"
    expect_block "$kind: new $path at HARD+1 ($((hard + 1))) blocks" "$path"
    cfg="$(new_cfg)"
    stage "$cfg" "$path" "$hard"
    run_pc "$cfg" "$cfg"
    expect_pass "$kind: new $path at exactly HARD ($hard) passes"
  done 3<<'EOF'
code|src/new.js|500
prompt|rules/x.md|200
docs|docs/x.md|500
EOF
}

core_case_over_hard_head_file_may_shrink_only() {
  local cfg
  cfg="$(new_cfg)"
  stage "$cfg" src/old.js 550
  run_pc "$cfg" "$cfg"
  expect_pass "src/old.js 600 -> 550 (shrink) passes"
  cfg="$(new_cfg)"
  stage "$cfg" src/old.js 600 v2
  run_pc "$cfg" "$cfg"
  expect_block "src/old.js 600 -> 600 (edited, same value) blocks" src/old.js
  cfg="$(new_cfg)"
  stage "$cfg" src/old.js 610
  run_pc "$cfg" "$cfg"
  expect_block "src/old.js 600 -> 610 (grow) blocks" src/old.js
  cfg="$(new_cfg)"
  stage "$cfg" src/other.js 10
  run_pc "$cfg" "$cfg"
  expect_pass "a commit that does not stage the over-HARD src/old.js passes"
}

# Stream records are never split on size; 501 is over the docs HARD and under the history HARD.
core_case_exempt_stream_records_pass() {
  local path cfg
  while IFS='|' read -r -u 3 path; do
    [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
    cfg="$(new_cfg)"
    stage "$cfg" "$path" 501
    run_pc "$cfg" "$cfg"
    expect_pass "exempt $path at 501 lines passes"
  done 3<<'EOF'
docs/history.md
CHANGELOG.md
docs/history/2026.md
changelog/2026.md
docs/_archive/old.md
EOF
}

# A space and non-ASCII letters: the staged list must reach size-check NUL-delimited and unquoted.
CORE_ODD_PATH="src/dir with space/naïve fïle.js"

core_case_odd_file_name() {
  local cfg
  cfg="$(new_cfg)"
  stage "$cfg" "$CORE_ODD_PATH" 501
  run_pc "$cfg" "$cfg"
  expect_block "'$CORE_ODD_PATH' at HARD+1 blocks, named verbatim" "$CORE_ODD_PATH"
  cfg="$(new_cfg)"
  stage "$cfg" "$CORE_ODD_PATH" 10
  run_pc "$cfg" "$cfg"
  expect_pass "'$CORE_ODD_PATH' at 10 lines passes"
}

# core_mutate <warn> <hard> — the install's working-tree SSOT says code <warn>/<hard> until the next new_cfg.
core_mutate() { node "$ROOT/tests/hooks/feature-2631-size-limits/mutate-limits.js" "$CFG_TEMPLATE" code "$1" "$2"; }

core_case_ssot_limit_change_propagates() {
  local cfg
  cfg="$(new_cfg)"
  if core_mutate 50 100; then pass "premise: the install's SSOT says code 50/100"; else fail "premise: the install's SSOT says code 50/100"; fi
  stage "$cfg" src/mid.js 150
  run_pc "$cfg" "$cfg"
  expect_block "lowered HARD 100: a new 150-line src/mid.js blocks" src/mid.js
  cfg="$(new_cfg)"
  stage "$cfg" src/mid.js 150
  run_pc "$cfg" "$cfg"
  expect_pass "control: the repo SSOT passes the same 150-line file"
  cfg="$(new_cfg)"
  if core_mutate 700 900; then pass "premise: the install's SSOT says code 700/900"; else fail "premise: the install's SSOT says code 700/900"; fi
  stage "$cfg" src/new.js 750
  run_pc "$cfg" "$cfg"
  expect_pass "raised HARD 900: a new 750-line src/new.js passes"
  cfg="$(new_cfg)"
  stage "$cfg" src/new.js 750
  run_pc "$cfg" "$cfg"
  expect_block "control: the repo SSOT blocks the same 750-line file" src/new.js
}

core_case_gate_makes_exactly_one_node_call() {
  local n
  if [ ! -f "$GATE" ]; then
    fail "hooks/lib/precommit-size-gate.sh exists" "missing"
  else
    n="$(grep -vE '^[[:space:]]*#' "$GATE" | grep -cE '(^|[^A-Za-z0-9_./-])node([[:space:]]|"|$)')"
    if [ "$n" = 1 ]; then pass "precommit-size-gate.sh contains exactly one node invocation"
    else fail "precommit-size-gate.sh contains exactly one node invocation" "found $n"; fi
  fi
  if grep -q 'precommit-size-gate\.sh' "$ROOT/hooks/pre-commit"; then pass "hooks/pre-commit sources precommit-size-gate.sh"
  else fail "hooks/pre-commit sources precommit-size-gate.sh"; fi
}
