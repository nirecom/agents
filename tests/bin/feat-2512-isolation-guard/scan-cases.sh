# Single-file classification cases for feat-2512-isolation-guard.sh.
# Sourced by the dispatcher after its pin; defines case bodies only.

c_i1_subdir_unpinned() {
  local r
  r="$(new_root i1)"
  fx "$r/hooks/sub/x.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  run_cls --root "$r"
  expect "I1 rc=1 for an unpinned exec in a subdirectory" rc_is 1
  expect "I1 STATE-UNPINNED names hooks/sub/x.sh" label_hits STATE-UNPINNED "hooks/sub/x.sh"
}

c_i4_plans_only() {
  local r
  r="$(new_root i4)"
  fx "$r/hooks/half.sh" '#!/usr/bin/env bash' 'export WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  run_cls --root "$r"
  expect "I4 rc=1 for a plans-only pin" rc_is 1
  expect "I4 HALF-PIN-REVERSE names half.sh" label_hits HALF-PIN-REVERSE "hooks/half.sh"
}

c_i5_inline_only() {
  local r
  r="$(new_root i5)"
  fx "$r/hooks/inline-all.sh" '#!/usr/bin/env bash' \
    "WORKFLOW_STATE_DIR=/tmp/s WORKFLOW_PLANS_DIR=/tmp/p $EXEC_RO" \
    "WORKFLOW_STATE_DIR=/tmp/s WORKFLOW_PLANS_DIR=/tmp/p $EXEC_BIN"
  fx "$r/hooks/inline-some.sh" '#!/usr/bin/env bash' \
    "WORKFLOW_STATE_DIR=/tmp/s WORKFLOW_PLANS_DIR=/tmp/p $EXEC_RO" "$EXEC_BIN"
  run_cls --root "$r"
  expect "I5 rc=1 for inline-only pins" rc_is 1
  expect "I5 STATE-INLINE-ONLY names inline-all.sh (every exec line pinned inline)" label_hits STATE-INLINE-ONLY "hooks/inline-all.sh"
  expect "I5 inline-some.sh is a violation too" violation_for "hooks/inline-some.sh"
}

c_i6_env_u_default_path() {
  local r
  r="$(new_root i6)"
  fx "$r/hooks/default-path.sh" '#!/usr/bin/env bash' "$PIN_BOTH" \
    "env -u WORKFLOW_STATE_DIR HOME=/tmp/h USERPROFILE=/tmp/h $EXEC_RO" "$EXEC_RO"
  run_cls --root "$r"
  expect "I6 rc=0 for a pinned file with an env -u default-path call" rc_is 0
  expect "I6 no violation for default-path.sh" no_violation_for "default-path.sh"
}

c_i7_static_only() {
  local r
  r="$(new_root i7)"
  fx "$r/hooks/static.sh" '#!/usr/bin/env bash' 'grep -q getStateRoot "$AGENTS_DIR/hooks/lib/x.js" || exit 1'
  run_cls --root "$r"
  expect "I7 rc=0 for a grep-only test" rc_is 0
  expect "I7 no violation for static.sh" no_violation_for "static.sh"
}

c_i8_excluded_dirs() {
  local r d
  r="$(new_root i8)"
  for d in lib _archive fixtures node_modules hooks/fixtures; do
    fx "$r/$d/skip-me.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  done
  fx "$r/hooks/ctl.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  run_cls --root "$r"
  expect "I8 control file hooks/ctl.sh is still flagged" violation_for "hooks/ctl.sh"
  expect "I8 lib/, _archive/, fixtures/, node_modules/ are not scanned" no_violation_for "skip-me.sh"
}

c_i21_pin_between_execs() {
  local r
  r="$(new_root i21)"
  fx "$r/hooks/late.sh" '#!/usr/bin/env bash' '# line 2' "$EXEC_RO" "$PIN_BOTH" "$EXEC_RO"
  run_cls --root "$r"
  expect "I21 rc=1 for an exec before the pin" rc_is 1
  expect "I21 STATE-PIN-LATE names late.sh:3" label_hits STATE-PIN-LATE "hooks/late.sh:3"
}

c_i22_function_defined_before_pin() {
  local r
  r="$(new_root i22)"
  fx "$r/hooks/fn-late.sh" '#!/usr/bin/env bash' '# line 2' 'run_it() {' "  $EXEC_RO" '}' "$PIN_BOTH" 'run_it'
  run_cls --root "$r"
  expect "I22 rc=1 for a function body defined before the pin" rc_is 1
  expect "I22 STATE-PIN-LATE counts the definition line (fn-late.sh:3)" label_hits STATE-PIN-LATE "hooks/fn-late.sh:3"
}

c_i24_pin_inside_function() {
  local r
  r="$(new_root i24)"
  fx "$r/hooks/fn-pin.sh" '#!/usr/bin/env bash' \
    'setup() { export WORKFLOW_STATE_DIR=/tmp/s WORKFLOW_PLANS_DIR=/tmp/p; }' 'setup' "$EXEC_RO"
  run_cls --root "$r"
  expect "I24 rc=1 when the only pin is inside a function body" rc_is 1
  expect "I24 STATE-UNPINNED names fn-pin.sh" label_hits STATE-UNPINNED "hooks/fn-pin.sh"
}

c_i25_plans_pin_late() {
  local r
  r="$(new_root i25)"
  fx "$r/hooks/second-late.sh" '#!/usr/bin/env bash' 'export WORKFLOW_STATE_DIR=/tmp/s' \
    "$EXEC_RO" 'export WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  run_cls --root "$r"
  expect "I25 rc=1 when the plans pin follows the first exec" rc_is 1
  expect "I25 STATE-PIN-LATE names second-late.sh" label_hits STATE-PIN-LATE "hooks/second-late.sh"
  expect "I25 the STATE-PIN-LATE line says plans" label_hits STATE-PIN-LATE "plans"
}

# A missed terminator hides every later exec; a missed opener turns body text into code.
c_heredoc_lexing() {
  local r tab=$'\t'
  r="$(new_root heredoc)"
  fx "$r/hooks/hd-body-only.sh" '#!/usr/bin/env bash' "cat <<'EOF'" "$EXEC_RO" 'EOF'
  fx "$r/hooks/hd-after.sh" '#!/usr/bin/env bash' 'cat <<EOF' 'text' 'EOF' "$EXEC_RO"
  fx "$r/hooks/hd-pin-inside.sh" '#!/usr/bin/env bash' 'cat <<EOF' "$PIN_BOTH" 'EOF' "$EXEC_RO"
  fx "$r/hooks/hd-tab.sh" '#!/usr/bin/env bash' 'cat <<-EOF' "${tab}text" "${tab}EOF" "$EXEC_RO"
  fx "$r/hooks/hd-two.sh" '#!/usr/bin/env bash' 'cat <<A <<B' 'a' 'A' "$PIN_BOTH" 'B' "$EXEC_RO"
  fx "$r/hooks/hd-herestring.sh" '#!/usr/bin/env bash' 'read -r x <<< foo' "$EXEC_RO"
  fx "$r/hooks/hd-in-string.sh" '#!/usr/bin/env bash' 'echo "<<EOF"' "$EXEC_RO"
  fx "$r/hooks/hd-backslash.sh" '#!/usr/bin/env bash' 'cat <<\EOF' "$EXEC_RO" 'EOF'
  fx "$r/hooks/hd-dquote.sh" '#!/usr/bin/env bash' 'cat <<"EOF"' "$EXEC_RO" 'EOF'
  fx "$r/hooks/hd-spaced.sh" '#!/usr/bin/env bash' 'cat << EOF' "$EXEC_RO" 'EOF'
  # Pin in the body, exec after the terminator: a missed opener or terminator both hide the violation.
  local pair name opener
  for pair in "plain|cat <<EOF" "squote|cat <<'EOF'" "dquote|cat <<\"EOF\"" "bslash|cat <<\\EOF" "spaced|cat << EOF"; do
    name="${pair%%|*}"
    opener="${pair#*|}"
    fx "$r/hooks/hd-close-$name.sh" '#!/usr/bin/env bash' "$opener" "$PIN_BOTH" 'EOF' "$EXEC_RO"
  done
  # Arithmetic table (name|prefix): `<<` inside it is a shift, so the exec after it stays
  # visible (shift-*), and a real heredoc after it still opens (reopen-*: body pin ignored).
  local row prefix
  local arith_rows=(
    'sub|x=$(( a << b ))'
    'cmd|(( n = n << s ))'
    'nest-sub|x=$(( (a) << b ))'
    'nest-cmd|(( (n) << s ))'
    "split|x=\$(( a <<"$'\n'"b ))"
    'dquote|echo "$(( a << b ))"'
  )
  local reopen_rows=(
    "${arith_rows[@]}"
    'shift-assign|(( n <<= 1 ))'
    'subshell|( true )'
    'case|case x in a) true ;; esac'
  )
  for row in "${arith_rows[@]}"; do
    fx "$r/hooks/hd-shift-${row%%|*}.sh" '#!/usr/bin/env bash' "${row#*|}" "$EXEC_RO"
  done
  for row in "${reopen_rows[@]}"; do
    fx "$r/hooks/hd-reopen-${row%%|*}.sh" '#!/usr/bin/env bash' "${row#*|}" 'cat <<EOF' "$PIN_BOTH" 'EOF' "$EXEC_RO"
  done
  fx "$r/hooks/hd-reopen-same-line.sh" '#!/usr/bin/env bash' 'x=$(( a << b )); cat <<EOF' "$PIN_BOTH" 'EOF' "$EXEC_RO"
  run_cls --root "$r"
  for name in plain squote dquote bslash spaced; do
    expect "HD the $name heredoc terminator closes the body" label_hits STATE-UNPINNED "hooks/hd-close-$name.sh"
  done
  for row in "${arith_rows[@]}"; do
    expect "HD arithmetic ${row%%|*}: a << shift opens no body" label_hits STATE-UNPINNED "hooks/hd-shift-${row%%|*}.sh"
  done
  for row in "${reopen_rows[@]}" 'same-line|'; do
    expect "HD after ${row%%|*} a real heredoc still opens" label_hits STATE-UNPINNED "hooks/hd-reopen-${row%%|*}.sh"
  done
  expect "HD a <<< here-string opens no body: the next exec is STATE-UNPINNED" label_hits STATE-UNPINNED "hooks/hd-herestring.sh"
  expect "HD <<EOF inside a quoted string opens no body" label_hits STATE-UNPINNED "hooks/hd-in-string.sh"
  expect "HD a <<\\EOF body is text" no_violation_for "hooks/hd-backslash.sh"
  expect "HD a <<\"EOF\" body is text" no_violation_for "hooks/hd-dquote.sh"
  expect "HD a << EOF (spaced) body is text" no_violation_for "hooks/hd-spaced.sh"
  expect "HD an exec that only appears in a heredoc body is not a violation" no_violation_for "hooks/hd-body-only.sh"
  expect "HD an exec after a closed heredoc is STATE-UNPINNED" label_hits STATE-UNPINNED "hooks/hd-after.sh"
  expect "HD a pin inside a heredoc body does not pin the file" label_hits STATE-UNPINNED "hooks/hd-pin-inside.sh"
  expect "HD a tab-indented <<- terminator closes the body" label_hits STATE-UNPINNED "hooks/hd-tab.sh"
  expect "HD two heredocs on one line: both bodies are text" label_hits STATE-UNPINNED "hooks/hd-two.sh"
}

c_gap_pinned_ok_and_files_mode() {
  local r
  r="$(new_root files-mode)"
  fx "$r/hooks/good.sh" '#!/usr/bin/env bash' "$PIN_BOTH" "$EXEC_RO" "$EXEC_BIN"
  fx "$r/hooks/good-harness.sh" '#!/usr/bin/env bash' 'source "$(dirname "$0")/../lib/harness.sh"' \
    'harness_isolate "$(make_tmp)"' "$EXEC_RO"
  fx "$r/hooks/bad.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  run_cls "$r/hooks/good.sh" "$r/hooks/good-harness.sh"
  expect "files mode: pinned files only -> rc=0" rc_is 0
  expect "files mode: export pin is accepted" no_violation_for "good.sh"
  run_cls "$r/hooks/good.sh" "$r/hooks/bad.sh"
  expect "files mode: classifies the named bad file (rc=1)" rc_is 1
  expect "files mode: STATE-UNPINNED names bad.sh" label_hits STATE-UNPINNED "bad.sh"
  expect "files mode: harness_isolate pin is accepted" no_violation_for "good-harness.sh"
}

c_gap_crlf_symmetry() {
  local r
  r="$(new_root crlf)"
  mkdir -p "$r/hooks"
  printf '#!/usr/bin/env bash\r\n%s\r\n%s\r\n' "$PIN_BOTH" "$EXEC_RO" > "$r/hooks/crlf-good.sh"
  printf '#!/usr/bin/env bash\r\n%s\r\n' "$EXEC_RO" > "$r/hooks/crlf-bad.sh"
  run_cls --root "$r"
  expect "CRLF: a pinned CRLF file is not flagged" no_violation_for "crlf-good.sh"
  expect "CRLF: an unpinned CRLF file is flagged" label_hits STATE-UNPINNED "crlf-bad.sh"
}

c_gap_never_executes_fixture() {
  local r marker
  r="$(new_root noexec)"
  marker="$T/noexec-marker"
  fx "$r/hooks/evil.sh" '#!/usr/bin/env bash' "touch '$marker'" "$EXEC_RO"
  run_cls --root "$r"
  expect "security: the scanned fixture is flagged" violation_for "hooks/evil.sh"
  expect "security: the classifier never runs a scanned file" test ! -e "$marker"
}

# Plan step 4, third signal form: node "$<var>" where the name holds HOOK, BIN or SCRIPT.
# Each row is written once unpinned (root sig-u) and once after PIN_BOTH (root sig-p).
# Assumption (caller's review, not spelled out in the plan): a comment line that only
# mentions the form is not an execution line.
c_exec_signal_forms() {
  local ru rp name line want i
  local -a names=() wants=()
  ru="$(new_root sig-u)"
  rp="$(new_root sig-p)"
  while IFS='|' read -r name line want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    want="${want//[[:space:]]/}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    names+=("$name")
    wants+=("$want")
    fx "$ru/hooks/$name.sh" '#!/usr/bin/env bash' "$line"
    fx "$rp/hooks/$name.sh" '#!/usr/bin/env bash' "$PIN_BOTH" "$line"
  done <<'TABLE'
# name           | line                                   | want (unpinned)
sig-hook         | node "$HOOK"                           | violation
sig-stop-hook    | node "$STOP_HOOK" </dev/null           | violation
sig-bin          | node "$BIN_CLI" --session s1           | violation
sig-script       | node "$SCRIPT"                         | violation
sig-script-js    | node "$SCRIPT_JS" arg                  | violation
rej-grep         | grep -q x "$HOOK"                      | none
rej-comment      | # runs node "$HOOK" later              | none
rej-assign       | HOOK="$AGENTS_DIR/hooks/x.js"          | none
rej-version      | node --version                         | none
rej-other-var    | node "$FIXTURE_JS"                     | none
TABLE
  run_cls --root "$ru"
  expect "exec signal: the table has rows" test "${#names[@]}" -eq 10
  for i in "${!names[@]}"; do
    name="${names[$i]}"
    if [[ "${wants[$i]}" == violation ]]; then
      expect "exec signal: unpinned $name is a violation" violation_for "hooks/$name.sh"
    else
      expect "exec signal: $name is not an execution line (no violation)" no_violation_for "hooks/$name.sh"
    fi
  done
  expect "exec signal: the unpinned tree exits 1" rc_is 1
  run_cls --root "$rp"
  expect "exec signal: every form pinned at the top -> rc=0" rc_is 0
  expect "exec signal: no pinned form is a violation" no_violation_for "hooks/"
}

# Pin recognition boundary (plan step 3): only `export WORKFLOW_STATE_DIR=` or a
# top-level harness_isolate call is a permanent pin.
c_pin_boundary() {
  local r
  r="$(new_root pin-boundary)"
  fx "$r/hooks/fn-harness.sh" '#!/usr/bin/env bash' 'setup() { harness_isolate "$(make_tmp)"; }' 'setup' "$EXEC_RO"
  fx "$r/hooks/longer-name.sh" '#!/usr/bin/env bash' 'export WORKFLOW_STATE_DIRS=/tmp/s WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  run_cls --root "$r"
  expect "pin boundary: harness_isolate inside a function is no pin (STATE-UNPINNED)" label_hits STATE-UNPINNED "hooks/fn-harness.sh"
  expect "pin boundary: WORKFLOW_STATE_DIRS is not the state pin" violation_for "hooks/longer-name.sh"
  expect "pin boundary: rc=1" rc_is 1
}

# A command word inside quoted literal text is data, not an exec (tests/run-all.sh:350
# false positive); inside a "$( … )" or "` … `" substitution it still executes.
c_quoted_literal_vs_substitution() {
  local r
  r="$(new_root quoted)"
  fx "$r/hooks/echo-hint.sh" '#!/usr/bin/env bash' \
    'false || { echo "stuck; inspect with: bash bin/test-lanes-status.sh" >&2' '  exit 4; }'
  fx "$r/hooks/sq-literal.sh" '#!/usr/bin/env bash' "msg='run node hooks/x.js later'"
  fx "$r/hooks/printf-fixture.sh" '#!/usr/bin/env bash' \
    "printf 'node hooks/workflow-gate.js\\n' > \"\$f\""
  fx "$r/hooks/dq-subst.sh" '#!/usr/bin/env bash' 'out="$(bash "$AGENTS_DIR/bin/workflow-control-dir" --session s1)"'
  fx "$r/hooks/dq-backtick.sh" '#!/usr/bin/env bash' 'out="`node "$AGENTS_DIR/hooks/x.js"`"'
  fx "$r/hooks/sq-in-subst.sh" '#!/usr/bin/env bash' "cmd=\"\$(printf 'bash \"%s/bin/evil.sh\"' \"\$D\")\""
  run_cls --root "$r"
  expect "quoted: an exec hint inside an echo string is not an exec" no_violation_for "hooks/echo-hint.sh"
  expect "quoted: a single-quoted literal is not an exec" no_violation_for "hooks/sq-literal.sh"
  expect "quoted: a printf fixture body is not an exec" no_violation_for "hooks/printf-fixture.sh"
  expect "quoted: a quoted single-quoted literal inside \$( ) is not an exec" no_violation_for "hooks/sq-in-subst.sh"
  expect "quoted: an exec inside \"\$( )\" is still flagged" label_hits STATE-UNPINNED "hooks/dq-subst.sh"
  expect "quoted: an exec inside a quoted backtick is still flagged" label_hits STATE-UNPINNED "hooks/dq-backtick.sh"
  expect "quoted: rc=1 for the substitution files" rc_is 1
}

c_gap_idempotent() {
  local r out1 rc1
  r="$(new_root idem)"
  fx "$r/hooks/a.sh" '#!/usr/bin/env bash' "$EXEC_RO"
  fx "$r/hooks/b.sh" '#!/usr/bin/env bash' 'export WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  run_cls --root "$r"
  out1="$CLS_OUT"
  rc1="$CLS_RC"
  run_cls --root "$r"
  expect "idempotency: rc=1 on a tree with violations" rc_is 1
  expect "idempotency: a second run returns the same rc" test "$rc1" = "$CLS_RC"
  expect "idempotency: a second run prints the same lines" test "$out1" = "$CLS_OUT"
}

# Codex C1: an export that carries no value is no pin. An empty value makes the resolver
# fall back to the live default root, and a bare export with no assignment in the file
# only re-exports whatever the caller had. A bare export after an assignment is the
# repo's existing two-step form and stays a pin.
c_pin_without_value() {
  local r
  r="$(new_root pin-novalue)"
  fx "$r/hooks/empty-val.sh" '#!/usr/bin/env bash' 'export WORKFLOW_STATE_DIR= WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  fx "$r/hooks/empty-quoted.sh" '#!/usr/bin/env bash' 'export WORKFLOW_STATE_DIR="" WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  fx "$r/hooks/empty-eol.sh" '#!/usr/bin/env bash' 'export WORKFLOW_PLANS_DIR=/tmp/p' 'export WORKFLOW_STATE_DIR=' "$EXEC_RO"
  fx "$r/hooks/bare-unassigned.sh" '#!/usr/bin/env bash' 'export WORKFLOW_STATE_DIR WORKFLOW_PLANS_DIR' "$EXEC_RO"
  fx "$r/hooks/bare-assigned.sh" '#!/usr/bin/env bash' 'WORKFLOW_STATE_DIR=/tmp/s; export WORKFLOW_STATE_DIR' \
    'export WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  fx "$r/hooks/bare-then-assign.sh" '#!/usr/bin/env bash' 'export WORKFLOW_STATE_DIR; WORKFLOW_STATE_DIR=/tmp/s' \
    'export WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  fx "$r/hooks/bare-then-empty.sh" '#!/usr/bin/env bash' 'export WORKFLOW_STATE_DIR; WORKFLOW_STATE_DIR=""' \
    'export WORKFLOW_PLANS_DIR=/tmp/p' "$EXEC_RO"
  run_cls --root "$r"
  expect "no-value pin: export WORKFLOW_STATE_DIR= (empty, mid-list) is a violation" violation_for "hooks/empty-val.sh"
  expect "no-value pin: export WORKFLOW_STATE_DIR=\"\" is a violation" violation_for "hooks/empty-quoted.sh"
  expect "no-value pin: export WORKFLOW_STATE_DIR= (empty, end of line) is a violation" violation_for "hooks/empty-eol.sh"
  expect "no-value pin: a bare export with no assignment in the file is a violation" violation_for "hooks/bare-unassigned.sh"
  expect "no-value pin: assign-then-bare-export stays a pin" no_violation_for "hooks/bare-assigned.sh"
  expect "no-value pin: bare-export-then-assign stays a pin" no_violation_for "hooks/bare-then-assign.sh"
  expect "no-value pin: bare-export-then-empty-assign is a violation" violation_for "hooks/bare-then-empty.sh"
  expect "no-value pin: rc=1" rc_is 1
}

case_begin "pin-without-value" "bin/check-plans-dir-isolation.sh"
c_pin_without_value
case_end
