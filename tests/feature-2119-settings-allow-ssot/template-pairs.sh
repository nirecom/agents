# tests/feature-2119-settings-allow-ssot/template-pairs.sh
# Tests: install/lib/settings-allow-rules.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T26: the pair invariant, asserted on the template table itself. Sourced AFTER generator.sh.

RULES_LIB_REL="install/lib/settings-allow-rules.js"

# T26 -- THE INVARIANT, NOT THE OUTPUT. Every other part checks rules the deploy emitted for
# the commands a fixture happens to list; that catches a family whose pair is missing only if
# some fixture exercises it. This part asserts the property on the TABLE: exactly half the
# entries end in a trailing wildcard, each of those has exactly one argument-less partner
# adjacent to it, and no entry carries a wildcard glued to a non-space character. A family
# added later without its pair fails here on the day it is added, whatever the fixtures do.
t26_node() { # <mode> -> verdict token
    local lib
    lib="$(node_path "$AGENTS_DIR/$RULES_LIB_REL")"
    run_with_timeout 20 node -e '
      const q = String.fromCharCode(39);
      let M;
      try { M = require(process.argv[1]); }
      catch (e) { console.log("REQUIRE-FAILED:" + String(e.message).split("\n")[0]); process.exit(0); }
      const P = M.PATH_TEMPLATES, B = M.BARE_TEMPLATES, drop = M.dropArgWildcard;
      for (const [v, n] of [[P, "PATH_TEMPLATES"], [B, "BARE_TEMPLATES"], [drop, "dropArgWildcard"]]) {
        if (v === undefined || v === null) { console.log("NOT-EXPORTED:" + n); process.exit(0); }
      }
      const argv = (t) => t.endsWith(" *)") || t.endsWith(" *" + q + ")");
      const half = (a) => a.filter(argv).length;
      const complete = (a) => a.filter(argv).every((t) => a.filter((x) => x === drop(t)).length === 1);
      const adjacent = (a) => {
        if (a.length === 0 || a.length % 2 !== 0) return false;
        for (let i = 0; i < a.length; i += 2) {
          if (!argv(a[i])) return false;
          if (a[i + 1] !== drop(a[i])) return false;
        }
        return true;
      };
      const noTrailStar = (a) => a.filter((t) => !argv(t))
        .every((t) => !/\*\)$/.test(t) && !new RegExp("\\*" + q + "\\)$").test(t));
      const noGluedStar = (a) => a.every((t) => {
        for (let i = 0; i < t.length; i++) {
          if (t[i] !== "*") continue;
          const p = i === 0 ? "" : t[i - 1];
          if (p !== " " && p !== "(") return false;
        }
        return true;
      });
      // A `*` glued to a path separator is the leading-wildcard spelling: `*` in a permission
      // rule does not stop at a space, so `Bash(*/agents/bin/x)` also admits any command line
      // ENDING in `/agents/bin/x` -- `touch owned # /agents/bin/x` included. The deploy-time
      // absolute root replaces it, so no template may carry the shape at all.
      const noLeadStar = (a) => a.every((t) => !new RegExp("\\*[/\\\\]").test(t));
      const yn = (b) => (b ? "yes" : "no");
      const out = {
        "path-count": () => String(P.length),
        "bare-count": () => String(B.length),
        "path-half": () => String(half(P)),
        "bare-half": () => String(half(B)),
        "path-pairs-complete": () => yn(complete(P)),
        "path-pairs-adjacent": () => yn(adjacent(P)),
        "bare-pairs-complete": () => yn(complete(B)),
        "bare-pairs-adjacent": () => yn(adjacent(B)),
        "path-argless-exact": () => yn(noTrailStar(P)),
        "bare-argless-exact": () => yn(noTrailStar(B)),
        "path-no-glued-star": () => yn(noGluedStar(P)),
        "bare-no-glued-star": () => yn(noGluedStar(B)),
        "path-no-leading-wildcard": () => yn(noLeadStar(P)),
        "bare-no-leading-wildcard": () => yn(noLeadStar(B)),
        "drop-plain": () => drop("Bash(node bin/fx-tool *)"),
        "drop-quoted": () => drop("Bash(bash -c " + q + "node bin/fx-tool *" + q + ")"),
        // The four families #2201 adds. dropArgWildcard is claimed to pair them for free
        // because they end in ` *)`, one of its two existing suffix branches -- claimed, so
        // asserted: each TEMPLATE string is handed over verbatim and its twin pinned exactly.
        "drop-quoted-abs-interp-posix": () => drop("Bash(<I> \"<R>/<P>\" *)"),
        "drop-quoted-abs-interp-win": () => drop("Bash(<I> \"<R2W>\\<W>\" *)"),
        "drop-quoted-abs-plain-posix": () => drop("Bash(\"<R>/<P>\" *)"),
        "drop-quoted-abs-plain-win": () => drop("Bash(\"<R2W>\\<W>\" *)"),
        "drop-throws": () => {
          try { drop("Bash(node bin/fx-tool)"); return "NO-THROW"; }
          catch (e) {
            const n = (e && e.name) || (e && e.constructor && e.constructor.name) || "?";
            return n === "GenError" ? "GenError" : "OTHER:" + n;
          }
        }
      }[process.argv[2]];
      console.log(out ? out() : "UNKNOWN-MODE");
    ' -- "$lib" "$1" 2>&1
}

t26_probe() { # <mode> -> verdict | sentinel
    have_lib || { missing_lib; return; }
    t26_node "$1"
}

# THE MEMBERSHIP HALF. The `drop-quoted-abs-*` rows above hand dropArgWildcard four literals the
# TEST owns and pin what comes back -- which proves the pairing rule, and would keep proving it
# with the real table empty of all four. So each literal is also looked up in the shipped
# PATH_TEMPLATES_ARGV and its twin in PATH_TEMPLATES, counted rather than tested for presence:
# a family listed twice deploys a duplicate rule the pair-adjacency check above cannot see.
t26_member() { # <template-literal> -> "argv=<n>/path=<n>/twin=<n>" | verdict
    local lib
    lib="$(node_path "$AGENTS_DIR/$RULES_LIB_REL")"
    run_with_timeout 20 node -e '
      let M;
      try { M = require(process.argv[1]); }
      catch (e) { console.log("REQUIRE-FAILED:" + String(e.message).split("\n")[0]); process.exit(0); }
      const A = M.PATH_TEMPLATES_ARGV, P = M.PATH_TEMPLATES, drop = M.dropArgWildcard;
      for (const [v, n] of [[A, "PATH_TEMPLATES_ARGV"], [P, "PATH_TEMPLATES"], [drop, "dropArgWildcard"]]) {
        if (v === undefined || v === null) { console.log("NOT-EXPORTED:" + n); process.exit(0); }
      }
      const t = process.argv[2];
      let twin;
      try { twin = drop(t); }
      catch (e) { console.log("DROP-THREW:" + String(e.message).split("\n")[0]); process.exit(0); }
      const count = (a, s) => a.filter((x) => x === s).length;
      console.log("argv=" + count(A, t) + "/path=" + count(P, t) + "/twin=" + count(P, twin));
    ' -- "$lib" "$1" 2>&1
}

t26_member_probe() { # <template-literal> -> verdict | sentinel
    have_lib || { missing_lib; return; }
    t26_member "$1"
}

t26_member_table() {
    local id template want label
    while IFS='|' read -r id template want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T26[$id]: $label -- $template" "$want" "$(t26_member_probe "$template")"
    done <<'T26_MEMBER_CASES'
member-quoted-abs-interp-posix|Bash(<I> "<R>/<P>" *)|argv=1/path=1/twin=1|#2201: the interpreter + QUOTED absolute POSIX family is IN the shipped argument-bearing table exactly once, and both halves of its pair are in PATH_TEMPLATES exactly once
member-quoted-abs-interp-win|Bash(<I> "<R2W>\<W>" *)|argv=1/path=1/twin=1|#2201: the same for the Windows-separator spelling, whose backslashes are the half a hand-written table is likeliest to mis-escape into a near-miss string
member-quoted-abs-plain-posix|Bash("<R>/<P>" *)|argv=1/path=1/twin=1|#2201: the interpreter-free QUOTED POSIX family, once
member-quoted-abs-plain-win|Bash("<R2W>\<W>" *)|argv=1/path=1/twin=1|#2201: the interpreter-free QUOTED Windows family, once -- CPR-ORTH, all four asked rather than one sampled
member-control-present|Bash(<I> <P> *)|argv=1/path=1/twin=1|POSITIVE CONTROL: a family that predates #2201 answers the same way, so the four rows above are reading the real table and not a probe that says yes to everything
member-control-absent|Bash(<I> "<P>" *)|argv=0/path=0/twin=0|NEGATIVE CONTROL: a QUOTED REPO-RELATIVE spelling nobody ships is counted zero in both tables -- without it the probe could be matching on "looks quoted" rather than on the exact string
T26_MEMBER_CASES
}

t26_pair_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T26[$id]: $label" "$want" "$(t26_probe "$id")"
    done <<'T26_CASES'
path-count|24|the path template table carries 24 spellings, one argument-bearing and one argument-less per family -- 16 before #2201 added the four QUOTED absolute-path families the model actually issues when it quotes a Windows path
bare-count|6|the bare template table carries 6, the same three families in the same paired form
path-half|12|exactly half the path table ends in a trailing wildcard, so the split is even rather than "a few extras were added"
bare-half|3|and exactly half the bare table does
path-pairs-complete|yes|every argument-bearing path spelling has exactly one argument-less partner in the table (not zero, and not two)
path-pairs-adjacent|yes|each pair is ADJACENT, so a deployed-file diff reads as pairs and a missing partner is visible by eye
bare-pairs-complete|yes|every argument-bearing bare spelling has exactly one argument-less partner
bare-pairs-adjacent|yes|and the bare pairs are adjacent too
path-argless-exact|yes|no argument-less path spelling ends in a wildcard: it is an exact match, which is the whole point of the pair
bare-argless-exact|yes|no argument-less bare spelling ends in a wildcard either
path-no-glued-star|yes|every wildcard in the path table follows a space or an opening paren -- never glued to a name, which would silently allow sibling files
bare-no-glued-star|yes|the same holds for the bare table
path-no-leading-wildcard|yes|no path template carries a wildcard glued to a path separator: `*` does not stop at a space, so a `*/agents/<P>` spelling admits `touch owned # /agents/<P>` as well as the command it was written for -- the deploy-time absolute root is what replaces it
bare-no-leading-wildcard|yes|CONTROL: the bare table never carried that shape, so the row above cannot be passing on a property both tables share by accident
drop-plain|Bash(node bin/fx-tool)|dropArgWildcard turns a trailing ` *)` into `)` and changes nothing else
drop-quoted|Bash(bash -c 'node bin/fx-tool')|and turns a trailing ` *')` into `')`, so the bash -c families keep their quoting
drop-throws|GenError|a spelling with no trailing wildcard makes dropArgWildcard throw GenError -- adding an unpaired family to the argument-bearing table stops the build instead of shipping half a pair
drop-quoted-abs-interp-posix|Bash(<I> "<R>/<P>")|#2201 interpreter + QUOTED absolute POSIX path: the closing quote sits between the path and the wildcard, so the twin keeps its quote and loses only the ` *`
drop-quoted-abs-interp-win|Bash(<I> "<R2W>\<W>")|#2201 interpreter + QUOTED absolute Windows-separator path pairs identically -- the trailing backslash-separated tail is not mistaken for the quoted `bash -c` suffix branch
drop-quoted-abs-plain-posix|Bash("<R>/<P>")|#2201 QUOTED absolute POSIX path with no interpreter prefix: the leading `(` sits directly in front of the quote and the twin is still exact
drop-quoted-abs-plain-win|Bash("<R2W>\<W>")|#2201 QUOTED absolute Windows path with no interpreter prefix -- the fourth new family, so the pairing claim is pinned for every one of them rather than sampled
T26_CASES
}

t26_pair_table
t26_member_table
