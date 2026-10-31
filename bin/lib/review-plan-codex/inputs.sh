#!/usr/bin/env bash
# bin/lib/review-plan-codex/inputs.sh — entrypoint-private input loaders of bin/review-plan-codex.
# Sourced by that entrypoint only (fail-closed); every function reads and sets the entrypoint's
# globals, and untrusted material goes through the entrypoint's defang_untrusted.
# shellcheck disable=SC2034  # the globals set here are read by the entrypoint

# shellcheck source=SCRIPTDIR/../codex-context-marker.sh
. "$(dirname "${BASH_SOURCE[0]}")/../codex-context-marker.sh" || return 1

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

# _rpc_split_built_context <file> — appends the parts of build-codex-context's output (provenance
# checked by the caller with ccm_is_built) to
# RPC_PART_ROLES / RPC_PART_BODIES, one per marker; the marker and the build's own heading right
# after it are dropped (the trusted side writes the heading). Text before any marker is supporting.
# Only a marker ccm_parse_marker accepts, in CCM_ROLES order, starts a part; any other
# marker-looking line stays body text, and rpc_load_context makes it inert.
_rpc_split_built_context() {
  local line role="" buf="" skip_heading=0 rank last=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ccm_parse_marker "$line" && rank="$(ccm_role_rank "$CCM_ROLE")" && (( rank > last )); then
      _rpc_add_part "${role:-supporting}" "$buf"
      role="$CCM_ROLE"; last="$rank"; buf=""; skip_heading=1
      continue
    fi
    if (( skip_heading )); then
      skip_heading=0
      [[ "${line%[[:cntrl:]]}" == "## $role" ]] && continue
    fi
    buf+="$line"$'\n'
  done < "$1"
  _rpc_add_part "${role:-supporting}" "$buf"
}
_rpc_add_part() { # <role> <body> — a whitespace-only body adds nothing.
  [[ "$2" == *[![:space:]]* ]] || return 0
  RPC_PART_ROLES+=("$1"); RPC_PART_BODIES+=("$2")
}

# Load optional context files; a symlinked or credential-shaped one ends the run unread
# (codex_core_input_refused). Each part is defanged and neutralized, then wrapped by the trusted
# nonce-bearing delimiters and its section heading (hierarchy.sh owns the grammar). CONTEXT_ROLES
# lists the distinct roles wrapped; a nonce found in a body is made again.
rpc_load_context() {
  local ctx_file body i tries=0 all
  CONTEXT_CONTENT=""; CONTEXT_ROLES=""; RPC_PART_ROLES=(); RPC_PART_BODIES=()
  for ctx_file in "${CONTEXT_FILES[@]:-}"; do
    [[ -z "$ctx_file" ]] && continue
    if codex_core_input_refused "$ctx_file"; then
      codex_core_emit_failed "refused --context input (symlink or credential-shaped name): ${ctx_file//[[:cntrl:]]/?}"
    fi
    [[ -f "$ctx_file" && -s "$ctx_file" ]] || continue
    # Only a file whose bytes build-codex-context recorded is split; a same-named file stays one
    # untrusted part, its marker-looking lines defanged below.
    case "${ctx_file##*[/\\]}" in
      codex-context.md|*-codex-context.md) ccm_is_built "$ctx_file" && { _rpc_split_built_context "$ctx_file"; continue; } ;;
    esac
    _rpc_add_part "$(rpc_context_role "$ctx_file")" "$(<"$ctx_file")"
  done
  for i in "${!RPC_PART_BODIES[@]}"; do
    body="$(printf '%s' "${RPC_PART_BODIES[i]}" | ccm_defang_stream)" || codex_core_emit_failed "could not defang the context markers"
    body="$(defang_untrusted "$body")" || codex_core_emit_failed "could not defang the context"
    RPC_PART_BODIES[i]="$(rpc_neutralize_section_lines "$body")" || codex_core_emit_failed "could not neutralize the context"
  done
  all="$(printf '%s\n' "${RPC_PART_BODIES[@]:-}")"
  while :; do
    tries=$((tries + 1))
    (( tries <= 5 )) || codex_core_emit_failed "context section nonce collides with the context on every try"
    rpc_context_nonce || codex_core_emit_failed "could not make the context section nonce"
    [[ "$all" == *"$CONTEXT_NONCE"* ]] || break
  done
  for i in "${!RPC_PART_ROLES[@]}"; do
    local r="${RPC_PART_ROLES[i]}"
    CONTEXT_CONTENT+="[CONTEXT SECTION START nonce=${CONTEXT_NONCE}: ${r}]"$'\n'"## ${r}"$'\n'
    CONTEXT_CONTENT+="${RPC_PART_BODIES[i]}"$'\n'"[CONTEXT SECTION END nonce=${CONTEXT_NONCE}: ${r}]"$'\n\n'
    case " $CONTEXT_ROLES " in *" $r "*) ;; *) CONTEXT_ROLES="${CONTEXT_ROLES:+$CONTEXT_ROLES }$r" ;; esac
  done
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
