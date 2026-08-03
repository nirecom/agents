#!/usr/bin/env bash
# Part of tests/fix-1780-round12-parser-unit-tables.sh (rules/coding/file-split.md).
# Sections A and S - the bash-scan sub-modules:
#   A  hooks/block-clearance-token-write/bash-scan/argv-scan.js
#   S  hooks/block-clearance-token-write/bash-scan/assignment-text.js
# Sourced by the parent, which owns run_table(), _expand() and the counters.

# ===========================================================================
# Section A — argv-scan.js. The read-only ALLOWLIST and the variable-reference
# recognizer, i.e. the two places where this scanner decides NOT to classify.
#
# Allowlist membership is granted to a command NAME, but read-only-ness is a
# property of the name AND its arguments — the codex round-5 HIGH. `less -o FILE`
# CREATES the named file, so it is the one member whose arguments are re-checked.
#
# PAIRING:
#   A-ro-cat / A-ro-exe / A-ro-case vs A-ro-catx  membership is a whole-word,
#            `.exe`-tolerant, case-folded match — `catx` is not `cat`
#   A-ro-tee / A-ro-touch          writers are NOT members
#   A-log-o / A-log-eq / A-log-bare / A-log-upper vs A-log-none / A-log-e
#            the `less` log-file options vs flags that only look like them
#   A-log-out                      `-out` matches `-o`+non-separator: over-match,
#            named and accepted — it can only ever REMOVE an allowlist exemption,
#            which is the fail-closed direction
#   A-inv-*                        the composed predicate: `less <file>` is a read,
#            `less -o <file>` is not, and `less -N <file>` still is
#   A-var-* / A-envvar-*           VAR_REF_RE is anchored on the WHOLE token, so
#            `$A` resolves and `"$A"` / `$A/x` / `$1` do not
# ===========================================================================
run_A_argv_scan() {
run_table A <<'TABLE'
A-ro-cat    | true  | rocmd | cat
A-ro-exe    | true  | rocmd | cat.exe
A-ro-case   | true  | rocmd | CAT
A-ro-rg     | true  | rocmd | rg
A-ro-less   | true  | rocmd | less
A-ro-catx   | false | rocmd | catx
A-ro-tee    | false | rocmd | tee
A-ro-touch  | false | rocmd | touch
A-ro-ln     | false | rocmd | ln
A-log-o     | true  | lesslog | -o
A-log-upper | true  | lesslog | -O
A-log-eq    | true  | lesslog | --log-file=x
A-log-bare  | true  | lesslog | --log-file
A-log-out   | true  | lesslog | -out
A-log-none  | false | lesslog | --log
A-log-e     | false | lesslog | -e
A-inv-cat   | true  | roinv | cat /wf/s1@MK@
A-inv-less  | true  | roinv | less /wf/s1@MK@
A-inv-lessN | true  | roinv | less -N /wf/s1@MK@
A-inv-logo  | false | roinv | less -o /wf/s1@MK@
A-inv-logeq | false | roinv | less --log-file=/wf/s1@MK@
A-inv-touch | false | roinv | touch /wf/s1@MK@
A-var-bare  | A | varref | $A
A-var-brace | A | varref | ${A}
A-var-env   | A | varref | $env:A
A-var-ENV   | A | varref | $ENV:A
A-var-quote | - | varref | "$A"
A-var-path  | - | varref | $A/x
A-var-pos   | - | varref | $1
A-var-plain | - | varref | A
TABLE
}

# ===========================================================================
# Section S — assignment-text.js. "Which earlier segment set the variable this
# one dereferences, and what text should the later segment be judged against?"
#
# Two readers with DELIBERATELY different widths, and the difference is what the
# pairing here pins:
#   precedingAssignmentChainText — CONTIGUOUS run only. Used as INTERPRETER gate
#     text, where folding in a distant `cd …` would arm the gate for an unrelated
#     invocation.
#   priorAssignmentsText         — every earlier assignment, nearest first. Used
#     for WRITE-TARGET resolution, where contiguity is simply wrong for shell
#     variable scope: in `S=<marker>; echo f; tee <wf>/s1$S` the parent shell has
#     already set S, and the write really does land on the marker (#1780 N-1).
#   S-chain-gap vs S-prior-gap is that pair, on the SAME input.
#
# PAIRING (the rest):
#   S-pwsh-env / S-pwsh-ENV vs S-pwsh-bash / S-pwsh-spaced / S-pwsh-empty
#       `$env:A=x` is pwsh's own assignment form and folds like the bash sibling;
#       the spaced form is NOT modelled and stays fail-closed (returns false)
#   S-only-yes vs S-only-cmd / S-only-export
#       "assignment-ONLY" means no real command follows — `export A=…` has one
#   S-prior-order  nearest-first, mirroring shell reassignment semantics
# ===========================================================================
run_S_assignment_text() {
run_table S <<'TABLE'
S-pwsh-env    | true  | pwshassign | $env:A=x
S-pwsh-ENV    | true  | pwshassign | $ENV:A=x
S-pwsh-bash   | false | pwshassign | A=x
S-pwsh-spaced | false | pwshassign | $env:A = x
S-pwsh-empty  | false | pwshassign | $env:A=
S-only-yes    | true  | assignonly | A=/wf/s1@MK@
S-only-cmd    | false | assignonly | A=/wf/s1@MK@ ln -s /tmp/x $A
S-only-export | false | assignonly | export A=/wf/s1@MK@
S-only-none   | false | assignonly | ln -s /tmp/x $A
S-chain-adj   | A=/wf/s1@MK@ | chain | A=/wf/s1@MK@; ln -s /tmp/x $A
S-chain-gap   | -            | chain | A=/wf/s1@MK@; echo hi; ln -s /tmp/x $A
S-prior-gap   | A=/wf/s1@MK@ | prior | A=/wf/s1@MK@; echo hi; ln -s /tmp/x $A
S-prior-none  | -            | prior | echo hi; ln -s /tmp/x $A
S-prior-order | B=1~A=/wf/s1@MK@ | chain | B=1; A=/wf/s1@MK@; ln -s /tmp/x $A
TABLE
}
