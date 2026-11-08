# Tests: profile-snippet.sh
# Tags: installer, profile-snippet, test-infrastructure, fixture-isolation, session-sync, scope:issue-specific
# Part of tests/install/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher, not run alone.
# Holds the sandbox builders and driver runner every part file uses; it defines functions and runs no case.

# mirror_native_path <path> — the form a native Windows node receives for an MSYS path argument.
mirror_native_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# Builds a temp HOME with valid symlinks (the repair block is a no-op where `ln -s` is real)
# and a fake git on PATH. Optionally seeds ~/.claude/projects/.git so the fetch block runs.
make_sandbox() {
    local with_git_repo="$1"   # 1 = seed .claude/projects/.git, 0 = no repo
    local sb
    sb="$(mktemp -d "${TMPDIR:-/tmp}/fix1225.XXXXXX")"

    mkdir -p "$sb/home/.claude"
    # Real targets for the four repair-checked slots, then valid symlinks.
    : > "$sb/real_CLAUDE.md"
    mkdir -p "$sb/real_skills" "$sb/real_rules" "$sb/real_agents"
    ln -s "$sb/real_CLAUDE.md" "$sb/home/.claude/CLAUDE.md"
    ln -s "$sb/real_skills"    "$sb/home/.claude/skills"
    ln -s "$sb/real_rules"     "$sb/home/.claude/rules"
    ln -s "$sb/real_agents"    "$sb/home/.claude/agents"

    if [ "$with_git_repo" = "1" ]; then
        mkdir -p "$sb/home/.claude/projects/.git"
    fi

    # The snippet's only git call is `git -C <session> config --get core.sshCommand`. The fake
    # answers it from <-C argument>/core-sshcommand (absent = unset, exit 1) and records the -C
    # argument to <sandbox>/dashc-config.out, so TC-SSH2b reads the probe's own scope.
    mkdir -p "$sb/bin"
    cat > "$sb/bin/git" <<EOF
#!/bin/bash
# fake git for fix-1225 test
cmd=""; repo="\$PWD"; prev=""; seen_c=""
for a in "\$@"; do
    if [ "\$prev" = "-C" ]; then repo="\$a"; seen_c="\$a"; fi
    case "\$a" in
        config) if [ -z "\$cmd" ]; then cmd="\$a"; fi ;;
    esac
    prev="\$a"
done
if [ "\$cmd" = "config" ]; then
    printf '%s' "\$seen_c" > "$sb/dashc-config.out"
    case "\$*" in
        *"--get core.sshCommand"*)
            if [ -f "\$repo/core-sshcommand" ]; then cat "\$repo/core-sshcommand"; exit 0; fi
            exit 1
            ;;
    esac
fi
exit 0
EOF
    chmod +x "$sb/bin/git"
    echo "$sb"
}

# mirror_install_recording_engine <sandbox> — the default engine of a mirror. One run records:
#   engine.calls (one line per run), engine-argv.out, gtp.out and sshcmd.out (value or UNSET).
# Optional control files: engine-stdout.txt (printed on stdout), engine-sleep-ms.txt, engine-exit-code.txt.
mirror_install_recording_engine() {
    cat > "$1/agents/bin/session-sync-engine" <<'EOF'
"use strict";
const fs = require("fs");
const path = require("path");
const root = path.join(__dirname, "..", "..");
const at = (name) => path.join(root, name);
const control = (name) => { try { return fs.readFileSync(at(name), "utf8"); } catch (_) { return null; } };
const valueOf = (name) => (process.env[name] === undefined ? "UNSET" : process.env[name]);
fs.appendFileSync(at("engine.calls"), "called\n");
fs.writeFileSync(at("engine-argv.out"), process.argv.slice(2).join("\n") + "\n");
fs.writeFileSync(at("gtp.out"), valueOf("GIT_TERMINAL_PROMPT"));
fs.writeFileSync(at("sshcmd.out"), valueOf("GIT_SSH_COMMAND"));
const leak = control("engine-stdout.txt");
if (leak !== null) fs.writeSync(1, leak);
const sleepMs = Number(control("engine-sleep-ms.txt") || 0);
if (sleepMs > 0) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, sleepMs);
process.exitCode = Number(control("engine-exit-code.txt") || 0);
EOF
}

# mirror_install_real_engine <sandbox> — swaps the fake git and the recording engine for the
# real git on PATH and the real engine. A case using it needs a real ~/.claude/projects clone.
mirror_install_real_engine() {
    local sb="$1"
    rm -f "$sb/bin/git"
    cp "$SCRIPT_CHECKOUT_ROOT/bin/session-sync-engine" "$sb/agents/bin/session-sync-engine"
    cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib/session-sync" "$sb/agents/bin/lib/session-sync"
}

# profile-snippet.sh resolves its root from its own location, so sourcing the real checkout's
# copy would reach the real .env, the real engine and the real dotfileslink.sh (whose
# wait-cc-exit blocks on any live Claude Code). The mirror is a throwaway tree holding the
# snippet plus recording stubs, which is what keeps every verdict independent of live Claude Code.
make_mirror_sandbox() {
    local with_git_repo="$1"
    local sb; sb="$(make_sandbox "$with_git_repo")"

    mkdir -p "$sb/agents/bin/lib" "$sb/agents/hooks/workflow-state" "$sb/agents/install/linux"
    cp "$SNIPPET" "$sb/agents/profile-snippet.sh"
    cp "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" "$sb/agents/bin/get-config-var"
    chmod +x "$sb/agents/bin/get-config-var"
    # codes() delegates to bin/codes-launch.sh (re-read from disk on every call,
    # unlike a sourced function) — mirror it too, or codes() would fail to find it.
    # No vscode-cc-repair stub: codes-launch.sh's own -e guard skips the repair
    # call cleanly when the directory is absent, as it is in this mirror.
    cp "$SCRIPT_CHECKOUT_ROOT/bin/codes-launch.sh" "$sb/agents/bin/codes-launch.sh"
    chmod +x "$sb/agents/bin/codes-launch.sh"
    # The marker SSOT lib ships beside the snippet; copying it here keeps the
    # mirror on the `source the lib` path rather than the inline fallback.
    if [ -f "$MARKERS_LIB" ]; then
        cp "$MARKERS_LIB" "$sb/agents/bin/lib/session-sync-markers.sh"
    fi
    # get-config-var resolves hooks/lib/load-env.js under AGENTS_MAIN_ROOT, and
    # hooks/lib/config-flag.js requires ../workflow-state/plan-step-table (#2820):
    # without that file every --is-off answer reads as off and the fetch block never runs.
    cp -R "$SCRIPT_CHECKOUT_ROOT/hooks/lib" "$sb/agents/hooks/lib"
    cp "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/plan-step-table.js" "$sb/agents/hooks/workflow-state/plan-step-table.js"
    # No .env in the mirror on purpose: loadDefaultEnv short-circuits on
    # AGENTS_MAIN_ROOT and never falls back, so SESSION_SYNC can only come from
    # the process environment. That makes each case decide its own value.

    mirror_install_recording_engine "$sb"

    # Recording stub for the manual sync CLI — never touches a real repo.
    cat > "$sb/agents/bin/session-sync.sh" <<EOF
#!/bin/bash
printf 'was-called %s\n' "\$*" >> "$sb/session-sync.calls"
exit 0
EOF
    chmod +x "$sb/agents/bin/session-sync.sh"
    cat > "$sb/agents/bin/wait-vscode-window.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$sb/agents/bin/wait-vscode-window.sh"
    # Prints on stdout like the real dotfileslink.sh, so the caller-side
    # redirection in profile-snippet.sh is observable (issue #2160).
    cat > "$sb/agents/install/linux/dotfileslink.sh" <<'EOF'
#!/bin/bash
printf 'Symlinks created in ~/.claude/\n'
printf '%s\n' "${WAIT_CC_RESULT-UNSET}" > "$HOME/wait-cc.env"
exit 0
EOF
    chmod +x "$sb/agents/install/linux/dotfileslink.sh"

    # Recording stub for the editor launch, so a case can tell "codes() did
    # nothing" apart from "codes() ran but skipped the push".
    cat > "$sb/bin/code" <<EOF
#!/bin/bash
printf 'was-called %s\n' "\$*" >> "$sb/code.calls"
exit 0
EOF
    chmod +x "$sb/bin/code"
    # Broken-node stub for the fail-safe cases — a stub rather than an empty
    # PATH, since the snippet still needs date/sleep/dirname.
    mkdir -p "$sb/nonode"
    cat > "$sb/nonode/node" <<'EOF'
#!/bin/bash
echo "node: simulated failure" >&2
exit 127
EOF
    chmod +x "$sb/nonode/node"
    echo "$sb"
}

# Runs a driver against the MIRRORED snippet. Four ambient vars are dropped so no assertion
# reads the developer's environment: SESSION_SYNC, CLAUDECODE (set whenever this suite runs
# inside Claude Code — with captured stdout that is the snippet's own skip condition),
# GIT_SSH_COMMAND and GIT_TERMINAL_PROMPT.
# Args: <shell> <sandbox> <driver> <SESSION_SYNC value|UNSET> [<with-node|no-node>]
run_mirror_driver() {
    local shell="$1" sb="$2" driver="$3" ss="${4:-UNSET}" node_mode="${5:-with-node}"
    local path_val="$sb/bin:$PATH"
    [ "$node_mode" = "no-node" ] && path_val="$sb/nonode:$sb/bin:$PATH"
    (
    pin_home_and_userprofile "$sb/home"
    if [ "$ss" = "UNSET" ]; then
        env -u SESSION_SYNC -u CLAUDECODE -u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT \
            HOME="$HOME" USERPROFILE="$USERPROFILE" PATH="$path_val" \
            SNIPPET="$sb/agents/profile-snippet.sh" \
            bash "$RUN_TIMEOUT" 30 "$shell" "$driver" 2>&1
    else
        env -u CLAUDECODE -u GIT_SSH_COMMAND -u GIT_TERMINAL_PROMPT \
            SESSION_SYNC="$ss" HOME="$HOME" USERPROFILE="$USERPROFILE" PATH="$path_val" \
            SNIPPET="$sb/agents/profile-snippet.sh" \
            bash "$RUN_TIMEOUT" 30 "$shell" "$driver" 2>&1
    fi
    )
}
