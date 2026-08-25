#!/usr/bin/env bash
# bin/lib/codex-review-loop/ledger-verdict.sh — ledger resolution, CLI wrapper,
# and finalize helper sourced by bin/run-codex-review-loop. Caller-scope globals:
# PLANS_DIR SID FORMAT LEDGER AGENTS_CONFIG_DIR ROUND CAP MAX_EXT EXT_USED TMP_OUT.

# Locate the CLI + library pair under AGENTS_CONFIG_DIR, then the wrapper's own
# repo; all three parts must exist, so a partial root loses (#1992).
# REPO_ROOT_ARG and `git rev-parse --show-toplevel` stopped being candidates at
# #2025 C5: they name the repository *under review*, whose contents are
# untrusted, and ledger_cli runs its pick with `bash` — a planted
# bin/concern-ledger there was code execution. On "not found", point
# AGENTS_CONFIG_DIR at the agents checkout; do not put those roots back.
resolve_concern_ledger() {
  local root
  for root in "${AGENTS_CONFIG_DIR}" \
              "$(dirname "$(dirname "$(realpath "$0" 2>/dev/null || printf '%s' "$0")")")"; do
    [[ -n "$root" ]] || continue
    if [[ -f "$root/bin/concern-ledger" && -f "$root/bin/lib/concern-ledger.sh" \
          && -d "$root/bin/lib/concern-ledger" ]]; then
      CL_CLI="$root/bin/concern-ledger"
      return 0
    fi
  done
  return 1
}

# ledger_cli <subcommand> [args...] — single addressing point for all ledger ops;
# binds the (plans-dir, session, format, ledger) tuple so call sites cannot drift.
ledger_cli() {
  local sub="$1"; shift
  bash "$CL_CLI" "$sub" --plans-dir "$PLANS_DIR" --session-id "$SID" \
    --format "$FORMAT" --ledger "$LEDGER" "$@"
}

# finalize_ledger <mode> <reason> <would-be-verdict>
# Writes the unresolved-concerns artifact; exits 7 (fail-CLOSED) on write failure
# so the caller cannot mark the step complete without a readable artifact.
finalize_ledger() {
  local mode="$1" reason="$2" wouldbe="$3" out msg rc=0
  out="$(ledger_cli finalize --mode "$mode" --reason "$reason" --round "$ROUND" \
      --cap "$CAP" --max-extensions "$MAX_EXT" --extensions-used "$EXT_USED" 2>&1)" || rc=$?
  [[ $rc -eq 0 ]] && return 0
  msg="$(printf '%s\n' "$out" | grep -F '## Concern Ledger: FINALIZE-FAILED — ' | head -n 1)"
  [[ -n "$msg" ]] || msg="## Concern Ledger: FINALIZE-FAILED — the unresolved-concerns artifact could not be written"
  msg="$msg (would-be verdict: $wouldbe)"
  cat "$TMP_OUT"
  printf '%s\n' "$msg"
  printf '%s\n' "$msg" >&2
  exit 7
}
