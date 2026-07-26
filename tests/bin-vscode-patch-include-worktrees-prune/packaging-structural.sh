# Part of tests/bin-vscode-patch-include-worktrees-prune.sh (sourced, not standalone).
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
  mode="$(git -C "$AGENTS_DIR" ls-files -s -- bin/vscode-patch-include-worktrees | awk '{print $1}')"
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

# ---- G2: the single-delete-site invariant ----------------------------------

# This is the structural half of the safety argument. Every behavioural test above
# proves that the ONE known deletion path refuses correctly; none of them can prove
# that a second, unguarded deletion path has not appeared elsewhere in the module —
# an `fs.unlinkSync` added inside the scanner for a "stale temp file" cleanup would
# leave this whole suite green.
#
# Both checks below are SOURCE GREPS, not behavioural assertions: they read the text
# of the shipped files. They can be defeated deliberately (an aliased fs handle, a
# computed member name) and they will need updating if the code is restructured. They
# are here because the property they describe — "there is exactly one place where a
# file is destroyed, and it is the place that carries the re-verification" — is worth
# an approximate guard, not because the grep itself is authoritative.
run_g_single_unlink_site() {
  local hits count file
  if [ ! -d "$LIB_DIR" ]; then
    echo "FAIL: G07: exactly one unlink site under $LIB_REL/ -- directory not found"
    FAIL=$((FAIL + 1))
    return 0
  fi
  hits="$(grep -rn --include='*.js' -E 'fs\.unlink|unlinkSync' "$LIB_DIR" 2>/dev/null || true)"
  count="$(printf '%s' "$hits" | grep -c . || true)"
  check "G07: exactly one unlink call site exists under $LIB_REL/ (source grep)" "1" "$count"
  if [ "$count" = "1" ]; then
    file="$(printf '%s' "$hits" | cut -d: -f1)"
    check "G08: that call site is prune.js (source grep)" "prune.js" "$(basename "$file")"
  else
    echo "FAIL: G08: the unlink call site is prune.js -- found $count site(s): $hits"
    FAIL=$((FAIL + 1))
  fi
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
            " UNLINK="+has(/unlink/)+" READ="+has(/readFileSync|readdirSync|opendirSync/));'
  check "G09: pruneRoots only composes the planner and the executor (source grep)" \
    "PLAN=y EXEC=y UNLINK=n READ=n" "$NODE_OUT"
}

run_g_entrypoint_packaging
run_g_lib_packaging
run_g_exports
run_g_readme
run_g_single_unlink_site
run_g_prune_roots_composition
