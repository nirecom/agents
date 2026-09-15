#!/bin/bash
# session-sync-init.sh - Initialize ~/.claude/projects as a git repo for session sync
# Usage: Called by install.sh, or manually: ./session-sync-init.sh
#
# Security contract (#1773): the remote URL must match the allowlist, $CLAUDE_DIR
# must resolve inside $HOME and $PROJECTS_DIR strictly inside $CLAUDE_DIR, and an
# existing $CLAUDE_DIR/.git is migrated only when its origin matches the expected
# one. Every gate runs before the first filesystem write.

set -euo pipefail

if [ -z "${C_RESET+x}" ]; then
    if [ -t 1 ]; then
        C_GREEN='\033[0;32m'; C_GRAY='\033[0;90m'; C_RESET='\033[0m'
    else
        C_GREEN=''; C_GRAY=''; C_RESET=''
    fi
fi

CLAUDE_DIR="$HOME/.claude"
_DEFAULT_REMOTE="git@github.com:nirecom/agent-sessions.git"
REMOTE_URL=""
EXPECTED_ORIGIN=""
NO_REMOTE=false

# POSIX ERE, shared verbatim with install/win/session-sync-init.ps1 and
# tests/fixtures/session-sync-remote-url-patterns.txt. Capturing groups only:
# a non-capturing group would be rejected by bash and accepted by .NET.
_URL_RE_SCHEME='^(https|ssh|git)://([^/@]+@)?(\[[0-9A-Fa-f:]*[0-9A-Fa-f][0-9A-Fa-f:]*\]|[A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]+)?(/.*)?$'
_URL_RE_SCP='^[A-Za-z0-9_][A-Za-z0-9_.-]*@[A-Za-z0-9][A-Za-z0-9.-]*:[^:].*$'

_is_allowed_remote_url() {
    [[ "$1" =~ $_URL_RE_SCHEME ]] || [[ "$1" =~ $_URL_RE_SCP ]]
}

# Installer output reaches CI logs and install transcripts, so the userinfo
# password never appears in it.
_redact_url() {
    printf '%s' "$1" | sed -E 's#^([A-Za-z0-9+.-]+://[^/@]*):[^/@]*@#\1:***@#'
}

# _rp_split <path> — dirname/basename in pure parameter expansion, published as
# $_RP_DIR / $_RP_BASE. The external coreutils are deliberately avoided: the
# containment gate must still run when PATH carries no `dirname`/`basename`,
# because it is evaluated before the git availability probe.
_rp_split() {
    local rps_p="$1"
    while [ "${rps_p%/}" != "$rps_p" ] && [ "$rps_p" != "/" ]; do
        rps_p="${rps_p%/}"
    done
    if [ "$rps_p" = "/" ]; then
        _RP_DIR="/"
        _RP_BASE="/"
        return 0
    fi
    _RP_BASE="${rps_p##*/}"
    if [ "$_RP_BASE" = "$rps_p" ]; then
        _RP_DIR="."
        return 0
    fi
    _RP_DIR="${rps_p%/*}"
    while [ "${_RP_DIR%/}" != "$_RP_DIR" ] && [ "$_RP_DIR" != "/" ]; do
        _RP_DIR="${_RP_DIR%/}"
    done
    [ -n "$_RP_DIR" ] || _RP_DIR="/"
    return 0
}

# _resolve_realpath <path> — the fully symlink-resolved, `..`-normalized location
# a path denotes, whether or not it exists yet. Resolution walks up to the
# deepest existing ancestor, resolves that for real, then re-applies the missing
# tail: a symlink hiding in an intermediate component is expanded like any other.
# A final component that is itself a symlink to a missing or non-directory target
# is followed too: `cd -P` cannot reach it, and reporting it as an inert leaf
# would hand the containment check a path the later mkdir/git never writes to.
_resolve_realpath() {
    local p="$1"
    local rest="" parent leaf base out seg target
    local hops=0
    [ -n "$p" ] || return 1
    while :; do
        while [ ! -e "$p" ] && [ ! -L "$p" ]; do
            _rp_split "$p"
            parent="$_RP_DIR"
            leaf="$_RP_BASE"
            [ "$parent" != "$p" ] || break
            rest="$leaf${rest:+/$rest}"
            p="$parent"
        done
        # A symlink onto an existing directory is left to `cd -P` below.
        if [ ! -L "$p" ] || [ -d "$p" ]; then
            break
        fi
        hops=$((hops + 1))
        # ELOOP, fail-closed: a looping chain must not spin forever.
        [ "$hops" -le 40 ] || return 1
        target=$(readlink -- "$p" 2>/dev/null) || return 1
        [ -n "$target" ] || return 1
        if [ "${target#/}" = "$target" ]; then
            _rp_split "$p"
            target="$_RP_DIR/$target"
        fi
        p="$target"
    done
    if [ -d "$p" ]; then
        base="$(cd "$p" 2>/dev/null && pwd -P)" || return 1
    elif [ -e "$p" ] || [ -L "$p" ]; then
        _rp_split "$p"
        base="$(cd "$_RP_DIR" 2>/dev/null && pwd -P)/$_RP_BASE" || return 1
    else
        base="$p"
    fi
    [ -n "$base" ] || return 1
    out="$base"
    if [ -n "$rest" ]; then
        local IFS=/
        for seg in $rest; do
            case "$seg" in
                ''|'.') ;;
                '..') _rp_split "$out"; out="$_RP_DIR" ;;
                *) out="$out/$seg" ;;
            esac
        done
    fi
    printf '%s' "$out"
}

# no_clobber_rename <from> <to> — rename only onto a free destination. Success is
# the post-condition "from gone AND to present", never the exit code: GNU `mv -n`
# returns 0 while silently skipping a collision.
no_clobber_rename() {
    local ncr_from="$1"
    local ncr_to="$2"
    if [ -e "$ncr_to" ] || [ -L "$ncr_to" ]; then
        return 1
    fi
    if ! mv -n -T -- "$ncr_from" "$ncr_to" 2>/dev/null; then
        mv -- "$ncr_from" "$ncr_to" 2>/dev/null || true
    fi
    if [ -e "$ncr_from" ] || [ -L "$ncr_from" ]; then
        return 1
    fi
    if [ ! -e "$ncr_to" ] && [ ! -L "$ncr_to" ]; then
        return 1
    fi
    return 0
}

# migrate_git_root <src> <dst> — move .git/.gitignore/.gitattributes from src to
# dst as one transaction: Phase 0 refuses to start over stale staging names,
# Phase 1a stages dst's incumbents, Phase 1b moves src's copies in, Phase 2
# promotes them onto the bare names, Phase 3 deletes the staged incumbents.
# Any failure before Phase 3 rolls every completed rename back; a Phase 3 failure
# leaves litter but keeps the success verdict, the data being migrated already.
migrate_git_root() {
    local src="$1"
    local dst="$2"
    local pid=$$
    local names=".git .gitignore .gitattributes"
    local staged_old="" staged_tmp="" promoted=""
    local n dir stale

    _mgr_rollback() {
        local r
        for r in $promoted; do
            if [ -e "$dst/$r" ] || [ -L "$dst/$r" ]; then
                mv -- "$dst/$r" "$dst/${r#.}.migrate-tmp.$pid" 2>/dev/null || true
            fi
        done
        for r in $staged_tmp; do
            if [ -e "$dst/${r#.}.migrate-tmp.$pid" ] || [ -L "$dst/${r#.}.migrate-tmp.$pid" ]; then
                mv -- "$dst/${r#.}.migrate-tmp.$pid" "$src/$r" 2>/dev/null || true
            fi
        done
        for r in $staged_old; do
            if [ -e "$dst/${r#.}.old.$pid" ] || [ -L "$dst/${r#.}.old.$pid" ]; then
                mv -- "$dst/${r#.}.old.$pid" "$dst/$r" 2>/dev/null || true
            fi
        done
    }

    for dir in "$src" "$dst"; do
        [ -d "$dir" ] || continue
        # shellcheck disable=SC2010 # a glob cannot see the dotfiles (.git.old.N)
        stale=$(ls -A "$dir" 2>/dev/null | grep -E '\.(old|migrate-tmp)\.[0-9]+$' | head -1 || true)
        if [ -n "$stale" ]; then
            echo "Migration aborted: stale staging path $dir/$stale" >&2
            return 1
        fi
    done

    for n in $names; do
        if [ -e "$src/$n" ] || [ -L "$src/$n" ]; then
            if [ -e "$dst/$n" ] || [ -L "$dst/$n" ]; then
                if no_clobber_rename "$dst/$n" "$dst/${n#.}.old.$pid"; then
                    staged_old="$staged_old $n"
                else
                    _mgr_rollback
                    echo "Migration aborted: could not stage $dst/$n" >&2
                    return 1
                fi
            fi
        fi
    done

    for n in $names; do
        if [ -e "$src/$n" ] || [ -L "$src/$n" ]; then
            if no_clobber_rename "$src/$n" "$dst/${n#.}.migrate-tmp.$pid"; then
                staged_tmp="$staged_tmp $n"
            else
                _mgr_rollback
                echo "Migration aborted: could not move $src/$n" >&2
                return 1
            fi
        fi
    done

    for n in $staged_tmp; do
        if no_clobber_rename "$dst/${n#.}.migrate-tmp.$pid" "$dst/$n"; then
            promoted="$promoted $n"
        else
            _mgr_rollback
            echo "Migration aborted: could not promote $dst/$n" >&2
            return 1
        fi
    done

    for n in $staged_old; do
        rm -rf -- "$dst/${n#.}.old.$pid" 2>/dev/null || true
    done

    return 0
}

# _harden_repo <repo> — neutralize the repo-supplied code paths git would
# otherwise run on our behalf. It must be applied before the first git command
# that touches the worktree: a migrated repo carries its own hooks, fsmonitor
# command and filter definitions, and a checkout is enough to execute them.
_harden_repo() {
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config core.fsmonitor false
}

# _restore_missing_tracked <repo> <worktree> — bring back the tracked files the
# git-root move made look deleted, without overwriting anything already present
# at the destination: only paths git reports as missing are checked out. The
# work-tree is the OLD root, not the new one: the index paths are still relative
# to it, so any other work-tree would recreate them one level too deep.
# The `projects` pathspec is what keeps the restore from re-scattering the old
# root: only session files under projects/<enc>/ belong at the new location,
# while .gitignore/.gitattributes and top-level *.jsonl never did.
_restore_missing_tracked() {
    local rmt_dir="$1/.git"
    local rmt_wt="$2"
    git -C "$rmt_wt" --git-dir="$rmt_dir" --work-tree="$rmt_wt" ls-files -z --deleted -- projects 2>/dev/null |
        xargs -0 git -C "$rmt_wt" --git-dir="$rmt_dir" --work-tree="$rmt_wt" checkout -- >/dev/null 2>&1 || true
}

while [ $# -gt 0 ]; do
    case "$1" in
        --claude-dir) CLAUDE_DIR="$2"; shift 2 ;;
        --remote-url) REMOTE_URL="$2"; shift 2 ;;
        --expected-origin) EXPECTED_ORIGIN="$2"; shift 2 ;;
        --no-remote) NO_REMOTE=true; shift ;;
        *) shift ;;
    esac
done

# Resolve remote URL: --remote-url arg > .env > default
_remote_url_env_file=""
if [ -z "$REMOTE_URL" ] && ! "$NO_REMOTE"; then
    _script_dir="$(cd "$(dirname "$0")" && pwd)"
    _env_file="$(cd "$_script_dir/../.." && pwd)/.env"
    if [ -f "$_env_file" ]; then
        _env_val=$(grep -E '^SESSION_SYNC_REMOTE_URL=' "$_env_file" | head -1 | cut -d= -f2- | tr -d "\"'" || true)
        if [ -n "$_env_val" ]; then
            REMOTE_URL="$_env_val"
            _remote_url_env_file="$_env_file"
        fi
    fi
    REMOTE_URL="${REMOTE_URL:-$_DEFAULT_REMOTE}"
fi

if ! "$NO_REMOTE" && [ -n "$REMOTE_URL" ]; then
    if ! _is_allowed_remote_url "$REMOTE_URL"; then
        echo "Refusing remote URL outside the allowlist: $(_redact_url "$REMOTE_URL")" >&2
        echo "Only https/ssh/git URLs and the SCP-like user@host:path form are accepted." >&2
        exit 1
    fi
fi

_resolved_home=$(_resolve_realpath "$HOME" || true)
_resolved_claude=$(_resolve_realpath "$CLAUDE_DIR" || true)
if [ -z "$_resolved_home" ] || [ -z "$_resolved_claude" ]; then
    echo "Refusing to continue: unable to resolve \$HOME or the claude dir." >&2
    exit 1
fi
case "$_resolved_claude" in
    "$_resolved_home"|"$_resolved_home"/*) ;;
    *)
        echo "Refusing a claude dir outside \$HOME: $_resolved_claude" >&2
        exit 1
        ;;
esac
CLAUDE_DIR="$_resolved_claude"

_resolved_projects=$(_resolve_realpath "$CLAUDE_DIR/projects" || true)
case "${_resolved_projects:-}" in
    "$CLAUDE_DIR"/*) ;;
    *)
        echo "Refusing a projects dir outside the claude dir: ${_resolved_projects:-<unresolvable>}" >&2
        exit 1
        ;;
esac
PROJECTS_DIR="$_resolved_projects"

if ! type git >/dev/null 2>&1; then
    echo "Git is required for session sync." >&2
    exit 1
fi

# Provenance (detail.md A1): an unidentified repo under ~/.claude may be the
# user's own unrelated work, so migration needs a positive origin match.
# Expected origin: explicit --expected-origin > the validated remote URL > absent.
_expected_origin="$EXPECTED_ORIGIN"
if [ -z "$_expected_origin" ] && ! "$NO_REMOTE"; then
    # A `.env` sitting inside the very tree whose trustworthiness is being judged
    # cannot authorize its own migration, so it is dropped as a provenance source
    # while still standing as the remote-URL source.
    _env_origin_trusted=true
    if [ -n "$_remote_url_env_file" ]; then
        _resolved_env_file=$(_resolve_realpath "$_remote_url_env_file" || true)
        case "${_resolved_env_file:-}" in
            "$CLAUDE_DIR"|"$CLAUDE_DIR"/*) _env_origin_trusted=false ;;
        esac
    fi
    if "$_env_origin_trusted"; then
        _expected_origin="$REMOTE_URL"
    fi
fi

if [ -d "$CLAUDE_DIR/.git" ]; then
    if [ -z "$_expected_origin" ]; then
        echo "Refusing to migrate $CLAUDE_DIR/.git: no expected origin to verify it against." >&2
        echo "Re-run with --expected-origin <url> if this really is the session-sync repo." >&2
        exit 1
    fi
    _old_origin=$(git -C "$CLAUDE_DIR" remote get-url origin 2>/dev/null || true)
    if [ -z "$_old_origin" ]; then
        echo "Refusing to migrate $CLAUDE_DIR/.git: it has no origin to verify." >&2
        exit 1
    fi
    if [ "$_old_origin" != "$_expected_origin" ]; then
        echo "Refusing to migrate $CLAUDE_DIR/.git: origin $(_redact_url "$_old_origin") is not the expected one." >&2
        exit 1
    fi
    # The destination loses its own .git to this migration, so a destination that
    # is a repository in its own right — a linked worktree or submodule, or a repo
    # published to some other origin — is refused instead of consumed.
    if [ -e "$PROJECTS_DIR/.git" ] || [ -L "$PROJECTS_DIR/.git" ]; then
        if [ ! -d "$PROJECTS_DIR/.git" ]; then
            echo "Refusing to migrate onto $PROJECTS_DIR: its .git is not a plain repo directory (linked worktree or submodule)." >&2
            exit 1
        fi
        # A matching origin is the only accepted proof. An origin-less repo is not
        # "nothing contradicting us": it is the user's own unpublished work.
        _dst_origin=$(git -C "$PROJECTS_DIR" remote get-url origin 2>/dev/null || true)
        if [ -z "$_dst_origin" ]; then
            echo "Refusing to migrate onto $PROJECTS_DIR: it is a repo with no origin to identify it as the session-sync repo." >&2
            exit 1
        fi
        if [ "$_dst_origin" != "$_expected_origin" ]; then
            echo "Refusing to migrate onto $PROJECTS_DIR: it is an independent repo with origin $(_redact_url "$_dst_origin")." >&2
            exit 1
        fi
    fi
fi

mkdir -p "$PROJECTS_DIR"

_changed=false

if [ -d "$CLAUDE_DIR/.git" ]; then
    echo "Migrating git root from $CLAUDE_DIR to $PROJECTS_DIR..."
    if ! migrate_git_root "$CLAUDE_DIR" "$PROJECTS_DIR"; then
        echo "Migration failed; $CLAUDE_DIR was left as it was." >&2
        exit 1
    fi
    # Hardening first: the restore below is a checkout, and the repo that just
    # arrived is the untrusted one, so its hooks and filters must already be
    # neutralized before git is allowed to touch the worktree.
    _harden_repo "$PROJECTS_DIR"
    # The repo moved, so its tracked files now read as deleted; restore them
    # under the new worktree root. Best-effort: an empty history has none.
    _restore_missing_tracked "$PROJECTS_DIR" "$CLAUDE_DIR"
    _changed=true
fi

if [ ! -d "$PROJECTS_DIR/.git" ]; then
    echo "Initializing git repo in $PROJECTS_DIR..."
    git init "$PROJECTS_DIR"
    _changed=true
else
    printf '%b%s%b\n' "$C_GRAY" "Git repo already exists in $PROJECTS_DIR." "$C_RESET"
fi
_harden_repo "$PROJECTS_DIR"

_attrs_content='# All files under this repo are machine-generated by Claude Code
* text eol=lf
*.jsonl merge=union
'
_attrs_path="$PROJECTS_DIR/.gitattributes"
if [ ! -f "$_attrs_path" ] || [ "$(cat "$_attrs_path")" != "$_attrs_content" ]; then
    printf '%s' "$_attrs_content" > "$_attrs_path"
    _changed=true
fi

_ignore_content='/workflow/*.tmp
'
_ignore_path="$PROJECTS_DIR/.gitignore"
if [ ! -f "$_ignore_path" ] || [ "$(cat "$_ignore_path")" != "$_ignore_content" ]; then
    printf '%s' "$_ignore_content" > "$_ignore_path"
    _changed=true
fi

if ! "$NO_REMOTE"; then
    _existing=$(git -C "$PROJECTS_DIR" remote 2>/dev/null || true)
    if echo "$_existing" | grep -qx "origin"; then
        _current_url=$(git -C "$PROJECTS_DIR" remote get-url origin 2>/dev/null || true)
        if [ "$_current_url" != "$REMOTE_URL" ]; then
            git -C "$PROJECTS_DIR" remote set-url origin "$REMOTE_URL"
            printf '%b%s%b\n' "$C_GREEN" "Remote updated to $(_redact_url "$REMOTE_URL")" "$C_RESET"
            _changed=true
        fi
    else
        git -C "$PROJECTS_DIR" remote add origin "$REMOTE_URL"
        printf '%b%s%b\n' "$C_GREEN" "Remote set to $(_redact_url "$REMOTE_URL")" "$C_RESET"
        _changed=true
    fi
fi

if [ "$_changed" = "true" ]; then
    printf '%b%s%b\n' "$C_GREEN" "Session sync initialized." "$C_RESET"
else
    printf '%b%s%b\n' "$C_GRAY" "Session sync already up to date." "$C_RESET"
fi
