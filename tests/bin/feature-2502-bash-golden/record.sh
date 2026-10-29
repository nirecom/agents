# tests/bin/feature-2502-bash-golden/record.sh
# Tests: bin/lib/case-record-reader.sh
# Tags: TL2, case-markers, golden, scope:issue-specific
# Builds the golden's fixture checkout from sample-list.txt and records the six bash results
# as TSV, one file per kind (GB_KINDS). Sourced by tests/bin/feature-2502-bash-golden.sh,
# which compares them with expected/, and by regen.sh, which rewrites expected/. Needs
# SCRIPT_CHECKOUT_ROOT, TMPBASE, the shared harness and tests/bin/test-language-registry/_lib.sh.

# shellcheck source=../../lib/node-entry-sandbox.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/node-entry-sandbox.sh"
GB_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2502-bash-golden"
GB_KINDS="crr-read embed-ops enumerate-cases remove-orphan check-case-markers verify-static"
GB_INPUTS=()
GB_VERIFY=()
GB_BUILD_ERR=""

# _gb_place <checkout> <src-file> <relpath> <verify y|n> — one input at <relpath>.
_gb_place() {
  [ -d "$1/${3%/*}" ] || mkdir -p "$1/${3%/*}"
  cp "$2" "$1/$3"
  GB_INPUTS+=("$3")
  if [ "$4" = y ]; then GB_VERIFY+=("$3"); fi
}

# _gb_ec_fixtures <dir> — the audit suite's builders, run with the stubs their file expects.
_gb_ec_fixtures() {
  local d="$1"
  (
    AGENTS_ROOT="$SCRIPT_CHECKOUT_ROOT"
    GROUP_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-audit-tests-embed-cases"
    EC_TMP="$TMPBASE/gb-ec-tmp"
    mkdir -p "$EC_TMP/fakebin"
    grp_done() { :; }
    # shellcheck source=../bin-audit-tests-embed-cases/fixture-helpers.sh
    . "$GROUP_DIR/fixture-helpers.sh"
    ec_add_test "$d" plain.sh "bin/alpha.sh, bin/bravo.sh" 2
    ec_add_test "$d" single.sh "bin/alpha.sh" 1
    ec_write_embedded "$d/embedded.sh" "bin/alpha.sh, bin/bravo.sh" bin/alpha.sh bin/bravo.sh
    ec_write_embedded "$d/embedded-orphan.sh" "bin/alpha.sh, bin/zulu.sh" bin/alpha.sh bin/zulu.sh
  )
}

# gb_build <checkout> — a git checkout holding the code under test (bin/lib, the two
# entrypoints and their parts), the registry, the shared harness, the targets the fixtures
# name and every input of sample-list.txt. Any other bin/ target stays absent, so the repo
# samples' cases are orphans and a later change elsewhere in bin/ never moves the golden.
# Sets GB_INPUTS / GB_VERIFY; GB_BUILD_ERR names a missing input.
gb_build() {
  local co="$1" src name verify blob role n FXD WD T=$'\t' crr_d vce_d ec_d
  crr_d="$TMPBASE/gb-crr" vce_d="$TMPBASE/gb-vce" ec_d="$TMPBASE/gb-ec"
  mkdir -p "$co/tests/lib" "$co/tests/bin/crr" "$co/tests/bin/vce" "$co/tests/bin/ec" "$co/bin" "$crr_d" "$vce_d" "$ec_d"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin/lib" "$co/bin/lib"
  cp -R "$SCRIPT_CHECKOUT_ROOT/bin/verify-case-embed" "$co/bin/verify-case-embed"
  cp "$SCRIPT_CHECKOUT_ROOT/bin/verify-case-embed.sh" "$SCRIPT_CHECKOUT_ROOT/bin/check-case-markers.sh" "$co/bin/"
  # #2507: check-case-markers.sh execs a Node CLI; carry it with its require closure and the
  # registered Node reader parts it loads by path.
  node_entry_sandbox_copy "$co" bin/check-case-markers/cli.js \
    hooks/lib/test-gates/parts/{bash-case-reader,bash-case-embed,external-runtime}.js >/dev/null
  install_test_language_registry "$co" "$SCRIPT_CHECKOUT_ROOT"
  cp "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh" "$co/tests/lib/harness.sh"
  fx_root_decoy "$co"
  for n in a b c alpha bravo charlie delta echo; do printf '#!/usr/bin/env bash\necho %s\n' "$n" >"$co/bin/$n.sh"; done
  FXD="$crr_d"
  # shellcheck source=../bin-case-record-reader/fixtures.sh
  . "$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-case-record-reader/fixtures.sh"
  WD="$vce_d"
  # shellcheck source=../bin-verify-case-embed/fixtures.sh
  . "$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-verify-case-embed/fixtures.sh"
  _gb_ec_fixtures "$ec_d"
  while IFS='|' read -r src name verify blob role; do
    case "$src" in '' | '#'*) continue ;; esac
    case "$src" in
      crr | vce | ec)
        case "$src" in crr) n="$crr_d" ;; vce) n="$vce_d" ;; ec) n="$ec_d" ;; esac
        if [ -f "$n/$name.sh" ]; then
          _gb_place "$co" "$n/$name.sh" "tests/bin/$src/$name.sh" "$verify"
        else
          GB_BUILD_ERR="${GB_BUILD_ERR:+$GB_BUILD_ERR, }$src/$name"
        fi ;;
      repo)
        if git -C "$SCRIPT_CHECKOUT_ROOT" cat-file blob "$blob" >"$TMPBASE/gb-blob" 2>/dev/null; then
          _gb_place "$co" "$TMPBASE/gb-blob" "$name" "$verify"
        else
          GB_BUILD_ERR="${GB_BUILD_ERR:+$GB_BUILD_ERR, }$name@$blob ($role)"
        fi ;;
    esac
  done <"$GB_DIR/sample-list.txt"
  cp "$vce_d/before.sh" "$co/tests/bin/sample.sh"
  harness_git_init "$co"
  git -C "$co" config user.email t@example.com
  git -C "$co" config user.name t
  git -C "$co" add -A >/dev/null 2>&1
  git -C "$co" commit -q --no-verify -m fixture >/dev/null 2>&1
}

# _gb_markers_and_verify <checkout> <out-dir> — check-case-markers.sh once over every input
# (its stdout lines name each file, then one rc row), then verify-case-embed.sh per GB_VERIFY
# input (rows led by the input's relpath).
_gb_markers_and_verify() {
  local co="$1" out="$2" rel rc res bk
  rc=0
  res="$(cd "$co" && bash "$co/bin/check-case-markers.sh" "${GB_INPUTS[@]}" 2>/dev/null)" || rc=$?
  { [ -z "$res" ] || printf '%s\n' "$res"; printf 'rc=%s\n' "$rc"; } >"$out/check-case-markers.tsv"
  : >"$out/verify-static.tsv"
  for rel in "${GB_VERIFY[@]}"; do
    rc=0
    bk="$(mktemp -d "$TMPBASE/gb-bk.XXXXXX")"
    res="$(cd "$co" && bash "$co/bin/verify-case-embed.sh" "$co/$rel" --relpath tests/bin/sample.sh --backup-dir "$bk" 2>/dev/null)" || rc=$?
    {
      printf '%s\trc=%s\n' "$rel" "$rc"
      [ -z "$res" ] || printf '%s\n' "$res" | while IFS= read -r line; do printf '%s\t%s\n' "$rel" "$line"; done
    } >>"$out/verify-static.tsv"
  done
}

# gb_record_all <checkout> <out-dir> — writes <out-dir>/<kind>.tsv for every GB_KINDS kind.
# Rows start with the input's relpath in the checkout; no row holds a path outside it.
# The walk.sh pass (four kinds) runs on <checkout>; check-case-markers and verify-case-embed
# run at the same time on a copy, so the walk's staged removals never meet their git calls.
gb_record_all() {
  local co="$1" out="$2" co2="$1-ro" k
  mkdir -p "$out"
  cp -R "$co" "$co2"
  _gb_markers_and_verify "$co2" "$out" &
  run_with_timeout 170 bash "$GB_DIR/walk.sh" "$co" "$out" "${GB_INPUTS[@]}" 2>"$TMPBASE/gb-walk.err"
  wait
  for k in $GB_KINDS; do [ -f "$out/$k.tsv" ] || return 1; done
}
