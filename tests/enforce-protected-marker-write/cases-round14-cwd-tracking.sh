#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-14: THE TRACKED CWD MUST FOLLOW EVERY DIRECTORY MOVE THE SHELL MAKES.
#
# commandCwd() in hooks/block-off-clearance-write/bash-target-context.js is what
# gives the N-2 containment qualifier a directory to resolve a RELATIVE glob
# against. `echo x | tee *` commits no literal character to a protected suffix,
# so the ONLY thing that can block it is knowing which directory the `*` expands
# in. Every gap in commandCwd() is therefore a direct ALLOW on a `tee`-truncation
# of live clearance state (a DoS on the OFF-clearance token + session markers)
# and, since the token is unsigned, a content forge.
#
# THREE MEASURED GAPS ARE PINNED HERE:
#
#   (1) codex round-13 HIGH-2 — only `cd` was recognized, so `pushd <wf>` moved
#       the real shell into the workflow dir while the tracked cwd stayed put.
#   (2) codex round-14 — moves were ONE-WAY: nothing popped the stack or swapped
#       back through OLDPWD, so `cd <wf> && pushd /tmp && popd && tee *` left the
#       tracked cwd wedged at /tmp forever while the real shell was back inside
#       the workflow dir.
#   (3) codex round-14 sibling sweep — `command cd <wf>` / `builtin cd <wf>` put
#       the WRAPPER word in seg.cmd0, so the real `cd` was never seen. Measured
#       live: `cd <wf> && … tee *` blocked, `command cd <wf> && … tee *` allowed.
#
# AND THE INVERSE DEFECT, which is equally real (CPR-5): a move model that only
# ever walks FORWARD over-blocks. `pushd -n <dir>` pushes without cd-ing, and
# `pushd +1` rotates the stack naming no path at all — treating either as a real
# `cd` moves the tracked cwd while the shell's stays put, which is the exact
# mirror-image bug. The `approve` rows below are not concessions: in each of
# them the shell genuinely is NOT in the workflow directory when the glob
# expands, so a block there would be a false positive on ordinary work.
#
# WHY EVERY ROW USES A BARE `*`: a literal protected basename would block on the
# basename matcher alone and prove nothing about commandCwd(). The pure-wildcard
# target is the ONE shape whose verdict is decided entirely by the tracked cwd.
#
# Table format: name|want|payload, as in ./cases-round6-stdin.sh. Placeholders:
#   @WF@  -> the sandbox workflow dir (absolute, node spelling)
#   @OUT@ -> the process CWD the hook is handed (a real linked worktree)
#   @SID@ -> the sandbox session id

# _r14_mk_input <command> <cwd> — like ./cases-round6-stdin.sh `_r6_mk_input`, but
# ALSO carries `cwd` INSIDE tool_input. That distinction is load-bearing here:
# dispatch.js reads the starting directory from `toolInput.cwd`, so a payload that
# only carries the top-level `cwd` leaves commandCwd()'s ORIGIN unknown (null).
# With an unknown origin `pushd <dir>` has nothing to push, so `popd` cannot
# restore and the tracked cwd stays wedged at <dir> — which is the deliberate
# fail-closed direction, pinned separately in run_R14_cwd_unknown_origin below.
# The tables that exercise the inverse moves need the origin to be KNOWN, so they
# use this builder.
_r14_mk_input() {
    printf '{"tool_name":"Bash","session_id":"wsid","cwd":"%s","tool_input":{"command":"%s","cwd":"%s"}}' \
        "$(_r6_json_esc "$2")" "$(_r6_json_esc "$1")" "$(_r6_json_esc "$2")"
}

# _r14_cwd_table <section> — one table runner; every row starts the hook with
# its process CWD at $LINKED_WT (NOT the workflow dir), so a row can only reach
# `block` by the command text itself moving the tracked cwd into @WF@.
_r14_cwd_table() {
    local section="$1" name want payload
    while IFS='|' read -r name want payload; do
        case "$name" in ''|\#*) continue ;; esac
        name="${name%"${name##*[![:space:]]}"}"
        want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
        payload="${payload#"${payload%%[![:space:]]*}"}"
        payload="${payload//@WF@/$WFDIR}"
        payload="${payload//@OUT@/$LINKED_WT}"
        payload="${payload//@SID@/$SID}"
        assert_verdict "$section $name" "$want" \
            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r14_mk_input "$payload" "$LINKED_WT")")"
    done
}

# run_R14_cwd_forward — gap (1): every spelling of "change directory" must move
# the tracked cwd, and the bare-`cd` control pins the defect to the SPELLING.
run_R14_cwd_forward() {
    _r14_cwd_table "R14" <<'TABLE'
14-a1 control: bare cd into wf|block|cd @WF@ && echo x | tee *
14-a2 pushd into wf|block|pushd @WF@ && echo x | tee *
14-a3 uppercase CD into wf (case-folded)|block|CD @WF@ && echo x | tee *
14-a4 pwsh Set-Location into wf|block|Set-Location @WF@ && echo x | tee *
14-a5 pwsh sl alias into wf|block|sl @WF@ && echo x | tee *
14-a6 pwsh chdir alias into wf|block|chdir @WF@ && echo x | tee *
14-a7 pwsh Push-Location into wf|block|Push-Location @WF@ && echo x | tee *
14-a8 cd into wf then relative glob|block|cd @WF@ && echo x > @SID@*
14-a9 control: cd elsewhere, bare glob|approve|cd /tmp && echo x | tee *
TABLE
}

# run_R14_cwd_inverse — gap (2): pop / OLDPWD-swap are REAL INVERSES of the
# forward moves. Each block row is a command whose real shell IS back inside the
# workflow dir at glob-expansion time; each approve row is its mirror, where the
# inverse genuinely carries the shell OUT again.
run_R14_cwd_inverse() {
    _r14_cwd_table "R14" <<'TABLE'
14-b1 cd wf, pushd away, popd back|block|cd @WF@ && pushd /tmp && popd && echo x | tee *
14-b2 pushd wf, pushd away, popd back|block|pushd @WF@ && pushd /tmp && popd && echo x | tee *
14-b3 pwsh Pop-Location returns to wf|block|cd @WF@ && Push-Location /tmp && Pop-Location && echo x | tee *
14-b4 cd - swaps back into wf via OLDPWD|block|cd @WF@ && cd /tmp && cd - && echo x | tee *
14-b5 Set-Location - swaps back into wf|block|cd @WF@ && cd /tmp && Set-Location - && echo x | tee *
14-b6 popd on empty stack leaves cwd in wf|block|cd @WF@ && popd && echo x | tee *
14-b7 cd - with no OLDPWD leaves cwd, then cd wf|block|cd - && cd @WF@ && echo x | tee *
14-b8 extra popd past stack bottom stays in wf|block|cd @WF@ && pushd /tmp && popd && popd && echo x | tee *
14-b9 inverse boundary: pushd wf then popd leaves wf|approve|pushd @WF@ && popd && echo x | tee *
14-b10 inverse boundary: cd wf, cd out, cd - , cd -|approve|cd @WF@ && cd /tmp && cd - && cd - && echo x | tee *
14-b11 forward-only control: pushd away from wf|approve|cd @WF@ && pushd /tmp && echo x | tee *
TABLE
}

# run_R14_cwd_wrapper — gap (3): `command` / `builtin` suppress function+alias
# lookup only; the builtin still changes the directory. The wrapper must be
# unwrapped one level, including `command`'s own leading flags.
run_R14_cwd_wrapper() {
    _r14_cwd_table "R14" <<'TABLE'
14-c1 command cd into wf|block|command cd @WF@ && echo x | tee *
14-c2 builtin cd into wf|block|builtin cd @WF@ && echo x | tee *
14-c3 command -p cd into wf|block|command -p cd @WF@ && echo x | tee *
14-c4 command pushd into wf|block|command pushd @WF@ && echo x | tee *
14-c5 command cd wf then builtin popd back|block|command cd @WF@ && pushd /tmp && builtin popd && echo x | tee *
14-c6 wrapper boundary: command cd elsewhere|approve|command cd /tmp && echo x | tee *
14-c7 wrapper boundary: bare `command` with no operand|approve|command && echo x | tee *
TABLE
}

# run_R14_cwd_nonmoves — the CPR-5 counterweight. `pushd -n <dir>` pushes
# WITHOUT cd-ing and `pushd +N` / `pushd -N` rotate the stack naming no path, so
# neither may move the tracked cwd. Getting this wrong in EITHER direction is a
# defect: 14-d1/14-d2 catch the over-block (tracked cwd moved when the shell's
# did not), 14-d3/14-d4 catch the under-block (a real move mistaken for a
# non-move).
run_R14_cwd_nonmoves() {
    _r14_cwd_table "R14" <<'TABLE'
14-d1 pushd -n wf does not move cwd|approve|pushd -n @WF@ && echo x | tee *
14-d2 pushd -n wf with explicit out-dir cd first|approve|cd @OUT@ && pushd -n @WF@ && echo x | tee *
14-d3 pushd -n away does not leave wf|block|cd @WF@ && pushd -n /tmp && echo x | tee *
14-d4 pushd rotation names no path, cwd stays wf|block|cd @WF@ && pushd +1 && echo x | tee *
14-d5 pushd rotation does not enter wf|approve|cd /tmp && pushd -0 && echo x | tee *
TABLE
}

# run_R14_cwd_unknown_origin — CPR-8 named exception. The payload here omits
# `tool_input.cwd`, i.e. the ORIGIN directory is unknown to commandCwd(). That is
# not a contrived shape: dispatch.js reads only `toolInput.cwd`, so any caller
# that supplies the starting directory at the TOP level of the hook payload lands
# in exactly this state.
#
# With an unknown origin the directory stack starts EMPTY (there is no real path
# to push), so `pushd <wf>` moves the tracked cwd in and `popd` has nothing to
# restore — the tracked cwd stays inside the workflow dir and the glob BLOCKS.
# 14-e1 pins that as intended fail-closed behaviour, not a bug: the alternative
# (treat an unrestorable pop as "left the directory") would ALLOW a `tee *`
# truncation of live clearance state. 14-e2/14-e3 prove the degradation is
# confined to the pop path — an OLDPWD swap chain and an ordinary `cd` elsewhere
# still resolve exactly as they do with a known origin, so this is a bounded
# exception rather than a blanket "unknown origin ⇒ block".
run_R14_cwd_unknown_origin() {
    local name want payload
    while IFS='|' read -r name want payload; do
        case "$name" in ''|\#*) continue ;; esac
        name="${name%"${name##*[![:space:]]}"}"
        want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
        payload="${payload#"${payload%%[![:space:]]*}"}"
        payload="${payload//@WF@/$WFDIR}"
        assert_verdict "R14 $name" "$want" \
            "$(run_hook_cwd "$LINKED_WT" "$WFDIR" "$(_r6_mk_input "$payload" "$LINKED_WT")")"
    done <<'TABLE'
14-e1 unknown origin: popd cannot restore, fail closed|block|pushd @WF@ && popd && echo x | tee *
14-e2 unknown origin: OLDPWD swap chain still exits wf|approve|cd @WF@ && cd /tmp && cd - && cd - && echo x | tee *
14-e3 unknown origin: plain cd elsewhere still approves|approve|cd /tmp && echo x | tee *
TABLE
}
