#!/usr/bin/env bash
# tests/tests/feature-2590-command-guard/misc-cases.sh — sourced by
# tests/tests/feature-2590-command-guard.sh: hit records, the instance, the cache, the PATH
# handling and the opt-out for tests that need the real CLIs. Functions only.

# Hit lines carry stub / test_id / target, and the two hit helpers agree with the hit files.
cg_case_hit_records() {
  cg_require "hit records name the stub, test and target" || return 0
  local hit out n
  gx "$OUT_REPO" git config core.hooksPath "$OUTSIDE/x"
  hit="$(cat "$(newest_hit)" 2>/dev/null)"
  expect_eq "git hit: stub" "$(field "$hit" stub)" "git"
  expect_eq "git hit: test_id" "$(field "$hit" test_id)" "$CG_TID"
  expect_has "git hit: target names the outside repo" "$(field "$hit" target | tr 'A-Z\\' 'a-z/')" "$(nlow "$OUT_REPO")"
  expect_has "git hit: argv" "$(field "$hit" argv)" "core.hooksPath"
  expect_has "git hit: stderr explains the refusal" "$ERR_TEXT" "command guard"
  n="$(hits_now)"
  out="$(cd "$TMP_ROOT" && TEST_RUN_ROOT="$RR" TEST_HOST_TMPDIR="$HOST" HOME="$FHOME" USERPROFILE="$FHOME" COMMAND_GUARD_DIR="$GDIR" \
    PATH="$SAFE_PATH" bash "$RWT" 120 bash "$TMP_ROOT/ensure-driver.sh" "$SCRIPT_CHECKOUT_ROOT" hits 2>&1)"
  expect_eq "command_guard_hit_count matches the hit files" "$(field "$out" HITCOUNT)" "$n"
  expect_eq "command_guard_hits prints one line per hit" "$(printf '%s\n' "$out" | grep -c '^HITLINE=')" "$n"
}

# guard.conf: the settings every guard binary reads from ../guard.conf, independent of env.
cg_case_instance_config() {
  cg_require "the instance carries guard.conf and hits/" || return 0
  local conf key
  conf="$(cat "$GDIR/guard.conf")"
  for key in node main realgit allowed readverbs; do
    expect_ne "guard.conf has $key=" "$(field "$conf" "$key")" ""
  done
  expect_has "guard.conf allows the run root" "$(printf '%s\n' "$conf" | sed -n 's/^allowed=//p' | tr 'A-Z\\' 'a-z/')" "$(nlow "$RR")"
  expect_eq "the instance sits in the run root" "$(nlow "$GDIR")" "$(nlow "$RR")/command-guard"
  expect_eq "hits/ exists" "$([[ -d "$GDIR/hits" ]] && echo yes)" "yes"
  expect_lacks "realgit is not the guard's git" "$(field "$conf" realgit | tr 'A-Z\\' 'a-z/')" "/command-guard/"
}

# The build output lives under the host temp cache, keyed, and is shared by later run roots;
# nothing lands under HOME.
cg_case_cache_location() {
  cg_require "the guard cache lives under the host temp area" || return 0
  local want user out2 g2
  user="$(node -p 'require("os").userInfo().username')"
  want="$(cd "$TMP_ROOT" && TEST_HOST_TMPDIR="$HOST" HOME="$FHOME" USERPROFILE="$FHOME" node "$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/command-guard-build.js")" --cache-dir 2>&1)"
  expect_has "--cache-dir is under the host temp cache" "$(printf '%s' "$want" | tr 'A-Z\\' 'a-z/')" "$(nlow "$HOST")/agents-test-cache-$(printf '%s' "$user" | tr 'A-Z' 'a-z')/command-guard/"
  expect_eq "the cache dir exists" "$([[ -d "$want" ]] && echo yes)" "yes"
  expect_eq "nothing under HOME" "$(find "$FHOME" -mindepth 1 | wc -l | tr -d ' ')" "0"
  mkdir -p "$TMP_ROOT/run root two"
  out2="$(cg_ensure "$TMP_ROOT/run root two")"
  g2="$(field "$out2" GDIR)"
  expect_eq "a second run root gets its own instance" "$(nlow "$g2")" "$(nlow "$TMP_ROOT/run root two")/command-guard"
  expect_eq "a second run root reuses the one cache entry" "$(find "${want%[/\\]*}" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" "1"
}

# The guard dir is first on PATH exactly once, a second ensure changes nothing, and a preset
# COMMAND_GUARD_DIR (the launcher's pin) is reused rather than replaced.
cg_case_path_handling() {
  cg_require "PATH prepend is idempotent and the pin is reused" || return 0
  local out p first count
  out="$(cg_ensure "$RR" twice)"
  p="$(field "$out" PATH)"
  first="${p%%:*}"
  expect_eq "guard bin is first on PATH" "$(nlow "$first")" "$(nlow "$GDIR/bin")"
  count="$(printf '%s\n' "$p" | tr ':' '\n' | grep -ci '/command-guard/bin$')"
  expect_eq "guard bin appears once after two ensures" "$count" "1"
  out="$(cd "$TMP_ROOT" && TEST_RUN_ROOT="$TMP_ROOT/unused root" TEST_HOST_TMPDIR="$HOST" HOME="$FHOME" USERPROFILE="$FHOME" \
    COMMAND_GUARD_DIR="$GDIR" PATH="$SAFE_PATH" bash "$RWT" 120 bash "$TMP_ROOT/ensure-driver.sh" "$SCRIPT_CHECKOUT_ROOT" 2>&1)"
  expect_eq "a preset COMMAND_GUARD_DIR is reused" "$(nlow "$(field "$out" GDIR)")" "$(nlow "$GDIR")"
  expect_eq "no instance under another run root" "$([[ -e "$TMP_ROOT/unused root/command-guard" ]] && echo made)" ""
}

cg_case_use_real() {
  cg_require "command_guard_use_real takes the guard off PATH" || return 0
  local out
  out="$(cg_ensure "$RR" use-real)"
  expect_eq "use_real returns 0" "$(field "$out" USE_REAL_RC)" "0"
  expect_lacks "use_real: no guard dir on PATH" "$(field "$out" REALPATH)" "/command-guard/"
  expect_lacks "use_real: git resolves to real git" "$(field "$out" GITNOW)" "/command-guard/"
}

# Only TL3 / TL4 tests may opt out. The guard's own library, docs and these tests are the
# definition and its checks, not callers.
cg_case_use_real_callers() {
  local callers bad="" f
  callers="$(git -C "$SCRIPT_CHECKOUT_ROOT" grep -l -e 'command_guard_use_real' -- . 2>/dev/null)"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      tests/lib/command-guard*|docs/*|*.md|tests/tests/feature-2590-command-guard*) continue ;;
      */TL3-*|*/TL4-*|TL3-*|TL4-*) continue ;;
    esac
    bad="$bad $f"
  done <<<"$callers"
  expect_eq "only TL3-* / TL4-* files call command_guard_use_real" "$bad" ""
}
