#!/usr/bin/env bash
# triage-split.sh — Parse `## Class members` from a full intent/outline document
# and emit pre-tiered MUST / OPTIONAL / NA lists.
#
# Usage:
#   triage-split.sh <path-to-document>
#   triage-split.sh --from-stdin   # piped full document
#
# Contract:
#   - Input must be a FULL document (not a bare `## Class members` block).
#   - Internally invokes "$AGENTS_CONFIG_DIR/bin/extract-mandatory-sections"
#     to lift the `## Class members` block.
#   - Each bullet must follow:
#         - <name>: <description> — disposition: <value>
#     where the delimiter is em-dash U+2014. The RIGHTMOST occurrence of
#     " — disposition: " is used (description text may contain em-dashes).
#   - Disposition values (case-insensitive):
#       MUST | fix in scope        → MUST tier
#       OPTIONAL                   → OPTIONAL tier
#       NA   | track separately    → NA tier
#
# Exit codes:
#   0 — OK
#   2 — input contract violation (AGENTS_CONFIG_DIR unset, file not found,
#       bare-block stdin)
#   3 — fail-loud: a bullet has a missing or unknown disposition value
#
# Output (stdout):
#   ### MUST (fix in scope required)
#   - <name>: <description>
#
#   ### OPTIONAL (planner judgment, justify in plan)
#   - <name>: <description>
#
#   ### NA (out of scope, do not address)
#   - <name>: <description>
#
# Each section header is always emitted; empty tiers print "- (none)".

set -euo pipefail

# Fail-loud: AGENTS_CONFIG_DIR is required. Use explicit check so the exit
# code is the documented 2 (the `:?` syntax under `set -u` would exit with
# the shell's parameter-expansion failure code, typically 1).
if [[ -z "${AGENTS_CONFIG_DIR:-}" ]]; then
  echo "triage-split.sh: AGENTS_CONFIG_DIR is unset" >&2
  exit 2
fi

usage() {
  echo "Usage: triage-split.sh <path> | triage-split.sh --from-stdin" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage

MODE=""
SRC=""
case "$1" in
  --from-stdin)
    MODE="stdin"
    ;;
  -*)
    usage
    ;;
  *)
    MODE="file"
    SRC="$1"
    ;;
esac

EXTRACT="$AGENTS_CONFIG_DIR/bin/extract-mandatory-sections"
if [[ ! -x "$EXTRACT" && ! -f "$EXTRACT" ]]; then
  echo "triage-split.sh: extract-mandatory-sections not found at $EXTRACT" >&2
  exit 2
fi

TMPDOC="$(mktemp)"
trap 'rm -f "$TMPDOC"' EXIT

if [[ "$MODE" == "stdin" ]]; then
  cat > "$TMPDOC"
  # Bare-block detection: input has `## Class members` but no other top-level `## ` heading.
  has_class=$(awk '/^## Class members[[:space:]]*$/{found=1} END{print found+0}' "$TMPDOC")
  has_other=$(awk '/^## /{ if ($0 !~ /^## Class members[[:space:]]*$/) {found=1} } END{print found+0}' "$TMPDOC")
  if [[ "$has_class" == "1" && "$has_other" == "0" ]]; then
    echo "triage-split.sh: stdin input must be a full document, not a bare ## Class members block" >&2
    exit 2
  fi
else
  if [[ ! -f "$SRC" ]]; then
    echo "triage-split.sh: file not found: $SRC" >&2
    exit 2
  fi
  cp "$SRC" "$TMPDOC"
fi

# Probe whether the `## Class members` section is present in the document.
# Use --with-headers so the header line itself appears in the output when the
# section exists. Distinguishes:
#   - Section present with `- (none detected)` placeholder → empty tiers, exit 0
#   - Section absent entirely                              → fail-loud, exit 2
HEADER_PROBE="$(bash "$EXTRACT" "$TMPDOC" --section "Class members" --with-headers 2>/dev/null || true)"
if ! printf '%s\n' "$HEADER_PROBE" | grep -q '^## Class members[[:space:]]*$'; then
  echo "triage-split.sh: input document is missing required '## Class members' section" >&2
  exit 2
fi

# Extract the Class members block (without the heading line for cleaner parsing).
BLOCK="$(bash "$EXTRACT" "$TMPDOC" --section "Class members" 2>/dev/null || true)"

# If no block content or it is the "(none detected)" stub, emit empty tiers.
must_list=""
optional_list=""
na_list=""

if [[ -n "${BLOCK//[[:space:]]/}" ]]; then
  # Parse each bullet line.
  while IFS= read -r line; do
    # Skip empty lines / non-bullet lines.
    [[ -z "${line//[[:space:]]/}" ]] && continue
    case "$line" in
      -\ *) ;;
      *) continue ;;
    esac

    # Skip the "(none detected)" / legacy stub markers.
    case "$line" in
      "- (none detected)"|"- (none detected) "*) continue ;;
      "- (none —"*|"- (none -"*) continue ;;
    esac

    # Use awk to split on RIGHTMOST " — disposition: " (em-dash U+2014).
    # Returns: name_desc<TAB>disposition_value
    parsed="$(printf '%s\n' "$line" | awk '
      BEGIN { delim = " \xe2\x80\x94 disposition: " }
      {
        # Find rightmost occurrence
        n = length($0)
        dl = length(delim)
        pos = 0
        for (i = n - dl + 1; i >= 1; i--) {
          if (substr($0, i, dl) == delim) { pos = i; break }
        }
        if (pos == 0) { print "__NO_DELIM__\t" $0; next }
        left = substr($0, 1, pos - 1)
        right = substr($0, pos + dl)
        # left starts with "- <name>: <description>" — strip leading "- "
        sub(/^- /, "", left)
        # trim right
        sub(/^[[:space:]]+/, "", right)
        sub(/[[:space:]]+$/, "", right)
        print left "\t" right
      }
    ')"

    name_desc="${parsed%%$'\t'*}"
    disp="${parsed#*$'\t'}"

    if [[ "$name_desc" == "__NO_DELIM__" ]]; then
      echo "triage-split.sh: bullet missing ' — disposition: ' delimiter: $line" >&2
      exit 3
    fi

    # Classify (case-insensitive).
    disp_lc="$(printf '%s' "$disp" | tr '[:upper:]' '[:lower:]')"
    case "$disp_lc" in
      must|"fix in scope")
        must_list+="- ${name_desc}"$'\n'
        ;;
      optional)
        optional_list+="- ${name_desc}"$'\n'
        ;;
      na|"track separately")
        na_list+="- ${name_desc}"$'\n'
        ;;
      *)
        echo "triage-split.sh: unknown disposition value: '$disp' (line: $line)" >&2
        exit 3
        ;;
    esac
  done <<< "$BLOCK"
fi

emit_tier() {
  local header="$1" body="$2"
  printf '%s\n' "$header"
  if [[ -z "${body//[[:space:]]/}" ]]; then
    printf -- '- (none)\n'
  else
    printf '%s' "$body"
  fi
}

emit_tier "### MUST (fix in scope required)" "$must_list"
printf '\n'
emit_tier "### OPTIONAL (planner judgment, justify in plan)" "$optional_list"
printf '\n'
emit_tier "### NA (out of scope, do not address)" "$na_list"
