# Part of tests/skills/fix-quality-gates-not-found.sh (sourced, not standalone).
# Tests: skills/review-code-security/scripts/run-quality-gates.sh
# Tags: security-gate, quality-gates, review-code-security, false-green, root-names, scope:common, pwsh-not-required, TL2
#
# G5 — the runner finds its gates from its own path, whatever $AGENTS_MAIN_ROOT holds.
# It is invoked with the CWD set to the repository UNDER REVIEW, so a root taken from the
# environment could point into the reviewed tree and run code supplied by it.
# Unset, empty, relative, not-a-directory, absent and an existing absolute tree that
# carries every gate are six inputs and one verdict.

plant_gate_tree() { # <dir> <label> ; a checkout-shaped tree whose gates print "## <label> <gate>"
  local dir="$1" label="$2" g
  mkdir -p "$dir/bin" "$dir/rules"
  : > "$dir/rules/core-principles.md"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    printf '#!/usr/bin/env bash\necho "## %s %s: PERFORMED"\n' "$label" "$g" > "$dir/bin/$g"
    chmod +x "$dir/bin/$g" 2>/dev/null || true
  done <<< "$GATES"
}

# The merge-base helper is the other thing the runner executes out of a checkout, and it
# runs before any gate. This stand-in leaves a file behind, so "it was executed" is a fact
# on disk and not an inference from the report.
plant_sentinel_helper() { # <dir> ; the sentinel is <dir>/helper-ran.sentinel
  mkdir -p "$1/bin"
  printf '#!/usr/bin/env bash\n: > "%s"\nprintf "state=UNRESOLVED\\n"\nexit 3\n' \
    "$1/helper-ran.sentinel" > "$1/bin/resolve-merge-base.sh"
  chmod +x "$1/bin/resolve-merge-base.sh" 2>/dev/null || true
}

g5_helper_not_run_from() { # <row> <dir> <whose tree>
  check "G5[$1]e: the merge-base helper of $3 is never executed" "absent" \
    "$([ -e "$2/helper-ran.sentinel" ] && echo present || echo absent)"
}

make_repo_with_relative_tree() { # ; prints a repo with a checkout-shaped subtree at ./rel
  local r
  r="$(make_repo)"
  plant_gate_tree "$r/rel" "REVIEWED-TREE"
  plant_sentinel_helper "$r/rel"
  printf '%s' "$r"
}

g5_no_gate_from() { # <row> <label> <whose tree>
  if grep -qF -- "## $2 " <<< "$RQG_OUT"; then
    fail "G5[$1]d: no gate is executed out of $3 -- ran: $RQG_OUT"
  else
    pass "G5[$1]d: no gate is executed out of $3"
  fi
}

g5_root_value_is_ignored() {
  local cfg repo notdir absent decoy

  # The sharpest input: absolute, existing, and complete. A runner that used "the root
  # when it is a real directory" would pass every other row and run these gates.
  cfg="$(make_full_cfg exec)"; repo="$(make_repo)"
  decoy="$(mktemp -d "$TMPROOT/decoy-root.XXXXXX")"
  plant_gate_tree "$decoy" "DECOY-ROOT"
  check "G5[absolute-decoy]0: the decoy tree carries every gate" "$GATE_COUNT" \
    "$(find "$decoy/bin" -maxdepth 1 -type f | grep -c . || true)"
  plant_sentinel_helper "$decoy"
  run_runner_cfg set "$decoy" "$cfg" "$repo"
  g5_row "absolute-decoy"
  g5_no_gate_from "absolute-decoy" "DECOY-ROOT" "the tree the variable names"
  g5_helper_not_run_from "absolute-decoy" "$decoy" "the tree the variable names"

  # Control for the `e` rows: the same stand-in, placed in the runner's OWN checkout, does
  # leave its file. Without this an absent sentinel could mean a stand-in that cannot write.
  cfg="$(make_full_cfg exec)"; repo="$(make_repo)"
  plant_sentinel_helper "$cfg"
  run_runner_cfg unset "" "$cfg" "$repo"
  check "G5[helper-control]: the runner's own merge-base helper is the one executed" "present" \
    "$([ -e "$cfg/helper-ran.sentinel" ] && echo present || echo absent)"

  cfg="$(make_full_cfg exec)"; repo="$(make_repo)"
  run_runner_cfg unset "" "$cfg" "$repo"
  g5_row "unset"

  cfg="$(make_full_cfg exec)"; repo="$(make_repo)"
  run_runner_cfg set "" "$cfg" "$repo"
  g5_row "empty"

  # The reviewed tree's own code must never be executed as a gate.
  cfg="$(make_full_cfg exec)"; repo="$(make_repo_with_relative_tree)"
  run_runner_cfg set "rel" "$cfg" "$repo"
  g5_row "relative"
  g5_no_gate_from "relative" "REVIEWED-TREE" "the reviewed tree"
  g5_helper_not_run_from "relative" "$repo/rel" "the reviewed tree"

  cfg="$(make_full_cfg exec)"; repo="$(make_repo)"
  notdir="$(mktemp "$TMPROOT/notadir.XXXXXX")"
  printf 'not a directory\n' > "$notdir"
  run_runner_cfg set "$notdir" "$cfg" "$repo"
  g5_row "not-a-directory"

  cfg="$(make_full_cfg exec)"; repo="$(make_repo)"
  absent="$TMPROOT/root-that-was-never-created"
  check "G5[absent-absolute]0: the fixture path does not exist" "absent" \
    "$([ -e "$absent" ] && echo present || echo absent)"
  run_runner_cfg set "$absent" "$cfg" "$repo"
  g5_row "absent-absolute"
}

# The properties every spelling owes, asserted identically so the six rows cannot drift
# apart (CPR-ORTH): all gates of the runner's own checkout ran, and the exit is 0.
g5_row() { # <name>
  local name="$1"
  check "G5[$name]a: every gate of the runner's own checkout ran" "$GATE_COUNT" \
    "$(grep -cF -- "## STUB " <<< "$RQG_OUT" || true)"
  check "G5[$name]b: the advisory contract holds — the runner still exits 0" "0" "$RQG_RC"
  check "G5[$name]c: the summary totals every gate and reports none missing" \
    "## gates: $GATE_COUNT/$GATE_COUNT ran, 0 NOT FOUND" "$(last_line)"
}

# TL3 gap: a checkout on a mount that disappears mid-run (a disconnected network share),
#          where the runner starts and the individual gates then vanish.

# Not gated on exec_bit_works: the runner interprets a gate without the execute bit through
# `bash <path>`, so every stub here runs on a host that ignores the bit as well.
g5_root_value_is_ignored
