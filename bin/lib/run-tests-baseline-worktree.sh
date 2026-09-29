#!/usr/bin/env bash
# Temporary merge-base checkouts for bin/run-tests-baseline (#2431). Source-only.
# Checkouts live outside the repo at $(run_all_cache_dir)/baseline/worktrees/ and are
# tagged by hooks/lib/baseline-checkout-marker.js so provenance never trusts them.
# Every git worktree command uses `-C <repo-root>` and never forces a removal, so it
# stays inside the main-worktree guard (hooks/enforce-worktree).

case "${BASH_SOURCE[0]}" in
  */*) RTB_WT_LIB_DIR="${BASH_SOURCE[0]%/*}" ;;
  *)   RTB_WT_LIB_DIR="." ;;
esac
# shellcheck source=bin/lib/run-all-parallelism.sh
. "$RTB_WT_LIB_DIR/run-all-parallelism.sh"
# shellcheck source=bin/lib/run-all-durations.sh
. "$RTB_WT_LIB_DIR/run-all-durations.sh"

RTB_WT_MARKER_JS="$RTB_WT_LIB_DIR/../../hooks/lib/baseline-checkout-marker.js"
# A checkout whose creating process is still alive is left alone for this long.
RTB_WT_LIVE_GRACE_SECS=21600

rtb_wt_warn() {
    printf 'run-tests-baseline: worktree: %s\n' "$1" >&2
}

# Native (C:/...) spelling on Windows so git, node and the guard see one form.
rtb_wt_native() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

rtb_wt_base_dir() {
    rtb_wt_native "$(run_all_cache_dir)/baseline/worktrees"
}

# rtb_wt_is_marked <path> — exit 0 when the checkout carries the baseline marker.
rtb_wt_is_marked() {
    local out
    out="$(node -e 'process.stdout.write(String(require(process.argv[1]).isBaselineCheckout(process.argv[2])))' \
        "$(rtb_wt_native "$RTB_WT_MARKER_JS")" "$(rtb_wt_native "$1")" 2>/dev/null)" || return 1
    [ "$out" = "true" ]
}

# rtb_wt_create <repo-root> <sha> — prints the new checkout path; non-zero on failure.
rtb_wt_create() {
    local root sha="${2:-}" base rid wt
    root="$(rtb_wt_native "${1:-}")"
    [ -n "${1:-}" ] && [ -n "$sha" ] || { rtb_wt_warn "usage: rtb_wt_create <root> <sha>"; return 2; }
    base="$(rtb_wt_base_dir)"
    mkdir -p "$base" 2>/dev/null || { rtb_wt_warn "cannot create $base"; return 1; }
    rid="$(run_all_dur_repo_id "$root")"
    wt="$base/$rid-$(date +%s)-$$"
    while [ -e "$wt" ]; do wt="$wt-$RANDOM"; done
    if ! git -C "$root" worktree add --detach "$wt" "$sha" >/dev/null 2>&1; then
        rtb_wt_warn "git worktree add failed for $sha"
        return 1
    fi
    if ! node "$(rtb_wt_native "$RTB_WT_MARKER_JS")" mark "$wt" >/dev/null 2>&1; then
        rtb_wt_warn "cannot mark $wt; removing it"
        rtb_wt_remove "$root" "$wt"
        return 1
    fi
    printf '%s\n' "$wt"
}

# rtb_wt_remove <repo-root> <path> — discard changes, then an unforced remove. Warns on failure.
rtb_wt_remove() {
    local root wt
    root="$(rtb_wt_native "${1:-}")"
    wt="$(rtb_wt_native "${2:-}")"
    [ -n "${2:-}" ] && [ -d "$wt" ] || return 0
    git -C "$wt" checkout -- . >/dev/null 2>&1 || true
    git -C "$wt" clean -fdxq >/dev/null 2>&1 || true
    if ! git -C "$root" worktree remove "$wt" >/dev/null 2>&1; then
        rtb_wt_warn "could not remove $wt; left in place for the next sweep"
        return 1
    fi
    return 0
}

# True when <name> (<repo_id>-<epoch>-<pid>) belongs to a live, recent run.
rtb_wt_in_use() {
    local name="${1##*/}" epoch pid now
    pid="${name##*-}"
    epoch="${name%-*}"
    epoch="${epoch##*-}"
    case "$pid$epoch" in ''|*[!0-9]*) return 1 ;; esac
    now="$(date +%s)"
    [ $((now - epoch)) -lt "$RTB_WT_LIVE_GRACE_SECS" ] || return 1
    [ "$pid" != "$$" ] || return 1
    kill -0 "$pid" 2>/dev/null
}

# rtb_wt_sweep_stale <repo-root> — remove marked checkouts left under the base dir.
rtb_wt_sweep_stale() {
    local root base base_lc line wt wt_lc
    root="$(rtb_wt_native "${1:-}")"
    base="$(rtb_wt_base_dir)"
    base_lc="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r line; do
        case "$line" in "worktree "*) ;; *) continue ;; esac
        wt="${line#worktree }"
        wt_lc="$(printf '%s' "$(rtb_wt_native "$wt")" | tr '[:upper:]' '[:lower:]')"
        case "$wt_lc" in "$base_lc"/*) ;; *) continue ;; esac
        rtb_wt_in_use "$wt" && continue
        rtb_wt_is_marked "$wt" || continue
        rtb_wt_remove "$root" "$wt" || true
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null)
    git -C "$root" worktree prune >/dev/null 2>&1 || true
    return 0
}
