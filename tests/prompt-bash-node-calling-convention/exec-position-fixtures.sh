# tests/prompt-bash-node-calling-convention/exec-position-fixtures.sh
# Tests: install/lib/settings-allow-rules.js, install/settings-allow-commands.txt
# Tags: prompt, permissions, calling-convention, ssot, scope:common, pwsh-not-required, TL2
# Fixture trees, sweep runner and JSON reducer for T50-T57. Sourced by the dispatcher, which
# owns PASS/FAIL/ROWS and assert_eq.

SWEEP_JS_REL="tests/prompt-bash-node-calling-convention/exec-position-sweep.js"
SWEEP_JS="$AGENTS_DIR/$SWEEP_JS_REL"
FX_ROOT=""
FX_MAIN=""
FX_ORPHAN=""
FX_DROP=""
FX_DOC=""
FX_JSON=""

have_sweep() { [ -f "$SWEEP_JS" ]; }
missing_sweep() { printf '<MISSING:%s>' "$SWEEP_JS_REL"; }

# EVERY FIXTURE IS TEST-OWNED. The deviant verdicts have to come from prompt text that really
# carries the defect, and the only text guaranteed to carry it is text this file writes: a
# mutation of a real repo asset would corrupt the tree the T50 zero-offender rows read.
fx_real_lib() { # <fixture-root> -- re-export, not a copy: the real module is root-parameterised
    local real
    real="$(node_path "$AGENTS_DIR/install/lib/settings-allow-rules.js")"
    printf '%s\n' "// Test-owned re-export of the REAL spelling library, asked about the fixture root." \
        "module.exports = require('$real');" > "$1/install/lib/settings-allow-rules.js"
}

# The ONE verdict the real generator cannot produce: it emits an interpreter-bearing rule for
# every entry it accepts, so `expected === null` needs a generator that skips one. This stub
# is that generator -- it emits real rules for every entry except the one named fx-orphan, so
# the sweep's fail-closed branch is exercised without the real module being made wrong.
fx_stub_lib() { # <fixture-root>
    printf '%s\n' \
        '"use strict";' \
        '// TEST-OWNED STUB. Emits one interpreter-bearing rule per SSOT entry, except fx-orphan.' \
        'const fs = require("fs");' \
        'const path = require("path");' \
        'const readEntries = (root) => fs.readFileSync(path.join(root, "install", "settings-allow-commands.txt"), "utf8")' \
        '    .split("\n").map((l) => l.replace(/\s+$/, "")).filter((l) => l.length > 0 && !/^\s*#/.test(l));' \
        'const interpreterOf = (root, entry) => {' \
        '    const first = fs.readFileSync(path.join(root, entry), "utf8").split("\n", 1)[0];' \
        '    return /node/.test(first) ? "node" : "bash";' \
        '};' \
        'const generatedAllowRules = ({ agentsRoot }) => {' \
        '    const rules = [];' \
        '    for (const e of readEntries(agentsRoot)) {' \
        '        if (e.indexOf("fx-orphan") !== -1) continue;' \
        '        rules.push("Bash(" + interpreterOf(agentsRoot, e) + " \"$AGENTS_CONFIG_DIR/" + e + "\")");' \
        '    }' \
        '    return { rules: rules, bareEmitted: false };' \
        '};' \
        'module.exports = { generatedAllowRules: generatedAllowRules };' \
        > "$1/install/lib/settings-allow-rules.js"
}

# fx-bash-tool-extra is a NODE tool whose entry is a superstring of the bash one: the sweep must
# match the whole entry, so a name-prefix heuristic would report it with the wrong interpreter.
fx_bin() { # <fixture-root>
    mkdir -p "$1/bin"
    printf '%s\n' '#!/usr/bin/env bash' 'echo fx-bash-tool' > "$1/bin/fx-bash-tool"
    printf '%s\n' '#!/usr/bin/env node' 'console.log("fx-bash-tool-extra");' > "$1/bin/fx-bash-tool-extra"
    printf '%s\n' '#!/usr/bin/env node' 'console.log("fx-node-tool");' > "$1/bin/fx-node-tool.js"
    printf '%s\n' '#!/usr/bin/env bash' 'echo fx-orphan' > "$1/bin/fx-orphan"
    chmod +x "$1/bin/fx-bash-tool" "$1/bin/fx-bash-tool-extra" "$1/bin/fx-node-tool.js" "$1/bin/fx-orphan"
}

fx_scaffold() { # <fixture-root> <real|stub>
    mkdir -p "$1/install/lib" "$1/rules" "$1/agents" "$1/skills/_shared" "$1/skills/fx-skill"
    fx_bin "$1"
    printf '%s\n' '# fixture: no PATH-exposed commands' > "$1/install/path-exposed-commands.txt"
    if [ "$2" = stub ]; then fx_stub_lib "$1"; else fx_real_lib "$1"; fi
}

fx_ssot() { # <fixture-root> <entry>...
    local d="$1"; shift
    printf '%s\n' '# fixture SSOT' "$@" > "$d/install/settings-allow-commands.txt"
}

# THE DEVIANT SET: one file per verdict, one occurrence per file, so a reported line is
# attributable to exactly one defect shape.
fx_deviant_assets() { # <fixture-root>
    printf '%s\n' '# fx deviant no-interpreter' '' \
        'Run `"$AGENTS_CONFIG_DIR/bin/fx-bash-tool"` and read what it prints.' \
        > "$1/rules/fx-deviant-no-interpreter.md"
    printf '%s\n' '# fx deviant unexpected-prefix' '' \
        'Run `sh "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"` and read what it prints.' \
        > "$1/rules/fx-deviant-unexpected-prefix.md"
    printf '%s\n' '# fx deviant wrong-interpreter' '' \
        'Run `node "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"` and read what it prints.' \
        > "$1/rules/fx-deviant-wrong-interpreter.md"
}

# THE EXCLUSION SET: quotation-equivalent forms only, plus ONE sentinel command line per file.
# The sentinel is what makes a zero-deviant result evidence rather than a file that was never
# opened -- a scan that skipped the file would lose the sentinel too.
fx_exclusion_assets() { # <fixture-root>
    printf '%s\n' '# fx exclusion prose' '' \
        'The tool lives at $AGENTS_CONFIG_DIR/bin/fx-bash-tool, where the installer puts it.' \
        'Even a sentence spelling bash $AGENTS_CONFIG_DIR/bin/fx-bash-tool is prose, not a command line.' \
        '' 'Sentinel: `bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' \
        > "$1/rules/fx-exclusion-prose.md"
    printf '%s\n' '# fx exclusion argument position' '' \
        'Read it with `cat "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' \
        'Stage it with `git add "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' \
        'Copy it with `cp "$AGENTS_CONFIG_DIR/bin/fx-bash-tool" /tmp/fx-copy`.' \
        '' 'Sentinel: `bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' \
        > "$1/rules/fx-exclusion-argument.md"
    printf '%s\n' '# fx exclusion allow-rule strings' '' \
        'The argument-less rule is `Bash(bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool")`.' \
        'Its argument-bearing twin is `Bash(node "$AGENTS_CONFIG_DIR/bin/fx-node-tool.js" *)`.' \
        'The interpreter-free spelling is `Bash("$AGENTS_CONFIG_DIR/bin/fx-bash-tool")`.' \
        '' 'Sentinel: `bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' \
        > "$1/rules/fx-exclusion-allow-rule.md"
}

# THE FOURTH EXCLUSION CLASS -- a documentary path CITATION (label, colon, a backtick span
# holding the bare entry path alone), real instance at skills/issue-setup/SKILL.md:38, plus its
# boundary companion, which keeps the $AGENTS_CONFIG_DIR/ prefix and so stays deviant. Its own
# tree: the pair's occurrences would move FX_MAIN's offender roster. Rationale: T52 rows in
# exec-position-sweep.sh.
fx_doc_assets() { # <fixture-root>
    printf '%s\n' '# fx documentary label mention' '' \
        'Backend script path: `bin/fx-bash-tool`.' \
        '' 'Sentinel: `bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' \
        > "$1/rules/fx-doc-label-mention.md"
    printf '%s\n' '# fx bare path as an instruction' '' \
        'Run: `$AGENTS_CONFIG_DIR/bin/fx-bash-tool`' \
        '' 'Sentinel: `bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' \
        > "$1/rules/fx-doc-run-instruction.md"
}

# One file per scan root the sweep claims to walk, so a root dropped from listPromptFiles turns
# a row red instead of quietly shrinking the corpus.
fx_ok_assets() { # <fixture-root>
    printf '%s\n' '# fx ok control' '' \
        'Run `bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"` as a single standalone command.' '' \
        'Run `node "$AGENTS_CONFIG_DIR/bin/fx-node-tool.js"` the same way.' \
        > "$1/rules/fx-ok-control.md"
    printf '%s\n' '# fx edge' '' \
        'Env prefix: `CLAUDE_SESSION_ID=abc bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' \
        'Chained: `cd /tmp && bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"`.' '' \
        '```bash' \
        'bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"' \
        'node "$AGENTS_CONFIG_DIR/bin/fx-node-tool.js"' \
        '```' \
        > "$1/agents/fx-edge.md"
    printf '%s\n' '# fx shared' '' \
        'Run `bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"` here too.' \
        > "$1/skills/_shared/fx-shared.md"
    printf '%s\n' '# fx skill' '' \
        'Run `node "$AGENTS_CONFIG_DIR/bin/fx-bash-tool-extra"` -- the longer entry, not its prefix.' \
        > "$1/skills/fx-skill/SKILL.md"
}

fx_manifest() { # <dir> -> per-file checksum manifest
    ( cd "$1" 2>/dev/null || { printf '<NO-DIR>'; exit 0; }
      find . -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
          printf '%s %s\n' "$f" "$(cksum < "$f" 2>/dev/null || printf 'UNREADABLE')"
      done )
}

fx_run() { # <tag> <fixture-root|NOARG>
    local rc=0
    if [ "$2" = NOARG ]; then
        run_with_timeout 60 node "$SWEEP_JS" > "$FX_JSON/$1.json" 2> "$FX_JSON/$1.err" || rc=$?
    else
        run_with_timeout 60 node "$SWEEP_JS" "$(node_path "$2")" \
            > "$FX_JSON/$1.json" 2> "$FX_JSON/$1.err" || rc=$?
    fi
    printf '%s' "$rc" > "$FX_JSON/$1.rc"
}

fx_rc() { cat "$FX_JSON/$1.rc" 2>/dev/null || printf 'NO-RC'; }

# FAIL-CLOSED means BOTH halves: a non-zero exit AND no JSON on stdout. A sweep that printed an
# empty occurrence list and then exited non-zero would still let a caller read "no offenders".
fx_failclosed() { # <tag> -> fail-closed | diagnosis
    have_sweep || { missing_sweep; return; }
    local rc; rc="$(fx_rc "$1")"
    [ "$rc" = "0" ] && { printf 'EXIT-ZERO'; return; }
    [ -s "$FX_JSON/$1.json" ] && { printf 'STDOUT-NOT-EMPTY'; return; }
    printf 'fail-closed'
}

fx_usage() { # -> "<rc>/usage" | "<rc>/NO-USAGE"
    have_sweep || { missing_sweep; return; }
    if grep -q 'usage:' "$FX_JSON/noargv.err" 2>/dev/null; then printf '%s/usage' "$(fx_rc noargv)"
    else printf '%s/NO-USAGE' "$(fx_rc noargv)"; fi
}

# The reducer: one node process, several modes, so every row below reads the SAME sweep output
# through the SAME parser instead of each growing its own grep.
fx_q() { # <tag> <mode> [arg] -> string
    have_sweep || { missing_sweep; return; }
    run_with_timeout 20 node -e '
      const fs = require("fs");
      const file = process.argv[1], mode = process.argv[2], arg = process.argv[3] || "";
      let d;
      try { d = JSON.parse(fs.readFileSync(file, "utf8")); }
      catch (e) { console.log("<UNPARSEABLE-JSON>"); process.exit(0); }
      const occ = Array.isArray(d.occurrences) ? d.occurrences : null;
      if (!occ) { console.log("<NO-OCCURRENCES-KEY>"); process.exit(0); }
      const uniq = (a) => [...new Set(a)].sort();
      const list = (s) => s.split(",").filter((x) => x.length > 0);
      const nonok = occ.filter((o) => o.status !== "ok");
      const at = (a) => { const p = a.split(":"); return occ.filter((o) => o.file === p[0] && String(o.line) === p[1]); };
      const one = (h, k) => (h.length === 1 ? h[0][k] : (h.length === 0 ? "NO-OCCURRENCE" : "MULTIPLE:" + h.length));
      const out = {
        "total": () => String(occ.length),
        "statuses": () => uniq(occ.map((o) => o.status)).join(",") || "<NONE>",
        "distinct-files": () => String(uniq(occ.map((o) => o.file)).length),
        "nonok": () => (nonok.length === 0 ? "none" : "offenders:" +
          nonok.map((o) => o.file + ":" + o.line + "[" + o.status + "]").sort().join(",")),
        "nonok-files": () => uniq(nonok.map((o) => o.file)).join(",") || "<NONE>",
        "file-summary": () => {
          const rows = occ.filter((o) => o.file === arg).map((o) => o.status + "@" + o.line).sort();
          return String(rows.length) + ":" + (rows.join(",") || "<NONE>");
        },
        "set-count": () => String(occ.filter((o) => list(arg).includes(o.file)).length),
        "set-statuses": () => uniq(occ.filter((o) => list(arg).includes(o.file)).map((o) => o.status)).join(",") || "<NONE>",
        "line-status": () => one(at(arg), "status"),
        "line-entry": () => one(at(arg), "entry"),
        "entry-count": () => String(occ.filter((o) => o.entry === arg).length),
        // Per-FILE reading, which entry-count cannot give: "<file>::<entry>,<entry>;<file>::..."
        // counts ok occurrences matching a pair, so one file losing its converted call shows.
        "pin-ok": () => {
          const specs = arg.split(";").filter((s) => s.length > 0).map((s) => {
            const p = s.split("::");
            return { file: p[0], entries: new Set(list(p[1] || "")) };
          });
          return String(occ.filter((o) => o.status === "ok" &&
            specs.some((s) => s.file === o.file && s.entries.has(o.entry))).length);
        },
        "nonok-among": () => {
          const s = uniq(nonok.filter((o) => list(arg).includes(o.file)).map((o) => o.file));
          return s.length === 0 ? "none" : "OVERLAP:" + s.join(",");
        },
        "nonok-covers": () => {
          const want = list(arg), have = new Set(nonok.map((o) => o.file));
          return want.filter((f) => have.has(f)).length + "/" + want.length;
        }
      }[mode];
      console.log(out ? out() : "UNKNOWN-MODE");
    ' -- "$FX_JSON/$1.json" "$2" "${3:-}" 2>&1
}

FX_MAIN_BEFORE=""
FX_MAIN_AFTER=""

fx_setup() {
    FX_ROOT="$TMPROOT/fx"
    FX_MAIN="$FX_ROOT/main"
    FX_ORPHAN="$FX_ROOT/orphan"
    FX_DROP="$FX_ROOT/drop"
    FX_DOC="$FX_ROOT/doc"
    FX_JSON="$FX_ROOT/json"
    mkdir -p "$FX_JSON"

    fx_scaffold "$FX_MAIN" real
    fx_ssot "$FX_MAIN" 'bin/fx-bash-tool' 'bin/fx-bash-tool-extra' 'bin/fx-node-tool.js'
    fx_deviant_assets "$FX_MAIN"
    fx_exclusion_assets "$FX_MAIN"
    fx_ok_assets "$FX_MAIN"

    fx_scaffold "$FX_ORPHAN" stub
    fx_ssot "$FX_ORPHAN" 'bin/fx-bash-tool' 'bin/fx-orphan'
    printf '%s\n' '# fx unresolvable' '' \
        'Run `bash "$AGENTS_CONFIG_DIR/bin/fx-orphan"` as a single standalone command.' \
        > "$FX_ORPHAN/rules/fx-unresolvable.md"
    printf '%s\n' '# fx orphan control' '' \
        'Run `bash "$AGENTS_CONFIG_DIR/bin/fx-bash-tool"` as a single standalone command.' \
        > "$FX_ORPHAN/rules/fx-orphan-control.md"

    fx_scaffold "$FX_DOC" real
    fx_ssot "$FX_DOC" 'bin/fx-bash-tool'
    fx_doc_assets "$FX_DOC"

    # SSOT-DRIVEN, not hardcoded: identical prompt text, one entry removed from the SSOT.
    cp -r "$FX_MAIN" "$FX_DROP"
    fx_ssot "$FX_DROP" 'bin/fx-node-tool.js'

    FX_MAIN_BEFORE="$(fx_manifest "$FX_MAIN")"
    fx_run main "$FX_MAIN"
    fx_run rerun "$FX_MAIN"
    FX_MAIN_AFTER="$(fx_manifest "$FX_MAIN")"
    fx_run orphan "$FX_ORPHAN"
    fx_run drop "$FX_DROP"
    fx_run doc "$FX_DOC"
    fx_run real "$AGENTS_DIR"
    fx_run noargv NOARG

    fx_failclosed_setup
}

# Four ways the sweep's inputs can be broken; each gets its own throwaway tree so one repair
# cannot mask another.
fx_failclosed_setup() {
    local d
    d="$FX_ROOT/no-ssot"; fx_scaffold "$d" real; rm -f "$d/install/settings-allow-commands.txt"
    fx_run no-ssot "$d"
    d="$FX_ROOT/traversal"; fx_scaffold "$d" real; fx_ssot "$d" 'bin/../../etc/passwd'
    fx_run traversal "$d"
    d="$FX_ROOT/metachar"; fx_scaffold "$d" real; fx_ssot "$d" 'bin/fx-bash-tool; rm -rf /'
    fx_run metachar "$d"
    d="$FX_ROOT/no-lib"; fx_scaffold "$d" real; fx_ssot "$d" 'bin/fx-bash-tool'
    rm -f "$d/install/lib/settings-allow-rules.js"
    fx_run no-lib "$d"
}

fx_setup
