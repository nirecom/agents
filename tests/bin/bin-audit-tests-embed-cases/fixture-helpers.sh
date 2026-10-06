# Tests: bin/lib/test-embed-cases.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, fixture
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — fixture builders and runners
# shared by every case file. Holds no cases. All runners set OUT / ERR / RC.
# Depends on the dispatcher for AGENTS_ROOT, AUDIT, EC_TMP, GROUP_DIR, check_eq.

cp "$GROUP_DIR/fixtures/fake-codex" "$EC_TMP/fakebin/codex"
chmod +x "$EC_TMP/fakebin/codex"

# ec_make_repo — git repo with the shared harness, two helper libs and five
# targets bin/{alpha,bravo,charlie,delta,echo}.sh. Echoes its root; not committed.
ec_make_repo() {
  local root t
  root="$(mktemp -d -p "$EC_TMP")"
  harness_git_init "$root"
  git -C "$root" config core.autocrlf false
  git -C "$root" config user.email t@example.com
  git -C "$root" config user.name t
  mkdir -p "$root/tests/bin" "$root/tests/lib" "$root/bin"
  cp "$AGENTS_ROOT/tests/lib/harness.sh" "$root/tests/lib/harness.sh"
  cp "$AGENTS_ROOT/tests/lib/section-runner.sh" "$root/tests/lib/section-runner.sh"
  cp "$AGENTS_ROOT/tests/lib/clearance-hook-harness.sh" "$root/tests/lib/clearance-hook-harness.sh"
  for t in alpha bravo charlie delta echo; do
    printf '#!/usr/bin/env bash\necho %s\n' "$t" >"$root/bin/$t.sh"
  done
  printf '%s\n' "$root"
}

# ec_commit <root> [msg]
ec_commit() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -q --no-verify -m "${2:-fixture}" >/dev/null 2>&1
}

# ec_add_test <root> <relpath> <tests-header> [n-assertions] — a passing,
# marker-less test that sources the shared harness.
ec_add_test() {
  local root="$1" rel="$2" hdr="$3" n="${4:-1}" i
  mkdir -p "$(dirname "$root/$rel")"
  {
    printf '#!/usr/bin/env bash\n# Tests: %s\n# Tags: TL2, scope:common\n' "$hdr"
    cat <<'EOF'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
EOF
    for ((i = 1; i <= n; i++)); do
      printf 'if [ -d "$ROOT/bin" ]; then pass "bin dir %s"; else fail "bin dir %s"; fi\n' "$i" "$i"
    done
    cat <<'EOF'
echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
EOF
  } >"$root/$rel"
}

# ec_write_embedded <dst> <tests-header> <target>... — the same test rewritten
# with one marker block (one assertion) per target: a verifier-passing output.
ec_write_embedded() {
  local dst="$1" hdr="$2" t i=0
  shift 2
  mkdir -p "$(dirname "$dst")"
  {
    printf '#!/usr/bin/env bash\n# Tests: %s\n# Tags: TL2, scope:common\n' "$hdr"
    cat <<'EOF'
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/tests/lib/harness.sh"
EOF
    for t in "$@"; do
      i=$((i + 1))
      sed -e "s|@N@|$i|g" -e "s|@T@|$t|g" <<'EOF'

case_begin "block-@N@" "@T@"
if [ -d "$ROOT/bin" ]; then pass "bin dir @N@"; else fail "bin dir @N@"; fi
case_end
EOF
    done
    cat <<'EOF'

echo "Results: $PASS passed, $FAIL failed"
exit "$FAIL"
EOF
  } >"$dst"
}

# ec_run <root> <script> [args...] — runs one entrypoint with CWD = <root>.
ec_run() {
  local root="$1" script="$2" outf errf
  shift 2
  outf="$(mktemp -p "$EC_TMP")"
  errf="$(mktemp -p "$EC_TMP")"
  (cd "$root" && bash "$AGENTS_ROOT/bin/run-with-timeout.sh" 600 bash "$script" "$@") >"$outf" 2>"$errf"
  RC=$?
  OUT="$(cat "$outf")"
  ERR="$(cat "$errf")"
  rm -f "$outf" "$errf"
}

# ec_band_paths — relpath column of the BAND lines in $OUT, in emitted order.
ec_band_paths() { printf '%s\n' "$OUT" | awk -F'\t' '$1 == "BAND" { print $3 }'; }

# ec_skip_reason <relpath> — reason column of that file's SKIP line in $OUT.
ec_skip_reason() { printf '%s\n' "$OUT" | awk -F'\t' -v p="$1" '$1 == "SKIP" && $2 == p { print $3; exit }'; }

# ec_has_line <text> <line> — exact whole-line match.
ec_has_line() { printf '%s\n' "$1" | grep -qxF -- "$2"; }

# ec_not_unknown_arg — guards an exit-2 assertion against the pre-implementation
# "unknown argument" rejection, which would otherwise green it for the wrong reason.
ec_not_unknown_arg() { [[ "$ERR" != *"unknown argument"* ]]; }

# ec_ledger_segment <root> <stamp> <key>... — one run-all duration segment for the
# repo identity of <root>, written with the ledger's own identity helpers.
ec_ledger_segment() {
  local root="$1" stamp="$2"
  shift 2
  (
    # shellcheck source=../../../bin/lib/run-all-parallelism.sh
    . "$AGENTS_ROOT/bin/lib/run-all-parallelism.sh"
    # shellcheck source=../../../bin/lib/run-all-durations.sh
    . "$AGENTS_ROOT/bin/lib/run-all-durations.sh"
    run_all_dur_repo_id "$root" >/dev/null
    run_all_dur_host_token >/dev/null
    dir="$(run_all_dur_dir)"
    mkdir -p "$dir"
    seg="$dir/dur.$RUN_ALL_DUR_SCHEMA.$RUN_ALL_DUR_HOST_TOKEN.${stamp}-1.log"
    for k in "$@"; do
      printf '%s|%s|%s\n' "$RUN_ALL_DUR_REPO_ID" 5 "$k" >>"$seg"
    done
  )
}

# ec_retry_record <root> <relpath> [reason] — a capped row keyed on the file's hash.
ec_retry_record() {
  local h
  h="$(git -C "$1" hash-object "$2")"
  mkdir -p "$SWEEP_TESTS_STATE_DIR"
  printf '%s\t%s\t2\t%s\n' "$h" "$2" "${3:-verify-failed}" >>"$SWEEP_TESTS_STATE_DIR/embed-retry.tsv"
}

# ec_codex_says <line>... — the fake codex answers these lines (none = empty answer).
ec_codex_says() {
  export FAKE_CODEX_MODE=respond
  export FAKE_CODEX_RESPONSE="$EC_TMP/codex-response.txt"
  if [[ "$#" -gt 0 ]]; then printf '%s\n' "$@" >"$FAKE_CODEX_RESPONSE"; else : >"$FAKE_CODEX_RESPONSE"; fi
}

# ec_codex_fails — the fake codex exits non-zero (codex-core reports FAILED).
ec_codex_fails() { export FAKE_CODEX_MODE=fail; }

# ec_stage1 <root> <script> [args...] — stage 1 (apply mode); sets EC_WORKDIR.
ec_stage1() {
  local root="$1" script="$2"
  shift 2
  ec_run "$root" "$script" --embed-cases "$@"
  EC_WORKDIR="$(printf '%s\n' "$OUT" | sed -n 's/^EMBED_WORKDIR: //p' | head -n 1)"
}

# ec_apply <root> [workdir] [script] — stage 3 on the given (default: last) workdir.
ec_apply() { ec_run "$1" "${3:-$AUDIT}" --embed-apply "${2:-$EC_WORKDIR}"; }

# ec_abs <path> — resolves a worklist/gate path against $EC_WORKDIR when relative.
ec_abs() {
  if [[ "$1" == "/"* || "$1" =~ ^[A-Za-z]:/ ]]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$EC_WORKDIR/$1"
  fi
}

# ec_wl_field <relpath> <column-number> — one worklist.tsv field of that file's row
# (idx relpath input output rules_doc header_status orig_hash state attempts).
ec_wl_field() {
  awk -F'\t' -v p="$1" -v c="$2" '$2 == p { print $c; exit }' "$EC_WORKDIR/worklist.tsv" 2>/dev/null
}

# ec_item_output <relpath> — the file the stage-2 writer must create for that item.
ec_item_output() {
  local v
  v="$(ec_wl_field "$1" 4)"
  [[ -n "$v" ]] || return 1
  v="$(ec_abs "$v")"
  if [[ -d "$v" || "${v: -1}" == "/" ]]; then v="${v%/}/$(basename "$1")"; fi
  printf '%s\n' "$v"
}

# ec_item_report <relpath> — that item's report.txt path.
ec_item_report() {
  local idx
  idx="$(ec_wl_field "$1" 1)"
  [[ -n "$idx" ]] || return 1
  printf '%s\n' "$EC_WORKDIR/items/$idx/report.txt"
}

# ec_set_wl_field <relpath> <column-number> <value> — rewrites one worklist field.
ec_set_wl_field() {
  local wl="$EC_WORKDIR/worklist.tsv"
  awk -F'\t' -v OFS='\t' -v p="$1" -v c="$2" -v v="$3" '$2 == p { $c = v } { print }' "$wl" >"$wl.tmp" && mv "$wl.tmp" "$wl"
}

grp_done fixture-helpers.sh
