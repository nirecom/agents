# Part of tests/feature-review-code-codex/path-priority.sh (sourced FIRST, not standalone).
# Tests: bin/review-code-codex
# Tags: codex, review, helpers, fixtures, budget, scope:issue-specific, pwsh-not-required, TL2
#
# The fixture builders and observation helpers every P-row shares. They live in their own part
# because the rows that use them now span six files, and a helper defined halfway down one of
# those files is a helper the next file cannot rely on having.
#
# The observation helpers are the important half. A row that greps the whole captured prompt
# for a marker cannot tell "the file was reviewed" from "the file's name appeared in a caveat",
# and a row that greps stdout for a label cannot tell "the budget was honoured" from "the whole
# diff was sent and a line was printed about it". pp_diff_body_* and pp_scope_* exist so those
# two questions can be asked separately and answered from captured content.
#
# TL3 gap (what these helpers do NOT catch):
# - The real codex CLI's stdin handling and true context window: every helper here observes a
#   shell mock's stdin, so a prompt that is well-formed and inside the line budget may still be
#   rejected by the real model.
# - The real filesystem's path encoding rules: pp_new_repo fixtures are created by whatever
#   filesystem the runner is on, so a name this host refuses to create is never exercised.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: merge-base-suspect.

PP_CAPTURE="$TMPDIR_BASE/captured-path-priority.txt"
PP_STDOUT="$TMPDIR_BASE/pp-stdout.txt"
PP_STDERR="$TMPDIR_BASE/pp-stderr.txt"
PP_ENV=()
PP_RC=0
PP_OUT_TEXT=""
PP_ERR_TEXT=""

# A mock codex that records the prompt. Written fresh here for the same reason the Y-series
# writes its own: the parent's mock is overwritten several times and these rows must not
# depend on which one happens to be current.
pp_install_capturing_mock() {
    cat > "$MOCK_BIN/codex" <<MOCK_EOF
#!/usr/bin/env bash
cat > "$PP_CAPTURE"
echo "No findings."
exit 0
MOCK_EOF
    chmod +x "$MOCK_BIN/codex"
}

# The same recorder, but exiting non-zero — for the rows that need a FAILED verdict without
# giving up the ability to read what was sent before it failed.
pp_install_failing_mock() {
    cat > "$MOCK_BIN/codex" <<MOCK_EOF
#!/usr/bin/env bash
cat > "$PP_CAPTURE"
echo "codex exec exploded" >&2
exit 2
MOCK_EOF
    chmod +x "$MOCK_BIN/codex"
}

# env(1) rather than an assignment prefix: PP_ENV carries VAR=VALUE words produced by
# expansion, and a word that only LOOKS like an assignment after expansion is passed as an
# argument, not as an environment entry.
#
# C2 (#1976 review gap): `env -u CODEX_REVIEW_MAX_DIFF_LINES` strips whatever the ambient
# process environment happens to export for that key BEFORE applying PP_ENV, so a caller that
# never puts the key into PP_ENV gets the real unset/default behaviour regardless of the
# developer's or CI's shell — and a caller that DOES put it in PP_ENV (e.g. G2) still wins,
# because PP_ENV's own assignment is applied after the `-u`.
pp_run() { # <repo> [args...] ; prints stdout, leaves the prompt in $PP_CAPTURE
    local repo="$1"
    shift
    rm -f "$PP_CAPTURE"
    (cd "$repo" && _timeout env -u CODEX_REVIEW_MAX_DIFF_LINES PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
        ${PP_ENV[@]+"${PP_ENV[@]}"} bash "$SCRIPT" "$@" 2>/dev/null) || true
}

# The status-preserving twin. pp_run discards the exit code by design (most rows read only
# stdout), which makes it structurally unable to test the exit-0 contract. This one keeps
# stdout, stderr and the real subprocess status apart, in files, because a command
# substitution would put the status assignment in a subshell and throw it away again.
pp_exec() { # <repo> [args...] ; sets PP_RC / PP_OUT_TEXT / PP_ERR_TEXT
    local repo="$1"
    shift
    rm -f "$PP_CAPTURE"
    PP_RC=0
    # Same C2 rationale as pp_run: strip the ambient CODEX_REVIEW_MAX_DIFF_LINES before PP_ENV
    # is applied, so callers that assume the default/pinned budget are deterministic.
    (cd "$repo" && _timeout env -u CODEX_REVIEW_MAX_DIFF_LINES PATH="$MOCK_BIN:$PATH" HOME="$TMPDIR_BASE" \
        ${PP_ENV[@]+"${PP_ENV[@]}"} bash "$SCRIPT" "$@") >"$PP_STDOUT" 2>"$PP_STDERR" || PP_RC=$?
    PP_OUT_TEXT="$(cat "$PP_STDOUT")"
    PP_ERR_TEXT="$(cat "$PP_STDERR")"
}

pp_new_repo() { # <name> ; prints the repo path, on a feature branch off main
    # Two statements, not one `local a=… b=…`: a builtin expands all its words before
    # assigning any of them, so the second would read an unset $name under `set -u`.
    local name="$1"
    local repo
    repo="$(pp_new_base_repo "$name")"
    git -C "$repo" checkout -q -b "feature-$name"
    printf '%s' "$repo"
}

# Same, but left on main so the caller can seed files into the BASE commit — the only way to
# build a deletion or a rename, whose "before" side must predate the branch.
pp_new_base_repo() { # <name> ; prints the repo path, HEAD on main, nothing branched yet
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    rm -rf "$repo"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config core.hooksPath "$repo/.git/no-such-hooks"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config commit.gpgsign false
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    printf '%s' "$repo"
}

pp_gen() { # <file> <lines> <marker>
    awk -v n="$2" -v m="$3" 'BEGIN { for (i = 0; i < n; i++) print m " line " i }' > "$1"
}

# The size of ONE path's chunk, measured the way the script must measure it. `|| true`
# because git diff --no-index exits 1 whenever the files differ, which is always here.
pp_untracked_chunk_lines() { # <repo> <path>
    local n
    n=$( (cd "$1" && { git diff --no-index /dev/null "$2" 2>/dev/null || true; } | wc -l) )
    printf '%s' "$(printf '%s' "$n" | tr -d '[:space:]')"
}

pp_committed_chunk_lines() { # <repo> <base> <path>
    local n
    n=$( (cd "$1" && { git diff "$2...HEAD" -- "$3" 2>/dev/null || true; } | wc -l) )
    printf '%s' "$(printf '%s' "$n" | tr -d '[:space:]')"
}

pp_has() { # <text> <pattern> ; grep -q without tripping set -e
    printf '%s\n' "$1" | grep -q -- "$2"
}

pp_has_fixed() { # <text> <literal> ; grep -qF without tripping set -e
    printf '%s\n' "$1" | grep -qF -- "$2"
}

pp_count_matching() { # <text> <pattern> ; prints how many lines match
    printf '%s\n' "$1" | grep -c -- "$2" || true
}

# Everything the script actually handed the model as reviewable material: the span from the
# first [DIFF START] marker to the last line of the prompt, exclusive of both. Anchored that
# way on purpose — diff content is untrusted and may carry a forged copy of either marker, and
# a naive `/START/,/END/` range would let the content itself move the boundary.
pp_diff_body() { # <capture-file>
    [ -f "$1" ] || return 0
    awk 'f { print } /^\[DIFF START\]$/ { f = 1 }' "$1" | sed '$d'
}

pp_diff_body_lines() { # <capture-file> ; prints the line count of the reviewed body
    local n
    n=$(pp_diff_body "$1" | wc -l)
    printf '%s' "$(printf '%s' "$n" | tr -d '[:space:]')"
}

# The declared count on a breakdown line: the K in `Reviewed (K): …`. Empty string when the
# line is absent, so a caller can tell "said zero" from "never said".
pp_scope_count() { # <output> <Reviewed|Dropped>
    printf '%s\n' "$1" | grep -oE "^$2 \([0-9]+\)" | grep -oE "[0-9]+" | head -1 || true
}

# The paths a breakdown line actually lists, one per line, trimmed. The `… and N more`
# continuation is dropped: it is a count, not a path, and a caller comparing sets of paths
# must not be handed it as one.
#
# C5 (#1976 review gap): entries are separated by the two-character sequence ", " (a comma
# followed by a space) — never a bare comma. A bare-comma split (the previous implementation)
# corrupts any filename that legitimately contains a comma, fragmenting it into multiple
# fake "paths" and making the observation helper itself the source of the failure rather than
# whatever the script under test actually did (see S2a-comma in path-edges-and-security.sh,
# whose fixture filename is `combo,comma,name.txt`). This is a documented format assumption,
# not an observed fact about the not-yet-rewritten source: none of its commas are followed by
# a space, so splitting on ", " leaves it intact while still separating ordinary
# comma-free entries exactly as a bare-comma split would have.
pp_scope_paths() { # <output> <Reviewed|Dropped>
    printf '%s\n' "$1" \
        | grep -E "^$2 \([0-9]+\):" \
        | sed -E "s/^$2 \([0-9]+\): //" \
        | sed -E 's/, /\n/g' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
        | grep -v '^$' \
        | grep -v '^… and [0-9]* more$' || true
}

# A resolve-merge-base.sh that reports a fixed answer, so the cross-reference rows assert
# review-code-codex's REACTION to a warn value rather than git's ability to produce one.
pp_write_resolver_stub() { # <dir> <warn>
    mkdir -p "$1/bin"
    cat > "$1/bin/resolve-merge-base.sh" <<STUB_EOF
#!/usr/bin/env bash
printf 'base=main\n'
printf 'state=RECORDED\n'
printf 'source=recorded-baseline\n'
printf 'base_is_head=0\n'
printf 'safe_base=HEAD\n'
printf 'warn=$2\n'
printf 'alt_base=0000000\n'
printf 'detail=-\n'
exit 0
STUB_EOF
    chmod +x "$1/bin/resolve-merge-base.sh"
}

# A throwaway AGENTS_CONFIG_DIR carrying a REAL .env and the real load-env.js, so the config
# rows exercise bin/get-config-var's actual resolution chain rather than asserting that a
# process-level export reaches a shell variable — which would still pass if .env were never
# read at all.
pp_make_cfg_dir() { # <dir> [<KEY=VALUE> ...] ; prints the dir
    local dir="$1"
    shift
    rm -rf "$dir"
    mkdir -p "$dir/hooks" "$dir/bin"
    cp -R "$AGENTS_ROOT/hooks/lib" "$dir/hooks/lib"
    : > "$dir/.env"
    local line
    for line in "$@"; do printf '%s\n' "$line" >> "$dir/.env"; done
    printf '%s' "$dir"
}
