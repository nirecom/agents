# tests/feature-2119-settings-allow-ssot/real-repo-expansion.sh
# Tests: install/settings-allow-commands.txt, install/path-exposed-commands.txt, install/lib/settings-allow-rules.js, install/assemble-settings.js, settings.json
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T31-T32: the REAL repository as input, never a fixture SSOT. Sourced AFTER ssot-structure.sh
# (SSOT_LIST, resolve_shebang) and generator.sh (the template contract, deployed_allow_dump).

T31_FX=""
T31_RC="unrun"

# The four commands this change admits. Every other case in the suite drives a fixture SSOT
# whose entries live under bin/, so an implementation that quietly drops `skills/**` entries --
# a path shape no fixture exercises -- passes all of them, and so does a round trip that asks
# the generator to grade its own output. This part deploys the REAL settings.json + the REAL
# SSOT into a throwaway HOME and then asserts each admitted entry's sixteen spellings as exact
# strings rebuilt from the independent template contract.
T31_NEW_ENTRIES='bin/check-issues-class-coverage
bin/workflow/record-skip-judgment
skills/_shared/assemble-mandatory.sh
skills/make-detail-plan/scripts/detect-scope-change.sh'

# The one SSOT entry whose basename install/path-exposed-commands.txt really carries. The bare
# forms are keyed on that second list, not on the SSOT, so it is the only entry in the real tree
# entitled to them -- which is what makes the absence rows below a pairing rule rather than a
# blanket "no bare rules anywhere".
T31_EXPOSED_ENTRY='bin/review-code-codex'

t31_setup() {
    T31_FX="$TMPROOT/t31"
    mkdir -p "$T31_FX/home/.claude"
    : > "$T31_FX/allow.txt"
    if ! have_lib; then T31_RC="$(missing_lib)"; return; fi
    if [ ! -f "$ASSEMBLE" ]; then T31_RC="$(missing_assemble)"; return; fi
    local rc=0
    ( cd "$AGENTS_DIR" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        HOME="$T31_FX/home" USERPROFILE="$(node_path "$T31_FX/home")" \
        CLAUDE_CONFIG_DIR="$T31_FX/home/.claude" \
        run_with_timeout 90 node "$ASSEMBLE_REL" ) >/dev/null 2>&1 || rc=$?
    T31_RC="$rc"
    deployed_allow_dump "$T31_FX" "$T31_FX/allow.txt"
}

t31_has() { # <rule> -> present|absent|sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    if grep -Fxq -- "$1" "$T31_FX/allow.txt" 2>/dev/null; then printf 'present'; else printf 'absent'; fi
}

# The deploy's own exit code is asserted first. Without it the twenty-four absence rows below
# would all pass on a deploy that produced nothing at all.
t31_deploy_row() {
    ROWS=$((ROWS + 1))
    assert_eq "T31[deploy]: $ASSEMBLE_REL deploys the real repository into a throwaway HOME and exits 0 (every T31 row below reads that deployment)" \
        "0" "$T31_RC"
}

t31_path_rules_table() {
    local entry interp rule
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        interp="$(resolve_shebang "$AGENTS_DIR/$entry")"
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            ROWS=$((ROWS + 1))
            assert_eq "T31[$entry|$interp]: $rule" "present" "$(t31_has "$rule")"
        done < <(expected_path_rules "$interp" "$entry")
    done <<< "$T31_NEW_ENTRIES"
}

# The symmetric half of the pairing rule. `bareRules` are emitted only for an entry whose
# basename appears in install/path-exposed-commands.txt; none of the four does, so a generator
# that emits bare spellings for every entry would hand a PATH-wide `Bash(record-skip-judgment *)`
# to anything of that name on the machine. Asserting the absence is the only way that widening
# is visible.
t31_bare_absence_table() {
    local entry name rule
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        name="$(basename "$entry")"
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            ROWS=$((ROWS + 1))
            assert_eq "T31[bare-absent|$entry]: $name is not on install/path-exposed-commands.txt, so it gets no bare spelling -- $rule" \
                "absent" "$(t31_has "$rule")"
        done < <(expected_bare_rules "$name")
    done <<< "$T31_NEW_ENTRIES"
}

t31_bare_presence_table() {
    local name rule
    name="$(basename "$T31_EXPOSED_ENTRY")"
    while IFS= read -r rule; do
        [ -n "$rule" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T31[bare-present|$T31_EXPOSED_ENTRY]: POSITIVE CONTROL -- $name IS PATH-exposed, so its six bare spellings are deployed: $rule" \
            "present" "$(t31_has "$rule")"
    done < <(expected_bare_rules "$name")
}

# T32 -- THE REPOSITORY'S OWN settings.json, AFTER THE DELETION. The generated rules move out of
# the tracked file entirely; the risk the delivery plan names is that the hand deletion of the
# generated block misses some. A leftover is invisible in review (it is a plausible-looking allow
# rule among hundreds) and harmless-looking at runtime (the same string is injected back), yet it
# resurrects exactly the hand-maintained mirror this change exists to abolish. So the assertion
# is computed from the LIVE SSOT rather than pinned to a rule list -- or to a rule COUNT -- that
# would need its own maintenance.
T32_GEN_ACTUAL="$TMPROOT/t32-actual.txt"
T32_GEN_SHAPED="$TMPROOT/t32-shaped.txt"
T32_ALLOW="$TMPROOT/t32-allow.txt"

# The third row's inputs. "No hand-written rule went with the block" cannot be asked of the
# after-image alone -- it needs the before-image T45 already resolves, so t45_setup is called
# ahead of this part's tables and its baseline is reused rather than re-derived here.
T32_BEFORE_ALLOW="$TMPROOT/t32-before-allow.txt"

# Hand-written is the COMPLEMENT of "names a command the SSOT owns": the pre-deletion mirror was
# hand-typed over years and carries spellings no current template emits (`*/agents/bin/x *`), so
# a shaped-set subtraction would read those retired forms as hand-written losses. Membership is
# asked of the command NAME -- the SSOT paths plus the PATH-exposed basenames that earn bare
# forms -- which every spelling of a generated rule, past or present, necessarily contains.
T32_SSOT_NAMES="$TMPROOT/t32-ssot-names.txt"

t32_expand() {
    local e n
    : > "$T32_GEN_ACTUAL"
    : > "$T32_GEN_SHAPED"
    : > "$T32_SSOT_NAMES"
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        n="$(basename "$e")"
        expected_path_rules "$(resolve_shebang "$AGENTS_DIR/$e")" "$e" >> "$T32_GEN_ACTUAL"
        # The shaped set is deliberately wider: BOTH interpreters and the bare forms for every
        # entry, PATH-exposed or not. A rule left behind from before an entry's shebang changed
        # is not in the actual set but is still a generated-shaped rule for an SSOT command.
        expected_path_rules bash "$e" >> "$T32_GEN_SHAPED"
        expected_path_rules node "$e" >> "$T32_GEN_SHAPED"
        expected_bare_rules "$n" >> "$T32_GEN_SHAPED"
        printf '%s\n' "$e" >> "$T32_SSOT_NAMES"
    done <<< "$SSOT_LIST"
    ssot_entries "$PATH_SSOT" >> "$T32_SSOT_NAMES"
}

t32_dump_allow() { # <settings-json> <out-file>
    node -e '
      const fs = require("fs");
      let a = [];
      try { a = (JSON.parse(fs.readFileSync(process.argv[1], "utf8")).permissions || {}).allow || []; }
      catch (e) { a = []; }
      fs.writeFileSync(process.argv[2], a.join("\n") + (a.length ? "\n" : ""));
    ' "$(node_path "$1")" "$(node_path "$2")" 2>/dev/null || : > "$2"
}

# The before-image is dumped only once T45 has resolved a revision for it; without one the
# `lost` row reports T45's own sentinel instead of comparing against an empty file.
t32_dump_before() {
    : > "$T32_BEFORE_ALLOW"
    [ -f "$T45_BEFORE" ] || return 0
    t32_dump_allow "$T45_BEFORE" "$T32_BEFORE_ALLOW"
}

# A hand-written rule counts as surviving when its exact string is still there OR when the
# command it points at is still allow-listed under some other spelling: settings.json's own
# `node hooks/cleanup-orphan-dir.js` pair was RE-SPELLED in this edit, not dropped, and calling
# that a lost permission would be the same false alarm the pinned count produced. Slashes are
# normalised first so the Windows twin of a POSIX rule is not read as a different command.
t32_lost() { # -> none | NO-HAND-WRITTEN-BASELINE | LOST(n):<rules>
    node -e '
      const fs = require("fs");
      const rd = (p) => { try { return fs.readFileSync(p, "utf8").split("\n").filter((s) => s.length); } catch (e) { return []; } };
      const norm = (s) => s.replace(/\\/g, "/");
      const before = rd(process.argv[1]);
      const after = rd(process.argv[2]).map(norm);
      const names = rd(process.argv[3]).map(norm);
      const target = (s) => {
        const m = norm(s).match(/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)+/g);
        return m ? m[m.length - 1] : "";
      };
      const hand = before.filter((b) => !names.some((n) => norm(b).indexOf(n) !== -1));
      if (!hand.length) { console.log("NO-HAND-WRITTEN-BASELINE"); }
      else {
        const lost = hand.filter((h) => {
          if (after.indexOf(norm(h)) !== -1) return false;
          const t = target(h);
          return !(t && after.some((a) => a.indexOf(t) !== -1));
        });
        console.log(lost.length ? "LOST(" + lost.length + "):" + lost.slice(0, 3).join(" ") : "none");
      }
    ' "$(node_path "$T32_BEFORE_ALLOW")" "$(node_path "$T32_ALLOW")" "$(node_path "$T32_SSOT_NAMES")" \
      2>/dev/null || printf 'NODE-ERROR'
}

t32_probe() { # <lost|intersection|shaped> -> value | sentinel
    [ -f "$SETTINGS" ] || { printf '<MISSING:%s>' "$SETTINGS_REL"; return; }
    local n g
    case "$1" in
        lost)
            case "$T45_BASELINE" in
                "<MISSING:"*|unresolved|NO-PRE-DELETION-REVISION) printf '%s' "$T45_BASELINE"; return ;;
            esac
            g="$(t45_gate)"
            [ -z "$g" ] || { printf '%s' "$g"; return; }
            t32_lost
            ;;
        intersection)
            n="$(grep -Fxf "$T32_GEN_ACTUAL" "$T32_ALLOW" 2>/dev/null | grep -c .)" || n=0
            [ "${n:-0}" = "0" ] && { printf 'none'; return; }
            printf 'LEFTOVER(%s):%s' "$n" "$(grep -Fxf "$T32_GEN_ACTUAL" "$T32_ALLOW" | head -3 | tr '\n' ' ')"
            ;;
        shaped)
            n="$(grep -Fxf "$T32_GEN_SHAPED" "$T32_ALLOW" 2>/dev/null | grep -c .)" || n=0
            [ "${n:-0}" = "0" ] && { printf 'none'; return; }
            printf 'SHAPED(%s):%s' "$n" "$(grep -Fxf "$T32_GEN_SHAPED" "$T32_ALLOW" | head -3 | tr '\n' ' ')"
            ;;
    esac
}

# The mirror risk runs both ways, so the third row asks the opposite question: did the deletion
# take a hand-written rule WITH it? A snapshot of the allow-list length would answer that only
# until the next legitimate grant lands from upstream, and would then fail reading "a hand-written
# rule went with the block" when nothing of the sort happened. Naming the survivors instead is
# both stable under such a grant and stricter -- it fails on WHICH rule vanished, not on a total.
t32_repo_original_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T32[$id]: $SETTINGS_REL $label" "$want" "$(t32_probe "$id")"
    done <<'T32_CASES'
intersection|none|shares not one entry with the rules the CURRENT SSOT expands to -- the generated block really left the tracked file
shaped|none|and carries nothing merely SHAPED like a generated rule for an SSOT command either (wrong-interpreter and bare leftovers included)
lost|none|and still allow-lists every command the pre-deletion revision allow-listed by hand -- the hand-written set is DERIVED from the before-image (the entries naming no SSOT command), so an upstream grant ARRIVING is not mistaken for the deletion overrunning its block, and the row names WHICH permission vanished rather than reporting a total that drifted
T32_CASES
}

# T45 -- WHAT THE DELETION MUST NOT TOUCH. The delivery plan's post-edit checklist ends with
# "permissions' other keys, hooks, env, statusLine -- every top-level key is deep-equal to
# before the edit". T32 proves the generated block left; nothing proves the edit STOPPED there.
# A hand deletion that clipped the line above the block, took `permissions.deny` with it, or
# re-serialised the document with its keys reordered satisfies every count in this suite and
# is invisible in a 244-line diff -- and losing `deny` turns an editing slip into a permission
# grant. So the whole document except permissions.allow is compared against its own before.
T45_BEFORE="$TMPROOT/t45-before.json"
T45_BASELINE="unresolved"
T45_MARKER=""

# The rule strings are JSON-escaped in the file, so membership is asked of the PARSED array
# rather than of the text -- a grep for the marker's real quotes never matches its `\"` form.
t45_has_marker() { # <json-file> <rule> -> yes|no
    node -e '
      const fs = require("fs");
      let a = [];
      try { a = (JSON.parse(fs.readFileSync(process.argv[1], "utf8")).permissions || {}).allow || []; }
      catch (e) { a = []; }
      console.log(a.indexOf(process.argv[2]) !== -1 ? "yes" : "no");
    ' "$(node_path "$1")" "$2" 2>/dev/null || printf 'no'
}

# "Before" is the newest COMMITTED revision of settings.json that still carries the generated
# block, not a pinned sha and not a merge-base: the same definition holds while the edit is
# only in the working tree, after it is committed, and after the branch is rebased. The marker
# is rebuilt from the template contract rather than typed, so it tracks the spelling table.
t45_setup() {
    command -v git >/dev/null 2>&1 || { T45_BASELINE="<MISSING:git>"; return; }
    [ -f "$SETTINGS" ] || { T45_BASELINE="<MISSING:$SETTINGS_REL>"; return; }
    T45_MARKER="$(expected_path_rules "$(resolve_shebang "$AGENTS_DIR/$T31_EXPOSED_ENTRY")" \
        "$T31_EXPOSED_ENTRY" | sed -n '1p')"
    local sha
    while IFS= read -r sha; do
        [ -n "$sha" ] || continue
        git -C "$AGENTS_DIR" show "$sha:$SETTINGS_REL" > "$T45_BEFORE" 2>/dev/null || continue
        if [ "$(t45_has_marker "$T45_BEFORE" "$T45_MARKER")" = "yes" ]; then
            T45_BASELINE="$sha"
            return
        fi
    done < <(git -C "$AGENTS_DIR" log --format=%H -n 40 -- "$SETTINGS_REL" 2>/dev/null)
    T45_BASELINE="NO-PRE-DELETION-REVISION"
}

# While the tracked settings.json still holds the generated block, "before" and "after" are the
# same document and every comparison below would pass without the deletion having been made.
# That is the S8 artifact being absent, so the rows report a sentinel instead of a green.
t45_gate() { # -> "" when the comparison is meaningful, else the sentinel to report
    case "$T45_BASELINE" in
        "<MISSING:"*)          printf '%s' "$T45_BASELINE"; return ;;
        unresolved)            printf 'SETUP-DID-NOT-RUN'; return ;;
        NO-PRE-DELETION-REVISION) printf 'NO-PRE-DELETION-REVISION'; return ;;
    esac
    [ "$(t45_has_marker "$SETTINGS" "$T45_MARKER")" = "yes" ] &&
        printf '<MISSING:%s -- the S8 deletion>' "$SETTINGS_REL"
}

t45_compare() { # <delta|deep|keys|perm> -> token
    node -e '
      const fs = require("fs");
      const mode = process.argv[3];
      let b, a;
      try {
        b = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        a = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
      } catch (e) { console.log("UNPARSEABLE:" + e.message); b = null; }
      if (b !== null) {
        const noAllow = (o) => {
          const c = JSON.parse(JSON.stringify(o));
          if (c.permissions) delete c.permissions.allow;
          return c;
        };
        const nb = noAllow(b), na = noAllow(a);
        if (mode === "delta") {
          const bl = ((b.permissions || {}).allow || []).length;
          const al = ((a.permissions || {}).allow || []).length;
          console.log(String(bl - al));
        } else if (mode === "keys") {
          const kb = Object.keys(b), ka = Object.keys(a);
          if (kb.join(",") === ka.join(",")) console.log("same");
          else console.log("LOST[" + kb.filter((k) => ka.indexOf(k) === -1).join("|") +
            "] ADDED[" + ka.filter((k) => kb.indexOf(k) === -1).join("|") +
            "] ORDER[" + ka.join(",") + "]");
        } else if (mode === "perm") {
          const pb = JSON.stringify(nb.permissions || {}), pa = JSON.stringify(na.permissions || {});
          console.log(pb === pa ? "equal" : "CHANGED before=" + pb.slice(0, 240) + " after=" + pa.slice(0, 240));
        } else {
          if (JSON.stringify(nb) === JSON.stringify(na)) console.log("equal");
          else {
            const all = Object.keys(nb).concat(Object.keys(na));
            const bad = all.filter((k, i) => all.indexOf(k) === i &&
              JSON.stringify(nb[k]) !== JSON.stringify(na[k]));
            console.log("CHANGED[" + bad.join("|") + "]");
          }
        }
      }
    ' "$(node_path "$T45_BEFORE")" "$(node_path "$SETTINGS")" "$1" 2>/dev/null || printf 'NODE-ERROR'
}

t45_probe() { # <id> -> token | sentinel
    if [ "$1" = "found" ]; then
        case "$T45_BASELINE" in
            "<MISSING:"*|unresolved|NO-PRE-DELETION-REVISION) printf '%s' "$T45_BASELINE" ;;
            *) printf 'found' ;;
        esac
        return
    fi
    local g
    g="$(t45_gate)"
    [ -z "$g" ] || { printf '%s' "$g"; return; }
    t45_compare "$1"
}

t45_before_after_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T45[$id]: $label" "$want" "$(t45_probe "$id")"
    done <<'T45_CASES'
found|found|PRECONDITION: a committed revision of settings.json that still carries the generated block is reachable, so the rows below compare against a real before rather than against the file itself
delta|123|PRECONDITION: exactly 123 entries left permissions.allow between that revision and now -- fewer means a hand-written rule went with the block, more means the deletion overran it
deep|equal|the whole document except permissions.allow is byte-for-byte the same serialisation as before the edit: env, attribution, hooks, statusLine, model and the rest all survive it
keys|same|and the top-level key SET AND ORDER is unchanged, which a document rebuilt out of the fields the editor cared about would not be
perm|equal|permissions' own other keys survive too -- deny, ask, disableBypassPermissionsMode and additionalDirectories, where a silent loss of deny is a permission GRANT rather than a broken build
T45_CASES
}

t31_setup
t31_deploy_row
t31_path_rules_table
t31_bare_absence_table
t31_bare_presence_table
t45_setup
t32_expand
t32_dump_allow "$SETTINGS" "$T32_ALLOW"
t32_dump_before
t32_repo_original_table
t45_before_after_table
