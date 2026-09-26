#!/bin/bash
# Tests: skills/sweep-shell-snapshots/SKILL.md, skills/sweep/SKILL.md, bin/sweep-shell-snapshots.sh
# Tags: sweep, shell-snapshots, skill-host, frontmatter, integration, scope:common, TL1, TL3
# Part file of tests/feature-sweep-hub.sh. T1-T14 there prove only that the hub's
# text mentions the new sub-skill; a SKILL.md that names the script in prose and
# never runs it passes all of them. T15-T17 pin the frontmatter the skill host
# actually reads; T18/T19 drive a real `claude -p` host so invocation, flag
# forwarding, exit status and on-disk effects are observed, not inferred.

# Sourced, not exec'd: a missing precondition cannot `exit 77` here.
SKIP=${SKIP:-0}
_shi_skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

SHI_UUID="7f3a1c2d-5b6e-4a80-9c11-2160deadbeef"
SHI_TMP="${TMPDIR:-/tmp}/sweep-hub-e2e-$$"

_shi_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T15 — the two frontmatter keys the host consumes, matched whole-line.
#       `grep model:` also matches `model: opus` or a commented-out line, so the
#       value has to be pinned exactly; and the keys must sit inside the `---`
#       block, which is why this reads frontmatter_of and not the whole file.
# ─────────────────────────────────────────────────────────────────────────────

T15_sweep_shell_snapshots_frontmatter_is_exact() {
    if [ ! -f "$SWEEP_SS" ]; then
        fail "T15 sweep_shell_snapshots_frontmatter_is_exact: $SWEEP_SS does not exist"
        return
    fi
    local fm; fm="$(frontmatter_of "$SWEEP_SS")"
    local missing=""
    printf '%s\n' "$fm" | grep -qx 'model: sonnet' || missing="$missing model:sonnet"
    printf '%s\n' "$fm" | grep -qx 'context: fork' || missing="$missing context:fork"
    printf '%s\n' "$fm" | grep -qx 'user-invocable: true' || missing="$missing user-invocable:true"
    if [ -z "$missing" ]; then
        pass "T15 sweep_shell_snapshots_frontmatter_is_exact (model: sonnet, context: fork, user-invocable: true)"
    else
        fail "T15 sweep_shell_snapshots_frontmatter_is_exact: missing or misspelled in the frontmatter block:$missing. Frontmatter was: $(printf '%s' "$fm" | tr '\n' '/')"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T16 — CPR-ORTH over the forked dispatch family. sweep-plans is the template
#       the plan names; worktrees and branches are its existing siblings. The
#       new skill joins that family, so one row per member keeps a future
#       divergence visible instead of letting the newcomer drift alone.
# ─────────────────────────────────────────────────────────────────────────────

_shi_forked_member() {
    local name="$1"
    local f="$AGENTS_DIR/skills/$name/SKILL.md"
    if [ ! -f "$f" ]; then
        fail "T16/$name: $f does not exist"
        return
    fi
    local fm; fm="$(frontmatter_of "$f")"
    local bad=""
    printf '%s\n' "$fm" | grep -qx 'model: sonnet' || bad="$bad model"
    printf '%s\n' "$fm" | grep -qx 'context: fork' || bad="$bad context"
    if [ -z "$bad" ]; then
        pass "T16/$name: forked dispatch member carries model: sonnet + context: fork"
    else
        fail "T16/$name: forked dispatch member diverges from the family on:$bad"
    fi
}

T16_forked_dispatch_family_is_uniform() {
    local m
    for m in sweep-plans sweep-worktrees sweep-branches sweep-shell-snapshots; do
        _shi_forked_member "$m"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# T17 — the mechanism by which `--dry-run` survives the hop. The hub forwards
#       flags to the sub-skill, and the sub-skill must in turn hand its own
#       arguments to the script; a Usage section that documents the flags but
#       tells the host nothing about passing them through is the failure mode.
# ─────────────────────────────────────────────────────────────────────────────

T17_flag_forwarding_is_instructed_end_to_end() {
    if [ ! -f "$SWEEP_HUB" ] || [ ! -f "$SWEEP_SS" ]; then
        fail "T17 flag_forwarding_is_instructed_end_to_end: hub or sub-skill SKILL.md missing"
        return
    fi
    local hub_body sub_body hub_ok=0 sub_ok=0
    hub_body="$(body_of "$SWEEP_HUB")"
    sub_body="$(body_of "$SWEEP_SS")"
    printf '%s\n' "$hub_body" | grep -qiE 'forward .*(flag|argument|--dry-run).*(sub-skill|each)' && hub_ok=1
    printf '%s\n' "$sub_body" | grep -qiE 'forward' && sub_ok=1
    printf '%s\n' "$sub_body" | grep -qF 'bin/sweep-shell-snapshots.sh' || sub_ok=0
    if [ "$hub_ok" = "1" ] && [ "$sub_ok" = "1" ]; then
        pass "T17 flag_forwarding_is_instructed_end_to_end (hub forwards to sub-skills; sub-skill forwards to bin/sweep-shell-snapshots.sh)"
    else
        fail "T17 flag_forwarding_is_instructed_end_to_end: hub-forwarding-rule=$hub_ok sub-skill-forwards-to-script=$sub_ok — without both, --dry-run never reaches the script and the hub deletes when the operator asked to preview"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T18/T19 — real skill host. `_shi_e2e_home` builds a HOME whose .claude holds
# only this sub-skill plus an empty settings.json (a copied global settings.json
# carries disableBypassPermissionsMode and hangs the run — rules/test/claude-e2e.md),
# and two snapshots: one corrupted by the known fetch marker, one healthy.
# ─────────────────────────────────────────────────────────────────────────────

_shi_e2e_home() {
    local tag="$1"
    local home="$SHI_TMP/$tag/home"
    local d="$home/.claude/shell-snapshots"
    mkdir -p "$d" "$home/.claude/skills" || { printf ''; return; }
    cp -R "$AGENTS_DIR/skills/sweep-shell-snapshots" "$home/.claude/skills/" || { printf ''; return; }
    printf '{}\n' > "$home/.claude/settings.json"
    printf '# Snapshot file generated by Claude Code\n' > "$d/broken.sh"
    printf "export PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" >> "$d/broken.sh"
    printf '# Snapshot file generated by Claude Code\n' > "$d/healthy.sh"
    printf "export PATH='/usr/bin:/bin'\n" >> "$d/healthy.sh"
    perl -e 'my $t = time - 3 * 86400; for (@ARGV) { utime $t, $t, $_ }' \
        "$d/broken.sh" "$d/healthy.sh" || { printf ''; return; }
    printf '%s' "$home"
}

# Returns 0 when a real `claude -p` run is possible here, else prints the reason.
_shi_e2e_gate() {
    [ -f "$SWEEP_SS" ] || { printf 'skills/sweep-shell-snapshots/SKILL.md does not exist yet'; return 1; }
    [ -f "$AGENTS_DIR/bin/sweep-shell-snapshots.sh" ] || { printf 'bin/sweep-shell-snapshots.sh does not exist yet'; return 1; }
    [ -x "$AGENTS_DIR/bin/get-config-var" ] || { printf 'bin/get-config-var is not executable'; return 1; }
    "$AGENTS_DIR/bin/get-config-var" --is-off RUN_TL3 off && { printf 'RUN_TL3 is off'; return 1; }
    command -v claude >/dev/null 2>&1 || { printf 'the claude CLI is not on PATH'; return 1; }
    return 0
}

_shi_e2e_run() {
    local home="$1" prompt="$2"
    unset CLAUDECODE
    HOME="$home" _shi_timeout claude -p "$prompt" --output-format text \
        --session-id "$SHI_UUID" --dangerously-skip-permissions 2>&1
}

T18_host_forwards_dry_run_to_the_script() {
    local why
    if ! why="$(_shi_e2e_gate)"; then
        _shi_skip "T18 host_forwards_dry_run_to_the_script: $why"
        return
    fi
    local home; home="$(_shi_e2e_home t18)"
    if [ -z "$home" ]; then
        fail "T18 host_forwards_dry_run_to_the_script: could not build the fixture HOME"
        return
    fi
    local d="$home/.claude/shell-snapshots"
    local out rc
    out="$(cd "$AGENTS_DIR" && _shi_e2e_run "$home" "/sweep-shell-snapshots --dry-run")"
    rc=$?
    local ran=0
    printf '%s\n' "$out" | grep -qE 'scanned=[0-9]+' && ran=1
    if [ "$rc" -eq 0 ] && [ "$ran" = "1" ] && [ -f "$d/broken.sh" ] && [ -f "$d/healthy.sh" ]; then
        pass "T18 host_forwards_dry_run_to_the_script: the real host ran the script and --dry-run survived the hop (nothing deleted)"
    else
        fail "T18 host_forwards_dry_run_to_the_script: exit=$rc script-summary-seen=$ran broken=$([ -f "$d/broken.sh" ] && echo kept || echo DELETED) healthy=$([ -f "$d/healthy.sh" ] && echo kept || echo DELETED) — a lost --dry-run deletes the operator's snapshots during a preview. Output: $out"
    fi
}

T19_host_invocation_has_write_mode_effects() {
    local why
    if ! why="$(_shi_e2e_gate)"; then
        _shi_skip "T19 host_invocation_has_write_mode_effects: $why"
        return
    fi
    local home; home="$(_shi_e2e_home t19)"
    if [ -z "$home" ]; then
        fail "T19 host_invocation_has_write_mode_effects: could not build the fixture HOME"
        return
    fi
    local d="$home/.claude/shell-snapshots"
    local out rc
    out="$(cd "$AGENTS_DIR" && _shi_e2e_run "$home" "/sweep-shell-snapshots")"
    rc=$?
    if [ "$rc" -eq 0 ] && [ ! -f "$d/broken.sh" ] && [ -f "$d/healthy.sh" ]; then
        pass "T19 host_invocation_has_write_mode_effects: the flagless host invocation removed the corrupted snapshot and kept the healthy one"
    else
        fail "T19 host_invocation_has_write_mode_effects: exit=$rc broken=$([ -f "$d/broken.sh" ] && echo STILL-PRESENT || echo removed) healthy=$([ -f "$d/healthy.sh" ] && echo kept || echo WRONGLY-DELETED) — the skill is registered but the script never really runs. Output: $out"
    fi
}

# T20 — a real host run of the HUB (not the sub-skill directly), proving
# dispatch reaches sweep-shell-snapshots' dry-run codepath. The hub->sub-skill
# hop was previously structural-only (T13/T14/T17): a full `/sweep --dry-run`
# also dispatches to worktrees/branches/plans/tests/issues sub-skills (GitHub +
# every host worktree). Blast radius here is bounded like _shi_e2e_home already
# bounds the sub-skill test: the isolated HOME's .claude/skills/ carries ONLY
# `sweep` + `sweep-shell-snapshots` (skills resolve from $HOME, not repo root),
# so the other SW-N steps have no matching skill, and cwd is a scratch repo.

_shi_hub_e2e_home() {
    local tag="$1"
    local home; home="$(_shi_e2e_home "$tag")"
    [ -z "$home" ] && { printf ''; return; }
    cp -R "$AGENTS_DIR/skills/sweep" "$home/.claude/skills/" || { printf ''; return; }
    printf '%s' "$home"
}

# A disposable git repo to `cd` into before the `claude -p` call, so a
# dispatch step the model attempts to improvise (no matching skill found under
# the isolated HOME) touches this throwaway checkout, never $AGENTS_DIR.
_shi_hub_scratch_repo() {
    local tag="$1"
    local repo="$SHI_TMP/$tag/repo"
    mkdir -p "$repo" || { printf ''; return; }
    ( cd "$repo" && git init -q && git config user.email "t@example.com" \
        && git config user.name "t" && printf '# scratch\n' > README.md \
        && git add README.md && git commit -q -m init ) >/dev/null 2>&1 \
        || { printf ''; return; }
    printf '%s' "$repo"
}

T20_hub_dry_run_dispatches_to_sweep_shell_snapshots() {
    local why
    if ! why="$(_shi_e2e_gate)"; then
        _shi_skip "T20 hub_dry_run_dispatches_to_sweep_shell_snapshots: $why"
        return
    fi
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T20 hub_dry_run_dispatches_to_sweep_shell_snapshots: $SWEEP_HUB does not exist"
        return
    fi
    local home; home="$(_shi_hub_e2e_home t20)"
    if [ -z "$home" ]; then
        fail "T20 hub_dry_run_dispatches_to_sweep_shell_snapshots: could not build the fixture HOME"
        return
    fi
    local repo; repo="$(_shi_hub_scratch_repo t20)"
    if [ -z "$repo" ]; then
        fail "T20 hub_dry_run_dispatches_to_sweep_shell_snapshots: could not build the scratch repo"
        return
    fi
    local d="$home/.claude/shell-snapshots"
    local out rc
    out="$(cd "$repo" && _shi_e2e_run "$home" "/sweep --dry-run")"
    rc=$?
    local ran=0
    printf '%s\n' "$out" | grep -qE 'scanned=[0-9]+' && ran=1
    if [ "$rc" -eq 0 ] && [ "$ran" = "1" ] && [ -f "$d/broken.sh" ] && [ -f "$d/healthy.sh" ]; then
        pass "T20 hub_dry_run_dispatches_to_sweep_shell_snapshots: /sweep --dry-run reached the sub-skill's dry-run codepath (scanned=N seen, nothing deleted)"
    else
        fail "T20 hub_dry_run_dispatches_to_sweep_shell_snapshots: exit=$rc script-summary-seen=$ran broken=$([ -f "$d/broken.sh" ] && echo kept || echo DELETED) healthy=$([ -f "$d/healthy.sh" ] && echo kept || echo DELETED) — the hub either never dispatched to sweep-shell-snapshots or --dry-run was lost crossing the hub boundary. Output: $out"
    fi
}

T15_sweep_shell_snapshots_frontmatter_is_exact
T16_forked_dispatch_family_is_uniform
T17_flag_forwarding_is_instructed_end_to_end
T18_host_forwards_dry_run_to_the_script
T19_host_invocation_has_write_mode_effects
T20_hub_dry_run_dispatches_to_sweep_shell_snapshots

[ "$SKIP" -gt 0 ] && echo "  ($SKIP TL3 skill-host case(s) skipped — see the SKIP lines above)"

rm -rf "$SHI_TMP" 2>/dev/null
true
