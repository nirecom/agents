#!/bin/bash
# Apply .github/labels.yml to the current repository via `gh label create`.
#
# Usage: bin/github-issues/sync-labels.sh [--repo OWNER/REPO] [--dry-run] [--no-delete] [path-to-labels.yml]
#
# Three-way diff: labels not on remote are created (no --force), labels that
# differ are updated (--force), labels that already match are skipped entirely.
#
# --repo OWNER/REPO targets a repo other than the CWD repo (cross-repo sync).
# Threaded into every gh label list/create call. Without it, gh resolves the
# repo from the current working directory (backward compatible).

set -uo pipefail

# Derive AGENTS_CONFIG_DIR from this script's own path when unset (#2308). CI
# workflows set only GH_TOKEN, so detect-forge-type must resolve without it.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_CONFIG_DIR="${AGENTS_CONFIG_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# URL-encode a string via node (available: detect-forge-type already needs node).
urlenc() { node -e "process.stdout.write(encodeURIComponent(process.argv[1]))" "$1"; }

REPO_FLAG=""
REPO_FLAG_SET=0
LABELS_FILE=""
DRY_RUN=0
NO_DELETE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-delete)
            NO_DELETE=1
            shift
            ;;
        --repo)
            if [ $# -lt 2 ]; then
                echo "Error: --repo requires a value" >&2; exit 2
            fi
            REPO_FLAG="$2"
            REPO_FLAG_SET=1
            shift 2
            ;;
        --repo=*)
            REPO_FLAG="${1#--repo=}"
            REPO_FLAG_SET=1
            shift
            ;;
        *)
            if [ -z "$LABELS_FILE" ]; then LABELS_FILE="$1"
            else echo "Error: extra positional argument: $1" >&2; exit 2
            fi
            shift
            ;;
    esac
done

[ -z "$LABELS_FILE" ] && LABELS_FILE=".github/labels.yml"

if [ ! -f "$LABELS_FILE" ]; then
    echo "Error: labels file not found: $LABELS_FILE" >&2
    exit 1
fi

# Forge detection (#2308). No silent github fallback: gh runs only for FORGE=github.
FORGE=$(node "$AGENTS_CONFIG_DIR/bin/detect-forge-type" --repo-dir . --field type 2>/dev/null)
GL_PROJECT=""
GL_PROJECT_ENC=""

if [ "$FORGE" = "github" ]; then
    # When --repo is supplied, its value must be a strict OWNER/REPO. `[[ =~ ]]`
    # anchors on the whole string (unlike line-oriented grep), rejecting embedded
    # newlines and other injection payloads. An empty value is invalid too.
    if [ "$REPO_FLAG_SET" -eq 1 ]; then
        if ! [[ "$REPO_FLAG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
            echo "Error: invalid --repo value: $REPO_FLAG" >&2; exit 2
        fi
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "Error: gh CLI not found" >&2
        exit 1
    fi
elif [ "$FORGE" = "gitlab" ]; then
    GL_PROJECT=$(node "$AGENTS_CONFIG_DIR/bin/detect-forge-type" --repo-dir . --field project 2>/dev/null)
    if [ -z "$GL_PROJECT" ]; then
        echo "Error: could not resolve GitLab project path from origin" >&2; exit 1
    fi
    # cross-repo is not supported on GitLab: --repo carries no host, so it cannot
    # be verified against the CWD origin. Reject anything other than the CWD project.
    if [ "$REPO_FLAG_SET" -eq 1 ] && [ "$REPO_FLAG" != "$GL_PROJECT" ]; then
        echo "Error: GitLab mode does not support cross-repo --repo; run from the target project's worktree" >&2; exit 2
    fi
    GL_PROJECT_ENC=$(urlenc "$GL_PROJECT")
    if ! command -v glab >/dev/null 2>&1; then
        echo "Error: glab CLI not found" >&2
        exit 1
    fi
else
    echo "Error: unsupported or undetected forge (type=${FORGE:-unknown}); no github fallback" >&2
    exit 1
fi

# Forge-neutral label CRUD wrappers. The awk 3-way diff engine below consumes a
# TSV (name/color/description) identically for both forges (CPR-SSOT). GitLab
# colors are #RRGGBB, so list strips the '#' and create/update re-add it.
label_list() {
    if [ "$FORGE" = "gitlab" ]; then
        glab api "projects/$GL_PROJECT_ENC/labels" --paginate \
            --jq '.[] | [.name, (.color|ltrimstr("#")), .description] | @tsv'
    else
        gh label list ${REPO_FLAG:+--repo "$REPO_FLAG"} --json name,color,description --limit 1000 \
            --jq '.[] | [.name, .color, .description] | @tsv'
    fi
}
label_create() {
    local name="$1" color="$2" desc="$3"
    if [ "$FORGE" = "gitlab" ]; then
        glab api "projects/$GL_PROJECT_ENC/labels" -X POST -f name="$name" -f color="#$color" -f description="$desc"
    else
        gh label create ${REPO_FLAG:+--repo "$REPO_FLAG"} "$name" --color "$color" --description "$desc"
    fi
}
label_update() {
    local name="$1" color="$2" desc="$3"
    if [ "$FORGE" = "gitlab" ]; then
        glab api "projects/$GL_PROJECT_ENC/labels/$(urlenc "$name")" -X PUT -f color="#$color" -f description="$desc"
    else
        gh label create ${REPO_FLAG:+--repo "$REPO_FLAG"} "$name" --color "$color" --description "$desc" --force
    fi
}
label_delete() {
    local name="$1"
    if [ "$FORGE" = "gitlab" ]; then
        glab api "projects/$GL_PROJECT_ENC/labels/$(urlenc "$name")" -X DELETE
    else
        gh label delete ${REPO_FLAG:+--repo "$REPO_FLAG"} "$name" --yes
    fi
}

C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_GRAY='\033[0;90m'
C_RED='\033[0;31m'
C_RESET='\033[0m'

# Parse the YAML with a small awk script. We only support the limited schema
# used by .github/labels.yml: a flat list of {name, color, description}.
# Lines look like:
#   - name: "type:task"
#     color: "0e8a16"
#     description: "..."
parse_and_apply() {
    awk '
        function strip(s) { gsub(/^[ \t]*[-]?[ \t]*[a-zA-Z_]+:[ \t]*/, "", s); gsub(/^"/, "", s); gsub(/"$/, "", s); return s }
        /^[ \t]*#/ { next }
        /^[ \t]*-[ \t]*name:/ {
            if (name != "") print name "\t" color "\t" desc
            name = strip($0); color = ""; desc = ""; next
        }
        /^[ \t]+color:/ { color = strip($0); next }
        /^[ \t]+description:/ { desc = strip($0); next }
        END { if (name != "") print name "\t" color "\t" desc }
    ' "$LABELS_FILE"
}

# Read the protected: top-level key from labels.yml.
# Lines under "protected:" starting with "  - " are protected label names.
PROTECTED_CSV=""
_in_protected=0
while IFS= read -r _line; do
    case "$_line" in
        protected:*)
            _in_protected=1
            ;;
        "- name:"*|"  color:"*|"  description:"*)
            _in_protected=0
            ;;
        *)
            if [ "$_in_protected" = "1" ]; then
                case "$_line" in
                    "  - "*)
                        _pname="${_line#  - }"
                        _pname="${_pname#\"}"
                        _pname="${_pname%\"}"
                        if [ -n "$_pname" ]; then
                            if [ -n "$PROTECTED_CSV" ]; then
                                PROTECTED_CSV="$PROTECTED_CSV,$_pname"
                            else
                                PROTECTED_CSV="$_pname"
                            fi
                        fi
                        ;;
                    "#"*|"")
                        : ;;
                    "- name:"*)
                        _in_protected=0
                        ;;
                    *)
                        _in_protected=0
                        ;;
                esac
            fi
            ;;
    esac
done < "$LABELS_FILE"
unset _in_protected _pname _line

# Read the protected_prefixes: top-level key from labels.yml (#2308). Any label
# whose name starts with one of these prefixes is never deleted by sync (e.g.
# `wip-fp:<hash>` created per-session by wip-state.sh, absent from the YAML list).
PROTECTED_PREFIX_CSV=""
_in_prefixes=0
while IFS= read -r _line; do
    case "$_line" in
        protected_prefixes:*)
            _in_prefixes=1
            ;;
        "- name:"*|"  color:"*|"  description:"*|protected:*)
            _in_prefixes=0
            ;;
        *)
            if [ "$_in_prefixes" = "1" ]; then
                case "$_line" in
                    "  - "*)
                        _ppfx="${_line#  - }"
                        _ppfx="${_ppfx#\"}"
                        _ppfx="${_ppfx%\"}"
                        if [ -n "$_ppfx" ]; then
                            if [ -n "$PROTECTED_PREFIX_CSV" ]; then
                                PROTECTED_PREFIX_CSV="$PROTECTED_PREFIX_CSV,$_ppfx"
                            else
                                PROTECTED_PREFIX_CSV="$_ppfx"
                            fi
                        fi
                        ;;
                    "#"*|"")
                        : ;;
                    *)
                        _in_prefixes=0
                        ;;
                esac
            fi
            ;;
    esac
done < "$LABELS_FILE"
unset _in_prefixes _ppfx _line

if ! EXISTING=$(label_list); then
    echo "error: label list failed; cannot determine existing labels" >&2
    exit 1
fi

CREATED=0
UPDATED=0
SKIPPED=0
FAIL=0
DELETED=0

while IFS=$'\t' read -r ACTION NAME COLOR DESC; do
    [ -z "$ACTION" ] && continue
    case "$ACTION" in
        CREATE)
            printf '%b%s (created)%b\n' "$C_GREEN" "$NAME" "$C_RESET"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                printf '  [DRY-RUN] Would create: %s\n' "$NAME"
                CREATED=$((CREATED + 1))
            elif ! label_create "$NAME" "$COLOR" "$DESC"; then
                echo "  Failed to create $NAME" >&2
                FAIL=$((FAIL + 1))
            else
                CREATED=$((CREATED + 1))
            fi
            ;;
        UPDATE)
            printf '%b%s (updated)%b\n' "$C_YELLOW" "$NAME" "$C_RESET"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                printf '  [DRY-RUN] Would update: %s\n' "$NAME"
                UPDATED=$((UPDATED + 1))
            elif ! label_update "$NAME" "$COLOR" "$DESC"; then
                echo "  Failed to update $NAME" >&2
                FAIL=$((FAIL + 1))
            else
                UPDATED=$((UPDATED + 1))
            fi
            ;;
        SKIP)
            printf '%b%s (already exists)%b\n' "$C_GRAY" "$NAME" "$C_RESET"
            SKIPPED=$((SKIPPED + 1))
            ;;
        DELETE)
            printf '%b%s (deleted)%b\n' "$C_RED" "$NAME" "$C_RESET"
            if [[ "$DRY_RUN" -eq 1 ]]; then
                printf '  [DRY-RUN] Would delete: %s\n' "$NAME"
                DELETED=$((DELETED + 1))
            elif [[ "$NO_DELETE" -eq 1 ]]; then
                printf '  [NO-DELETE] Skipped delete: %s\n' "$NAME"
                DELETED=$((DELETED + 1))
            elif ! label_delete "$NAME"; then
                echo "  Failed to delete $NAME" >&2
                FAIL=$((FAIL + 1))
            else
                DELETED=$((DELETED + 1))
            fi
            ;;
    esac
done < <(awk -v protected_csv="$PROTECTED_CSV" -v protected_prefix_csv="$PROTECTED_PREFIX_CSV" '
    BEGIN {
        FS = OFS = "\t"
        n = split(protected_csv, _pa, ",")
        for (i = 1; i <= n; i++) {
            _k = _pa[i]
            gsub(/^[ \t]+|[ \t]+$/, "", _k)
            if (_k != "") protected_set[_k] = 1
        }
        np = split(protected_prefix_csv, _px, ",")
        for (i = 1; i <= np; i++) {
            _p = _px[i]
            gsub(/^[ \t]+|[ \t]+$/, "", _p)
            if (_p != "") protected_prefix[++prefix_n] = _p
        }
    }
    function is_prefix_protected(name,   j) {
        for (j = 1; j <= prefix_n; j++) {
            if (substr(name, 1, length(protected_prefix[j])) == protected_prefix[j]) return 1
        }
        return 0
    }
    NR == FNR { if ($1 != "") existing[$1] = $2 OFS $3; next }
    {
      key = $1
      if (key == "") next
      yml_seen[key] = 1
      if (!(key in existing))              { print "CREATE", $1, $2, $3 }
      else if (existing[key] == $2 OFS $3) { print "SKIP",   $1, $2, $3 }
      else                                  { print "UPDATE", $1, $2, $3 }
    }
    END {
      for (k in existing) {
        if (!(k in yml_seen) && !(k in protected_set) && !is_prefix_protected(k)) { print "DELETE", k }
      }
    }
' <(printf '%s\n' "$EXISTING") <(parse_and_apply))

TOTAL=$((CREATED + UPDATED + SKIPPED + DELETED + FAIL))
echo "$CREATED created, $UPDATED updated, $SKIPPED already-exists, $DELETED deleted / $TOTAL total"
[ "$FAIL" -eq 0 ]
