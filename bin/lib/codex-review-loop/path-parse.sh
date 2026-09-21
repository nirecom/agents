#!/usr/bin/env bash
# bin/lib/codex-review-loop/path-parse.sh — the path-kind (planner-format)
# reviewer-output parsers for bin/run-codex-review-loop. Sourced by the loop;
# caller-scope globals: TMP_OUT DELTA_SRC LEDGER ROUND AGENTS_CONFIG_DIR.
# Each function writes the round's delta records into $DELTA_SRC, rewrites
# $TMP_OUT to the transformed content, sets $PARSER, and exits nonzero on a
# structural fault (fail-closed) rather than returning.

# Round 1: the reviewer numbers its own findings; this loop assigns the concern
# IDs the later rounds refer back to. Sets PARSER=numbered.
parse_round1_numbered() {
  local line SEV TEXT VALIDATOR REJECT_REASON CN
  ID_COUNTER=0
  TRANSFORMED_CONTENT=""
  INBLOCK=0

  while IFS= read -r line; do
    if [[ "$line" =~ ^\<!--[[:space:]]*begin-codex-output ]]; then
      INBLOCK=1
      TRANSFORMED_CONTENT+="$line"$'\n'
      continue
    fi
    if [[ "$line" =~ ^\<!--[[:space:]]*end-codex-output ]]; then
      INBLOCK=0
      TRANSFORMED_CONTENT+="$line"$'\n'
      continue
    fi
    if [[ "$INBLOCK" -eq 1 ]] && \
       [[ "$line" =~ ^(C[0-9]+|[0-9]+)\.[[:space:]]\[(HIGH|MEDIUM|LOW)\][[:space:]](.+)$ ]]; then
      SEV="${BASH_REMATCH[2]}"
      TEXT="${BASH_REMATCH[3]}"
      VALIDATOR="${AGENTS_CONFIG_DIR}/bin/validate-hook-scope-concern"
      if [[ -x "$VALIDATOR" ]]; then
        REJECT_REASON=""
        if ! REJECT_REASON="$("$VALIDATOR" "$TEXT" 2>&1)"; then
          echo "run-codex-review-loop: auto-rejected concern ($(( ID_COUNTER + 1 ))): $REJECT_REASON" >&2
          TRANSFORMED_CONTENT+="<!-- auto-rejected: ${REJECT_REASON}: ${TEXT} -->"$'\n'
          continue
        fi
      fi
      ID_COUNTER=$((ID_COUNTER + 1))
      CN="C${ID_COUNTER}"
      printf '%s. [%s] %s\n' "$ID_COUNTER" "$SEV" "$TEXT" >> "$DELTA_SRC"
      TRANSFORMED_CONTENT+="${CN}. [${SEV}] ${TEXT}"$'\n'
    elif [[ "$INBLOCK" -eq 1 ]] && [[ "$line" =~ ^[0-9]+\.[[:space:]] ]]; then
      # Numbered line that did not match the full [HIGH|MEDIUM|LOW] format — format violation.
      echo "run-codex-review-loop: severity format violation in concern: $line" >&2
      exit 4
    else
      TRANSFORMED_CONTENT+="$line"$'\n'
    fi
  done < "$TMP_OUT"

  if [[ $ID_COUNTER -eq 0 ]]; then
    echo "run-codex-review-loop: NEEDS_REVISION with no parseable concerns" >&2
    exit 4
  fi

  # A round 1 that arrives on top of a live ledger is a new cycle, not a
  # collision: the previous cycle is archived rather than renumbered over.
  # Fail closed. Swallowing this rc left the ledger un-archived and still
  # live, and the stage/reduce below then folded round 1 into the previous
  # cycle's entries — the cycle history destroyed silently, at rc 0.
  if ! ledger_cli begin-round --round 1 >/dev/null; then
    echo "run-codex-review-loop: the previous concern cycle could not be archived (round 1 on a live ledger at ${LEDGER}); refusing to reduce round 1 into it" >&2
    rm -f "$DELTA_SRC"
    exit 4
  fi
  PARSER="numbered"
  printf '%s' "$TRANSFORMED_CONTENT" > "$TMP_OUT"
}

# Round 2+: the reviewer may only speak about IDs the ledger already holds.
# Sets PARSER=cnref.
parse_round2_cnref() {
  local line CID STATUS
  [[ -f "$LEDGER" ]] || {
    echo "run-codex-review-loop: ledger missing for round ${ROUND} (expected at ${LEDGER})" >&2
    exit 4
  }

  declare -A LEDGER_IDS
  local LID _rest
  while IFS='|' read -r LID _rest; do
    case "$LID" in ''|'#'*) continue ;; esac
    LEDGER_IDS["$LID"]=1
  done < "$LEDGER"

  local -a DISCARDED=()
  RETAINED_CONTENT=""
  INBLOCK=0

  while IFS= read -r line; do
    if [[ "$line" =~ ^\<!--[[:space:]]*begin-codex-output ]]; then
      INBLOCK=1
      RETAINED_CONTENT+="$line"$'\n'
      continue
    fi
    if [[ "$line" =~ ^\<!--[[:space:]]*end-codex-output ]]; then
      INBLOCK=0
      RETAINED_CONTENT+="$line"$'\n'
      continue
    fi
    if [[ "$INBLOCK" -eq 1 ]] && [[ "$line" =~ ^(C[0-9]+):[[:space:]]*(.*)$ ]]; then
      CID="${BASH_REMATCH[1]}"
      STATUS="${BASH_REMATCH[2]}"
      if [[ -v LEDGER_IDS["$CID"] ]]; then
        RETAINED_CONTENT+="$line"$'\n'
        # Only the lines that report a concern as still open become delta
        # records; an entry nobody restates is closed out by its absence.
        if [[ ! "$STATUS" =~ ^resolved($|[[:space:]]) ]]; then
          printf '%s\n' "$line" >> "$DELTA_SRC"
        fi
      else
        DISCARDED+=("$CID")
      fi
    else
      RETAINED_CONTENT+="$line"$'\n'
    fi
  done < "$TMP_OUT"

  if (( ${#DISCARDED[@]} > 0 )); then
    local DISCARDED_STR
    DISCARDED_STR=$(printf '%s\n' "${DISCARDED[@]}" | sort -V | paste -sd ',' - | sed 's/,/, /g')
    printf 'run-codex-review-loop: discarded new concern IDs in round %s: %s\n' \
      "$ROUND" "$DISCARDED_STR" >&2
  fi

  PARSER="cnref"
  printf '%s' "$RETAINED_CONTENT" > "$TMP_OUT"
}

# path_build_args — populate the global ARGS array for review-plan-codex: the
# draft (--input), the loop budget flags, the ledger from round 2 on, and every
# context file. The ref-kind sibling is rk_build_args. Caller globals: ARGS
# DRAFT FORMAT SID PLANS_DIR CAP MAX_EXT EXT_USED TRADEOFFS ROUND LEDGER
# CONTEXT_OUT EXTRA_CTX CORE_PRINCIPLES REPO_ROOT_ARG CODEX_MCP_FS CLASS_MEMBERS.
path_build_args() {
  local ctx
  ARGS=(
    --input "$DRAFT"
    --format "$FORMAT"
    --session-id "$SID"
    --log-dir "$PLANS_DIR"
    --cap "$CAP"
    --max-extensions "$MAX_EXT"
    --extensions-used "$EXT_USED"
    --accepted-tradeoffs "$TRADEOFFS"
    --round "$ROUND"
  )
  # Class members SSOT (intent.md, #2228): forwarded when the caller named it.
  [[ -n "${CLASS_MEMBERS:-}" ]] && ARGS+=(--class-members "$CLASS_MEMBERS")
  [[ "$ROUND" -ge 2 ]] && ARGS+=(--ledger "$LEDGER")
  if [[ -f "$CONTEXT_OUT" && -s "$CONTEXT_OUT" ]]; then
    ARGS+=(--context "$CONTEXT_OUT")
  fi
  for ctx in "${EXTRA_CTX[@]+"${EXTRA_CTX[@]}"}"; do
    [[ -z "$ctx" ]] && continue
    [[ -f "$ctx" && -s "$ctx" ]] && ARGS+=(--context "$ctx")
  done
  ARGS+=(--context "$CORE_PRINCIPLES")
  # --repo-root is the MCP filesystem sandbox (suppressed when CODEX_MCP_FS=off);
  # --project-root is the NFR lookup root and is forwarded regardless.
  if [[ "${CODEX_MCP_FS:-}" != "off" ]] && [[ -n "$REPO_ROOT_ARG" ]]; then
    ARGS+=(--repo-root "$REPO_ROOT_ARG")
  fi
  [[ -n "$REPO_ROOT_ARG" ]] && ARGS+=(--project-root "$REPO_ROOT_ARG")
}

# path_verdict — extract the reviewer's verdict from its begin/end-codex-output
# block and validate it against the per-format non-APPROVED keyword. Exits 3
# (codex unusable) on an empty or malformed verdict. Sets VERDICT.
# Caller globals: TMP_OUT FORMAT HEADER VERDICT.
path_verdict() {
  VERDICT=$(awk '
    /<!-- begin-codex-output/ { inblock=1; next }
    /<!-- end-codex-output -->/ { inblock=0; next }
    inblock && NF { print; exit }
  ' "$TMP_OUT" | tr -d '\r')

  if [[ -z "$VERDICT" ]]; then
    echo "run-codex-review-loop: codex unavailable or verdict malformed (empty verdict block)" >&2
    exit 3
  fi

  [[ "$VERDICT" =~ ^APPROVED($|[[:space:]].+$) ]] && return 0
  case "$FORMAT" in
    detail-plan|security-plan|test-review)
      [[ "$VERDICT" == "NEEDS_REVISION" ]] || {
        echo "run-codex-review-loop: codex unavailable or verdict malformed (header=$HEADER, verdict=$VERDICT)" >&2
        exit 3
      } ;;
    outline-plan)
      [[ "$VERDICT" =~ ^MISSING_ALTERNATIVE: ]] || {
        echo "run-codex-review-loop: codex unavailable or verdict malformed (header=$HEADER, verdict=$VERDICT)" >&2
        exit 3
      } ;;
  esac
}
