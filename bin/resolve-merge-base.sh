#!/usr/bin/env bash
# bin/resolve-merge-base.sh
# Tests: bin/resolve-merge-base.sh
# Tags: merge-base, ssot, baseline, anomaly-detection, scope:common, pwsh-not-required
#
# Single source of truth for "which commit is this branch's base, and can it be trusted?".
#
# Two layers, in order:
#   layer 1  the baseline recorded at branching time (a FACT about this session)
#   layer 2  a guess: origin/main -> main -> HEAD~1
#
# The helper REPORTS a state; it never decides what a consumer should do about it. Every state
# except UNRESOLVED exits 0 — including SUSPECT — so the policy stays with the caller.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_DIR="."
SESSION_ID=""
FORMAT="kv"
DO_FETCH=1
EXPLAIN=0

DEFAULT_MAX_LINES=20000
DEFAULT_MAX_FILES=500

usage() {
  cat >&2 <<'USAGE'
Usage: bin/resolve-merge-base.sh [-C <repo-dir>] [--session <sid>]
                                 [--format kv|base] [--no-fetch] [--explain]

  -C <repo-dir>    repository to inspect (default: .)
  --session <sid>  session id whose recorded baseline should be consulted
  --format kv      key=value block on stdout (default)
  --format base    the base revision only, one line
  --no-fetch       never contact a remote
  --explain        write a candidate-by-candidate diagnostic block to stderr

Exit: 0 usable base (RECORDED/RESOLVED/SUSPECT/FALLBACK), 2 argument error,
      3 UNRESOLVED (stdout still carries the kv block, with an empty base).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -C)
      REPO_DIR="${2:-}"
      [[ -n "$REPO_DIR" ]] || { echo "[resolve-merge-base] -C needs a directory" >&2; exit 2; }
      shift 2
      ;;
    --session)
      SESSION_ID="${2:-}"
      [[ -n "$SESSION_ID" ]] || { echo "[resolve-merge-base] --session needs a value" >&2; exit 2; }
      shift 2
      ;;
    --format)
      FORMAT="${2:-}"
      shift 2
      ;;
    --no-fetch) DO_FETCH=0; shift ;;
    --explain)  EXPLAIN=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)
      echo "[resolve-merge-base] unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

case "$FORMAT" in
  kv|base) ;;
  *) echo "[resolve-merge-base] --format must be kv or base" >&2; exit 2 ;;
esac

g() { git -C "$REPO_DIR" "$@"; }

# ---- reported fields --------------------------------------------------------

# Initialised HERE, above the "not a git repository" early exit below: that exit goes through
# emit_and_exit, so a field first assigned further down would abort under `set -u`.
#
# The kv key ORDER is not part of the contract — every consumer parses it with a `case` over the
# key, so fields may be added or reordered without breaking them.
BASE=""
STATE="UNRESOLVED"
SOURCE="none"
DIFF_LINES="-"
DIFF_FILES="-"
BRANCH="DETACHED"
WARN="none"
ALT_BASE="-"
DETAIL=""
# #1779. A branch with no commits of its own resolves to a base that IS HEAD: correct, and the
# range it implies (`<base>...HEAD`) is empty by construction. These four fields report that
# observation plus the size of the working tree the consumer can fall back to. They are FACTS,
# not a verdict — what to diff instead stays with each consumer.
#
# `uncommitted_*` comes from `git diff HEAD`, so it counts TRACKED paths only. A consumer that
# builds a FILE SET for the degraded range must union `git ls-files --others --exclude-standard`
# separately (prior art: bin/check-verification-gate.sh degraded_scope_files()). There is no
# `untracked_lines` on purpose: counting lines in an untracked file needs one
# `git diff --no-index` per file, which is not worth the cost of a reported number.
BASE_IS_HEAD="-"
UNCOMMITTED_LINES="-"
UNCOMMITTED_FILES="-"
UNTRACKED_FILES="-"

emit_and_exit() { # <exit-code>
  if [[ "$FORMAT" == "base" ]]; then
    printf '%s\n' "$BASE"
  else
    printf 'base=%s\n' "$BASE"
    printf 'state=%s\n' "$STATE"
    printf 'source=%s\n' "$SOURCE"
    printf 'base_is_head=%s\n' "$BASE_IS_HEAD"
    printf 'safe_base=%s\n' "HEAD"
    printf 'uncommitted_lines=%s\n' "$UNCOMMITTED_LINES"
    printf 'uncommitted_files=%s\n' "$UNCOMMITTED_FILES"
    printf 'untracked_files=%s\n' "$UNTRACKED_FILES"
    printf 'diff_lines=%s\n' "$DIFF_LINES"
    printf 'diff_files=%s\n' "$DIFF_FILES"
    printf 'threshold_lines=%s\n' "$MAX_LINES"
    printf 'threshold_files=%s\n' "$MAX_FILES"
    printf 'branch=%s\n' "$BRANCH"
    printf 'warn=%s\n' "$WARN"
    printf 'alt_base=%s\n' "$ALT_BASE"
    printf 'detail=%s\n' "$DETAIL"
  fi
  exit "$1"
}

# ---- thresholds -------------------------------------------------------------
# Resolution order, per axis independently: process env -> bin/get-config-var (the repo's
# .env) -> built-in default. Per axis, because overriding one must not reset the other.

resolve_threshold() { # <var-name> <default>
  local name="$1" def="$2" v=""
  v="${!name:-}"
  if [[ ! "$v" =~ ^[0-9]+$ ]]; then
    v=""
    # Absent in a standalone copy of this file — that is a supported degradation.
    if [[ -x "$SCRIPT_DIR/get-config-var" ]]; then
      v="$("$SCRIPT_DIR/get-config-var" "$name" "$def" 2>/dev/null)" || v=""
    fi
  fi
  [[ "$v" =~ ^[0-9]+$ ]] || v="$def"
  printf '%s' "$v"
}

MAX_LINES="$(resolve_threshold MERGE_BASE_MAX_DIFF_LINES "$DEFAULT_MAX_LINES")"
MAX_FILES="$(resolve_threshold MERGE_BASE_MAX_DIFF_FILES "$DEFAULT_MAX_FILES")"

# ---- repository -------------------------------------------------------------

# $REPO_DIR may be an absolute host filesystem path (caller-supplied via -C). --explain output
# is operator-visible/reviewable, so it is displayed as a bare basename rather than the full
# path — same treatment as the helper-path messages in run-quality-gates.sh / select-tests.sh.
_repo_display() { basename -- "$1" 2>/dev/null || printf '%s' "$1"; }

if ! g rev-parse --git-dir >/dev/null 2>&1; then
  DETAIL="not a git repository: $(_repo_display "$REPO_DIR")"
  if [[ $EXPLAIN -eq 1 ]]; then
    printf '[resolve-merge-base] repo=%s branch=%s state=%s\n' "$(_repo_display "$REPO_DIR")" "-" "UNRESOLVED" >&2
    printf '[resolve-merge-base] %s\n' "$DETAIL" >&2
  fi
  emit_and_exit 3
fi

CUR_BRANCH="$(g rev-parse --abbrev-ref HEAD 2>/dev/null)" || CUR_BRANCH=""
if [[ -n "$CUR_BRANCH" && "$CUR_BRANCH" != "HEAD" ]]; then
  BRANCH="$CUR_BRANCH"
fi

# added+deleted over a range, and the number of changed paths. `git diff --numstat` prints `-`
# in both numeric columns for a binary file: it is one FILE and zero LINES, never a non-numeric
# addend.
count_numstat() { # <numstat-text> ; prints "<lines> <files>"
  local numstat="$1" a d f lines=0 files=0
  if [[ -n "$numstat" ]]; then
    while IFS=$'\t' read -r a d f; do
      [[ -n "${f:-}" ]] || continue
      files=$((files + 1))
      if [[ "$a" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]]; then
        lines=$((lines + a + d))
      fi
    done <<< "$numstat"
  fi
  printf '%s %s' "$lines" "$files"
}

count_range() { # <base> ; prints "<lines> <files>"
  local out
  out="$(g diff --numstat "${1}...HEAD" 2>/dev/null)" || out=""
  count_numstat "$out"
}

count_uncommitted() { # prints "<lines> <files>"
  local out
  out="$(g diff --numstat HEAD 2>/dev/null)" || out=""
  count_numstat "$out"
}

# The other half of the working tree. `git diff HEAD` is blind to untracked paths, so this is a
# SEPARATE axis rather than an addend: a consumer that read only uncommitted_files would report
# "nothing changed" on a branch whose whole change is brand-new files. `--exclude-standard` keeps
# gitignored build output and local scratch out of the census.
count_untracked() { # prints "<files>"
  local out
  out="$(g ls-files --others --exclude-standard 2>/dev/null)" || out=""
  # `grep -c` exits 1 on zero matches, which would surface as a failure under pipefail.
  if [[ -n "$out" ]]; then printf '%s' "$(printf '%s\n' "$out" | grep -c .)"; else printf '0'; fi
}

# ---- layer 1: the recorded baseline ----------------------------------------

REC_BASE=""
REC_BRANCH=""
REC_HEAD=""
REC_SOURCE="recorded-baseline"
REC_POST="false"
REC_ALT="-"
REC_PRESENT=0
DEMOTE_REASON=""

if [[ -z "$SESSION_ID" && -x "$SCRIPT_DIR/resolve-session-id" ]]; then
  SESSION_ID="$("$SCRIPT_DIR/resolve-session-id" 2>/dev/null | head -1 | tr -d '\r')" || SESSION_ID=""
fi

READ_CLI="$SCRIPT_DIR/workflow/read-merge-base-baseline"
if [[ -n "$SESSION_ID" && -f "$READ_CLI" ]]; then
  rec_out=""
  if command -v node >/dev/null 2>&1; then
    rec_out="$(node "$READ_CLI" --session "$SESSION_ID" 2>/dev/null)" || rec_out=""
  elif [[ -x "$READ_CLI" ]]; then
    rec_out="$("$READ_CLI" --session "$SESSION_ID" 2>/dev/null)" || rec_out=""
  fi
  if [[ -n "$rec_out" && "$rec_out" != "NONE" ]]; then
    while IFS='=' read -r rk rv; do
      rv="${rv%$'\r'}"
      case "$rk" in
        base)              REC_BASE="$rv" ;;
        branch)            REC_BRANCH="$rv" ;;
        branch_head)       REC_HEAD="$rv" ;;
        source)            [[ -n "$rv" ]] && REC_SOURCE="$rv" ;;
        post_session_head) REC_POST="$rv" ;;
        alt_base)          REC_ALT="$rv" ;;
        # repo_root is INFORMATIONAL ONLY and must not take part in the decision below. The
        # same session legitimately resolves against a path spelled differently (drive-letter
        # case, /c/... vs C:\..., a symlinked worktree), and comparing paths would demote a
        # correct baseline over a cosmetic mismatch.
        *) : ;;
      esac
    done <<< "$rec_out"
    [[ -n "$REC_BASE" ]] && REC_PRESENT=1
  fi
fi

# Three identity conditions, all of which must hold. A record that cannot be verified is
# treated exactly like one that failed verification: adopting an unverified base is the
# failure mode this whole helper exists to prevent.
if [[ $REC_PRESENT -eq 1 ]]; then
  if [[ -z "$CUR_BRANCH" || "$CUR_BRANCH" == "HEAD" || -z "$REC_BRANCH" || "$REC_BRANCH" != "$CUR_BRANCH" ]]; then
    DEMOTE_REASON="recorded baseline ignored: branch mismatch (recorded [${REC_BRANCH}], current [${CUR_BRANCH:-DETACHED}])"
  # Format-validate before EITHER value reaches a git invocation: the baseline state file is
  # read from disk, not derived, so a tampered or corrupt record with a value starting with
  # '-' would otherwise be parsed by `git merge-base --is-ancestor` as an option rather than
  # rejected by the ancestry check that follows.
  elif ! [[ "$REC_HEAD" =~ ^[0-9a-f]{7,40}$ ]]; then
    DEMOTE_REASON="recorded baseline ignored: the recorded branch_head is not a well-formed commit hash"
  elif ! [[ "$REC_BASE" =~ ^[0-9a-f]{7,40}$ ]]; then
    DEMOTE_REASON="recorded baseline ignored: the recorded base is not a well-formed commit hash"
  elif ! g merge-base --is-ancestor "$REC_HEAD" HEAD >/dev/null 2>&1; then
    DEMOTE_REASON="recorded baseline ignored: the recorded branch_head is not a verified ancestor of HEAD"
  elif ! g merge-base --is-ancestor "$REC_BASE" HEAD >/dev/null 2>&1; then
    DEMOTE_REASON="recorded baseline ignored: the recorded base is not a verified ancestor of HEAD"
  else
    BASE="$REC_BASE"
    STATE="RECORDED"
    SOURCE="$REC_SOURCE"
    [[ "$REC_POST" == "true" ]] && WARN="post-session-head"
    if [[ -n "$REC_ALT" && "$REC_ALT" != "null" && "$REC_ALT" != "undefined" ]]; then
      ALT_BASE="$REC_ALT"
    else
      ALT_BASE="-"
    fi
    DETAIL="recorded baseline adopted (${SOURCE})"
  fi
fi

# ---- layer 2: the guess -----------------------------------------------------

if [[ "$STATE" != "RECORDED" && $DO_FETCH -eq 1 ]]; then
  if [[ -f "$SCRIPT_DIR/run-with-timeout.sh" ]]; then
    bash "$SCRIPT_DIR/run-with-timeout.sh" 20 \
      git -C "$REPO_DIR" fetch origin main --no-tags >/dev/null 2>&1 || true
  else
    g fetch origin main --no-tags >/dev/null 2>&1 || true
  fi
fi

MB_ORIGIN="$(g merge-base origin/main HEAD 2>/dev/null)" || MB_ORIGIN=""
MB_MAIN="$(g merge-base main HEAD 2>/dev/null)" || MB_MAIN=""
MB_HEAD1=""
g rev-parse --verify --quiet 'HEAD~1^{commit}' >/dev/null 2>&1 && MB_HEAD1="HEAD~1"

if [[ "$STATE" != "RECORDED" ]]; then
  if [[ -n "$MB_ORIGIN" ]]; then
    BASE="$MB_ORIGIN"; SOURCE="origin/main"; STATE="RESOLVED"
  elif [[ -n "$MB_MAIN" ]]; then
    BASE="$MB_MAIN"; SOURCE="main"; STATE="RESOLVED"
  elif [[ -n "$MB_HEAD1" ]]; then
    BASE="HEAD~1"; SOURCE="HEAD~1"; STATE="FALLBACK"
    DETAIL="no merge-base against origin/main or main; degraded to HEAD~1"
  else
    BASE=""; SOURCE="none"; STATE="UNRESOLVED"
    DETAIL="no merge-base against origin/main or main, and no HEAD~1 in this repository"
  fi

  # Anomaly detection is layer-2 ONLY, and asymmetric on purpose. A recorded baseline is a
  # fact about where the branch started, so a large diff from it means the branch is large —
  # not that the base is wrong. HEAD~1 is already announced as a degradation.
  if [[ "$SOURCE" == "origin/main" || "$SOURCE" == "main" ]]; then
    read -r DIFF_LINES DIFF_FILES <<< "$(count_range "$BASE")"
    if [[ "$DIFF_LINES" -gt "$MAX_LINES" || "$DIFF_FILES" -gt "$MAX_FILES" ]]; then
      STATE="SUSPECT"
      DETAIL="the range ${SOURCE}...HEAD spans ${DIFF_LINES} lines across ${DIFF_FILES} files (thresholds: ${MAX_LINES} lines / ${MAX_FILES} files), which is implausible for a single branch"
    else
      DETAIL="merge-base against ${SOURCE}"
    fi
    if [[ -n "$MB_ORIGIN" && -n "$MB_MAIN" && "$MB_ORIGIN" != "$MB_MAIN" ]]; then
      if [[ "$SOURCE" == "origin/main" ]]; then ALT_BASE="$MB_MAIN"; else ALT_BASE="$MB_ORIGIN"; fi
    fi
  fi

  [[ -n "$DEMOTE_REASON" ]] && DETAIL="${DEMOTE_REASON}; ${DETAIL}"
fi

DETAIL="${DETAIL//$'\n'/ }"

# ---- the working-tree observation (#1779) -----------------------------------
#
# Runs AFTER $BASE and $STATE are settled — base_is_head cannot be answered before there is a
# base — and covers RECORDED as well as the layer-2 states, because a baseline recorded on a
# branch with no commits names HEAD itself.
#
# One gate for all four fields: `--format base` prints a single line and cannot carry them, so
# neither `git diff --numstat HEAD` nor `git ls-files --others` is worth running there.
if [[ "$FORMAT" == "kv" || $EXPLAIN -eq 1 ]]; then
  HEAD_SHA="$(g rev-parse --verify --quiet HEAD 2>/dev/null)" || HEAD_SHA=""
  if [[ -n "$BASE" && -n "$HEAD_SHA" ]]; then
    # `^{commit}` because a FALLBACK base is the literal string `HEAD~1`, not a sha.
    BASE_SHA="$(g rev-parse --verify --quiet "${BASE}^{commit}" 2>/dev/null)" || BASE_SHA=""
    if [[ -n "$BASE_SHA" ]]; then
      if [[ "$BASE_SHA" == "$HEAD_SHA" ]]; then BASE_IS_HEAD="true"; else BASE_IS_HEAD="false"; fi
    fi
  fi
  read -r UNCOMMITTED_LINES UNCOMMITTED_FILES <<< "$(count_uncommitted)"
  UNTRACKED_FILES="$(count_untracked)"
fi

# ---- --explain (diagnostics only; never on stdout) --------------------------

if [[ $EXPLAIN -eq 1 ]]; then
  explain_row() { # <label> <value-or-empty> <absent-text>
    local label="$1" value="$2" absent="$3" el ef
    if [[ -n "$value" ]]; then
      read -r el ef <<< "$(count_range "$value")"
      printf '  %-18s: %-42s lines=%s files=%s\n' "$label" "$value" "$el" "$ef" >&2
    else
      printf '  %-18s: %-42s lines=%s files=%s\n' "$label" "$absent" "-" "-" >&2
    fi
  }
  printf '[resolve-merge-base] repo=%s branch=%s state=%s base_is_head=%s\n' \
    "$(_repo_display "$REPO_DIR")" "$BRANCH" "$STATE" "$BASE_IS_HEAD" >&2
  if [[ $REC_PRESENT -eq 1 ]]; then
    explain_row "recorded-baseline" "$REC_BASE" "(none)"
  else
    explain_row "recorded-baseline" "" "(none)"
  fi
  explain_row "origin/main" "$MB_ORIGIN" "(unresolvable)"
  explain_row "main" "$MB_MAIN" "(unresolvable)"
  explain_row "HEAD~1" "$MB_HEAD1" "(unresolvable)"
  # Already computed above; recomputing here would run `git diff --numstat HEAD` twice.
  printf '  %-18s: %-42s lines=%s files=%s\n' "safe (uncommitted)" "HEAD" \
    "$UNCOMMITTED_LINES" "$UNCOMMITTED_FILES" >&2
  printf '  %-18s: %-42s lines=%s files=%s\n' "untracked" "(not in HEAD)" "-" "$UNTRACKED_FILES" >&2
  [[ -n "$DEMOTE_REASON" ]] && printf '[resolve-merge-base] %s\n' "$DEMOTE_REASON" >&2
  printf '[resolve-merge-base] detail=%s\n' "$DETAIL" >&2
fi

[[ "$STATE" == "UNRESOLVED" ]] && emit_and_exit 3
emit_and_exit 0
