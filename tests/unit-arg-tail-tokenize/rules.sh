# tests/unit-arg-tail-tokenize/rules.sh
# Tests: hooks/enforce-worktree/arg-tail-guard.js
# Tags: hook, worktree, enforce, arg-tail, unit, security, classifier, scope:common
#
# STATUS: RED until C3 lands — every row fails with
# `ERROR: require arg-tail-guard.js: Cannot find module ...`.
#
# Sourced by tests/unit-arg-tail-tokenize.sh. Sections 8-9: rejectsUnsafeToken
# rule-by-rule, the UNSAFE_PROFILES table, and rejectsUnsafeArgTail per profile.

run_tokenize_rule_cases() {

# ============================================================================
# 8. rejectsUnsafeToken, per token, against the same tokens pinned above.
#    Rules (first match wins): 1 fail-closed, 2 ansic, 3 unquoted SET-A,
#    4 unquoted/dq SET-B, 5 dq/sq SET-A allowed, 6 allow.
# ============================================================================
run_table <<'TABLE'
TKR-plain-word         %--title foo%rejtok        %1%false
TKR-dq-pipe            %--title "a|b"%rejtok      %1%false
TKR-sq-pipe            %--title 'a|b'%rejtok      %1%false
TKR-mixed-dq-pipe      %--title foo"|"bar%rejtok  %1%false
TKR-dq-semicolon       %--title "a;b"%rejtok      %1%false
TKR-dq-parens          %--title "a (b)"%rejtok    %1%false
TKR-unquoted-pipe      %--title a|b%rejtok        %1%true
TKR-unquoted-semicolon %--title a;b%rejtok        %1%true
TKR-unquoted-amp       %--title a&b%rejtok        %1%true
TKR-unquoted-paren     %--title (b)%rejtok        %1%true
TKR-unquoted-lt        %--title a<b%rejtok        %1%true
TKR-unquoted-gt        %--title a>b%rejtok        %1%true
TKR-dq-cmdsubst        %--title "$(id)"%rejtok    %1%true
TKR-dq-backtick        %--title "`id`"%rejtok     %1%true
TKR-dq-bare-dollar     %--title "$HOME"%rejtok    %1%true
TKR-dq-escaped-dollar  %--title "a\$b"%rejtok     %1%false
TKR-dq-escaped-backtick%--title "a\`b"%rejtok     %1%false
TKR-unquoted-cmdsubst  %--title $(id)%rejtok      %1%true
TKR-sq-dollar-safe     %--title '$HOME'%rejtok    %1%false
TKR-sq-backtick-safe   %--title '`id`'%rejtok     %1%false
TKR-ansic-plain        %--title $'ab'%rejtok      %1%true
TKR-ansic-with-pipe    %--title $'a|b'%rejtok     %1%true
TKR-flag-token-safe    %--title "a|b"%rejtok      %0%false
TABLE
# Rule 4's escape exclusion is documented for `dq` pieces only. An unquoted
# `\$` therefore still carries a raw `$` in its piece text and is rejected —
# fail-closed, and the pair above (TKR-dq-escaped-dollar) shows the dq side is
# genuinely different, so this is not a blanket rejection.
assert_probe "TKR-unquoted-escaped-dollar" '--title a\$b' rejtok 1 true
# Symmetric half of rule 4's escape exclusion (CPR-5): the exclusion covers
# BOTH `\$` and `\``, so the backtick pair must answer exactly like the dollar
# pair — allowed inside dq (TKR-dq-escaped-backtick above), still rejected
# unquoted. An implementation that special-cased only `\$` fails here.
assert_probe "TKR-unquoted-escaped-backtick" '--title a\`b' rejtok 1 true

# ============================================================================
# 8b. Rule 1 (fail closed) against HANDCRAFTED malformed Token objects.
#
# Every row above feeds rejectsUnsafeToken a token the tokenizer itself built,
# so they are all well-formed by construction: an implementation that skipped
# the coverage check entirely would pass all of them. Rule 1 says the predicate
# must reject whenever the piece list does not exactly and contiguously cover
# [start,end) with non-empty pieces whose text reconstructs `raw`. The shapes
# live in tests/fixtures/arg-tail-tokenize-probe.js (BAD_TOKENS).
#
# TKM-base is the non-vacuity guard: it is the one shape that must be ACCEPTED,
# so "reject everything" does not satisfy this table either.
# ============================================================================
# NOTE: the `input` column is deliberately NOT trimmed by run_table, so these
# shape names carry no padding.
run_table <<'TABLE'
TKM-base%base%rejshape%%false
TKM-coverage-hole%hole%rejshape%%true
TKM-overlap%overlap%rejshape%%true
TKM-pieces-out-of-order%outoforder%rejshape%%true
TKM-empty-piece%empty%rejshape%%true
TKM-short-coverage%short%rejshape%%true
TKM-overruns-token-end%overrun%rejshape%%true
TKM-starts-after-token%startsafter%rejshape%%true
TKM-piece-end-lt-start%reversedpiece%rejshape%%true
TKM-token-end-lt-start%reversedtoken%rejshape%%true
TKM-negative-offset%negative%rejshape%%true
TKM-piece-text-mismatch%textmismatch%rejshape%%true
TKM-raw-mismatch%rawmismatch%rejshape%%true
TKM-no-pieces%nopieces%rejshape%%true
TKM-pieces-missing%piecesmissing%rejshape%%true
TKM-pieces-not-array%piecesnotarray%rejshape%%true
TKM-piece-null%piecenull%rejshape%%true
TKM-unknown-piece-kind%badkind%rejshape%%true
TKM-fractional-bounds%floatbounds%rejshape%%true
TKM-nan-bounds%boundsnan%rejshape%%true
TKM-string-bounds%boundsstring%rejshape%%true
TKM-raw-missing%rawmissing%rejshape%%true
TKM-null-token%nulltoken%rejshape%%true
TKM-not-an-object%notanobject%rejshape%%true
TABLE

# ============================================================================
# 9. Profile table — the three documented profiles and the flag that keeps
#    standard.js:341 / :399-401 distinguishable from worker-script/overlay.
# ============================================================================
assert_probe "TKP-profile-names" "" profiles "" "overlay,sanctioned-bin,worker-script"
assert_probe "TKP-worker-allows-amp-redirect"   worker-script   profileflag allowRedirectAmpersand true
assert_probe "TKP-overlay-allows-amp-redirect"  overlay         profileflag allowRedirectAmpersand true
assert_probe "TKP-sanctioned-denies-amp-redir"  sanctioned-bin  profileflag allowRedirectAmpersand false

# rejectsUnsafeArgTail end-to-end, per profile. The `&>` row is the only one
# whose answer differs across profiles — that difference is Risk 10.
run_table <<'TABLE'
TKA-worker-plain       % --title foo%reject     %worker-script  %false
TKA-worker-dq-pipe     % --title "a|b"%reject   %worker-script  %false
TKA-worker-bare-pipe   % --title a|b%reject     %worker-script  %true
TKA-worker-amp-redir   % --title foo &> o%reject%worker-script  %false
TKA-overlay-amp-redir  % --title foo &> o%reject%overlay        %false
TKA-sanct-amp-redir    % --title foo &> o%reject%sanctioned-bin %true
TKA-sanct-plain-gt     % --title foo > o%reject %sanctioned-bin %true
TKA-worker-plain-gt    % --title foo > o%reject %worker-script  %false
TKA-sanct-dq-pipe      % --title "a|b"%reject   %sanctioned-bin %false
TKA-sanct-bare-pipe    % --title a|b%reject     %sanctioned-bin %true
TKA-worker-unclosed    % --title "a%reject      %worker-script  %true
TKA-sanct-unclosed     % --title "a%reject      %sanctioned-bin %true
TKA-overlay-unclosed   % --title "a%reject      %overlay        %true
TKA-worker-empty       %%reject                 %worker-script  %false
TKA-sanct-empty        %%reject                 %sanctioned-bin %false
TKA-overlay-empty      %%reject                 %overlay        %false
TABLE

# ============================================================================
# 9b. EXPANDING span kinds must ALL be rejected by rejectsUnsafeArgTail, on
#     every profile.
#
# Because: quote-spans documents five expanding kinds (ansic, cmdsubst,
# backtick, arith, subshell) — every one of them hands its body back to the
# shell to re-parse, so none of them is ever data, no matter which quote
# encloses it. rejectsUnsafeArgTail's span sweep names only three of the five;
# `arith` and `subshell` fall through it. Inside a double quote the positional
# SET-A sweep cannot catch them either, because the enclosing dq makes every
# character "quoted", so `"a$((cmd))"` reaches the callee intact.
#
# Rule 4 (unescaped `$` in a dq piece -> reject) is pinned here at the tail
# level as well: rejectsUnsafeToken already answers `true` for `"$HOME"`
# (TKR-dq-bare-dollar above), and the two predicates must not disagree about
# the same text — a call site that only runs the tail form is the weaker one.
#
# Pairing: each rejection row has an ALLOW row over the same characters made
# inert (`"a(b)"` — parens as dq data; `'a$HOME'` — `$` inside a single quote),
# so "reject every tail" fails this table just as "allow every tail" does.
# ============================================================================
run_table <<'TABLE'
TKA-worker-dq-arith    % --title "a$((1))"%reject %worker-script  %true
TKA-overlay-dq-arith   % --title "a$((1))"%reject %overlay        %true
TKA-sanct-dq-arith     % --title "a$((1))"%reject %sanctioned-bin %true
TKA-worker-dq-cmdsubst % --title "a$(id)"%reject  %worker-script  %true
TKA-overlay-dq-cmdsubst% --title "a$(id)"%reject  %overlay        %true
TKA-sanct-dq-cmdsubst  % --title "a$(id)"%reject  %sanctioned-bin %true
TKA-worker-dq-dollar   % --title "a$HOME"%reject  %worker-script  %true
TKA-overlay-dq-dollar  % --title "a$HOME"%reject  %overlay        %true
TKA-sanct-dq-dollar    % --title "a$HOME"%reject  %sanctioned-bin %true
TKA-worker-bare-arith  % --title $((1))%reject    %worker-script  %true
TKA-overlay-bare-arith % --title $((1))%reject    %overlay        %true
TKA-sanct-bare-arith   % --title $((1))%reject    %sanctioned-bin %true
TKA-worker-subshell    % --title (id)%reject      %worker-script  %true
TKA-overlay-subshell   % --title (id)%reject      %overlay        %true
TKA-sanct-subshell     % --title (id)%reject      %sanctioned-bin %true
TKA-worker-dq-parens   % --title "a(b)"%reject    %worker-script  %false
TKA-overlay-dq-parens  % --title "a(b)"%reject    %overlay        %false
TKA-sanct-dq-parens    % --title "a(b)"%reject    %sanctioned-bin %false
TKA-worker-sq-dollar   % --title 'a$HOME'%reject  %worker-script  %false
TKA-overlay-sq-dollar  % --title 'a$HOME'%reject  %overlay        %false
TKA-sanct-sq-dollar    % --title 'a$HOME'%reject  %sanctioned-bin %false
TABLE
}
