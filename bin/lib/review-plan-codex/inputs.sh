#!/usr/bin/env bash
# bin/lib/review-plan-codex/inputs.sh — entrypoint-private input loaders of bin/review-plan-codex.
# Sourced by that entrypoint only (fail-closed); every function reads and sets the entrypoint's
# globals, and untrusted material goes through the entrypoint's defang_untrusted.
# shellcheck disable=SC2034  # the globals set here are read by the entrypoint

resolve_threshold() { # <var-name> <default>
  local name="$1" def="$2" v=""
  v="${!name:-}"
  if [[ ! "$v" =~ ^[0-9]{1,18}$ ]]; then
    v=""
    if [[ -x "$SCRIPT_DIR/get-config-var" ]]; then
      v="$("$SCRIPT_DIR/get-config-var" "$name" "$def" 2>/dev/null)" || v=""
    fi
  fi
  [[ "$v" =~ ^[0-9]{1,18}$ ]] || v="$def"
  [[ "$v" =~ ^0+$ ]] && v="$def"
  printf '%s' "$v"
}

# Load optional context files; a symlinked or credential-shaped one ends the run unread
# (codex_core_input_refused).
rpc_load_context() {
  CONTEXT_CONTENT=""
  for ctx_file in "${CONTEXT_FILES[@]:-}"; do
    [[ -z "$ctx_file" ]] && continue
    if codex_core_input_refused "$ctx_file"; then
      codex_core_emit_failed "refused --context input (symlink or credential-shaped name): ${ctx_file//[[:cntrl:]]/?}"
    fi
    if [[ -f "$ctx_file" && -s "$ctx_file" ]]; then
      CONTEXT_CONTENT+=$(<"$ctx_file")
      CONTEXT_CONTENT+=$'\n\n'
    fi
  done
  CONTEXT_CONTENT="$(defang_untrusted "$CONTEXT_CONTENT")" || codex_core_emit_failed "could not defang the context"
}

# Settled design decisions (Accepted Tradeoffs + Class members triage); the triage semantics
# codex must honour are spelled out in ACCEPTED_TRADEOFFS_BLOCK (agents/lib/triage-legacy-compat.md).
# The two live in different files (#2228): Accepted Tradeoffs via --accepted-tradeoffs, Class
# members via --class-members (intent.md, their SSOT). Each is extracted from its own source and
# concatenated, so the block is unchanged from codex's perspective; an absent/empty source just
# omits its portion (fail-open).
rpc_load_settled_decisions() {
  EXTRACT_BIN="$(dirname "$(realpath "$0")")/extract-mandatory-sections"
  TRADEOFFS_CONTENT=""
  if [[ -n "$ACCEPTED_TRADEOFFS_FILE" && -f "$ACCEPTED_TRADEOFFS_FILE" ]]; then
    TRADEOFFS_CONTENT=$("$EXTRACT_BIN" "$ACCEPTED_TRADEOFFS_FILE" \
      --section "Accepted Tradeoffs" --with-headers 2>/dev/null || true)
  fi
  CLASS_MEMBERS_CONTENT=""
  if [[ -n "$CLASS_MEMBERS_FILE" && -f "$CLASS_MEMBERS_FILE" ]]; then
    CLASS_MEMBERS_CONTENT=$("$EXTRACT_BIN" "$CLASS_MEMBERS_FILE" \
      --section "Class members" --with-headers 2>/dev/null || true)
  fi
  SETTLED_CONTENT=""
  if [[ -n "$TRADEOFFS_CONTENT" ]]; then
    SETTLED_CONTENT="$TRADEOFFS_CONTENT"
  fi
  if [[ -n "$CLASS_MEMBERS_CONTENT" ]]; then
    if [[ -n "$SETTLED_CONTENT" ]]; then
      SETTLED_CONTENT="${SETTLED_CONTENT}"$'\n\n'"${CLASS_MEMBERS_CONTENT}"
    else
      SETTLED_CONTENT="$CLASS_MEMBERS_CONTENT"
    fi
  fi
  SETTLED_CONTENT="$(defang_untrusted "$SETTLED_CONTENT")" || codex_core_emit_failed "could not defang the settled decisions"
  ACCEPTED_TRADEOFFS_BLOCK=""
  if [[ -n "$SETTLED_CONTENT" ]]; then
    TRADEOFFS_CONTENT="$SETTLED_CONTENT"
    ACCEPTED_TRADEOFFS_BLOCK="IMPORTANT — SETTLED DECISIONS (Accepted Tradeoffs + Class members):
The design choices and class-member scope below are finalised by the approved context
and MUST be treated as out of scope for this review. Do NOT raise concerns about these
areas (including triage of class members marked 'NA' or 'OPTIONAL'). Triage
semantics: NA = do not raise why this wasn't fixed; OPTIONAL = do not demand
elevation to MUST; MUST = coverage required (HOW it is covered is still fair
game). Backward compatibility: legacy disposition 'fix in scope' = MUST,
'track separately' = NA. (Full mapping: see agents/lib/triage-legacy-compat.md.)

[ACCEPTED TRADEOFFS START]
${TRADEOFFS_CONTENT}
[ACCEPTED TRADEOFFS END]

"
  fi
}

# Build ledger-concerns block (Round 2+)
rpc_load_ledger_concerns() {
  LEDGER_CONCERNS=""
  if [[ "$ROUND" -ge 2 && -f "$LEDGER" ]]; then
    while IFS='|' read -r CID CSEV CTEXT; do
      [[ -n "$CID" ]] || continue
      LEDGER_LINE="$(defang_untrusted "${CID} [${CSEV}]: ${CTEXT}")" \
        || codex_core_emit_failed "could not defang the ledger concerns"
      LEDGER_CONCERNS+="${LEDGER_LINE}"$'\n'
    done < "$LEDGER"
  fi
}
