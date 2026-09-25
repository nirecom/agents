# Tests: profile-snippet.sh, bin/get-config-var
# Tags: installer, profile-snippet, session-sync, toggle, scope:issue-specific
# Part of tests/fix-1225-profile-snippet-guards.sh — sourced by that dispatcher,
# not run alone. Uses its make_mirror_sandbox / run_mirror_driver helpers.
#
# Contract under test — the SESSION_SYNC toggle gates the two *automatic*
# profile-snippet.sh call sites:
#   1. the startup auto-fetch block (~/.claude/projects fetch + ff-only merge)
#   2. the codes() auto-push (bin/session-sync.sh push --quiet)
# Shipped default is off, and the resolution is fail-safe OFF: automatic sync
# runs only on an explicit, readable `on`. Every other outcome — unset,
# unrecognized value, or an unreadable config (broken node) — must leave the
# automatic path silent. The manual CLI is not gated; that contract lives in
# tests/main-session-sync/session-sync-independence.sh.
#
# The `codes` command itself is NOT gated — only its sync side effect (TC21).

# _ssg_wait_marker <file> <max-tenths> — poll for a marker file. Emitted into
# the generated drivers, kept here as the single definition of the wait budget.

# ---------------------------------------------------------------------------
# Startup auto-fetch matrix
#
# Table-driven over the whole value domain of SESSION_SYNC: the shipped default
# (unset), both recognized values, an unrecognized value, and a case-variant of
# the recognized "on". Only an explicit on may enable the automatic fetch.
# ---------------------------------------------------------------------------
tc_gate_startup_fetch() {
    local label="$1" ss_value="$2" node_mode="$3" expect="$4" why="$5"
    local sb; sb="$(make_mirror_sandbox 1)"   # seed projects/.git so the block can run
    local drv="$sb/drv_gate_fetch.sh"
    cat > "$drv" <<'EOF'
. "$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" "$ss_value" "$node_mode")"
    local ran=0
    if echo "$out" | grep -q "git fetch Claude session sync" || [ -f "$sb/gtp.out" ]; then
        ran=1
    fi
    if [ "$ran" = "$expect" ]; then
        pass "$label: startup auto-fetch $([ "$expect" = "1" ] && echo runs || echo stays silent) ($why)"
    else
        fail "$label: startup auto-fetch ran=$ran expected=$expect ($why). Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# Startup auto-fetch matrix — REAL git.
#
# tc_gate_startup_fetch above observes the block through a fake `git` on PATH,
# so it can only report "the fetch command was reached". The guarded block is
# two operations, not one:
#
#     _session_sync_fetch                                   # git fetch
#     [ "${_rc_ss:-1}" -eq 0 ] && git ... merge --ff-only FETCH_HEAD
#
# A gate placed around the fetch alone would leave the ff-only merge running on
# every shell start — the working tree would still be mutated with the toggle
# off. Making ~/.claude/projects a real clone of a real (local) remote turns
# both halves into observable facts: FETCH_HEAD appears only if the fetch ran,
# and HEAD advances to the remote tip only if the merge ran.
# ---------------------------------------------------------------------------
make_real_git_sandbox() {
    local sb; sb="$(make_mirror_sandbox 0)"
    # Drop the fake recorder so the snippet drives the real git binary.
    rm -f "$sb/bin/git"

    cat > "$sb/gitconfig" <<'GITCONFIG'
[user]
	name = Session Sync Test
	email = session-sync-test@example.com
[init]
	defaultBranch = main
[commit]
	gpgSign = false
[advice]
	detachedHead = false
GITCONFIG
    # The developer's global config may point core.hooksPath at this repo's own
    # hooks, which would fire (and abort) inside the fixture repos.
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL="$sb/gitconfig"

    git init --bare "$sb/remote.git" >/dev/null 2>&1
    git clone "$sb/remote.git" "$sb/seed" >/dev/null 2>&1
    printf '{"a":1}\n' > "$sb/seed/a.jsonl"
    git -C "$sb/seed" add -A >/dev/null 2>&1
    git -C "$sb/seed" commit -m "base" >/dev/null 2>&1
    git -C "$sb/seed" push -u origin main >/dev/null 2>&1

    git clone "$sb/remote.git" "$sb/home/.claude/projects" >/dev/null 2>&1
    # A fresh clone leaves no FETCH_HEAD; remove any the git version wrote so
    # its presence after the run means "this run fetched".
    rm -f "$sb/home/.claude/projects/.git/FETCH_HEAD"

    # Advance the remote so a successful ff-only merge is observable as a moved HEAD.
    printf '{"b":2}\n' > "$sb/seed/b.jsonl"
    git -C "$sb/seed" add -A >/dev/null 2>&1
    git -C "$sb/seed" commit -m "advance" >/dev/null 2>&1
    git -C "$sb/seed" push >/dev/null 2>&1

    echo "$sb"
}

# tc_gate_fetch_merge_real <label> <SESSION_SYNC|UNSET> <with-node|no-node> <expect> <why>
# expect: 1 = fetch AND merge must both happen, 0 = neither may happen.
tc_gate_fetch_merge_real() {
    local label="$1" ss_value="$2" node_mode="$3" expect="$4" why="$5"
    local sb; sb="$(make_real_git_sandbox)"
    local proj="$sb/home/.claude/projects"
    local base_head remote_head
    base_head="$(git -C "$proj" rev-parse HEAD 2>/dev/null)"
    remote_head="$(git -C "$sb/seed" rev-parse HEAD 2>/dev/null)"

    local drv="$sb/drv_real_git.sh"
    cat > "$drv" <<EOF
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$sb/gitconfig"
. "\$SNIPPET"
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" "$ss_value" "$node_mode")"

    local fetched=0 merged=0 head_after
    [ -f "$proj/.git/FETCH_HEAD" ] && fetched=1
    head_after="$(git -C "$proj" rev-parse HEAD 2>/dev/null)"
    [ -n "$head_after" ] && [ "$head_after" = "$remote_head" ] && merged=1

    if [ "$fetched" = "$expect" ]; then
        pass "$label: real git fetch $([ "$expect" = "1" ] && echo runs || echo stays silent) ($why)"
    else
        fail "$label: real git fetch ran=$fetched expected=$expect ($why). Output: $out"
    fi
    # The merge is the half a fetch-only gate would leave unguarded.
    if [ "$merged" = "$expect" ]; then
        pass "$label: ff-only merge $([ "$expect" = "1" ] && echo reached || echo stays silent) ($why)"
    else
        fail "$label: ff-only merge ran=$merged expected=$expect ($why). HEAD base=$base_head after=$head_after remote=$remote_head. Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# codes() auto-push matrix — same value domain, second call site (CPR-ORTH: the
# two automatic sites are symmetric members of one class and must agree).
# ---------------------------------------------------------------------------
tc_gate_codes_push() {
    local label="$1" ss_value="$2" node_mode="$3" expect="$4" why="$5"
    local sb; sb="$(make_mirror_sandbox 0)"
    local drv="$sb/drv_gate_push.sh"
    cat > "$drv" <<EOF
. "\$SNIPPET"
if ! type codes >/dev/null 2>&1; then echo "CODES=missing"; exit 0; fi
codes "\$HOME" >/dev/null 2>&1
# codes() backgrounds its body and disowns it, so \`wait\` cannot be used —
# poll for the stubs' marker files instead, on a bounded budget.
_i=0
while [ "\$_i" -lt 25 ]; do
    [ -f "$sb/code.calls" ] && break
    sleep 0.2
    _i=\$((_i + 1))
done
# The VS Code stub has run; give the rest of the subshell a grace period to
# reach (or deliberately skip) the bin/session-sync.sh push.
_j=0
while [ "\$_j" -lt 15 ]; do
    [ -f "$sb/session-sync.calls" ] && break
    sleep 0.1
    _j=\$((_j + 1))
done
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" "$ss_value" "$node_mode")"
    local pushed=0
    [ -f "$sb/session-sync.calls" ] && pushed=1
    if [ "$pushed" = "$expect" ]; then
        pass "$label: codes() auto-push $([ "$expect" = "1" ] && echo runs || echo stays silent) ($why)"
    else
        fail "$label: codes() auto-push pushed=$pushed expected=$expect ($why). calls=$(cat "$sb/session-sync.calls" 2>/dev/null). Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC20b — when the gate is ON, the recorded push must carry the same arguments
# as before the gate landed (--quiet, with or without --toast). Guards against
# a gate rewrite that silently changes the invocation.
# ---------------------------------------------------------------------------
tc_gate_codes_push_args() {
    local sb; sb="$(make_mirror_sandbox 0)"
    local drv="$sb/drv_gate_args.sh"
    cat > "$drv" <<EOF
. "\$SNIPPET"
codes "\$HOME" >/dev/null 2>&1
_i=0
while [ "\$_i" -lt 25 ]; do
    [ -f "$sb/session-sync.calls" ] && break
    sleep 0.2
    _i=\$((_i + 1))
done
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" on with-node)"
    local calls; calls="$(cat "$sb/session-sync.calls" 2>/dev/null || true)"
    if echo "$calls" | grep -q "push --quiet"; then
        pass "TC20b: gate ON preserves the codes() push invocation (push --quiet ...)"
    else
        fail "TC20b: codes() push args changed or push never ran (calls: '$calls'). Output: $out"
    fi
    rm -rf "$sb"
}

# ---------------------------------------------------------------------------
# TC21 — orthogonality: the toggle gates the *sync side effect* only. With the
# gate off, `codes` must still be defined and must still launch VS Code.
# ---------------------------------------------------------------------------
tc_gate_codes_still_launches() {
    local sb; sb="$(make_mirror_sandbox 0)"
    local drv="$sb/drv_gate_launch.sh"
    cat > "$drv" <<EOF
. "\$SNIPPET"
if type codes >/dev/null 2>&1; then echo "CODES=function"; else echo "CODES=missing"; fi
codes "\$HOME" >/dev/null 2>&1
_i=0
while [ "\$_i" -lt 25 ]; do
    [ -f "$sb/code.calls" ] && break
    sleep 0.2
    _i=\$((_i + 1))
done
echo "DONE"
EOF
    local out; out="$(run_mirror_driver bash "$sb" "$drv" off with-node)"
    if echo "$out" | grep -q "CODES=function" && [ -f "$sb/code.calls" ] \
        && [ ! -f "$sb/session-sync.calls" ]; then
        pass "TC21: SESSION_SYNC=off still defines codes() and still launches VS Code (only the push is gated)"
    else
        fail "TC21: gate off changed the codes() command itself (code_called=$([ -f "$sb/code.calls" ] && echo yes || echo no) pushed=$([ -f "$sb/session-sync.calls" ] && echo yes || echo no)). Output: $out"
    fi
    rm -rf "$sb"
}

# --- Run the gate matrix ----------------------------------------------------
# expect: 1 = the automatic path must run, 0 = it must stay silent.
tc_gate_startup_fetch "TC13" off      with-node 0 "explicit off"
tc_gate_startup_fetch "TC14" UNSET    with-node 0 "unset — shipped default is off"
tc_gate_startup_fetch "TC15" maybe    no-node   0 "unreadable config, fail-safe off"
tc_gate_startup_fetch "TC16" on       with-node 1 "explicit on"
tc_gate_startup_fetch "TC16b" ON      with-node 1 "value match is case-insensitive"
tc_gate_startup_fetch "TC16c" maybe   with-node 0 "unrecognized value, fail-safe off"

# Same rows again, but against a real clone of a real remote so the ff-only
# merge — not just the fetch — is pinned on both sides of the gate.
tc_gate_fetch_merge_real "TC16d" off   with-node 0 "explicit off"
tc_gate_fetch_merge_real "TC16e" UNSET with-node 0 "unset — shipped default is off"
tc_gate_fetch_merge_real "TC16f" maybe no-node   0 "unreadable config, fail-safe off"
tc_gate_fetch_merge_real "TC16g" maybe with-node 0 "unrecognized value, fail-safe off"
tc_gate_fetch_merge_real "TC16h" on    with-node 1 "explicit on"
tc_gate_fetch_merge_real "TC16i" ON    with-node 1 "value match is case-insensitive"

# CPR-ORTH: the push matrix carries exactly the same row set as the fetch matrix
# above. A value domain covered at one automatic call site but not the other is
# the asymmetry this pairing exists to catch.
tc_gate_codes_push "TC17"  off   with-node 0 "explicit off"
tc_gate_codes_push "TC18"  UNSET with-node 0 "unset — shipped default is off"
tc_gate_codes_push "TC19"  maybe no-node   0 "unreadable config, fail-safe off"
tc_gate_codes_push "TC19b" maybe with-node 0 "unrecognized value with a working resolver, fail-safe off"
tc_gate_codes_push "TC20"  on    with-node 1 "explicit on"
tc_gate_codes_push "TC20a" ON    with-node 1 "value match is case-insensitive"

tc_gate_codes_push_args            # TC20b
tc_gate_codes_still_launches       # TC21
