# Tests: bin/check-test-frontmatter.sh
# Tags: TL2, bin, merge, tests-gates, self-impl, scope:issue-specific
# Test-file bodies shared by the case files of both feat-2812-tests-gates-merge entrypoints
# (sourced after fixture.sh). ex-*: one detection per body (EX_PAIRS stages them as one set);
# c<N>-<side>: a bash test with N PASS=0 counter lines and an echo per side word.
# shellcheck shell=bash

raw ex-si "$(hdr bin/a.sh)" 'PASS=0' "$(mcase a bin/a.sh)"
raw ex-flat "$(hdr bin/a.sh)" "$(mcase a bin/a.sh)"
raw ex-nosrc '#!/usr/bin/env bash' '# Tests: bin/a.sh' '# Tags: scope:issue-specific' "$(mcase a bin/a.sh)"
raw ex-nomark "$(hdr 'bin/a.sh, bin/foo.sh')" 'echo one'
raw ex-mm "$(hdr bin/foo.js)" "$(mcase j bin/foo.js)"
EX_PAIRS="tests/bin/si.sh=ex-si tests/flat.sh=ex-flat tests/bin/nosrc.sh=ex-nosrc tests/bin/nomark.sh=ex-nomark tests/bin/mm.sh=ex-mm tests/bin/mode.sh=ex-si"

# sib <name> <counters> <echo-word>... — a bash test with <counters> PASS=0 lines and one echo per word.
sib() {
  local name="$1" n="$2" w
  local -a lines=("$(hdr bin/a.sh)")
  shift 2
  while [ "$n" -gt 0 ]; do lines+=('PASS=0'); n=$((n - 1)); done
  for w in "$@"; do lines+=("echo $w"); done
  lines+=("$(mcase a bin/a.sh)")
  raw "$name" "${lines[@]}"
}

sib c0-b 0 base
sib c1-b 1 base
sib c0-h 0 h
sib c1-h 1 h
sib c0-m 0 m
sib c1-m 1 m
sib c1-hm 1 h m
sib c2-hm 2 h m
sib c3-hm 3 h m
sib c2-h 2 h
