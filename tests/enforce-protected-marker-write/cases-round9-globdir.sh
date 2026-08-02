#!/usr/bin/env bash
# Part of tests/enforce-protected-marker-write.sh (rules/coding/file-split.md).
# Round-9 MEDIUM-1: THE WORKFLOW DIR SPELLED THE WAY PEOPLE ACTUALLY SPELL IT.
#
# A bulk glob commits no literal character to a protected suffix, so
# ../../hooks/lib/basename-glob-normalize.js deliberately reports `<wf>/*` as a
# NON-match (otherwise `rm -rf build/*` would block). That named exception is
# only safe while such a glob cannot land on a protected file, and the qualifier
# that guarantees it is DIRECTORY CONTAINMENT in
# hooks/block-off-clearance-write/bash-target-context.js.
#
# The qualifier fired for a LITERAL absolute directory only. A `$` anywhere in
# the directory spelling, or a leading `~`, made it `continue` — i.e. CLEAR the
# route — and the SAME `continue` sat in staticPathArg(), so a `cd` into the
# workflow dir was invisible too. The workflow dir's canonical spelling is
# `~/.claude/projects/workflow`, so the NATURAL way to write it was the
# bypassing way; the literal spelling was the only one that blocked:
#
#     echo x | tee $HOME/.claude/projects/workflow/*   -> ALLOW (bug)
#     echo x | tee ~/.claude/projects/workflow/*       -> ALLOW (bug)
#     cd ~/.claude/projects/workflow && echo x | tee * -> ALLOW (bug)
#
# WHAT THAT BUYS AN ATTACKER — a glob cannot CREATE a file, so this is not a
# marker forge. It is a CONTENT forge (bin/request-off-clearance mints an
# UNSIGNED token, so rewriting a live token file can flip `target` /
# `claimed_target`) and a clean `tee`-truncation DoS on all clearance state.
#
# EVERY BLOCK ROW HERE IS A CORRECT BLOCK — nothing in this file is a
# concession, and nothing in it is available to relax. Each payload resolves,
# through the same expander the rest of the hook chain uses, to a glob whose
# directory IS the workflow directory. 20-c1 is the literal spelling, which
# blocked BEFORE the fix as well: it is the control that pins the defect to the
# SPELLING of the directory rather than to the containment rule itself.
#
# THE BOUNDARY IS PINNED BY THE ALLOW ROWS (CPR-5). Containment is what keeps
# this from becoming "every glob blocks":
#   20-nr1  a $HOME-relative glob in a DIFFERENT directory
#   20-nr2  `cd` to an unrelated absolute dir, then a bare glob
#   20-nr3/20-nr4  ordinary absolute bulk globs
#
# NOT HARDCODED. The workflow dir is whatever CLAUDE_WORKFLOW_DIR resolves to at
# runtime (hooks/workflow-state/state-io/core.js), which for this suite is a
# throwaway fixture — so the $HOME-relative spelling is DERIVED from that
# fixture, never written as `.claude/projects/workflow`. The fixture is created
# under $HOME precisely so the derivation has an answer on every platform; if it
# cannot be derived, every row here SKIPs loudly rather than asserting something
# that can never be true.
#
# Table format: name|want|payload, as in ./cases-round6-stdin.sh. Placeholders:
#   @HWF@ -> $HOME/<derived>    @BWF@ -> ${HOME}/<derived>   @TWF@ -> ~/<derived>
#   @EWF@ -> $CLAUDE_WORKFLOW_DIR                @LWF@ -> the resolved absolute dir
#   @SID@ -> the sandbox session id

R9_WF_DIR=""; R9_WF_POSIX=""; R9_WF_REL=""

# _r9_wf_fixture: a throwaway workflow dir UNDER $HOME, plus the $HOME-relative
# spelling of it as node's os.homedir() sees it (Git Bash's $HOME and Node's
# homedir() disagree on separators and drive spelling, so the relative part is
# computed by node, not by string-chopping in bash).
_r9_wf_fixture() {
    R9_WF_POSIX=$(mktemp -d "$HOME/.protmark-wf-XXXXXX" 2>/dev/null) || return 1
    [ -d "$R9_WF_POSIX" ] || return 1
    R9_WF_DIR=$(node_path "$R9_WF_POSIX")
    R9_WF_REL=$("$RWT" 10 node -e \
        'const os=require("os"),p=require("path");const h=os.homedir().replace(/\\/g,"/");const d=process.argv[1].replace(/\\/g,"/");const r=p.relative(h,d).replace(/\\/g,"/");process.stdout.write(r===""||r.startsWith("..")||p.isAbsolute(r)?"":r)' \
        "$R9_WF_DIR" 2>/dev/null)
    [ -n "$R9_WF_REL" ]
}

_r9_wf_table() {
    local section="$1" name want payload
    local hspell="\$HOME/$R9_WF_REL" bspell="\${HOME}/$R9_WF_REL" tspell="~/$R9_WF_REL"
    while IFS='|' read -r name want payload; do
        case "$name" in ''|\#*) continue ;; esac
        name="${name%"${name##*[![:space:]]}"}"
        want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
        payload="${payload#"${payload%%[![:space:]]*}"}"
        payload="${payload//@HWF@/$hspell}"
        payload="${payload//@BWF@/$bspell}"
        payload="${payload//@TWF@/$tspell}"
        payload="${payload//@EWF@/\$CLAUDE_WORKFLOW_DIR}"
        payload="${payload//@LWF@/$R9_WF_DIR}"
        payload="${payload//@SID@/$SID}"
        assert_verdict "$section $name" "$want" \
            "$(run_hook_cwd "$LINKED_WT" "$R9_WF_DIR" "$(_r6_mk_input "$payload" "$LINKED_WT")")"
    done
}

# run_R9_workflow_dir_glob - the measured ALLOW->BLOCK spellings, the literal
# control, and the containment boundary. One function so the $HOME fixture has
# exactly one create/remove site.
run_R9_workflow_dir_glob() {
    if ! _r9_wf_fixture; then
        skip "R9 20-* workflow-dir spelling fixture unavailable (no writable \$HOME or node relative-path derivation failed)"
        [ -n "$R9_WF_POSIX" ] && cleanup_tmp "$R9_WF_POSIX"
        return
    fi
    pass "R9 20-H workflow-dir fixture derived as \$HOME/$R9_WF_REL"

    _r9_wf_table "R9" <<'TABLE'
20-a tee $HOME glob|block|echo x | tee @HWF@/*
20-b tee ${HOME} glob|block|echo x | tee @BWF@/*
20-c tee ~ glob|block|echo x | tee @TWF@/*
20-d tee $HOME session-prefixed glob|block|echo x | tee @HWF@/@SID@*
20-e cp into $HOME glob|block|cp /tmp/x @HWF@/*
20-f cd ~ then bare glob|block|cd @TWF@ && echo x | tee *
20-g cd $HOME then bare glob|block|cd @HWF@ && echo x | tee *
20-h tee $CLAUDE_WORKFLOW_DIR glob|block|echo x | tee @EWF@/*
20-i redirect into $HOME glob|block|echo x > @HWF@/*
20-j tee ~ question-mark glob|block|echo x | tee @TWF@/?
20-c1 pre-fix control: literal spelling|block|echo x | tee @LWF@/*
20-nr1 $HOME glob, different directory|approve|echo x | tee $HOME/Downloads/*
20-nr2 cd elsewhere then bare glob|approve|cd /tmp && echo x | tee *
20-nr3 ordinary absolute bulk glob|approve|echo x | tee /tmp/build/*
20-nr4 ordinary redirect glob|approve|echo x > /tmp/build/*
20-nr5 $HOME path, no glob at all|approve|echo x | tee $HOME/Downloads/notes.txt
TABLE

    cleanup_tmp "$R9_WF_POSIX"
}
