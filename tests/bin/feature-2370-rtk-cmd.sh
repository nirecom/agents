#!/bin/bash
# tests/bin/feature-2370-rtk-cmd.sh
# Tests: bin/rtk-cmd
# Tags: rtk, wrapper, bin, scope:issue-specific, dup-group-keep:distinct-layer

# TL3 gap (what this test does NOT catch):
# - Uses a FAKE rtk binary; does NOT verify real rtk output compression or
#   native audit evidence (e.g., hooks/lib/rtk-guard-audit.js log entries).
# - That residual gap is covered by tests/bin/TL3-rtk-cmd-real-binary.sh (RUN_TL3-gated).
# Closest-to-action mitigation: bin/check-verification-gate.sh at WORKFLOW_USER_VERIFIED.

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RTK_CMD="$AGENTS_DIR/bin/rtk-cmd"

# Shared harness: pass/fail/skip reporters + PASS/FAIL counters + session-ID unset.
. "$AGENTS_DIR/tests/lib/harness.sh"

TMPDIR_T="$(make_tmp)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# ---- Fake binaries ----

cat > "$TMPDIR_T/fake_rtk" << 'FAKE_RTK_EOF'
#!/bin/bash
echo "RTK_CALLED $*"
FAKE_RTK_EOF
chmod +x "$TMPDIR_T/fake_rtk"

cat > "$TMPDIR_T/fake_cmd" << 'FAKE_CMD_EOF'
#!/bin/bash
printf 'FAKECMD_CALLED %s\n' "$*"
FAKE_CMD_EOF
chmod +x "$TMPDIR_T/fake_cmd"

cat > "$TMPDIR_T/fake_cmd_ec42" << 'FAKE_EC42_EOF'
#!/bin/bash
exit 42
FAKE_EC42_EOF
chmod +x "$TMPDIR_T/fake_cmd_ec42"

# fake_rtk_ec: emulates rtk failing — writes to stdout AND stderr, exits 42.
# Used by case (o) to verify the RTK=on path is transparent to exit code and
# stderr (not just stdout), i.e. `exec rtk ...` propagates both faithfully.
cat > "$TMPDIR_T/fake_rtk_ec" << 'FAKE_RTK_EC_EOF'
#!/bin/bash
echo "RTK_STDOUT_MARKER"
echo "RTK_STDERR_MARKER" >&2
exit 42
FAKE_RTK_EC_EOF
chmod +x "$TMPDIR_T/fake_rtk_ec"

# fake_rtk_canary: writes each arg (one per line) to canary_args, then exec "$@".
# Unquoted heredoc delimiter — $TMPDIR_T is expanded here; \$@ becomes literal $@.
cat > "$TMPDIR_T/fake_rtk_canary" << FAKE_CANARY_EOF
#!/bin/bash
printf '%s\n' "\$@" > "$TMPDIR_T/canary_args"
exec "\$@"
FAKE_CANARY_EOF
chmod +x "$TMPDIR_T/fake_rtk_canary"

# ---- Fake AGENTS_CONFIG_DIR fixtures ----

# case (c): get-config-var exits 1 (RTK ON), but no rtk in PATH
mkdir -p "$TMPDIR_T/fake_agents_c/bin"
cat > "$TMPDIR_T/fake_agents_c/bin/get-config-var" << 'GCV_C_EOF'
#!/bin/bash
exit 1
GCV_C_EOF
chmod +x "$TMPDIR_T/fake_agents_c/bin/get-config-var"
mkdir -p "$TMPDIR_T/no-rtk-bin"

# case (h): get-config-var exits 3 (fail-safe-OFF)
mkdir -p "$TMPDIR_T/fake_agents_h3/bin"
cat > "$TMPDIR_T/fake_agents_h3/bin/get-config-var" << 'GCV_H3_EOF'
#!/bin/bash
exit 3
GCV_H3_EOF
chmod +x "$TMPDIR_T/fake_agents_h3/bin/get-config-var"

# case (h): get-config-var exits 4 (fail-safe-OFF)
mkdir -p "$TMPDIR_T/fake_agents_h4/bin"
cat > "$TMPDIR_T/fake_agents_h4/bin/get-config-var" << 'GCV_H4_EOF'
#!/bin/bash
exit 4
GCV_H4_EOF
chmod +x "$TMPDIR_T/fake_agents_h4/bin/get-config-var"

# case (m): get-config-var exits 2 (fail-safe-OFF, CPR-ORTH sibling of 3/4)
mkdir -p "$TMPDIR_T/fake_agents_h2/bin"
cat > "$TMPDIR_T/fake_agents_h2/bin/get-config-var" << 'GCV_H2_EOF'
#!/bin/bash
exit 2
GCV_H2_EOF
chmod +x "$TMPDIR_T/fake_agents_h2/bin/get-config-var"

# case (k): fake rtk named 'rtk' on PATH, so `command -v rtk` (not RTK_BIN)
# is the resolution route under test.
mkdir -p "$TMPDIR_T/rtk-on-path"
cat > "$TMPDIR_T/rtk-on-path/rtk" << 'RTK_ON_PATH_EOF'
#!/bin/bash
echo "RTK_CALLED $*"
RTK_ON_PATH_EOF
chmod +x "$TMPDIR_T/rtk-on-path/rtk"

# case (e): argv-fidelity fixture. Brackets each positional param on its own
# line, so a quoted `exec "$@"` (correct) is distinguishable from an unquoted
# `exec $@` (would word-split "arg with space" into three brackets). Guards
# against the false-green that a "$*"-joining fixture would allow.
cat > "$TMPDIR_T/fake_cmd_argv" << 'FAKE_ARGV_EOF'
#!/bin/bash
for a in "$@"; do printf '[%s]\n' "$a"; done
FAKE_ARGV_EOF
chmod +x "$TMPDIR_T/fake_cmd_argv"

# ---- Test cases ----

# (a) RTK=on + usable RTK_BIN=fake_rtk → rtk is called, stdout contains RTK_CALLED
ec_a=0
out_a=$(env RTK=on RTK_BIN="$TMPDIR_T/fake_rtk" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_a=$?
if [[ "$out_a" == *"RTK_CALLED"* ]]; then
  pass "(a) RTK=on: stdout contains RTK_CALLED"
else
  fail "(a) RTK=on: expected RTK_CALLED in stdout, got '$out_a' (ec=$ec_a)"
fi

# (b) RTK=off + RTK_BIN set → passthrough (rtk NOT called)
ec_b=0
out_b=$(env RTK=off RTK_BIN="$TMPDIR_T/fake_rtk" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_b=$?
if [[ "$out_b" == *"FAKECMD_CALLED"* ]]; then
  pass "(b) RTK=off: stdout contains FAKECMD_CALLED (passthrough)"
else
  fail "(b) RTK=off: expected FAKECMD_CALLED, got '$out_b' (ec=$ec_b)"
fi

# (c) rtk absent — HERMETIC: fake AGENTS_CONFIG_DIR returns exit 1 (RTK ON),
#     no rtk binary in PATH, RTK_BIN="" → passthrough.
#     PATH includes /usr/bin:/bin because the wrapper's `#!/usr/bin/env bash`
#     shebang needs `env`/`bash` resolvable via PATH; the empty no-rtk-bin dir
#     is prepended so rtk stays absent. rtk is a cargo-installed binary
#     (~/.cargo/bin etc.), never shipped in /usr/bin or /bin, so hermeticity of
#     the "rtk absent" premise holds. This is the PATH the approved detail plan
#     specifies (detail.md case (c) — two-stage hermetic approach).
ec_c=0
out_c=$(env AGENTS_CONFIG_DIR="$TMPDIR_T/fake_agents_c" RTK_BIN="" \
  PATH="$TMPDIR_T/no-rtk-bin:/usr/bin:/bin" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_c=$?
if [[ "$out_c" == *"FAKECMD_CALLED"* ]]; then
  pass "(c) rtk absent: passthrough despite RTK=on (FAKECMD_CALLED)"
else
  fail "(c) rtk absent: expected FAKECMD_CALLED, got '$out_c' (ec=$ec_c)"
fi

# (d) exit-code transparency: passthrough command exits 42
ec_d=0
out_d=$(env RTK=off AGENTS_CONFIG_DIR="$AGENTS_DIR" RTK_BIN="" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd_ec42") || ec_d=$?
if [[ "$ec_d" -eq 42 ]]; then
  pass "(d) exit-code transparency: ec=$ec_d (expected 42)"
else
  fail "(d) exit-code transparency: expected ec=42, got ec=$ec_d"
fi

# (e) argument fidelity: quoting, empty string, and glob char preserved verbatim.
#     fake_cmd_argv brackets each argv element; an unquoted exec would split
#     "arg with space" into three separate brackets and drop the empty arg,
#     so these assertions genuinely distinguish correct from broken behavior.
ec_e=0
out_e=$(env RTK=off AGENTS_CONFIG_DIR="$AGENTS_DIR" RTK_BIN="" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd_argv" arg1 "arg with space" "" '*' --flag) || ec_e=$?
if [[ "$out_e" == *"[arg1]"* ]] \
   && [[ "$out_e" == *"[arg with space]"* ]] \
   && [[ "$out_e" == *"[]"* ]] \
   && [[ "$out_e" == *"[*]"* ]] \
   && [[ "$out_e" == *"[--flag]"* ]]; then
  pass "(e) arg fidelity: quoting, empty string, and glob preserved verbatim"
else
  fail "(e) arg fidelity: stdout='$out_e' (ec=$ec_e)"
fi

# (f) mechanism canary: fake_rtk_canary writes args to canary_args then exec git log
ec_f=0
out_f=$(env RTK=on RTK_BIN="$TMPDIR_T/fake_rtk_canary" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
  "$RTK_CMD" git log --oneline -1 2>&1) || ec_f=$?

canary_content=""
if [[ -f "$TMPDIR_T/canary_args" ]]; then
  canary_content=$(cat "$TMPDIR_T/canary_args")
fi

if [[ "$canary_content" == *"git"* ]] \
   && [[ "$canary_content" == *"log"* ]] \
   && [[ "$canary_content" == *"--oneline"* ]] \
   && [[ "$canary_content" == *"-1"* ]]; then
  pass "(f) canary: canary_args contains git log --oneline -1 args"
else
  fail "(f) canary: canary_args='$canary_content' (expected git log --oneline -1)"
fi
if [[ "$ec_f" -eq 0 ]]; then
  pass "(f) canary: exit 0 (exec chain succeeded)"
else
  fail "(f) canary: expected exit 0, got ec=$ec_f (out='$out_f')"
fi

# (g) AGENTS_CONFIG_DIR empty → immediate passthrough (fail-safe-OFF at dir check)
ec_g=0
out_g=$(env AGENTS_CONFIG_DIR="" RTK_BIN="" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_g=$?
if [[ "$out_g" == *"FAKECMD_CALLED"* ]]; then
  pass "(g) AGENTS_CONFIG_DIR empty: passthrough"
else
  fail "(g) AGENTS_CONFIG_DIR empty: expected FAKECMD_CALLED, got '$out_g' (ec=$ec_g)"
fi

# (h) get-config-var exit 3 → fail-safe-OFF → passthrough
ec_h3=0
out_h3=$(env AGENTS_CONFIG_DIR="$TMPDIR_T/fake_agents_h3" RTK_BIN="$TMPDIR_T/fake_rtk" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_h3=$?
if [[ "$out_h3" == *"FAKECMD_CALLED"* ]]; then
  pass "(h) gcv exit 3: fail-safe-OFF passthrough"
else
  fail "(h) gcv exit 3: expected FAKECMD_CALLED, got '$out_h3' (ec=$ec_h3)"
fi

# (h) get-config-var exit 4 → fail-safe-OFF → passthrough
ec_h4=0
out_h4=$(env AGENTS_CONFIG_DIR="$TMPDIR_T/fake_agents_h4" RTK_BIN="$TMPDIR_T/fake_rtk" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_h4=$?
if [[ "$out_h4" == *"FAKECMD_CALLED"* ]]; then
  pass "(h) gcv exit 4: fail-safe-OFF passthrough"
else
  fail "(h) gcv exit 4: expected FAKECMD_CALLED, got '$out_h4' (ec=$ec_h4)"
fi

# (i) non-executable RTK_BIN → [ -x ] check fails → passthrough
touch "$TMPDIR_T/non_exec_rtk"
ec_i=0
out_i=$(env RTK=on RTK_BIN="$TMPDIR_T/non_exec_rtk" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_i=$?
if [[ "$out_i" == *"FAKECMD_CALLED"* ]]; then
  pass "(i) non-exec RTK_BIN: passthrough"
else
  fail "(i) non-exec RTK_BIN: expected FAKECMD_CALLED, got '$out_i' (ec=$ec_i)"
fi

# (i2) directory RTK_BIN → [ -f ] guard rejects it → passthrough
#      C3 regression: [ -x dir ] alone is true, so without the -f guard the wrapper
#      would `exec` the directory and fail instead of falling back (documented at
#      bin/rtk-cmd's RTK_BIN override comment).
mkdir -p "$TMPDIR_T/dir_rtk"
ec_i2=0
out_i2=$(env RTK=on RTK_BIN="$TMPDIR_T/dir_rtk" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_i2=$?
if [[ "$out_i2" == *"FAKECMD_CALLED"* && "$ec_i2" -eq 0 ]]; then
  pass "(i2) directory RTK_BIN: -f guard rejects dir, passthrough"
else
  fail "(i2) directory RTK_BIN: expected FAKECMD_CALLED + exit 0, got '$out_i2' (ec=$ec_i2)"
fi

# (k) RTK=on + RTK_BIN="" + rtk on PATH → `command -v rtk` resolves it → rtk called
ec_k=0
out_k=$(env AGENTS_CONFIG_DIR="$TMPDIR_T/fake_agents_c" RTK_BIN="" \
  PATH="$TMPDIR_T/rtk-on-path:/usr/bin:/bin" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_k=$?
# Assert both the RTK_CALLED marker AND the forwarded downstream arg: a bare
# `exec "$_rtk_bin"` (no args) would still print "RTK_CALLED", so requiring the
# forwarded path guards against that false-green.
if [[ "$out_k" == *"RTK_CALLED"*"$TMPDIR_T/fake_cmd"* ]]; then
  pass "(k) PATH rtk resolution: rtk invoked via command -v with forwarded args"
else
  fail "(k) PATH rtk resolution: expected RTK_CALLED + forwarded arg, got '$out_k' (ec=$ec_k)"
fi
if [[ "$ec_k" -eq 0 ]]; then
  pass "(k) PATH rtk resolution: exit 0 (exec chain succeeded)"
else
  fail "(k) PATH rtk resolution: expected exit 0, got ec=$ec_k"
fi

# (m) get-config-var exit 2 → fail-safe-OFF → passthrough (CPR-ORTH sibling of 3/4)
ec_m=0
out_m=$(env AGENTS_CONFIG_DIR="$TMPDIR_T/fake_agents_h2" RTK_BIN="$TMPDIR_T/fake_rtk" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd") || ec_m=$?
if [[ "$out_m" == *"FAKECMD_CALLED"* ]]; then
  pass "(m) gcv exit 2: fail-safe-OFF passthrough"
else
  fail "(m) gcv exit 2: expected FAKECMD_CALLED, got '$out_m' (ec=$ec_m)"
fi

# (n) zero args → usage error on stderr, exit 2
ec_n=0
out_n=$(env RTK=off AGENTS_CONFIG_DIR="$AGENTS_DIR" RTK_BIN="" \
  "$RTK_CMD" 2>&1) || ec_n=$?
if [[ "$ec_n" -eq 2 ]]; then
  pass "(n) zero args: exit 2 (usage)"
else
  fail "(n) zero args: expected exit 2, got ec=$ec_n (out='$out_n')"
fi

# (o) RTK=on path transparency: when rtk exits nonzero and writes to stderr,
#     the wrapper (via `exec rtk ...`) must propagate BOTH the exit code and
#     stderr to the caller — not just stdout. Captures stdout and stderr into
#     separate variables so each stream is asserted independently.
o_err_file="$TMPDIR_T/case_o_stderr"
ec_o=0
out_o=$(env RTK=on RTK_BIN="$TMPDIR_T/fake_rtk_ec" AGENTS_CONFIG_DIR="$AGENTS_DIR" \
  "$RTK_CMD" "$TMPDIR_T/fake_cmd" 2>"$o_err_file") || ec_o=$?
err_o=""
if [[ -f "$o_err_file" ]]; then
  err_o=$(cat "$o_err_file")
fi
if [[ "$ec_o" -eq 42 ]]; then
  pass "(o) RTK=on transparency: exit code 42 propagated from rtk"
else
  fail "(o) RTK=on transparency: expected ec=42, got ec=$ec_o"
fi
if [[ "$err_o" == *"RTK_STDERR_MARKER"* ]]; then
  pass "(o) RTK=on transparency: stderr propagated to caller"
else
  fail "(o) RTK=on transparency: expected RTK_STDERR_MARKER on stderr, got '$err_o'"
fi
if [[ "$out_o" == *"RTK_STDOUT_MARKER"* ]]; then
  pass "(o) RTK=on transparency: stdout propagated to caller"
else
  fail "(o) RTK=on transparency: expected RTK_STDOUT_MARKER on stdout, got '$out_o'"
fi

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
