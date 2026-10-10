# Shared fixture helpers for tests/bin/feature-2561-root-names-*.sh (#2561).
# Sourced by each entrypoint after its isolation pin; the entrypoint sets T,
# REAL_GATE and RETIRED_LIST first. Defines data and functions only.

# The four root names and the three carrier spellings as data: fixture lines are
# assembled at run time, so no tracked line carries a form the gate rejects.
N_SCR="SCRIPT_CHECKOUT_ROOT"
N_AMR="AGENTS_MAIN_ROOT"
N_TMR="TARGET_MAIN_ROOT"
N_TCR="TARGET_CHECKOUT_ROOT"
V_SCR='$'"$N_SCR"
V_AMR='$'"$N_AMR"
CAMEL_SCR="script""CheckoutRoot"
C_PROP="anchors.$CAMEL_SCR"
C_KEY="script_""checkout_root"
C_FN="resolveS${CAMEL_SCR#s}"

# fx <file> <line>... — write a fixture file, one argument per line (text, never run).
fx() {
  local f="$1"
  shift
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$@" > "$f"
}

# std_sh <ups> [<name>] — the standard bash assignment line; <ups> is like ../..
std_sh() {
  printf '%s="$(cd "$(dirname "${BASH_SOURCE[0]}")/%s" && pwd)"\n' "${2:-$N_SCR}" "$1"
}

# std_js <levels> — the standard Node assignment line climbing <levels> directories.
std_js() {
  local ups="" i
  for ((i = 0; i < $1; i++)); do ups+=', ".."'; done
  printf 'const %s = path.resolve(__dirname%s);\n' "$N_SCR" "$ups"
}

# make_kit <name> — private copy of the gate under $T; sets KIT. The copy reads its
# classification table and its default retired-name list from its own checkout, so a
# fixture table never touches the real one. No gate yet => the copy is absent and
# every run reports "not found", which fails the exit-code assertions.
make_kit() {
  KIT="$T/kits/$1"
  mkdir -p "$KIT/bin" "$KIT/tests/bin"
  if [[ -f "$REAL_GATE" ]]; then cp "$REAL_GATE" "$KIT/bin/"; fi
  if [[ -d "${REAL_GATE%.sh}" ]]; then cp -r "${REAL_GATE%.sh}" "$KIT/bin/"; fi
  cp "$RETIRED_LIST" "$KIT/tests/bin/"
}

# write_table <kit> [<exception-json>...] — the fixture classification table.
write_table() {
  local k="$1" e extra="" all
  shift
  all="\"$N_SCR\",\"$N_AMR\",\"$N_TMR\",\"$N_TCR\""
  for e in "$@"; do extra+="    $e,"$'\n'; done
  fx "$k/bin/check-root-names/classification.json" \
    '{' \
    '  "rules": [' \
    "    {\"repo\":\"agents\",\"glob\":\"bin/sourced/**\",\"allow\":[\"$N_SCR\"],\"sourced\":true,\"reason\":\"fixture: sourced libraries\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"bin/special/**\",\"allow\":[\"$N_SCR\",\"$N_TMR\"],\"sourced\":false,\"reason\":\"fixture: the earlier rule wins\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"bin/**\",\"allow\":[\"$N_SCR\"],\"sourced\":false,\"reason\":\"fixture\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"hooks/**\",\"allow\":[\"$N_SCR\"],\"sourced\":false,\"reason\":\"fixture\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"skills/**/scripts/**\",\"allow\":[\"$N_SCR\"],\"sourced\":false,\"reason\":\"fixture\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"skills/**\",\"allow\":[\"$N_AMR\"],\"sourced\":false,\"reason\":\"fixture\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"docs/**\",\"allow\":[\"$N_AMR\"],\"sourced\":false,\"reason\":\"fixture\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"install/**\",\"allow\":[\"$N_SCR\"],\"sourced\":false,\"reason\":\"fixture\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"profile-snippet.*\",\"allow\":[\"$N_AMR\"],\"sourced\":false,\"reason\":\"fixture\"}," \
    "    {\"repo\":\"agents\",\"glob\":\"tests/**\",\"allow\":[$all],\"sourced\":false,\"reason\":\"fixture\"}," \
    '    {"repo":"agents","glob":"plain/**","allow":[],"sourced":false,"reason":"fixture: no root name"},' \
    "    {\"repo\":\"dotfiles\",\"glob\":\"dot/**\",\"allow\":[\"$N_AMR\"],\"sourced\":false,\"reason\":\"fixture\"}" \
    '  ],' \
    '  "exceptions": [' \
    "${extra}    {\"carrier\":\"$C_PROP\",\"kind\":\"property\",\"source\":\"bin/carrier-src.js\",\"files\":[\"bin/carrier-src.js\",\"bin/carrier-user.js\",\"bin/carrier-listed.js\"],\"reason\":\"fixture\"}," \
    "    {\"carrier\":\"$C_KEY\",\"kind\":\"payload-key\",\"source\":\"hooks/key-src.js\",\"files\":[\"hooks/key-src.js\",\"hooks/key-user.js\",\"hooks/key-blind.js\",\"docs/key.md\"],\"reason\":\"fixture\"}," \
    "    {\"carrier\":\"$C_FN\",\"kind\":\"function\",\"source\":\"hooks/fn-src.js\",\"files\":[\"hooks/fn-src.js\",\"hooks/fn-user.js\"],\"reason\":\"fixture\"}" \
    '  ]' \
    '}'
}

# new_repo <name> — committed-file fixture tree under $T; sets REPO.
new_repo() {
  REPO="$T/repos/$1"
  mkdir -p "$REPO"
  init_repo "$REPO"
}

init_repo() {
  harness_git_init "$1"
  git -C "$1" config core.autocrlf false
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -qm fixture
}

# table <name> — store the pipe-delimited table on stdin in the variable <name>.
# Columns: path|line. The line is the last column, so it is taken verbatim.
table() { printf -v "$1" '%s' "$(cat)"; }

# seed <dir> <table-name> [<skip>] — one fixture file per "path|line" row; <skip>
# columns between the path and the line are dropped. <NL> in the line starts a new line.
# A table without a row is a failure: nothing seeded would leave every row unasserted.
seed() {
  local path line i n=0
  while IFS='|' read -r path line; do
    [[ -n "$path" ]] || continue
    n=$((n + 1))
    for ((i = 0; i < ${3:-0}; i++)); do line="${line#*|}"; done
    fx "$1/$path" "${line//<NL>/$'\n'}"
  done <<<"${!2}"
  [[ "$n" -gt 0 ]] || fail "seed: the table $2 holds a row" "no row was read"
}

# run_gate_at <cwd> <kit> <args...> — sets GATE_OUT / GATE_RC.
run_gate_at() {
  local cwd="$1" k="$2"
  shift 2
  GATE_RC=0
  GATE_OUT="$(cd "$cwd" && run_with_timeout 120 bash "$k/bin/check-root-names.sh" "$@" 2>&1)" || GATE_RC=$?
}

# run_gate <kit> <args...> — same, from the neutral temp root.
run_gate() { run_gate_at "$T" "$@"; }

rc_is() { [[ "$GATE_RC" == "$1" ]]; }

# has_line <path> [<check> [<line> [<text>]]] — a report line begins with the whole
# path, then ":<n>: " (or ": " alone: a file-level line, asked for as line 0), then
# "<check>: " and a message that carries <text>. An empty argument matches anything.
# Every part is compared as exact text, never as a pattern.
has_line() {
  local path="$1" check="${2:-}" want="${3:-}" text="${4:-}" l rest n
  while IFS= read -r l; do
    l="${l%$'\r'}"
    [[ "$l" == "$path:"* ]] || continue
    rest="${l#"$path:"}"
    n=0
    if [[ "$rest" =~ ^([0-9]+):\ (.*)$ ]]; then
      n="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
    elif [[ "$rest" == " "* ]]; then
      rest="${rest# }"
    else
      continue
    fi
    [[ -z "$check" || "$rest" == "$check: "* ]] || continue
    [[ -z "$want" || "$n" == "$want" ]] || continue
    [[ -z "$text" || "${rest#*: }" == *"$text"* ]] || continue
    return 0
  done <<<"$GATE_OUT"
  return 1
}

# reports <path> [<check> [<line> [<text>]]] — a violation run carries that line.
reports() { [[ "$GATE_RC" == 1 ]] && has_line "$@"; }

# clean_for <path> [<check>] — the gate really ran (exit 0 or 1) and no line of the
# check (of any check when omitted) is about that path.
clean_for() {
  [[ "$GATE_RC" == 0 || "$GATE_RC" == 1 ]] || return 1
  ! has_line "$1" "${2:-}"
}

# silent_on <path> <check> <line> — the gate ran and that one line is not reported.
silent_on() {
  [[ "$GATE_RC" == 0 || "$GATE_RC" == 1 ]] || return 1
  ! has_line "$1" "$2" "$3"
}

# never_says <text> — the gate ran and the text is nowhere in its output.
never_says() {
  [[ "$GATE_RC" == 0 || "$GATE_RC" == 1 ]] || return 1
  [[ "$GATE_OUT" != *"$1"* ]]
}

# lines_for <path> — how many report lines are about that path.
lines_for() {
  local l n=0
  while IFS= read -r l; do
    if [[ "$l" == "$1: "* || "$l" == "$1:"[0-9]* ]]; then n=$((n + 1)); fi
  done <<<"$GATE_OUT"
  printf '%s' "$n"
}

# expect_rows <label> <check> — one assertion per row on stdin. Columns:
# path|verdict[|ignored]. The verdict is "accepted" (the check reports nothing for
# the path) or "<key>@<line>": the line is reported with the message msg_of <key>
# names. Each test defines msg_of for its own check. No row at all is a failure.
expect_rows() {
  local label="$1" check="$2" path verdict _rest n=0
  while IFS='|' read -r path verdict _rest; do
    [[ -n "$path" ]] || continue
    n=$((n + 1))
    if [[ "$verdict" == accepted ]]; then
      expect "$label: $path is accepted" clean_for "$path" "$check"
    elif [[ "$verdict" == *@* ]]; then
      expect "$label: $path is reported (${verdict%@*}, line ${verdict#*@})" \
        reports "$path" "$check" "${verdict#*@}" "$(msg_of "${verdict%@*}")"
    else
      fail "$label: $path" "unknown verdict '$verdict'"
    fi
  done
  [[ "$n" -gt 0 ]] || fail "$label: the row table holds a row" "no row was read"
}

# expect <name> <command...> — record PASS when the command succeeds.
expect() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name" "rc=${GATE_RC:-} out=$(head -c 400 <<<"${GATE_OUT:-}" | tr '\n' ' ')"
  fi
}

# tree_sum <dir> — checksum listing of the working files (the .git dir excluded).
tree_sum() {
  (cd "$1" && find . -type f -not -path './.git/*' -exec cksum {} + | sort)
}

# expect_rerun_stable <label> <want-rc> <tree> <kit> <args...> — the same verdict
# twice, and neither the scanned tree nor the gate's own checkout is written to.
expect_rerun_stable() {
  local label="$1" want="$2" tree="$3" before out1
  shift 3
  before="$(tree_sum "$tree")$(tree_sum "$1")"
  run_gate "$@"
  expect "$label: first run exits $want" rc_is "$want"
  out1="$GATE_OUT"
  run_gate "$@"
  expect "$label: rerun exits $want" rc_is "$want"
  expect "$label: rerun prints the same report" test "$GATE_OUT" = "$out1"
  expect "$label: nothing is written" test "$(tree_sum "$tree")$(tree_sum "$1")" = "$before"
}

# no_marker_file — no fixture text was executed (a run would create a PWNED_* file).
no_marker_file() { [[ -z "$(find "$T" -name 'PWNED_*' -print -quit)" ]]; }
