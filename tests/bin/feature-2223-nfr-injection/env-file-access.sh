#!/usr/bin/env bash
# tests/feature-2223-nfr-injection/env-file-access.sh
# Tests: hooks/lib/load-env.js, hooks/lib/local-env.js
# Tags: scope:issue-specific, TL2, load-env, local-env, security, trust-boundary, pwsh-not-required
# Case file for tests/feature-2223-nfr-injection.sh — sourced from it, never run
# standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# Two access-layer questions the rest of the suite substitutes for: a file the
# process really may not read (EACCES, not "it is a directory"), and a .env.local
# that is a symlink pointing outside the project root it belongs to.
NFR_ENV_FILE_ACCESS_CASES_LOADED=1

# ---------------------------------------------------------------------------
# Part K — unreadable and out-of-root .env.local.
# ---------------------------------------------------------------------------
ACCESS_GLOBAL="GLOBALNFR5TP"
ACCESS_LOCAL="LOCALNFR5TP"
CFG_ACCESS="$(make_cfg access "PROJECT_NFR=$ACCESS_GLOBAL")"

# effective_nfr <project-root> — PROJECT_NFR as the two-layer resolver answers
# it, or __THREW__ when the resolver raised instead of degrading.
effective_nfr() {
    local root="$1" root_node="$1"
    if command -v cygpath >/dev/null 2>&1; then root_node="$(cygpath -m "$1")"; fi
    AGENTS_CONFIG_DIR="$CFG_ACCESS" run_with_timeout 20 node -e '
try {
  const m = require(process.argv[1] + "/hooks/lib/load-env.js");
  const map = m.readEffectiveEnvFile(process.argv[2]);
  process.stdout.write(String(map.PROJECT_NFR === undefined ? "__UNSET__" : map.PROJECT_NFR));
} catch (e) { process.stdout.write("__THREW__"); }
' "$AGENTS_DIR_NODE_ACCESS" "$root_node" 2>/dev/null
}
AGENTS_DIR_NODE_ACCESS="$AGENTS_DIR"
if command -v cygpath >/dev/null 2>&1; then AGENTS_DIR_NODE_ACCESS="$(cygpath -m "$AGENTS_DIR")"; fi

# Control: a readable .env.local wins over the global value, so the two cases
# below measure the loss of the local layer and not a broken fixture.
PROJ_READABLE="$(make_project accessok)"
printf 'PROJECT_NFR=%s\n' "$ACCESS_LOCAL" > "$PROJ_READABLE/$LOCAL_ENV_BASENAME"
assert_eq "T2223K-readable-local-wins" "$ACCESS_LOCAL" "$(effective_nfr "$PROJ_READABLE")"

# --- EACCES: a real permission denial, not a directory standing in for one ---
PROJ_EACCES="$(make_project accesseacces)"
EACCES_FILE="$PROJ_EACCES/$LOCAL_ENV_BASENAME"
printf 'PROJECT_NFR=%s\n' "$ACCESS_LOCAL" > "$EACCES_FILE"
chmod 000 "$EACCES_FILE" 2>/dev/null || true
# Whether the mode bites is a platform property: on Windows (and as root) a
# 000 file stays readable, so the denial is confirmed before it is relied on.
if run_with_timeout 20 node -e '
const fs = require("fs");
try { fs.readFileSync(process.argv[1], "utf8"); process.exit(1); } catch { process.exit(0); }
' "$(command -v cygpath >/dev/null 2>&1 && cygpath -m "$EACCES_FILE" || printf '%s' "$EACCES_FILE")" 2>/dev/null; then
    # The overlay must degrade to the global layer, never throw and never leave
    # a half-applied map: an unreadable local file reads as "no local layer".
    assert_eq "T2223K-eacces-degrades-to-global" "$ACCESS_GLOBAL" "$(effective_nfr "$PROJ_EACCES")"
else
    # TL3 gap: only a POSIX host where mode bits are enforced can run this.
    pass "T2223K-eacces-degrades-to-global SKIPPED \"Because chmod 000 does not deny reads on this host, so a real EACCES cannot be produced\""
fi
chmod 644 "$EACCES_FILE" 2>/dev/null || true

# --- Symlink escaping the project root ---
OUTSIDE_DIR="$TMP_ROOT/outside-any-project"
mkdir -p "$OUTSIDE_DIR"
OUTSIDE_ENV="$OUTSIDE_DIR/escaped.env"
printf 'PROJECT_NFR=%s\nAGENTS_CONFIG_DIR=/hijacked\n' "ESCAPEDNFR5TP" > "$OUTSIDE_ENV"
PROJ_LINK="$(make_project accesslink)"
LINK_FILE="$PROJ_LINK/$LOCAL_ENV_BASENAME"
rm -f "$LINK_FILE"
ln -s "$OUTSIDE_ENV" "$LINK_FILE" 2>/dev/null || true
if [ -L "$LINK_FILE" ]; then
    # KNOWN GAP — the resolver joins root + basename and reads through whatever
    # that name is, so a symlink is followed out of the project without comment.
    # The row records today's answer: a repo can point .env.local at any file the
    # user can read and have it become the project's config. A containment check
    # belongs in the resolver, which is outside this suite; if one is added, this
    # row flips visibly instead of the behaviour changing unnoticed.
    assert_eq "T2223K-symlink-escape-followed (KNOWN GAP: no containment check)" \
        "ESCAPEDNFR5TP" "$(effective_nfr "$PROJ_LINK")"
    # The blocklist is the one boundary that must survive the escape: whatever
    # the link points at, a local AGENTS_CONFIG_DIR is still refused.
    link_cfg="$(AGENTS_CONFIG_DIR="$CFG_ACCESS" run_with_timeout 20 node -e '
const m = require(process.argv[1] + "/hooks/lib/load-env.js");
const map = m.readEffectiveEnvFile(process.argv[2]);
process.stdout.write(String(map.AGENTS_CONFIG_DIR === undefined ? "__UNSET__" : map.AGENTS_CONFIG_DIR));
' "$AGENTS_DIR_NODE_ACCESS" "$(command -v cygpath >/dev/null 2>&1 && cygpath -m "$PROJ_LINK" || printf '%s' "$PROJ_LINK")" 2>/dev/null)"
    assert_eq "T2223K-symlink-escape-blocklist-still-applies" "__UNSET__" "$link_cfg"
else
    # TL3 gap: a host where ln -s produces a real link (POSIX, or Windows with
    # developer mode plus MSYS winsymlinks=nativestrict) can run this.
    pass "T2223K-symlink-escape-followed SKIPPED \"Because ln -s does not create a real symlink on this host, so the escape cannot be constructed\""
    pass "T2223K-symlink-escape-blocklist-still-applies SKIPPED \"Because ln -s does not create a real symlink on this host\""
fi
