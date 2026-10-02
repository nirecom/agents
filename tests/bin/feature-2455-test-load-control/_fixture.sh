#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/_fixture.sh — shared fixture builders,
# runners, the fork-count shim and the lanes driver. Sourced FIRST by the
# dispatcher; every other case file relies on these helpers.

# ── Repo builders ───────────────────────────────────────────────────────────

# mk_repo — throwaway git repo with tests/ (not committed). Echoes its root.
mk_repo() {
    local root
    root="$(mktemp -d -p "$TMPDIR_BASE")"
    git -C "$root" init -q
    git -C "$root" config core.hooksPath /dev/null
    git -C "$root" config core.autocrlf false
    git -C "$root" config user.email "t@example.com"
    git -C "$root" config user.name "t"
    git -C "$root" config commit.gpgsign false
    mkdir -p "$root/tests/bin"
    printf 'init\n' > "$root/README.md"
    echo "$root"
}

# add_tf <root> <path-under-tests> <tests-csv> — one well-formed test file.
add_tf() {
    local f="$1/tests/$2"
    mkdir -p "${f%/*}"
    printf '#!/usr/bin/env bash\n# Tests: %s\n# Tags: scope:common\necho fixture\n' "$3" > "$f"
}

# commit_all <root> <message>
commit_all() {
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" commit -q -m "$2" >/dev/null 2>&1
}

# synth_corpus <root> <N> — N committed test files; each shares src/common.js
# (so every file is a candidate: the worst case) plus one unique token.
synth_corpus() {
    local root="$1" n="$2" i
    for ((i = 1; i <= n; i++)); do
        printf '#!/usr/bin/env bash\n# Tests: src/common.js,src/u%s.js\n# Tags: scope:common\necho fixture %s\n' \
            "$i" "$i" > "$root/tests/bin/t$i.sh"
    done
    commit_all "$root" "synthetic corpus $n"
}

# ── find-tests runner ───────────────────────────────────────────────────────
# run_ft <cwd> [NAME=VAL ...] -- <helper-args...> — sets OUT / ERR / RC.
OUT=""
ERR=""
RC=0
run_ft() {
    local cwd="$1"; shift
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    local outf="$TMPDIR_BASE/ft.out" errf="$TMPDIR_BASE/ft.err"
    (
        cd "$cwd" || exit 2
        unset GIT_DIR GIT_WORK_TREE
        bash "$RUN_TIMEOUT" "${FT_TIMEOUT:-120}" env ${envs[@]+"${envs[@]}"} bash "$HELPER" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"
    ERR="$(cat "$errf")"
}

# ── Fork-count shim (plan FC1-FC3) ──────────────────────────────────────────
FC_CMDS="awk sort wc grep sed git sha256sum shasum md5sum cksum mkdir rm mv sleep uname date cat touch stat head tail tr cut dirname"
SHIM_DIR="$TMPDIR_BASE/shim"
FORK_LOG_FILE="$TMPDIR_BASE/fork.log"

mk_shims() {
    local c real bashp
    mkdir -p "$SHIM_DIR"
    bashp="$(type -P bash)"
    for c in $FC_CMDS; do
        real="$(type -P "$c" 2>/dev/null || true)"
        [ -n "$real" ] || continue
        printf '#!%s\nprintf '"'"'%%s\\n'"'"' %s >> "$FORK_LOG"\nexec %q "$@"\n' "$bashp" "$c" "$real" > "$SHIM_DIR/$c"
        chmod +x "$SHIM_DIR/$c"
    done
}
mk_shims

# fork_run <cwd> [NAME=VAL ...] -- <helper-args...> — run_ft under the shim PATH.
# The shim PATH is set INSIDE the timeout wrapper so the wrapper's own forks never
# reach the log. Sets FC_TALLY ("cmd=n " sorted by name), FC_TOTAL and OUT/ERR/RC.
FC_TALLY=""
FC_TOTAL=0
fork_run() {
    local cwd="$1"; shift
    : > "$FORK_LOG_FILE"
    run_ft "$cwd" "PATH=$SHIM_DIR:$PATH" "FORK_LOG=$FORK_LOG_FILE" "$@"
    FC_TALLY="$(LC_ALL=C sort "$FORK_LOG_FILE" | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
    FC_TOTAL="$(grep -c '' "$FORK_LOG_FILE" || true)"
}

# fc_count <cmd> — that command's count in FC_TALLY (0 when absent).
fc_count() {
    local kv
    for kv in $FC_TALLY; do
        [ "${kv%%=*}" = "$1" ] && { printf '%s' "${kv#*=}"; return 0; }
    done
    printf '0'
}

# fc_caps_check <label> — FC3 per-command caps and the total cap on the last fork_run.
fc_caps_check() {
    local label="$1" kv c n cap bad=""
    for kv in $FC_TALLY; do
        c="${kv%%=*}"; n="${kv#*=}"
        case "$c" in
            awk) cap=2 ;; git) cap=6 ;; sha256sum) cap=1 ;; mkdir) cap=3 ;;
            rm) cap=2 ;; mv) cap=1 ;; dirname) cap=4 ;; *) cap=0 ;;
        esac
        [ "$n" -le "$cap" ] || bad="$bad $c=$n>$cap"
    done
    if [ -z "$bad" ] && [ "$FC_TOTAL" -le 19 ]; then
        pass "FC3 $label: every command within its cap and total $FC_TOTAL <= 19"
    else
        fail "FC3 $label: cap exceeded [${bad# }] total=$FC_TOTAL (cap 19) tally=[$FC_TALLY]"
    fi
}

# ── Corpus cache inspection ─────────────────────────────────────────────────
# cc_files <cache-root> — cache file basenames, name-sorted, one per line.
cc_files() {
    local f
    for f in "$1"/corpus/corpus.1.*.tsv; do
        [ -f "$f" ] && printf '%s\n' "${f##*/}"
    done
    return 0
}
# cc_digests <cache-root> — distinct digests (corpus.1.<stamp>.<digest>.tsv).
cc_digests() {
    local b
    for b in $(cc_files "$1"); do
        b="${b%.tsv}"
        printf '%s\n' "${b##*.}"
    done | LC_ALL=C sort -u
}
cc_ndigests() { cc_digests "$1" | grep -c . || true; }

# cc_valid <file> — 0 when the file follows the schema-1 corpus format.
cc_valid() {
    awk -F'\t' '
        NR == 1 { if ($0 != "#trd-corpus\tschema=1") bad = 1; next }
        { last = $0; lastf1 = $1; lastf2 = $2
          if ($1 == "#end") { ended = NR; next }
          if (ended) bad = 1
          body++
          if ($1 !~ /^[0-9]+$/ || $1 != NF - 2) bad = 1 }
        END { if (NR < 2 || lastf1 != "#end" || lastf2 != body || bad) exit 1 }
    ' "$1"
}

# ── Lanes helpers ───────────────────────────────────────────────────────────
now_epoch() { printf '%(%s)T' -1; }

# dead_pid — a pid that has already exited.
dead_pid() {
    local p
    bash -c 'exit 0' &
    p=$!
    wait "$p" 2>/dev/null
    printf '%s' "$p"
}

# mk_slot <cache-root> <i> <pid|""> [env] [kind] [hb-epoch] [token]
# An empty pid makes an ownerless slot (bare lane.<i> directory).
mk_slot() {
    local d="$1/slots/lane.$2" pid="$3" env="${4:-$OSTYPE}" kind="${5:-run-all}" hb="${6:-}" tok="${7:-}"
    mkdir -p "$d"
    [ -n "$pid" ] || return 0
    [ -n "$hb" ] || hb="$(now_epoch)"
    [ -n "$tok" ] || tok="$pid.$hb.4242"
    printf 'pid=%s\nenv=%s\nkind=%s\nstart=%s\ntoken=%s\n' "$pid" "$env" "$kind" "$hb" "$tok" > "$d/owner"
    printf '%s\n' "$hb" > "$d/hb"
}

# lane_names <cache-root> — held lane.* basenames, space-joined.
lane_names() {
    local d res=""
    for d in "$1"/slots/lane.*; do
        [ -d "$d" ] && res="$res ${d##*/}"
    done
    printf '%s' "${res# }"
}

# grave_count <cache-root> — reclaim leftovers (slots/.grave.*) still on disk.
grave_count() {
    local d n=0
    for d in "$1"/slots/.grave.*; do
        [ -e "$d" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# slot_entries <cache-root> — every entry under slots/, hidden ones included.
slot_entries() {
    local d n=0
    for d in "$1"/slots/* "$1"/slots/.[!.]*; do
        [ -e "$d" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# owner_token <cache-root> <i> — the token= field of lane.<i>/owner (empty if none).
owner_token() { sed -n 's/^token=//p' "$1/slots/lane.$2/owner" 2>/dev/null | head -n 1; }

# no_shell_error <text> — 0 when <text> carries no bash evaluation/arithmetic error.
no_shell_error() {
    ! printf '%s' "$1" | grep -qiE 'syntax error|integer expression|invalid arithmetic|bad substitution|unbound variable|command not found'
}

# The driver sources both libs (parallelism first — the lanes lib's precondition)
# and evaluates one snippet, so a case can call the lib API directly.
LANES_DRV="$TMPDIR_BASE/lanes-drv.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$DRV_PAR_LIB" 2>/dev/null || { echo "DRV: parallelism lib missing" >&2; exit 90; }' \
    '. "$DRV_LANES_LIB" 2>/dev/null || { echo "DRV: lanes lib missing (not implemented)" >&2; exit 91; }' \
    'eval "$1"' > "$LANES_DRV"

# lanes_drv <cache-root> [NAME=VAL ...] -- <snippet> — sets OUT / ERR / RC.
# Waits are shortened (interval 1s, cap 3s) unless a case overrides them.
lanes_drv() {
    local cache="$1"; shift
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    local outf="$TMPDIR_BASE/drv.out" errf="$TMPDIR_BASE/drv.err"
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 60 env "DRV_PAR_LIB=$PAR_LIB" "DRV_LANES_LIB=$LANES_LIB" \
            "RUN_ALL_CACHE_DIR=$cache" TEST_LANES_WAIT_INTERVAL=1 TEST_LANES_WAIT_CAP=3 \
            ${envs[@]+"${envs[@]}"} bash "$LANES_DRV" "$1"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"
    ERR="$(cat "$errf")"
}

# kv_of <text> <key> — value of the first `key=value` line in <text>.
kv_of() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

# run_status <cache-root> [NAME=VAL ...] [-- args] — bin/test-lanes-status.sh; sets OUT/ERR/RC.
run_status() {
    local cache="$1"; shift
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    [ "$#" -gt 0 ] && shift
    local outf="$TMPDIR_BASE/st.out" errf="$TMPDIR_BASE/st.err"
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 60 env "RUN_ALL_CACHE_DIR=$cache" ${envs[@]+"${envs[@]}"} \
            bash "$STATUS_CLI" "$@"
    ) >"$outf" 2>"$errf"
    RC=$?
    OUT="$(cat "$outf")"
    ERR="$(cat "$errf")"
}

grp_done _fixture.sh
