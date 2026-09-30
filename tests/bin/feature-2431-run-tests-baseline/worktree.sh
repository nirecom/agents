# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/worktree.sh
# Tests: bin/lib/run-tests-baseline-worktree.sh
# Tags: run-tests, baseline, worktree, scope:issue-specific, pwsh-not-required, TL2
# Sourced by the dispatcher; never run standalone.
# Also covers: hooks/lib/baseline-checkout-marker.js
# Plan contract: rtb_wt_create <repo-root> <sha> (prints the path, under
# $(run_all_cache_dir)/baseline/worktrees/), rtb_wt_remove <repo-root> <path>,
# rtb_wt_sweep_stale <repo-root>; marker CLI `node baseline-checkout-marker.js mark <root>`.

# wt_call <cache> <fn> [args...] — worktree lib call in a child bash with a pinned cache.
wt_call() {
  local cache="$1"; shift
  (cd "$TMPROOT" && export RUN_ALL_CACHE_DIR="$cache" && rtb_call 60 "$WORKTREE_LIB" "$@")
}

# is_marked <root> — prints true/false via isBaselineCheckout.
is_marked() {
  run_with_timeout 15 node -e '
try { process.stdout.write(String(require(process.argv[1]).isBaselineCheckout(process.argv[2]))); }
catch (e) { process.stdout.write("error"); }' "$(np "$MARKER_JS")" "$(np "$1")" 2>/dev/null
}

run_worktree_cases() {
  # ---- W1 / W4 / W5: marker module exists, parses, exports the SSOT name ----
  if [ -f "$MARKER_JS" ]; then
    pass "W1: hooks/lib/baseline-checkout-marker.js exists"
    run_with_timeout 10 node --check "$(np "$MARKER_JS")" >/dev/null 2>&1 \
      && pass "W4: baseline-checkout-marker.js passes Node syntax check" \
      || fail "W4: baseline-checkout-marker.js has syntax errors"
    local exp
    exp="$(run_with_timeout 10 node -e '
const m = require(process.argv[1]);
process.stdout.write(m.BASELINE_CHECKOUT_MARKER + "|" + typeof m.isBaselineCheckout);' \
      "$(np "$MARKER_JS")" 2>/dev/null)"
    [ "$exp" = "agents-baseline-checkout|function" ] \
      && pass "W5: exports BASELINE_CHECKOUT_MARKER and isBaselineCheckout" \
      || fail "W5: unexpected exports: ${exp:-none}"
  else
    fail "W1: hooks/lib/baseline-checkout-marker.js not found (impl pending)"
    fail "W4: marker JS not present (impl pending)"
    fail "W5: marker JS not present (impl pending)"
  fi

  if [ ! -f "$WORKTREE_LIB" ]; then
    local id
    for id in W2 W3 W6 W7; do
      fail "$id: bin/lib/run-tests-baseline-worktree.sh not found (impl pending)"
    done
    return
  fi

  local repo="$TMPROOT/repo-wt" cache="$TMPROOT/cache-wt" base wt
  base="$(mk_fixture_repo "$repo")"
  mkdir -p "$cache"

  # ---- W2: create checks out B2 detached, outside the repo, and marks it ----
  wt="$(wt_call "$cache" rtb_wt_create "$repo" "$base" 2>/dev/null | tail -1)"
  if [ -n "$wt" ] && [ -d "$wt" ] \
    && [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" = "$base" ] \
    && case "$(np "$wt")" in "$(np "$cache")"/baseline/worktrees/*) true ;; *) false ;; esac \
    && [ "$(is_marked "$wt")" = "true" ]; then
    pass "W2: rtb_wt_create → marked detached checkout of base under baseline/worktrees/"
  else
    fail "W2: create wrong (path=${wt:-none} marked=$(is_marked "${wt:-/nonexistent}"))"
  fi

  # ---- W3: remove deletes the checkout and its worktree registration ----
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    wt_call "$cache" rtb_wt_remove "$repo" "$wt" >/dev/null 2>&1
    if [ ! -d "$wt" ] && ! git -C "$repo" worktree list --porcelain | grep -qF "$(basename "$wt")"; then
      pass "W3: rtb_wt_remove removes directory and registration"
    else
      fail "W3: worktree still present after rtb_wt_remove: $wt"
    fi
  else
    fail "W3: no worktree from W2 to remove"
  fi

  # ---- W6: sweep removes a stale marked checkout, keeps an unmarked one ----
  local stale plain="$cache/baseline/worktrees/unmarked-$$"
  stale="$(wt_call "$cache" rtb_wt_create "$repo" "$base" 2>/dev/null | tail -1)"
  git -C "$repo" worktree add -q --detach "$plain" "$base" >/dev/null 2>&1
  wt_call "$cache" rtb_wt_sweep_stale "$repo" >/dev/null 2>&1
  if [ -n "$stale" ] && [ ! -d "$stale" ] && [ -d "$plain" ]; then
    pass "W6: sweep removes stale marked checkout, keeps unmarked one"
  else
    fail "W6: sweep wrong (stale=${stale:-none} exists=$([ -d "${stale:-/x}" ] && echo y || echo n) plain=$([ -d "$plain" ] && echo y || echo n))"
  fi

  # ---- W7: repo root and an unmarked linked worktree are not baseline checkouts ----
  if [ "$(is_marked "$repo")" = "false" ] && [ "$(is_marked "$plain")" = "false" ]; then
    pass "W7: isBaselineCheckout false for main checkout and unmarked worktree"
  else
    fail "W7: false positive (repo=$(is_marked "$repo") plain=$(is_marked "$plain"))"
  fi
  git -C "$repo" worktree remove "$plain" >/dev/null 2>&1 || true
}

# W8: every `git worktree` command the lib issues must pass the main-worktree guard
# predicate (external add target, no forced remove). A PATH shim logs the real argv.
run_worktree_guard_cases() {
  if [ ! -f "$WORKTREE_LIB" ]; then
    fail "W8-guard: bin/lib/run-tests-baseline-worktree.sh not found (impl pending)"
    fail "W8-no-force: bin/lib/run-tests-baseline-worktree.sh not found (impl pending)"
    return
  fi
  local repo="$TMPROOT/repo-wtg" cache="$TMPROOT/cache-wtg" shim="$TMPROOT/git-shim"
  local log="$TMPROOT/git-shim.log" real_git base wt
  real_git="$(command -v git)"
  base="$(mk_fixture_repo "$repo")"
  mkdir -p "$cache" "$shim"
  : > "$log"
  cat > "$shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = worktree ] && { printf '%s\x1f' "\$@" >> "$log"; printf '\n' >> "$log"; break; }; done
exec "$real_git" "\$@"
SHIM
  chmod +x "$shim/git"
  wt="$( (export PATH="$shim:$PATH"; wt_call "$cache" rtb_wt_create "$repo" "$base") 2>/dev/null | tail -1)"
  if [ -n "$wt" ] && [ -d "$wt" ]; then
    (export PATH="$shim:$PATH"; wt_call "$cache" rtb_wt_remove "$repo" "$wt") >/dev/null 2>&1
  fi

  local probe="$TMPROOT/wt-guard-probe.js" verdicts
  cat > "$probe" <<'JSCODE'
"use strict";
const fs = require("fs");
const { isAllowedWorktreeCommand, hasWorktreeRemoveForceFlag } =
  require(process.argv[2] + "/hooks/enforce-worktree/main-worktree-allows/worktree-command.js");
const lines = fs.readFileSync(process.argv[3], "utf8").split("\n").filter(Boolean);
for (const l of lines) {
  const argv = l.split("\x1f").filter((a) => a !== "");
  const subIdx = argv.indexOf("worktree") + 1;
  // Rebuild the lib's own command form: the -C value and the operands after the
  // subcommand are quoted; git, -C, worktree, the subcommand and flags are bare.
  const cmd = "git " + argv.map((a, i) =>
    (argv[i - 1] === "-C" || (i > subIdx && !a.startsWith("-"))) ? '"' + a + '"' : a
  ).join(" ");
  const sub = argv[subIdx] || "?";
  const ok = isAllowedWorktreeCommand(cmd, process.argv[4]);
  const forced = sub === "remove" && hasWorktreeRemoveForceFlag(cmd);
  process.stdout.write(sub + ":" + (ok ? "allow" : "deny") + (forced ? ":force" : "") + "\n");
}
JSCODE
  verdicts="$(run_with_timeout 15 node "$(np "$probe")" "$AGENTS_WIN" "$(np "$log")" "$(np "$repo")" 2>&1)"
  if printf '%s\n' "$verdicts" | grep -q '^add:allow$' \
    && printf '%s\n' "$verdicts" | grep -q '^remove:allow$' \
    && ! printf '%s\n' "$verdicts" | grep -q ':deny'; then
    pass "W8-guard: lib's worktree add/remove commands are allowed by the worktree guard"
  else
    fail "W8-guard: guard verdicts: $(printf '%s' "$verdicts" | tr '\n' '|')"
  fi
  if printf '%s\n' "$verdicts" | grep -q '^remove:' && ! printf '%s\n' "$verdicts" | grep -q ':force'; then
    pass "W8-no-force: lib removes its checkout without --force/-f"
  else
    fail "W8-no-force: no remove observed or a forced remove was issued: $(printf '%s' "$verdicts" | tr '\n' '|')"
  fi
}
