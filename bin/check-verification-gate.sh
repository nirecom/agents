#!/usr/bin/env bash
# bin/check-verification-gate.sh
# Tests: bin/check-verification-gate.sh
# Tags: verification-gate, risk-category, user-verified, pwsh-required
#
# Risk-category classifier for the WORKFLOW_USER_VERIFIED preflight gate (#833).
# Reads a list of file paths (staged files by default) and emits zero or more
# risk-category verdict lines on stdout, sorted lexicographically by token.
#
# Stdout line format (TAB-separated):
#   CATEGORY: <token>\tQUESTION: <question text>
#
# Exit codes:
#   0  verdict produced (stdout may be empty)
#   2  usage error
#   3  internal error

set -euo pipefail

if [ "${AGENTS_BASH_MAJOR_OVERRIDE:-${BASH_VERSINFO:-0}}" -lt 4 ]; then
  printf '[check-verification-gate] requires bash >= 4 (found %s). Install a newer bash: '"'"'brew install bash'"'"'.\n' "${BASH_VERSION:-unknown}" >&2
  exit 3
fi

usage() {
    cat >&2 <<'EOF'
Usage: check-verification-gate.sh [--files FILE...] | [--stdin] [--settings-path PATH]
       check-verification-gate.sh   (no args: auto-detect via git diff --cached)

Options:
  --files FILE...       Explicit file list (literal paths, no shell evaluation).
  --stdin               Read newline-separated file paths from stdin.
  --settings-path PATH  Override settings.json resolution.
  -h, --help            Show this help.
EOF
}

# --- Argument parsing -------------------------------------------------------

MODE="auto"
SETTINGS_PATH=""
FILES=()
# Set only by the auto-mode merge-base fallback. --files / --stdin never consult the resolver:
# the caller has already stated the file set, and asking would be both pointless and a
# needless git dependency in a mode that has none.
MERGE_BASE_DEGRADED=0

# Parse args manually so --files can take a variadic list of positional values.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --files)
            if [[ "$MODE" == "stdin" ]]; then
                echo "Error: --files cannot be combined with --stdin" >&2
                exit 2
            fi
            MODE="files"
            shift
            # Consume all subsequent non-flag values as files.
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --*)
                        break
                        ;;
                    *)
                        FILES+=("$1")
                        shift
                        ;;
                esac
            done
            ;;
        --stdin)
            if [[ "$MODE" == "files" ]]; then
                echo "Error: --stdin cannot be combined with --files" >&2
                exit 2
            fi
            MODE="stdin"
            shift
            ;;
        --settings-path)
            if [[ $# -lt 2 ]]; then
                echo "Error: --settings-path requires a value" >&2
                exit 2
            fi
            SETTINGS_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            echo "Error: unknown flag: $1" >&2
            usage
            exit 2
            ;;
        *)
            echo "Error: unexpected positional argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

# --- File-list acquisition --------------------------------------------------

if [[ "$MODE" == "stdin" ]]; then
    while IFS= read -r line; do
        # Skip blank lines.
        [[ -z "$line" ]] && continue
        FILES+=("$line")
    done
elif [[ "$MODE" == "auto" ]]; then
    if ! command -v git >/dev/null 2>&1; then
        echo "Error: git not found and no --files/--stdin provided" >&2
        exit 3
    fi
    if ! staged="$(git diff --cached --name-only 2>/dev/null)"; then
        echo "Error: git diff --cached failed" >&2
        exit 3
    fi
    if [[ -z "$staged" ]]; then
        # Fallback: staged is empty (e.g., ENFORCE_WORKTREE=on, commit already landed).
        # The base comes from bin/resolve-merge-base.sh rather than from a default-branch
        # search of this script's own (#1638): five callers each deriving their own base gave
        # five answers to one question, and this one runs at commit/merge time where a wrong
        # answer silently removes the questions the user was about to be asked.
        #
        # --no-fetch because this runs SYNCHRONOUSLY inside the <<WORKFLOW_USER_VERIFIED>>
        # preflight. A network wait there is a wait the user sits through.
        #
        # Every degradation lands on `git diff HEAD` and RAISES a flag rather than leaving the
        # file set empty. This is the one consumer where the safe direction is inverted: an
        # empty classification produces NO questions, which reads as "nothing needs verifying".
        mb_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-merge-base.sh"
        mb_state=""
        mb_base=""
        if [[ -r "$mb_helper" ]]; then
            mb_rc=0
            mb_out="$(bash "$mb_helper" -C . --format kv --no-fetch 2>/dev/null)" || mb_rc=$?
            if [[ "$mb_rc" -eq 0 ]]; then
                while IFS='=' read -r mb_k mb_v; do
                    case "$mb_k" in
                        base)  mb_base="$mb_v" ;;
                        state) mb_state="$mb_v" ;;
                    esac
                done <<< "$mb_out"
            else
                mb_state="UNRESOLVED"
            fi
        else
            mb_state="UNAVAILABLE"
        fi

        # Degraded scope must also see untracked files: `git diff HEAD --name-only` only
        # reports tracked-file changes, so a brand-new (never `git add`-ed) risky file --
        # e.g. a new install/*.ps1 -- is invisible to the classifier unless it is combined
        # with `git ls-files --others --exclude-standard` (dedupe via `sort -u`).
        degraded_scope_files() {
            { git diff HEAD --name-only 2>/dev/null || true; git ls-files --others --exclude-standard 2>/dev/null || true; } | sort -u
        }

        case "$mb_state" in
            RECORDED|RESOLVED)
                if [[ -n "$mb_base" && "$mb_base" != "-" ]]; then
                    staged="$(git diff "${mb_base}...HEAD" --name-only 2>/dev/null || true)"
                else
                    MERGE_BASE_DEGRADED=1
                    staged="$(degraded_scope_files)"
                fi
                ;;
            *)
                MERGE_BASE_DEGRADED=1
                staged="$(degraded_scope_files)"
                ;;
        esac
        if [[ "$MERGE_BASE_DEGRADED" == "1" ]]; then
            # Also on stderr, because a caller may suppress the questions entirely, and a
            # degradation nobody can see afterwards is a degradation that will happen again.
            echo "[check-verification-gate] merge-base ${mb_state:-UNKNOWN}: classification narrowed to uncommitted changes" >&2
        fi
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        FILES+=("$line")
    done <<< "$staged"
fi

# --- Settings.json resolution -----------------------------------------------

resolve_settings() {
    if [[ -n "$SETTINGS_PATH" ]]; then
        if [[ -f "$SETTINGS_PATH" ]]; then
            printf '%s\n' "$SETTINGS_PATH"
            return 0
        fi
        return 1
    fi
    # Locate repo root from this script's location.
    local script_dir repo_root
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    repo_root="$(cd "$script_dir/.." && pwd)"
    local candidates=()
    if [[ -n "${AGENTS_CONFIG_DIR:-}" ]]; then
        candidates+=("$AGENTS_CONFIG_DIR/settings.json")
    fi
    candidates+=("$repo_root/settings.json")
    candidates+=("$repo_root/.claude/settings.json")
    local c
    for c in "${candidates[@]}"; do
        if [[ -f "$c" ]]; then
            printf '%s\n' "$c"
            return 0
        fi
    done
    return 1
}

# --- Helpers ----------------------------------------------------------------

# Get registered hook basenames from effective settings.json.
# Emits one basename per line (filename minus .js).
# Empty output if no settings.json found or jq unavailable.
get_registered_hooks() {
    local settings
    if ! settings="$(resolve_settings)"; then
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    # Extract every .command across the four event types, then derive a basename
    # by stripping any leading tokens and the .js extension.
    jq -r '
        [
            (.hooks.PreToolUse // []),
            (.hooks.PostToolUse // []),
            (.hooks.Stop // []),
            (.hooks.SessionStart // [])
        ]
        | flatten
        | map(.hooks // [])
        | flatten
        | map(.command // empty)
        | .[]
    ' "$settings" 2>/dev/null | tr -d '\r' | while IFS= read -r cmd; do
        # cmd example: "node hooks/foo.js" or "node /abs/hooks/foo.js arg1"
        # Split into words and find the first token ending in .js
        local word base words
        read -ra words <<< "$cmd"
        for word in "${words[@]}"; do
            case "$word" in
                *.js)
                    base="${word##*/}"
                    base="${base%.js}"
                    printf '%s\n' "$base"
                    break
                    ;;
            esac
        done
    done | sort -u
}

# Test whether a path is "under install/" or matches installer file conventions.
is_installer_path() {
    local p="$1"
    case "$p" in
        */install/*|install/*) return 0 ;;
        *dotfileslink.sh|*dotfileslink.ps1) return 0 ;;
        *.nsi|*.iss) return 0 ;;
    esac
    return 1
}

# Test whether path looks like settings.json (any location).
is_settings_json_path() {
    local p="$1"
    case "$p" in
        settings.json|*/settings.json|.claude/settings.json|*/.claude/settings.json)
            return 0
            ;;
    esac
    return 1
}

# Test whether path is hooks/*.js (any depth prefix allowed; segment must match).
is_hooks_js_path() {
    local p="$1"
    case "$p" in
        hooks/*.js|*/hooks/*.js) ;;
        *) return 1 ;;
    esac
    # Must end with .js (already enforced by case) — also reject deeper subdirs?
    # The spec says "hooks/*.js" (one level). Enforce that the basename's parent
    # equals "hooks".
    local parent
    parent="$(dirname "$p")"
    parent="${parent##*/}"
    [[ "$parent" == "hooks" ]]
}

# Test whether path is under skills/**/*.md (any depth, .md extension).
is_skills_md_path() {
    local p="$1"
    case "$p" in
        skills/*.md|*/skills/*.md)
            # Verify any path component is exactly "skills" and ends with .md.
            [[ "$p" == *.md ]] || return 1
            return 0
            ;;
    esac
    return 1
}

# Test whether path is under install/ AND ends in .ps1.
is_install_ps1_path() {
    local p="$1"
    case "$p" in
        */install/*.ps1|install/*.ps1) return 0 ;;
    esac
    return 1
}

# Check if file body (head -200) mentions pwsh/powershell case-insensitive
# AND does not contain "pwsh-not-required" in a Tags line.
# Only applies to hooks/** or bin/** paths. File must exist on disk.
body_indicates_pwsh_required() {
    local p="$1"
    case "$p" in
        hooks/*|*/hooks/*|bin/*|*/bin/*) ;;
        *) return 1 ;;
    esac
    [[ -f "$p" ]] || return 1
    local head_content
    head_content="$(head -n 200 -- "$p" 2>/dev/null || true)"
    # Opt-out check: any line containing "Tags:" with "pwsh-not-required".
    if printf '%s\n' "$head_content" | grep -qE -- 'Tags:.*pwsh-not-required'; then
        return 1
    fi
    # Match pwsh or powershell (word boundary; case-insensitive).
    if printf '%s\n' "$head_content" | grep -qiE -- '(^|[^[:alnum:]_])(pwsh|powershell)([^[:alnum:]_]|$)'; then
        return 0
    fi
    return 1
}

# Check if a file has '# Tags:' line containing pwsh-required.
tags_contain_pwsh_required() {
    local p="$1"
    [[ -f "$p" ]] || return 1
    head -n 200 -- "$p" 2>/dev/null | grep -qE -- '^[[:space:]]*#[[:space:]]*Tags:.*pwsh-required([^[:alnum:]_-]|$)'
}

# --- Classification ---------------------------------------------------------

# Collect matched categories into a set (use associative array).
declare -A MATCHED=()

# Raised by the auto-mode merge-base fallback above when the classified set had to be narrowed
# to uncommitted changes. It becomes a category of its own: a narrowed set silently drops the
# questions the wider set would have raised, so the narrowing itself has to be asked about.
if [[ "$MERGE_BASE_DEGRADED" == "1" ]]; then
    MATCHED["merge-base-suspect"]=1
fi

# Pre-fetch the registered-hook basename set (only if needed).
REGISTERED_HOOKS=""
need_registered_hooks() {
    if [[ -z "$REGISTERED_HOOKS" ]]; then
        REGISTERED_HOOKS="$(get_registered_hooks || true)"
        # Use a sentinel so we don't re-fetch on empty result.
        if [[ -z "$REGISTERED_HOOKS" ]]; then
            REGISTERED_HOOKS=$'__none__'
        fi
    fi
}

is_hook_registered() {
    local basename="$1"
    need_registered_hooks
    [[ "$REGISTERED_HOOKS" == "__none__" ]] && return 1
    printf '%s\n' "$REGISTERED_HOOKS" | grep -qxF "$basename"
}

classify_one() {
    local p="$1"
    # --- hook-registration --------------------------------------------------
    if is_settings_json_path "$p"; then
        MATCHED["hook-registration"]=1
    elif is_hooks_js_path "$p"; then
        local base
        base="${p##*/}"
        base="${base%.js}"
        if is_hook_registered "$base"; then
            MATCHED["hook-registration"]=1
        fi
    fi

    # --- installer ----------------------------------------------------------
    if is_installer_path "$p"; then
        MATCHED["installer"]=1
    fi

    # --- pwsh-required ------------------------------------------------------
    if is_install_ps1_path "$p"; then
        MATCHED["pwsh-required"]=1
    elif tags_contain_pwsh_required "$p"; then
        MATCHED["pwsh-required"]=1
    elif body_indicates_pwsh_required "$p"; then
        MATCHED["pwsh-required"]=1
    fi

    # --- skill-orchestration ------------------------------------------------
    if is_skills_md_path "$p"; then
        MATCHED["skill-orchestration"]=1
    fi
}

# Iterate input files (deduplicate by exact path for efficiency only —
# dedupe of categories happens via MATCHED set).
if [[ "${#FILES[@]}" -gt 0 ]]; then
    for f in "${FILES[@]}"; do
        [[ -z "$f" ]] && continue
        classify_one "$f"
    done
fi

# --- Emit verdict lines -----------------------------------------------------

# Question text per category token.
question_for() {
    case "$1" in
        hook-registration)
            printf '%s\n' "Did you verify the hook actually fires in a real Claude Code session?"
            ;;
        installer)
            printf '%s\n' "Did you run the installer on a clean target (no prior install state)?"
            ;;
        pwsh-required)
            printf '%s\n' "Did you run the affected paths under pwsh on Windows?"
            ;;
        skill-orchestration)
            printf '%s\n' "Did you run the skill end-to-end (not just unit-tested its scripts)?"
            ;;
        merge-base-suspect)
            printf '%s\n' "Did you confirm the diff scope yourself? The merge-base was not trustworthy, so the classified file set was narrowed to uncommitted changes."
            ;;
        *)
            printf '%s\n' "unknown category"
            ;;
    esac
}

# Sort matched tokens lexicographically.
if [[ "${#MATCHED[@]}" -gt 0 ]]; then
    tokens_sorted="$(printf '%s\n' "${!MATCHED[@]}" | sort)"
    while IFS= read -r tok; do
        [[ -z "$tok" ]] && continue
        q="$(question_for "$tok")"
        printf 'CATEGORY: %s\tQUESTION: %s\n' "$tok" "$q"
    done <<< "$tokens_sorted"
fi

exit 0
