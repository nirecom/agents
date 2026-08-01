#!/usr/bin/env bash
#
# bin/sweep-issues.sh — /sweep family member: open-issue triage sweeper.
#
# Usage: bin/sweep-issues.sh [--dry-run|--apply] [--deep] [--repo OWNER/REPO]
#                            [--repo-root DIR]
#                            [--band-size N] [--band-index K] [--ci-mode]
#                            [--verify-candidates FILE | --decisions FILE]
#
# TWO REPOSITORIES, ONE RUN: issues come from --repo, but path staleness (SI-2)
# and the SI-4 evidence run are probed against a checkout on disk. Those are only
# the same thing when the working tree IS --repo. When --repo names something
# else, --repo-root must name the checkout to probe; otherwise the run aborts
# rather than reporting one repository's issues against another's files.
#
# Writes by default. --dry-run suppresses EVERY write, including the tier-1
# closes. --deep is an orthogonal axis: it widens the candidate set and emits
# the tier-2 human-gate blocks, and never changes the write mode.
#
# Three exclusive passes (AskUserQuestion is a Claude tool and cannot be called
# from bash, so the human gates live in skills/sweep-issues/SKILL.md and this
# script is ALWAYS non-interactive):
#
#   pass 1  no flag / --deep      SI-1 band → SI-2 stale scan → SI-3 candidate
#                                 report → SI-7 meta-parent scan → tier-1 close
#   pass 2  --verify-candidates   SI-4 evidence for the survivors TSV only
#   pass 3  --decisions           SI-6 close execution and nothing else
#
# --verify-candidates and --decisions each REQUIRE --deep (exit 2 otherwise) and
# are mutually exclusive (exit 2). Requiring --deep for pass 3 is what makes
# "tier 2 only fires when --deep is explicit" true at the machine level.
#
# The judgement axis table (which axis maps to which close action) lives in
# bin/sweep-issues/close-batch.sh's header and is not restated here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SI_DIR="$SCRIPT_DIR/sweep-issues"

# shellcheck source=lib/sweep-write-mode.sh
source "$SCRIPT_DIR/lib/sweep-write-mode.sh"
sweep_write_mode_init
# shellcheck source=./sweep-issues/summary.sh
source "$SI_DIR/summary.sh"

DEEP=0
CI_MODE=0
BAND_SIZE=100
BAND_INDEX=0
REPO=""
REPO_EXPLICIT=0
REPO_ROOT=""
VERIFY_TSV=""
DECISIONS_TSV=""

usage() {
  cat <<'EOF'
Usage: bin/sweep-issues.sh [--dry-run] [--deep] [--repo OWNER/REPO]
                           [--repo-root DIR]
                           [--band-size N] [--band-index K] [--ci-mode]
                           [--verify-candidates FILE | --decisions FILE]

  --deep                Emit the tier-2 human-gate blocks and unlock passes 2/3.
                        Does NOT change the write mode.
  --repo OWNER/REPO     Target repository (default: resolved via `gh repo view`).
  --repo-root DIR       Checkout that path tokens are probed against. Required
                        when --repo names a repository other than the working
                        tree (default: the working tree).
  --band-size N         Issues per band (default 100).
  --band-index K        Zero-based band to sweep (default 0).
  --verify-candidates F Pass 2: gather evidence for the survivors TSV (needs --deep).
  --decisions F         Pass 3: execute the decisions TSV (needs --deep).
  --ci-mode             Emit a one-line JSON summary instead of prose.
EOF
  sweep_write_mode_usage_lines
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --deep) DEEP=1; shift ;;
    --dry-run) sweep_write_mode_dry_run; shift ;;
    --apply) sweep_write_mode_apply; shift ;;
    --ci-mode) CI_MODE=1; shift ;;
    --band-size) BAND_SIZE="${2:?--band-size requires an argument}"; shift 2 ;;
    --band-index) BAND_INDEX="${2:?--band-index requires an argument}"; shift 2 ;;
    --repo) REPO="${2:?--repo requires an argument}"; REPO_EXPLICIT=1; shift 2 ;;
    --repo-root) REPO_ROOT="${2:?--repo-root requires an argument}"; shift 2 ;;
    --verify-candidates) VERIFY_TSV="${2:?--verify-candidates requires an argument}"; shift 2 ;;
    --decisions) DECISIONS_TSV="${2:?--decisions requires an argument}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# ─── Mode gates (before any I/O, so a misuse never half-runs) ────────────────

if [[ -n "$VERIFY_TSV" && -n "$DECISIONS_TSV" ]]; then
  printf 'ERROR: --verify-candidates and --decisions are mutually exclusive\n' >&2
  exit 2
fi
if [[ -n "$VERIFY_TSV" && "$DEEP" -ne 1 ]]; then
  printf 'ERROR: --verify-candidates requires --deep (tier 2 is opt-in)\n' >&2
  exit 2
fi
if [[ -n "$DECISIONS_TSV" && "$DEEP" -ne 1 ]]; then
  printf 'ERROR: --decisions requires --deep (tier 2 writes are opt-in)\n' >&2
  exit 2
fi

# ─── Environment guards: never fail a cron run over a non-GitHub checkout ────

if [[ -x "$SCRIPT_DIR/is-github-dotcom-remote" ]]; then
  if ! "$SCRIPT_DIR/is-github-dotcom-remote" >/dev/null 2>&1; then
    printf 'INFO: not a GitHub.com remote; sweep-issues skipped\n'
    exit 0
  fi
fi
if ! command -v gh >/dev/null 2>&1; then
  printf 'INFO: gh CLI not found; sweep-issues skipped\n'
  exit 0
fi

if [[ -z "$REPO" ]]; then
  REPO="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null || true)"
fi
if [[ -z "$REPO" ]]; then
  printf 'INFO: could not resolve a repository (pass --repo OWNER/REPO); sweep-issues skipped\n'
  exit 0
fi

DRY_FLAG=()
[[ "$DRY_RUN" == "1" ]] && DRY_FLAG=(--dry-run)

# ─── Pass 3 — SI-6 only. Nothing else may run here. ─────────────────────────

if [[ -n "$DECISIONS_TSV" ]]; then
  printf '# sweep-issues pass 3 (decisions) — repo=%s\n' "$REPO"
  # Propagate the batch's status: pass 3 has no summary of its own to carry it.
  "$SI_DIR/close-batch.sh" --decisions "$DECISIONS_TSV" --repo "$REPO" "${DRY_FLAG[@]+"${DRY_FLAG[@]}"}"
  exit $?
fi

# ─── Probe root — the checkout that path tokens are answered against ─────────
# Passes 1 and 2 read the filesystem; pass 3 (above) does not, which is why this
# resolution is deliberately placed after it.

if [[ -n "$REPO_ROOT" ]]; then
  if [[ ! -d "$REPO_ROOT" ]]; then
    printf 'ERROR: --repo-root is not a directory: %s\n' "$REPO_ROOT" >&2
    exit 2
  fi
else
  REPO_ROOT="$PWD"
  # No explicit root: the working tree is being used as the answer for --repo, so
  # they must actually be the same repository. A blank identity (gh cannot see a
  # remote here) is not a proven mismatch and is left alone.
  if [[ "$REPO_EXPLICIT" -eq 1 ]]; then
    wt_repo="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name' 2>/dev/null || true)"
    if [[ -n "$wt_repo" && "$wt_repo" != "$REPO" ]]; then
      printf 'ERROR: --repo %s does not match the working tree repository (%s).\n' "$REPO" "$wt_repo" >&2
      printf '       Path staleness would be probed against %s, so the verdicts would be meaningless.\n' "$wt_repo" >&2
      printf '       Pass --repo-root <dir> naming a checkout of %s, or run from inside it.\n' "$REPO" >&2
      exit 2
    fi
  fi
fi

# ─── Pass 2 — SI-4 evidence for exactly the survivors listed. Read-only. ────

if [[ -n "$VERIFY_TSV" ]]; then
  if [[ ! -f "$VERIFY_TSV" ]]; then
    printf 'ERROR: survivors file not found: %s\n' "$VERIFY_TSV" >&2
    exit 2
  fi
  printf '# sweep-issues pass 2 (verify) — repo=%s\n' "$REPO"
  verified=0
  while IFS=$'\t' read -r s_number s_tokens s_class || [[ -n "${s_number:-}" ]]; do
    [[ -z "${s_number// /}" ]] && continue
    [[ "$s_number" == \#* ]] && continue
    # A number that is not a bare integer would reach verify-candidate.sh (and
    # from there `git grep`) as a flag. Skip the row, keep the pass going.
    if [[ ! "$s_number" =~ ^[0-9]+$ ]]; then
      printf 'SKIP: issue=%s not a bare issue number; row ignored\n' "$s_number" >&2
      continue
    fi
    printf 'EVIDENCE-CLASS: issue=%s class=%s\n' "$s_number" "${s_class:--}"
    "$SI_DIR/verify-candidate.sh" --issue "$s_number" --tokens "${s_tokens:-}" \
      --repo-root "$REPO_ROOT" "${DRY_FLAG[@]+"${DRY_FLAG[@]}"}" || true
    verified=$(( verified + 1 ))
  done < "$VERIFY_TSV"

  printf '<<<TIER2-GATE-SI5\n'
  printf '# Judge each candidate from the EVIDENCE- lines above, not from the issue body.\n'
  printf '# Decisions TSV columns: number<TAB>action<TAB>arg<TAB>rationale\n'
  printf '# action: completed | migrated (arg = surviving issue) | cancelled | scope-reduce\n'
  while IFS=$'\t' read -r s_number s_tokens s_class || [[ -n "${s_number:-}" ]]; do
    [[ -z "${s_number// /}" ]] && continue
    [[ "$s_number" == \#* ]] && continue
    [[ "$s_number" =~ ^[0-9]+$ ]] || continue
    printf '%s\t\t-\t\n' "$s_number"
  done < "$VERIFY_TSV"
  printf '>>>\n'
  printf 'SUMMARY: verified=%s\n' "$verified"
  exit 0
fi

# ─── Pass 1 — scan, report tier 2, close tier 1 ─────────────────────────────

printf '# sweep-issues pass 1 (scan) — repo=%s band=%s/%s\n' "$REPO" "$BAND_INDEX" "$BAND_SIZE"

# Counters the summary reads. Declared before the first fallible step so the
# abort path below can still emit a well-formed summary.
scanned=0
tier2_count=0
tier1_count=0
tier1_closed=0
partial_count=0
errors=0

# SI-1. list-band.sh validates --band-size / --band-index and fetches the band;
# both failures used to be swallowed into `[]`, which let a misuse sail on into
# the meta-parent scan and close tier-1 issues on an empty, unvalidated band.
# Nothing may be closed on the strength of a band we never actually got.
band_rc=0
band_json="$("$SI_DIR/list-band.sh" --repo "$REPO" --band-size "$BAND_SIZE" \
  --band-index "$BAND_INDEX")" || band_rc=$?
if [[ "$band_rc" -ne 0 ]]; then
  printf 'ERROR: band fetch/validation failed (list-band.sh exit %s); aborting before any close\n' \
    "$band_rc" >&2
  errors=1
  emit_scan_summary
fi
[[ -z "$band_json" ]] && band_json='[]'

scanned="$(printf '%s' "$band_json" | node -e '
let a;
try { a = JSON.parse(require("fs").readFileSync(0, "utf8") || "[]"); } catch (e) { a = []; }
process.stdout.write(String(Array.isArray(a) ? a.length : 0));
' || printf '0')"

# SI-2. A detector failure is not fatal (tier 1 does not depend on it) but it is
# never silent: it is counted, so the run cannot report itself as clean.
stale_rc=0
stale_tsv="$(printf '%s' "$band_json" | node "$SI_DIR/scan-stale-paths.js" --repo-root "$REPO_ROOT")" || stale_rc=$?
if [[ "$stale_rc" -ne 0 ]]; then
  printf 'ERROR: stale-path scan failed (scan-stale-paths.js exit %s); tier 2 candidates are incomplete\n' \
    "$stale_rc" >&2
  errors=$(( errors + 1 ))
  stale_tsv=""
fi

# SI-3 does NOT machine-classify. Separating "artifact not built yet" from
# "target deleted by a refactor" is exactly what the human gate is for.
tier2_numbers=()
tier2_tokens=()
if [[ -n "$stale_tsv" ]]; then
  while IFS=$'\t' read -r t_number t_status t_missing t_total t_tokens; do
    [[ -z "${t_number// /}" ]] && continue
    printf 'TIER2-CANDIDATE: issue=%s tokens=%s class=undetermined\n' "$t_number" "${t_tokens:--}"
    tier2_numbers+=("$t_number")
    tier2_tokens+=("${t_tokens:-}")
    tier2_count=$(( tier2_count + 1 ))
  done <<< "$stale_tsv"
fi

# SI-7 — meta parents. Pass 1 only. A failed listing means the tier-1 set is
# unknown; treat the empty result as an error rather than as "nothing to close".
meta_rc=0
meta_tsv="$("$SI_DIR/meta-parent-scan.sh" --repo "$REPO")" || meta_rc=$?
if [[ "$meta_rc" -ne 0 ]]; then
  printf 'ERROR: meta-parent scan failed (meta-parent-scan.sh exit %s); tier 1 was not evaluated\n' \
    "$meta_rc" >&2
  errors=$(( errors + 1 ))
  meta_tsv=""
fi

TIER1_FILE="$(mktemp)"
trap 'rm -f "$TIER1_FILE"' EXIT

if [[ -n "$meta_tsv" ]]; then
  while IFS=$'\t' read -r m_number m_verdict m_open m_title; do
    [[ -z "${m_number// /}" ]] && continue
    printf 'TIER1-META: issue=%s verdict=%s open=%s title=%s\n' \
      "$m_number" "$m_verdict" "${m_open:--}" "${m_title:-}"
    if [[ "$m_verdict" == "all-closed" ]]; then
      printf '%s\tcompleted\t-\ttier1: all sub-issues closed (parent-all-closed-check exit 0)\n' \
        "$m_number" >> "$TIER1_FILE"
      tier1_count=$(( tier1_count + 1 ))
    fi
  done <<< "$meta_tsv"
fi

if [[ "$tier1_count" -gt 0 ]]; then
  # close-batch.sh is documented to exit 0 even when individual rows fail; its
  # real outcome is in the PARTIAL: / SKIP: lines. Both a non-zero exit and any
  # incomplete row must reach `errors`, or a batch that half-closed an issue
  # would still report a clean sweep.
  close_rc=0
  close_out="$("$SI_DIR/close-batch.sh" --decisions "$TIER1_FILE" --repo "$REPO" \
    "${DRY_FLAG[@]+"${DRY_FLAG[@]}"}" 2>&1)" || close_rc=$?
  printf '%s\n' "$close_out"
  if [[ "$close_rc" -ne 0 ]]; then
    printf 'ERROR: tier-1 close batch exited %s\n' "$close_rc" >&2
    errors=$(( errors + 1 ))
  fi
  tier1_closed="$(grep -c '^CLOSED:' <<< "$close_out" || true)"
  partial_count="$(grep -c '^PARTIAL:' <<< "$close_out" || true)"
  skipped_count="$(grep -c '^SKIP:' <<< "$close_out" || true)"
  errors=$(( errors + ${partial_count:-0} + ${skipped_count:-0} ))
fi

# --deep only: the machine-readable block the SKILL.md human gate consumes.
# Its absence in a flagless run is the mechanical guarantee that the default
# path never asks a question.
if [[ "$DEEP" -eq 1 ]]; then
  printf '<<<TIER2-GATE-SI3\n'
  printf '# Separate false positives (artifact not created yet) from real staleness.\n'
  printf '# Survivors TSV columns: number<TAB>tokens_csv<TAB>class\n'
  printf '# class: resolved | refactored-away | duplicate | obsolete | partial\n'
  for i in "${!tier2_numbers[@]}"; do
    printf '%s\t%s\t\n' "${tier2_numbers[$i]}" "${tier2_tokens[$i]}"
  done
  printf '>>>\n'
fi

# Single summary/exit owner — see bin/sweep-issues/summary.sh. Does not return.
emit_scan_summary
