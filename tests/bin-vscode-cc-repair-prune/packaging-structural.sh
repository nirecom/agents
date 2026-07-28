# Part of tests/bin-vscode-cc-repair-prune.sh (sourced, not standalone).
# Tests: bin/vscode-cc-repair, bin/lib/vscode-cc-repair/prune.js, bin/lib/vscode-cc-repair/prune/execute.js, bin/lib/vscode-cc-repair/patch/apply.js
# Tags: bin, vscode, prune, packaging, structural, scope:common, pwsh-not-required, TL2
#
# G — packaging and structure. Nothing here is behavioural; these are the properties
# that no functional test can observe because every other part of this suite reaches
# the code through `node "$SCRIPT"` or `require(...)`, both of which work perfectly on
# a build that is unusable as a shipped CLI or that has quietly grown a second delete
# site.

# ---- G1: the delivery contract ---------------------------------------------

run_g_entrypoint_packaging() {
  local first mode
  first="$(head -1 "$SCRIPT")"
  first="${first%$'\r'}"
  check "G01: the entrypoint keeps the node shebang" "#!/usr/bin/env node" "$first"

  if ! git -C "$AGENTS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip_case "G02 git index mode (AGENTS_DIR is not a git repository)"
    return 0
  fi
  mode="$(git -C "$AGENTS_DIR" ls-files -s -- bin/vscode-cc-repair | awk '{print $1}')"
  if [ -z "$mode" ]; then
    skip_case "G02 git index mode (the entrypoint is not tracked)"
    return 0
  fi
  check "G02: the entrypoint keeps index mode 100755" "100755" "$mode"
}

# The extracted modules are libraries, not commands: a shebang or an execute bit on
# them advertises an entry point that does not exist. `git ls-files -s` reads the INDEX,
# so the assertion holds on Windows and regardless of core.fileMode.
run_g_lib_packaging() {
  local files f rel first mode n
  if [ ! -d "$LIB_DIR" ]; then
    echo "FAIL: G03: $LIB_REL/ exists -- directory not found"
    FAIL=$((FAIL + 1))
    return 0
  fi
  files="$(find "$LIB_DIR" -type f -name '*.js' 2>/dev/null | sort)"
  n="$(printf '%s' "$files" | grep -c . || true)"
  if [ "$n" = "0" ]; then
    echo "FAIL: G03: $LIB_REL/ contains at least one .js module -- none found"
    FAIL=$((FAIL + 1))
    return 0
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$AGENTS_DIR"/}"
    first="$(head -1 "$f")"
    first="${first%$'\r'}"
    case "$first" in
      '#!'*) echo "FAIL: G03: $rel carries a shebang -- [$first]"; FAIL=$((FAIL + 1)) ;;
      *)     echo "PASS: G03: $rel carries no shebang"; PASS=$((PASS + 1)) ;;
    esac
    if git -C "$AGENTS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      mode="$(git -C "$AGENTS_DIR" ls-files -s -- "$rel" | awk '{print $1}')"
      if [ -z "$mode" ]; then
        skip_case "G04 index mode for $rel (not tracked yet)"
      else
        check "G04: $rel is recorded as a non-executable library (100644)" "100644" "$mode"
      fi
    fi
  done <<< "$files"
}

# The entrypoint is being slimmed down, and the existing suite requires these six
# symbols. Re-exporting them is what makes the migration invisible to that suite —
# asserted here as well so the obligation is visible from the side that changed.
run_g_exports() {
  node_m 'const m=require("'"$REQUIRE_PATH"'");
const want=["classify","classifyValue","resolveRoots","listExtensionDirs",
            "classifySessionFile","verifyCounterpart","planPrune","planPruneRoots",
            "executePrunePlan","pruneRoots","resolvePruneRoots","listSessionFiles"];
const missing=want.filter(function(k){return typeof m[k]!=="function";});
const consts=["CANDIDATE_ROOTS","EXTENSION_DIR_PATTERN","SESSION_FILE_PATTERN",
              "DEFAULT_PROJECTS_ROOTS"].filter(function(k){return m[k]==null;});
console.log("MISSINGFN="+(missing.join(",")||"-")+" MISSINGCONST="+(consts.join(",")||"-"));'
  check "G05: the entrypoint exports the legacy six and the new prune surface" \
    "MISSINGFN=- MISSINGCONST=-" "$NODE_OUT"
}

run_g_readme() {
  local readme body
  readme="$AGENTS_DIR/README.md"
  check_file "G06a: README.md exists at the repo root" "$readme"
  if [ ! -f "$readme" ]; then
    echo "FAIL: G06b: README.md documents --prune-stub-sessions -- no README.md"
    FAIL=$((FAIL + 1))
    return 0
  fi
  body="$(cat "$readme")"
  check_contains "G06b: README.md documents the new flag" "--prune-stub-sessions" "$body"
}

# ---- G2: the single-displacement-site invariant -----------------------------

# This is the structural half of the safety argument. Every behavioural test above
# proves that the ONE known deletion path refuses correctly; none of them can prove
# that a second, unguarded deletion path has not appeared elsewhere in the module —
# an `fs.unlinkSync` added inside the scanner for a "stale temp file" cleanup would
# leave this whole suite green.
#
# The property is NOT "there is exactly one unlink". A session file is just as gone
# when it is renamed out from under the extension, truncated to zero, or overwritten
# in place, and the prune path is being changed to displace the stub with rename rather
# than destroy it with unlink — so a guard spelled `unlinkSync` would have gone green on
# a build with no protection at all. The invariant restated for the whole class:
#
#   there is exactly one place under bin/lib/vscode-cc-repair/ where a
#   session file is destroyed OR displaced, and it is the place that carries the
#   re-verification.
#
# Everything else that touches these primitives is enumerated below as an allowlist keyed
# on (file, primitive) — currently the patch path, which legitimately writes a temp file,
# renames it over the bundle, and removes the temp file on failure. A NEW destructive call
# anywhere, including a second one inside an already-allowlisted file's new primitive,
# fails EXTRA. An allowlist entry that no longer matches anything fails MISSING, so the
# list cannot rot into a blanket permission.
#
# Still a SOURCE GREP, not a behavioural assertion: it reads the text of the shipped
# files. It can be defeated deliberately (an aliased fs handle, a computed member name,
# a child process) and it will need updating whenever the code is restructured. Only
# full-line `//` comments are stripped, so a primitive named inside a trailing comment or
# a string literal still counts — a false positive here is cheap and a false negative is
# not. It is here because the property is worth an approximate guard, not because the
# grep itself is authoritative.
run_g_destructive_call_sites() {
  if [ ! -d "$LIB_DIR" ]; then
    echo "FAIL: G07: one displacement site under $LIB_REL/ -- directory not found"
    FAIL=$((FAIL + 1))
    return 0
  fi
  G_LIB="$(native_path "$LIB_DIR")" node_m 'const fs=require("fs"), path=require("path");
const root=process.env.G_LIB;
// (file, primitive) pairs that are NOT session-file displacement. Anything else is.
const ALLOW=["patch/apply.js:rmSync",
             "patch/apply.js:writeFileSync",
             "patch/apply.js:renameSync",
             "prune/execute.js:renameSync"];
const PRIMS=["unlink","unlinkSync","rm","rmSync","rename","renameSync",
             "truncate","truncateSync","writeFileSync","createWriteStream"];
const RE=new RegExp("(?:fs\\s*\\.\\s*("+PRIMS.join("|")+")|\\b(unlinkSync|rmSync|renameSync|truncateSync|writeFileSync|createWriteStream))\\s*\\(","g");
const files=[];
(function walk(d){ for (const e of fs.readdirSync(d,{withFileTypes:true})) {
  const f=path.join(d,e.name);
  if (e.isDirectory()) walk(f); else if (e.isFile() && /\.js$/.test(e.name)) files.push(f);
} })(root);
files.sort();
const seen=new Set(); const extra=[];
for (const f of files) {
  const rel=path.relative(root,f).replace(/\\/g,"/");
  const lines=fs.readFileSync(f,"utf8").split(/\r?\n/);
  lines.forEach(function(line,i){
    if (line.trim().slice(0,2)==="//") return;
    let mm; RE.lastIndex=0;
    while ((mm=RE.exec(line))!==null) {
      const key=rel+":"+(mm[1]||mm[2]);
      seen.add(key);
      if (ALLOW.indexOf(key)<0) extra.push(key+"@"+(i+1));
    }
  });
}
const missing=ALLOW.filter(function(k){return !seen.has(k);});
console.log("EXTRA="+(extra.join(",")||"-")+" MISSING="+(missing.join(",")||"-")+
            " FILES="+files.length);'
  # FILES is asserted only as non-zero via the surrounding walk; a build where the walk
  # found nothing would report EXTRA=- vacuously, so the count is printed and pinned by
  # G03 (which independently fails when the directory holds no .js module).
  check "G07: no destructive call site outside the allowlist (source grep)" \
    "EXTRA=-" "$(printf '%s' "$NODE_OUT" | sed -e 's/ MISSING=.*//')"
  check "G08: every allowlist entry still matches real code (source grep)" \
    "MISSING=-" "$(printf '%s' "$NODE_OUT" | sed -e 's/^EXTRA=[^ ]* //' -e 's/ FILES=.*//')"
}

# G11 — the executor half moved out of prune.js (it was 495 lines against a 500-line hard
# limit). The move is only safe if it is a MOVE: prune.js must keep neither a stale copy
# of the re-verification nor a second definition that a future edit could diverge from.
# `defined` here means a top-level `function <name>(` — a re-export line mentioning the
# same identifier is exactly what prune.js is supposed to keep.
run_g_executor_relocated() {
  local ex="$LIB_DIR/prune/execute.js"
  check_file "G11a: the executor lives in $LIB_REL/prune/execute.js" "$ex"
  if [ ! -f "$ex" ]; then return 0; fi
  G_PRUNE="$(native_file "$LIB_DIR/prune.js")" G_EXEC="$(native_file "$ex")" \
    node_m 'const fs=require("fs");
const def=function(src,name){return new RegExp("^function\\s+"+name+"\\s*\\(","m").test(src);};
const p=fs.readFileSync(process.env.G_PRUNE,"utf8");
const e=fs.readFileSync(process.env.G_EXEC,"utf8");
const names=["executePrunePlan","prunable","zeroTally","executeFailureState"];
const left=names.filter(function(n){return def(p,n);});
const right=names.filter(function(n){return !def(e,n);});
console.log("STILLINPRUNE="+(left.join(",")||"-")+" NOTINEXEC="+(right.join(",")||"-"));'
  check "G11b: the executor is defined once, in prune/execute.js (source grep)" \
    "STILLINPRUNE=- NOTINEXEC=-" "$NODE_OUT"
}

# G10 — the split must be invisible from outside. The module boundary moved, so the one
# thing that must NOT move is the public surface: every key prune.js and the entrypoint
# exported before the split is still exported, and the two agree with each other. Asserted
# as a set comparison rather than a spot check, because a re-export list is exactly the
# kind of thing that loses a line during a move and is never noticed until a caller in
# another repository breaks.
run_g_export_surface() {
  node_m 'const e=require("'"$REQUIRE_PATH"'");
const p=require("'"$PRUNE_REQUIRE"'");
// The surface as it stood before the executor was split out, plus the one addition the
// title-ownership fix makes (isOwnTitleRecord, which replaces a shape-only predicate).
const PRUNE_BASE=["DEFAULT_PROJECTS_ROOTS","SESSION_FILE_PATTERN","CLASSIFY_MAX_SCAN",
  "VERIFY_MAX_SCAN","resolvePruneRoots","listSessionFiles","classifySessionFile",
  "planPrune","planPruneRoots","executePrunePlan","pruneRoots","verifyCounterpart"];
const ENTRY_PRUNE=["classifySessionFile","verifyCounterpart","planPrune","planPruneRoots",
  "executePrunePlan","pruneRoots","resolvePruneRoots","listSessionFiles",
  "SESSION_FILE_PATTERN","DEFAULT_PROJECTS_ROOTS"];
const lost=PRUNE_BASE.filter(function(k){return p[k]==null;});
const elost=ENTRY_PRUNE.filter(function(k){return e[k]==null;});
const drift=ENTRY_PRUNE.filter(function(k){return p[k]!==e[k];});
console.log("LOST="+(lost.join(",")||"-")+" ELOST="+(elost.join(",")||"-")+
            " DRIFT="+(drift.join(",")||"-")+
            " OWN="+(typeof p.isOwnTitleRecord));'
  check "G10: the split loses no export and the entrypoint re-exports the same objects" \
    "LOST=- ELOST=- DRIFT=- OWN=function" "$NODE_OUT"
}

# pruneRoots must stay a pure composition of the read-only planner and the executor.
# The moment it grows logic of its own, the two-phase split stops being enforceable:
# any decision made inside pruneRoots is a decision that bypasses executePrunePlan's
# re-verification. Brace-matched extraction, again a source grep and not behavioural.
run_g_prune_roots_composition() {
  local f
  f="$LIB_DIR/prune.js"
  if [ ! -f "$f" ]; then
    echo "FAIL: G09: pruneRoots is a pure composition -- $LIB_REL/prune.js not found"
    FAIL=$((FAIL + 1))
    return 0
  fi
  G_FILE="$(native_file "$f")" node_m 'const fs=require("fs");
const src=fs.readFileSync(process.env.G_FILE,"utf8");
const i=src.search(/function\s+pruneRoots\s*\(/);
if(i<0){console.log("BODY=not-found");process.exit(0);}
let s=src.indexOf("{",i),d=0,e=-1;
for(let k=s;k<src.length;k++){
  if(src[k]==="{")d++;
  else if(src[k]==="}"){d--;if(d===0){e=k;break;}}
}
const body=e<0?"":src.slice(s+1,e);
const has=function(re){return re.test(body)?"y":"n";};
console.log("PLAN="+has(/planPruneRoots\s*\(/)+" EXEC="+has(/executePrunePlan\s*\(/)+
            " WRITE="+has(/unlink|rename|rmSync|truncate|writeFileSync/)+
            " READ="+has(/readFileSync|readdirSync|opendirSync/));'
  # WRITE covers the whole displacement class, not just unlink: after the backup change
  # the stub is displaced by rename, and a rename smuggled into pruneRoots would bypass
  # the re-verification exactly as an unlink would.
  check "G09: pruneRoots only composes the planner and the executor (source grep)" \
    "PLAN=y EXEC=y WRITE=n READ=n" "$NODE_OUT"
}

# G12 — the dead export. `CONTENT_RECORD_TYPES` was the SSOT for "which record types are
# transcript content" until `CONTENT_PAYLOAD` replaced it with a type→payload-field map;
# the Set is now derived from that Map, exported, and consumed by nothing. A second
# exported name for one fact is exactly the drift CPR-2 forbids: the next reader takes the
# Set as authoritative, adds a type to it, and the payload rule silently stops applying to
# that type — a content record with no payload would then authorise a deletion.
#
# Removal is asserted from BOTH sides, because either alone can pass on a broken build: the
# export list can lose the key while the constant stays (still two definitions of the fact),
# and the constant can be deleted while some other file still names it (a broken build).
run_g_dead_export() {
  node_m 'const v=require("'"$VERIFY_REQUIRE"'");
const dead=Object.prototype.hasOwnProperty.call(v,"CONTENT_RECORD_TYPES");
const payload=v.CONTENT_PAYLOAD;
console.log("DEAD="+dead+" PAYLOAD="+(payload instanceof Map)+
            " SIZE="+(payload instanceof Map?payload.size>0:false));'
  check "G12a: the superseded CONTENT_RECORD_TYPES export is gone; CONTENT_PAYLOAD is the SSOT" \
    "DEAD=false PAYLOAD=true SIZE=true" "$NODE_OUT"

  local hits
  hits="$( { grep -rlF 'CONTENT_RECORD_TYPES' "$LIB_DIR" 2>/dev/null || true; } | sed "s|^$AGENTS_DIR/||" | sort | tr '\n' ' ')"
  hits="${hits% }"
  check "G12b: no file under $LIB_REL/ still mentions the retired name" "" "$hits"
}

run_g_entrypoint_packaging
run_g_lib_packaging
run_g_dead_export
run_g_exports
run_g_readme
run_g_destructive_call_sites
run_g_executor_relocated
run_g_export_surface
run_g_prune_roots_composition
