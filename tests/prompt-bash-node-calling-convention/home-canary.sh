# tests/prompt-bash-node-calling-convention/home-canary.sh
# Tests: install/lib/settings-allow-rules.js
# Tags: prompt, permissions, calling-convention, ssot, scope:common, pwsh-not-required, TL2

CANARY_HOME=""
CANARY_BEFORE=""

# T22 -- READ-ONLY, ASSERTED. Every part of this suite claims to only READ: the sweep scans
# prompt assets, the template probes require a pure string module, the RT-0 probes grep text.
# The cheapest place for that claim to break is the home directory, which no fixture path can
# pin because subprocesses inherit it -- so it is repointed at a seeded canary before any part
# runs and compared byte for byte after all of them have.

# CONTRACT FOR EVERY OTHER PART: a part that starts writing (a deploy, a cache, a lock file)
# turns T22 red rather than silently editing the developer's real ~/.claude.
# Kept suite-local on purpose: the sibling copy under tests/feature-2119-settings-allow-ssot/
# belongs to an issue-specific suite retired when #2119's coverage is subsumed, and a
# scope:common suite must not lose its isolation guard to another suite's retirement.
canary_setup() {
    CANARY_HOME="$TMPROOT/canary-home"
    mkdir -p "$CANARY_HOME/.claude"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(canary-do-not-touch *)"] } }' \
        > "$CANARY_HOME/.claude/settings.json"
    printf '%s\n' '{ "canary": "local settings" }' > "$CANARY_HOME/.claude/settings.local.json"
    printf '%s\n' '# canary CLAUDE.md' > "$CANARY_HOME/.claude/CLAUDE.md"
    HOME="$CANARY_HOME"
    XDG_CONFIG_HOME="$CANARY_HOME/.config"
    CLAUDE_CONFIG_DIR="$CANARY_HOME/.claude"
    USERPROFILE="$(node_path "$CANARY_HOME")"
    APPDATA="$USERPROFILE/AppData/Roaming"
    LOCALAPPDATA="$USERPROFILE/AppData/Local"
    export HOME XDG_CONFIG_HOME CLAUDE_CONFIG_DIR USERPROFILE APPDATA LOCALAPPDATA
    unset HOMEDRIVE HOMEPATH
    CANARY_BEFORE="$(home_manifest)"
}

# A whole-tree manifest rather than one digest: a writer that adds a NEW file (a backup, a
# lock, a settings.json.tmp) leaves the original byte-identical, and a single-file check
# would call that clean.
home_manifest() {
    ( cd "$CANARY_HOME" 2>/dev/null || { printf '<NO-CANARY-HOME>'; exit 0; }
      find . -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
          printf '%s %s\n' "$f" "$(cksum < "$f" 2>/dev/null || printf 'UNREADABLE')"
      done )
}

t22_probe() { # <id> -> verdict
    local after mutated
    case "$1" in
        settings-file)
            printf '%s' "$(cksum < "$CANARY_HOME/.claude/settings.json" 2>/dev/null || printf 'GONE')" ;;
        whole-tree)
            after="$(home_manifest)"
            [ "$after" = "$CANARY_BEFORE" ] && { printf 'unchanged'; return; }
            printf 'MODIFIED' ;;
        detector)
            printf '%s\n' 'intruder' > "$CANARY_HOME/.claude/intruder.json"
            mutated="$(home_manifest)"
            rm -f "$CANARY_HOME/.claude/intruder.json"
            [ "$mutated" != "$CANARY_BEFORE" ] && { printf 'detected'; return; }
            printf 'BLIND' ;;
    esac
}

t22_home_canary() {
    local want_settings
    want_settings="$(printf '%s\n' '{ "permissions": { "allow": ["Bash(canary-do-not-touch *)"] } }' | cksum)"
    ROWS=$((ROWS + 1))
    assert_eq "T22[settings-file]: the deployed ~/.claude/settings.json stand-in is byte-identical after the whole suite ran" \
        "$want_settings" "$(t22_probe settings-file)"
    ROWS=$((ROWS + 1))
    assert_eq "T22[whole-tree]: nothing anywhere under the canary HOME was created, edited or deleted -- the read-only claim, asserted" \
        "unchanged" "$(t22_probe whole-tree)"
    ROWS=$((ROWS + 1))
    assert_eq "T22[detector]: CANARY -- the manifest really notices a write into the canary HOME (so the two rows above are evidence, not a no-op)" \
        "detected" "$(t22_probe detector)"
}
