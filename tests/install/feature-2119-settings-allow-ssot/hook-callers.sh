# tests/feature-2119-settings-allow-ssot/hook-callers.sh
# Tests: hooks/post-merge, hooks/post-checkout, install/assemble-settings.js, install/lib/settings-deploy.js
# Tags: install, settings, permissions, hook, caller, scope:issue-specific, pwsh-not-required, TL2
# T37: the two git-hook CALLERS driven against the REAL assembler. Sourced AFTER generator.sh.

POST_MERGE_REL="hooks/post-merge"
POST_CHECKOUT_REL="hooks/post-checkout"

# WHY NOT THE STUB. tests/fix-846-settings-drift-hooks.sh drives both hooks against a stub that
# only touches a sentinel, which isolates TRIGGER logic and is worth keeping. What it can never
# see is the half this change actually alters: that the real assembler accepts the arguments the
# hook passes, that the deployed settings under the caller's HOME really gains the generated
# rules, that a failing assembler leaves the previous deployment alone (D3 fail-closed), and that
# its diagnostic now reaches the operator with the `2>/dev/null` gone. S14 already runs the real
# assembler against a temporary HOME, so none of that needs a real machine -- only the installer
# entry points and a genuine git event do, and those stay documented as the residual TL3 gap.

# Anchored on the fixture command's own name: only the assembler names the entry it choked on,
# so a hook that prints its own generic "assembler failed" line cannot satisfy this.
T37_SEEN_ERE='fx-bad'

t37_have() { # -> ok | sentinel-text
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    [ -f "$AGENTS_DIR/$POST_MERGE_REL" ] || { printf '<MISSING:%s>' "$POST_MERGE_REL"; return; }
    [ -f "$AGENTS_DIR/$POST_CHECKOUT_REL" ] || { printf '<MISSING:%s>' "$POST_CHECKOUT_REL"; return; }
    command -v git >/dev/null 2>&1 || { printf '<MISSING:git>'; return; }
    printf 'ok'
}

# A real agents-shaped git repo carrying the REAL install layer, plus a private home that starts
# EMPTY -- so "the deployed file appeared" and "it was never written" are distinguishable states
# rather than two shades of the same digest.
t37_sandbox() { # <dir>
    local d="$1"
    mkdir -p "$d/hooks" "$d/install/lib" "$d/bin" "$d/docs" "$d/home/.claude"
    git init -q "$d"
    git -C "$d" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config commit.gpgsign false
    git -C "$d" config init.defaultBranch main >/dev/null 2>&1 || true
    cp "$AGENTS_DIR/$POST_MERGE_REL" "$d/hooks/post-merge"
    cp "$AGENTS_DIR/$POST_CHECKOUT_REL" "$d/hooks/post-checkout"
    chmod +x "$d/hooks/post-merge" "$d/hooks/post-checkout" 2>/dev/null || true
    cp "$ASSEMBLE" "$d/install/assemble-settings.js"
    if have_gen; then cp "$GEN" "$d/install/gen-settings-allow.js"; fi
    cp "$AGENTS_DIR"/install/lib/*.js "$d/install/lib/" 2>/dev/null || true
    printf '%s\n' '# fixture PATH-exposed list (never the real one)' > "$d/install/path-exposed-commands.txt"
    mk_tool "$d" bin/fx-tool env-bash
    write_ssot "$d" bin/fx-tool
    write_settings "$d" --
    write_ext "$d" --
    printf '%s\n' 'unrelated prose' > "$d/docs/unrelated.md"
    printf '%s\n' 'home/' > "$d/.gitignore"
    git -C "$d" add -A
    ENFORCE_WORKTREE=off git -C "$d" commit -q -m "seed"
}

# One commit carrying the change the hook is supposed to react to. The three healthy kinds edit
# a file the SSOT reader ignores the content of, so the trigger is exercised without changing
# what the assembler should produce; `failure` instead admits a shebang-less command, which is
# how the REAL assembler is made to fail without touching a single source file.
t37_mutate() { # <dir> <ssot|cmdfile|unrelated|failure>
    case "$2" in
        ssot)      printf '%s\n' '# edited for the caller probe' >> "$1/install/settings-allow-commands.txt" ;;
        cmdfile)   printf '%s\n' '# edited for the caller probe' >> "$1/bin/fx-tool" ;;
        unrelated) printf '%s\n' 'edited for the caller probe' >> "$1/docs/unrelated.md" ;;
        failure)   mk_tool "$1" bin/fx-bad none; write_ssot "$1" bin/fx-tool bin/fx-bad ;;
    esac
    git -C "$1" add -A
    ENFORCE_WORKTREE=off git -C "$1" commit -q -m "probe change: $2"
}

t37_run_hook() { # <dir> <merge|checkout> <sha-prev> <sha-new> -> hook output on stdout+stderr
    local d="$1"
    if [ "$2" = "merge" ]; then
        ( cd "$d" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
            HOME="$d/home" USERPROFILE="$(node_path "$d/home")" CLAUDE_CONFIG_DIR="$d/home/.claude" \
            run_with_timeout 60 bash hooks/post-merge ) 2>&1
    else
        ( cd "$d" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
            HOME="$d/home" USERPROFILE="$(node_path "$d/home")" CLAUDE_CONFIG_DIR="$d/home/.claude" \
            run_with_timeout 60 bash hooks/post-checkout "$3" "$4" 1 ) 2>&1
    fi
}

# Verdict slots: <deploy>/<rules>/<diag>. `rules` asks whether the deployed file carries a rule
# the SSOT command actually expands to, so "the hook wrote something" cannot pass for "the hook
# wrote the generated rules". `diag` is computed only where a diagnostic is due.
t37_case() { # <merge|checkout> <ssot|cmdfile|unrelated|failure> -> verdict | sentinel
    local ok d target before after out state rules diag first base sha_prev sha_new
    ok="$(t37_have)"
    [ "$ok" = "ok" ] || { printf '%s' "$ok"; return; }
    d="$TMPROOT/t37-$1-$2"
    t37_sandbox "$d"
    target="$(deployed_file "$d")"
    # A healthy deployment FIRST for the failure case only, so "left alone" is a claim about a
    # real previous file rather than about a home that was never written to.
    if [ "$2" = "failure" ]; then run_assemble "$d"; fi
    base="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
    sha_prev="$(git -C "$d" rev-parse HEAD)"
    git -C "$d" checkout -q -b probe-branch
    t37_mutate "$d" "$2"
    sha_new="$(git -C "$d" rev-parse HEAD)"
    if [ "$1" = "merge" ]; then
        git -C "$d" checkout -q "$base"
        git -C "$d" merge -q --no-ff -m "merge probe-branch" probe-branch >/dev/null 2>&1
    fi
    before="$(file_digest "$target")"
    out="$(t37_run_hook "$d" "$1" "$sha_prev" "$sha_new")"
    after="$(file_digest "$target")"
    if [ ! -f "$target" ]; then state="absent"
    elif [ "$before" = "$after" ]; then state="unchanged"
    else state="changed"; fi
    rules="-"
    if [ -f "$target" ]; then
        deployed_allow_dump "$d" "$d/allow.txt"
        first="$(expected_path_rules bash bin/fx-tool "$d" | sed -n 1p)"
        if grep -Fxq -- "$first" "$d/allow.txt" 2>/dev/null; then rules="rules-present"; else rules="RULES-MISSING"; fi
    fi
    diag="-"
    if [ "$2" = "failure" ]; then
        if printf '%s\n' "$out" | grep -Eqi -- "$T37_SEEN_ERE"; then diag="seen"; else diag="SWALLOWED"; fi
    fi
    printf '%s/%s/%s' "$state" "$rules" "$diag"
}

t37_caller_table() {
    local hook kind want label
    while IFS='|' read -r hook kind want label; do
        [ -n "$hook" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T37[$hook/$kind]: $label" "$want" "$(t37_case "$hook" "$kind")"
    done <<'T37_CASES'
merge|ssot|changed/rules-present/-|post-merge on an SSOT change runs the REAL assembler and the caller's own ~/.claude/settings.json gains the generated spellings -- the stub suite only ever proved a sentinel file was touched
checkout|ssot|changed/rules-present/-|CPR-ORTH: post-checkout does the same across a branch switch, through the same real assembler
merge|cmdfile|changed/rules-present/-|post-merge on a change to an SSOT-LISTED command file deploys too: stage 2 of the trigger is worthless if the assembler it reaches cannot produce the rules
checkout|cmdfile|changed/rules-present/-|and post-checkout on that same dynamic match
merge|unrelated|absent/-/-|NEGATIVE CONTROL post-merge: a path in neither trigger stage leaves the home untouched, so the four rows above are not passing because the hook always deploys
checkout|unrelated|absent/-/-|NEGATIVE CONTROL post-checkout: the same, which is what makes "changed" evidence
merge|failure|unchanged/rules-present/seen|post-merge merging an SSOT that admits a shebang-less command keeps the ALREADY-deployed settings byte-identical (D3 fail-closed) and lets the assembler's own reason -- which names bin/fx-bad -- reach the operator, because the `2>/dev/null` that hid it is gone
checkout|failure|unchanged/rules-present/seen|CPR-ORTH: post-checkout fails closed on the same broken SSOT and stays just as audible
T37_CASES
}

t37_caller_table

T38_BASH="$(command -v bash 2>/dev/null || true)"
T38_SHIM_CMDS="git grep tr dirname sed cut timeout perl"

# T38 -- THE NO-NODE BRANCH. Both hooks carry an early `command -v node` check whose whole job is
# to degrade quietly on a machine where node is not on PATH, and nothing exercises it: every other
# row in this suite runs with node present, so a branch that exited 1, or ran the assembler
# anyway, or said nothing at all would go unnoticed until a real user hit it mid-checkout. The
# specified degradation is exactly three things -- exit 0 (a git hook must never break the
# checkout), no assembler invocation, and a stderr line telling the operator to run the installer.
#
# MECHANISM: PATH is replaced by a directory of `#!/bin/sh` wrappers that exec the absolute path
# of each external command the hooks actually use, with `node` present or absent by case.
t38_shim() { # <dir> <with-node|no-node>
    local d="$1" c p
    mkdir -p "$d"
    for c in $T38_SHIM_CMDS; do
        p="$(command -v "$c" 2>/dev/null || true)"
        [ -n "$p" ] || continue
        printf '%s\n' '#!/bin/sh' "exec \"$p\" \"\$@\"" > "$d/$c"
        chmod +x "$d/$c" 2>/dev/null || true
    done
    [ "$2" = "with-node" ] || return 0
    p="$(command -v node 2>/dev/null || true)"
    [ -n "$p" ] || return 0
    printf '%s\n' '#!/bin/sh' "exec \"$p\" \"\$@\"" > "$d/node"
    chmod +x "$d/node" 2>/dev/null || true
}

# The mechanism is asserted before it is relied on: a shim PATH that still reaches node would turn
# both no-node rows into ordinary runs, and one that lost git would make them pass for the wrong
# reason (the hook's repo guard exits 0 silently when git is unavailable).
t38_shim_canary() { # <shimdir> -> "<no-node|NODE-FOUND>/<git-ok|GIT-MISSING>"
    [ -n "$T38_BASH" ] || { printf '<MISSING:bash>'; return; }
    ( PATH="$1"; export PATH
      if [ -n "$(command -v node 2>/dev/null || true)" ]; then printf 'NODE-FOUND'; else printf 'no-node'; fi
      if [ -n "$(command -v git 2>/dev/null || true)" ]; then printf '/git-ok'; else printf '/GIT-MISSING'; fi )
}

t38_have() { # <no-node|with-node> -> ok | sentinel
    [ -f "$AGENTS_DIR/$POST_MERGE_REL" ] || { printf '<MISSING:%s>' "$POST_MERGE_REL"; return; }
    [ -f "$AGENTS_DIR/$POST_CHECKOUT_REL" ] || { printf '<MISSING:%s>' "$POST_CHECKOUT_REL"; return; }
    command -v git >/dev/null 2>&1 || { printf '<MISSING:git>'; return; }
    [ -n "$T38_BASH" ] || { printf '<MISSING:bash>'; return; }
    if [ "$1" = "with-node" ]; then
        have_lib || { missing_lib; return; }
        [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    fi
    printf 'ok'
}

t38_run() { # <dir> <merge|checkout> <shimdir> <sha-prev> <sha-new> -> hook output
    ( cd "$1" || exit 127
      unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
      HOME="$1/home"; USERPROFILE="$(node_path "$1/home")"; CLAUDE_CONFIG_DIR="$1/home/.claude"
      export HOME USERPROFILE CLAUDE_CONFIG_DIR
      PATH="$3"; export PATH
      if [ "$2" = "merge" ]; then
          run_with_timeout 60 "$T38_BASH" hooks/post-merge
      else
          run_with_timeout 60 "$T38_BASH" hooks/post-checkout "$4" "$5" 1
      fi ) 2>&1
}

# settings.json is the file changed here because it triggers under the CURRENT fixed ERE as well:
# a failing row then means the no-node branch and nothing about the widened trigger.
t38_case() { # <merge|checkout> <no-node|with-node> -> "rc=<n>/<state>/<notice>" | sentinel
    local ok d shim target out rc state notice base sha_prev sha_new
    ok="$(t38_have "$2")"
    [ "$ok" = "ok" ] || { printf '%s' "$ok"; return; }
    d="$TMPROOT/t38-$1-$2"
    t37_sandbox "$d"
    shim="$TMPROOT/t38-shim-$1-$2"
    t38_shim "$shim" "$2"
    base="$(git -C "$d" rev-parse --abbrev-ref HEAD)"
    sha_prev="$(git -C "$d" rev-parse HEAD)"
    git -C "$d" checkout -q -b probe-branch
    printf '%s\n' 'Bash(t38-marker *)' > "$d/t38.txt"
    write_settings "$d" "$d/t38.txt"
    git -C "$d" add -A
    ENFORCE_WORKTREE=off git -C "$d" commit -q -m "t38: settings.json changed"
    sha_new="$(git -C "$d" rev-parse HEAD)"
    if [ "$1" = "merge" ]; then
        git -C "$d" checkout -q "$base"
        git -C "$d" merge -q --no-ff -m "merge probe-branch" probe-branch >/dev/null 2>&1
    fi
    target="$(deployed_file "$d")"
    rc=0
    out="$(t38_run "$d" "$1" "$shim" "$sha_prev" "$sha_new")" || rc=$?
    if [ -f "$target" ]; then state="deployed"; else state="absent"; fi
    if printf '%s\n' "$out" | grep -q 'node not found'; then notice="told"; else notice="silent"; fi
    printf 'rc=%s/%s/%s' "$rc" "$state" "$notice"
}

t38_nonode_table() {
    local shim hook mode want label
    shim="$TMPROOT/t38-shim-canary"
    t38_shim "$shim" no-node
    ROWS=$((ROWS + 1))
    assert_eq "T38[mechanism]: MECHANISM CHECK -- the shim PATH really hides node while still reaching git (if not, every T38 row below is a no-op)" \
        "no-node/git-ok" "$(t38_shim_canary "$shim")"
    while IFS='|' read -r hook mode want label; do
        [ -n "$hook" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T38[$hook/$mode]: $label" "$want" "$(t38_case "$hook" "$mode")"
    done <<'T38_CASES'
merge|no-node|rc=0/absent/told|post-merge on a machine without node exits 0 (breaking the merge would be worse than a stale settings.json), deploys nothing, and tells the operator to run the installer
checkout|no-node|rc=0/absent/told|CPR-ORTH: post-checkout degrades identically -- the branch is duplicated in both hooks, so a fix applied to one only is exactly what this pair catches
merge|with-node|rc=0/deployed/silent|POSITIVE CONTROL: the same shim PATH WITH node deploys normally and says nothing about node, so the two rows above fail on the missing interpreter and not on a broken PATH
checkout|with-node|rc=0/deployed/silent|and the same control for post-checkout
T38_CASES
}

t38_nonode_table
