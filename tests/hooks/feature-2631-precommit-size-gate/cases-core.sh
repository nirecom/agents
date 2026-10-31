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

# core_row_wanted <key> [wanted ...] — true with no wanted list, or when <key> is in it; a heavy
# table case is split across lanes by naming its rows.
core_row_wanted() {
  local key="$1" w
  shift
  [ "$#" = 0 ] && return 0
  for w in "$@"; do [ "$w" = "$key" ] && return 0; done
  return 1
}

# [kind ...] — only these rows (all when none).
core_case_new_file_over_hard_blocks_exactly_hard_passes() {
  local kind path hard cfg
  # kind | path | HARD
  while IFS='|' read -r -u 3 kind path hard; do
    [[ -z "$kind" || "$kind" =~ ^[[:space:]]*# ]] && continue
    core_row_wanted "$kind" "$@" || continue
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
# [path ...] — only these rows (all when none).
core_case_exempt_stream_records_pass() {
  local path cfg
  while IFS='|' read -r -u 3 path; do
    [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
    core_row_wanted "$path" "$@" || continue
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

# The Node gate hooks/pre-commit.d/checks/size-gate.js: one bin/size-check child per commit, chained
# onto the agents-repo-only registry row agents-repo-gates, and never run once that row blocked.
core_case_gate_makes_exactly_one_node_call() {
  local n got
  if [ ! -f "$GATE" ]; then
    fail "hooks/pre-commit.d/checks/size-gate.js exists" "missing"
    return
  fi
  n="$(grep -vE '^[[:space:]]*//' "$GATE" | grep -cE 'spawnSync\(')"
  if [ "$n" = 1 ]; then pass "size-gate.js spawns exactly one child"
  else fail "size-gate.js spawns exactly one child" "found $n"; fi
  if grep -qF '"--staged-auto", "--session-gate"' "$GATE" && grep -qF '"bin", "size-check"' "$GATE"; then
    pass "the one child is bin/size-check --staged-auto --session-gate"
  else fail "the one child is bin/size-check --staged-auto --session-gate"; fi
  # shellcheck disable=SC2016 # a JS template literal, not a shell expansion
  got="$(node -e 'const r=require(process.argv[1]).CHECKS.find((c)=>c.name==="agents-repo-gates");process.stdout.write(r?`${r.agentsRepoOnly}/${r.failMode}`:"absent")' "$ROOT/hooks/pre-commit.d/registry.js" 2>&1)"
  if [ "$got" = "true/closed" ]; then pass "registry row agents-repo-gates is agents-repo-only and fails closed"
  else fail "registry row agents-repo-gates is agents-repo-only and fails closed" "got $got"; fi
  if grep -qF 'entry.name === "agents-repo-gates" ? require("./checks/size-gate").after(check)' "$ROOT/hooks/pre-commit.d/main.js"; then
    pass "hooks/pre-commit.d/main.js chains size-gate.js onto the agents-repo-gates row"
  else fail "hooks/pre-commit.d/main.js chains size-gate.js onto the agents-repo-gates row"; fi
  if grep -qF 'hooks/pre-commit.d/main.js' "$ROOT/hooks/pre-commit"; then pass "hooks/pre-commit runs the Node body main.js"
  else fail "hooks/pre-commit runs the Node body main.js"; fi
  # A blocking agents-repo gate returns as is: no size-check child runs (the cfgDir has none, so a
  # spawned child would add its rc diagnostic).
  got="$(node -e '
const g=require(process.argv[1]);const first={verdict:"block",messages:[]};
g.after({run:async()=>first}).run({context:{cfgDir:process.argv[2],repoTop:process.argv[2]}}).then((r)=>process.stdout.write(r===first?"same":JSON.stringify(r)));
' "$GATE" "$TMP_ROOT/no-such-cfg" 2>&1)"
  if [ "$got" = same ]; then pass "a blocking agents-repo gate returns as is; size-check never runs after it"
  else fail "a blocking agents-repo gate returns as is; size-check never runs after it" "got $got"; fi
}
