# tests/feature-2119-settings-allow-ssot/home-canary.sh
# Tests: install/lib/settings-deploy.js, install/assemble-settings.js, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

CANARY_HOME=""
CANARY_BEFORE=""

# T22 -- THE OTHER settings.json. The developer running this suite has a DEPLOYED
# ~/.claude/settings.json, and this feature's whole subject is writing one. Every fixture is
# built under $TMPROOT, but subprocesses inherit the real HOME/USERPROFILE, so a target
# resolved through the home directory would corrupt the live permission set while the suite
# reports green. The home variables are therefore repointed at a seeded canary before any
# part runs, and compared byte for byte after all of them have.
# CONTRACT FOR EVERY OTHER PART: rules are injected AT DEPLOY TIME, so lines in this suite
# really do write a ~/.claude/settings.json. Any such line MUST pass a fixture-private HOME
# (and USERPROFILE) PER SUBPROCESS -- see run_gen / run_assemble in generator.sh. A part that
# forgets deploys INTO the canary, and T22 turns red rather than staying silent.
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

# A whole-tree manifest rather than one digest: an implementation that writes a NEW file into
# ~/.claude (a backup, a lock, a rewritten settings.json.tmp) leaves the original byte-
# identical, and a single-file check would call that clean.
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
    assert_eq "T22[whole-tree]: nothing anywhere under the canary HOME was created, edited or deleted" \
        "unchanged" "$(t22_probe whole-tree)"
    ROWS=$((ROWS + 1))
    assert_eq "T22[detector]: CANARY -- the manifest really notices a write into the canary HOME (so the two rows above are evidence, not a no-op)" \
        "detected" "$(t22_probe detector)"
}
