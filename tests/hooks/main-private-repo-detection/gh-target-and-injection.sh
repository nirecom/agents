# ===========================================================================
# Tests: hooks/lib/is-private-repo.js, hooks/lib/parse-remote-url.js
# Tags: scan, filter, outbound, hook, origin-resolution, parse-remote-url, security, injection, fail-open, TL2, scope:common
#
# #1899 rewired isPrivateRepo() onto the shared parser: host and repo id now come
# from ONE parseOriginOwnerRepo() call instead of two independent extractions.
# The sibling cases in unit-is-private-repo.sh assert only the BOOLEAN that comes
# back. A boolean cannot distinguish "gh was asked about the right repository"
# from "gh was asked about a different one and happened to answer the same way" —
# and asking about the wrong repository is exactly the #1899 defect. When the
# answer is wrong in the private direction the hook then scans (or fails to scan)
# outbound content against the wrong repo's visibility.
#
# So this group asserts the CALL, not the verdict: a mock `gh` records its full
# argv, and the recorded line is compared to `api repos/<parsed owner/repo>
# --jq .private` for the exact owner/repo the URL names. It also asserts the
# NEGATIVE half — the rejection paths (non-GitHub host, unparsable path, no
# remote) must reach gh ZERO times, because a call made after a failed parse is a
# call made about an unvalidated identity.
#
# The injection axis is the same claim seen from the other side. `parsed.ownerRepo`
# is interpolated into a shell command string (`gh api repos/${parsed.ownerRepo}`),
# so the charset guards in parse-remote-url.js (OWNER_RE / REPO_RE) are what
# stands between a hostile origin URL and command execution — anyone who can set
# a checkout's origin remote controls that text. Rows below feed origin URLs whose
# path carries `;`, `$(`, backticks and `|` and assert the call never happens.
#
# NOTE on the repoDir side of the same function: repoDir no longer reaches a
# shell at all. It used to be interpolated into an execSync command STRING —
# `git -C "<repoDir>" remote get-url origin` — where the double quotes stopped
# word splitting but NOT command substitution, so `$(...)` and backticks in a
# checkout path were expanded by the shell and ran attacker-chosen commands.
# isPrivateRepo() now uses spawnSync("git", ["-C", repoDir, ...]), which passes
# repoDir as an argv element: no shell, nothing to expand. The rows below pin
# both halves of that — the metacharacter paths (`&`, space) still RESOLVE, and
# the command-substitution payloads execute NOTHING — because "the path is inert"
# and "the path still works" are different claims and a broken quoting fix can
# satisfy either one alone.
#
# TL2: real git fixtures, real node, real parse-remote-url.js; only `gh` is
# mocked. TL3 gap: no real `gh api` round-trip proves the recorded owner/repo is
# the repository GitHub itself resolves, and no real fork with two remotes is
# exercised. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
# ===========================================================================

echo ""
echo "=== Unit: isPrivateRepo gh-call targeting and origin-URL injection ==="

GHA_LOG="$MOCK_BIN/gh-argv.log"
if command -v cygpath >/dev/null 2>&1; then
    GHA_LOG_WIN="$(cygpath -w "$GHA_LOG")"
else
    GHA_LOG_WIN="$GHA_LOG"
fi

# Records the FULL argv of every invocation, then answers <answer>.
setup_mock_gh_argv() {  # <answer: true|false>
    rm -f "$GHA_LOG"
    printf '@echo off\r\necho %%* 1>>"%s"\r\necho %s\r\n' "$GHA_LOG_WIN" "$1" > "$MOCK_BIN/gh.cmd"
    printf '#!/bin/bash\necho "$*" >> "%s"\necho "%s"\n' "$GHA_LOG" "$1" > "$MOCK_BIN/gh"
    chmod +x "$MOCK_BIN/gh"
}
gha_lines() { if [ -f "$GHA_LOG" ]; then awk 'END { print NR }' "$GHA_LOG"; else echo 0; fi; }
# Trailing whitespace is stripped: cmd.exe's `echo %*` appends a space that the
# POSIX `echo "$*"` form does not, and the argv under test is identical either
# way. Everything else — order, spacing between args, the arguments themselves —
# is compared verbatim.
gha_first() {
    if [ -f "$GHA_LOG" ]; then
        head -1 "$GHA_LOG" | tr -d '\r' | sed -e 's/[[:space:]]*$//'
    else
        printf ''
    fi
}

# --- the gh call names exactly the owner/repo the origin URL names -------------
# Each row: a URL FORM that must produce the SAME api target. Case is preserved
# (GitHub echoes the login's own case), the `.git` suffix and any userinfo are
# stripped, and the token in the last row must never reach the command line.
while IFS='|' read -r case_name origin_url want_target; do
    [ -z "${case_name// /}" ] && continue
    case "$case_name" in \#*) continue ;; esac
    case_name="$(echo "$case_name" | xargs)"
    origin_url="$(echo "$origin_url" | xargs)"
    want_target="$(echo "$want_target" | xargs)"

    setup_mock_gh_argv false
    REPO_T="$(setup_repo_with_origin "$origin_url")"
    result="$(run_is_private_repo "$REPO_T")"
    got_target="$(gha_first)"
    if [ "$got_target" = "$want_target" ]; then
        pass "gh target/$case_name"
    else
        fail "gh target/$case_name — want '$want_target' got '$got_target'"
    fi
    if [ "$result" = "false" ]; then
        pass "gh target/$case_name/answer-passed-through"
    else
        fail "gh target/$case_name/answer-passed-through — got: $result"
    fi
done <<'TABLE'
# case                | origin url                                                | expected gh argv
https-plain           | https://github.com/target-owner/target-repo.git           | api repos/target-owner/target-repo --jq .private
https-no-dotgit       | https://github.com/target-owner/target-repo               | api repos/target-owner/target-repo --jq .private
scp-form              | git@github.com:target-owner/target-repo.git               | api repos/target-owner/target-repo --jq .private
ssh-scheme            | ssh://git@github.com/target-owner/target-repo.git         | api repos/target-owner/target-repo --jq .private
case-preserved        | https://github.com/Target-Owner/Target-Repo.git           | api repos/Target-Owner/Target-Repo --jq .private
host-case-insensitive | https://GitHub.COM/target-owner/target-repo.git           | api repos/target-owner/target-repo --jq .private
# The userinfo is credential-shaped and FAKE (16 chars after `ghp_`, under the 36
# bin/scan-outbound.sh's token pattern needs). It must be stripped before the
# owner/repo is built, so it can never appear on a command line or in ps output.
# The single quotes around the fake token are LOAD-BEARING and must stay: the
# row is normalised through `xargs`, which removes them, so the URL this case
# actually feeds to git is byte-identical to the unquoted form — while the
# source line no longer contains a contiguous `<local>@<domain>` run for
# bin/scan-outbound.sh's email pattern to false-positive on. Do not "tidy" them
# away; scanning this file is what re-detects the regression.
token-userinfo-stripped | https://x-access-token:'ghp_EXAMPLEEXAMPLE'@github.com/target-owner/target-repo.git | api repos/target-owner/target-repo --jq .private
TABLE

# --- the private answer is passed through, not just the public one -------------
setup_mock_gh_argv true
REPO_T="$(setup_repo_with_origin "https://github.com/target-owner/target-repo.git")"
result="$(run_is_private_repo "$REPO_T")"
if [ "$result" = "true" ]; then pass "gh target/private-answer-passed-through"
else fail "gh target/private-answer-passed-through — got: $result"; fi
if [ "$(gha_lines)" = "1" ]; then pass "gh target/exactly-one-gh-call"
else fail "gh target/exactly-one-gh-call — got $(gha_lines) call(s)"; fi

# --- rejection paths must not reach gh at all ---------------------------------
# The mock answers "true" here so an unwanted call is doubly visible: it would
# show in the log AND flip any fail-open row's expected value.
while IFS='|' read -r case_name origin_url want_result; do
    [ -z "${case_name// /}" ] && continue
    case "$case_name" in \#*) continue ;; esac
    case_name="$(echo "$case_name" | xargs)"
    origin_url="$(echo "$origin_url" | xargs)"
    want_result="$(echo "$want_result" | xargs)"

    setup_mock_gh_argv true
    REPO_T="$(setup_repo_with_origin "$origin_url")"
    result="$(run_is_private_repo "$REPO_T")"
    if [ "$result" = "$want_result" ]; then
        pass "no-gh/$case_name/verdict"
    else
        fail "no-gh/$case_name/verdict — want $want_result got $result"
    fi
    if [ "$(gha_lines)" = "0" ]; then
        pass "no-gh/$case_name/zero-gh-calls"
    else
        fail "no-gh/$case_name/zero-gh-calls — gh was called: $(gha_first)"
    fi
done <<'TABLE'
# case                 | origin url                                          | expected isPrivateRepo
# Non-GitHub hosts are answered from the host classification alone — the API is
# never consulted, because the caller has no authority there.
non-github-host        | https://gitlab.example.com/team/project.git         | true
lookalike-suffix-host  | https://github.com.evil.example/owner/repo.git      | true
# github.com, but no owner/repo to ask about. Fail OPEN (false) and, critically,
# ask nothing: a salvaged fragment would name someone else's repository.
owner-only-path        | https://github.com/onlyowner                        | false
path-too-deep          | https://github.com/owner/team/repo                  | false
dot-segment-owner      | https://github.com/../repo                          | false
# Single quotes as in the token row above: load-bearing, removed by `xargs`, and
# only there so the at-sign run inside the URL path is not a contiguous email
# match for bin/scan-outbound.sh. The URL under test is unchanged.
at-in-path-rebase      | https://github.com/safe/'repo'@evil.example/attacker/pwn | false
TABLE

# --- origin-URL injection: hostile path bytes must never reach the shell -------
# parsed.ownerRepo is interpolated into `gh api repos/${parsed.ownerRepo}`, so
# the charset guards are the boundary. If a row below ever produced a gh call,
# the recorded argv would show the metacharacters — and on a shell that command
# would no longer be a single `gh api`.
while IFS='|' read -r case_name origin_url; do
    [ -z "${case_name// /}" ] && continue
    case "$case_name" in \#*) continue ;; esac
    case_name="$(echo "$case_name" | xargs)"
    origin_url="$(echo "$origin_url" | xargs)"

    setup_mock_gh_argv true
    rm -f "$TMPDIR_BASE/INJECTED-URL"
    REPO_T="$(setup_repo_with_origin "$origin_url")"
    result="$(run_is_private_repo "$REPO_T")"
    if [ "$(gha_lines)" = "0" ]; then
        pass "url-injection/$case_name/never-reaches-gh"
    else
        fail "url-injection/$case_name/never-reaches-gh — argv was: $(gha_first)"
    fi
    if [ "$result" = "false" ]; then
        pass "url-injection/$case_name/fails-open"
    else
        fail "url-injection/$case_name/fails-open — got: $result"
    fi
    if [ -f "$TMPDIR_BASE/INJECTED-URL" ]; then
        fail "url-injection/$case_name/no-side-effect — the payload executed"
    else
        pass "url-injection/$case_name/no-side-effect"
    fi
done <<'TABLE'
# case             | origin url
semicolon-in-repo  | https://github.com/owner/repo;touch
cmd-subst-in-repo  | https://github.com/owner/$(touch INJECTED-URL)
backtick-in-repo   | https://github.com/owner/`touch INJECTED-URL`
pipe-in-owner      | https://github.com/own|er/repo
ampersand-in-repo  | https://github.com/owner/repo&whoami
newline-ish-repo   | https://github.com/owner/repo$IFS
TABLE

# --- repoDir with shell-significant characters --------------------------------
# repoDir reaches git as an argv element, so `;`, `&`, `|` and spaces in a
# checkout path are inert AND the path still resolves. An interpolation that
# word-split the path would fail these rows, so they are a real pin and not
# decoration. The command-substitution half is asserted separately below.
inj_repo_dir() {  # <dir-basename> <origin-url> — prints the node-facing path
    # Assigned on separate lines: bash expands every word of a `local` command
    # before any of its names exist, so `d="$TMPDIR_BASE/$base"` on the same line
    # would read an unset `base` under `set -u`.
    local base="$1" url="$2"
    local d="$TMPDIR_BASE/$base"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$d" remote add origin "$url"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else printf '%s' "$d"; fi
}

#
# The character set is `&` and a space, not the full shell-metacharacter set:
# `|` is not a legal NTFS filename byte at all, and `;` is the PATH-list
# separator MSYS2's `cygpath -m` refuses to translate, so both produce a
# FIXTURE failure on Windows rather than a statement about is-private-repo.js.
# `&` and space carry the same claim — an unquoted `git -C $repoDir` splits on
# either — and are portable.
for meta_case in "amp&dir" "space dir"; do
    setup_mock_gh_argv false
    REPO_T="$(inj_repo_dir "meta-$RANDOM$RANDOM-$meta_case" "https://github.com/meta-owner/meta-repo.git")"
    result="$(run_is_private_repo "$REPO_T")"
    if [ "$(gha_first)" = "api repos/meta-owner/meta-repo --jq .private" ]; then
        pass "repodir-meta/$meta_case/resolves-through-quoting"
    else
        fail "repodir-meta/$meta_case/resolves-through-quoting — argv was '$(gha_first)'"
    fi
    if [ "$result" = "false" ]; then
        pass "repodir-meta/$meta_case/verdict"
    else
        fail "repodir-meta/$meta_case/verdict — got: $result"
    fi
done

# A metacharacter-laden path that is NOT a git checkout: the git read fails, so
# there is no identity, so gh must not be consulted at all.
setup_mock_gh_argv true
NOTREPO="$TMPDIR_BASE/notrepo-meta&dir"
mkdir -p "$NOTREPO"
if command -v cygpath >/dev/null 2>&1; then NOTREPO="$(cygpath -m "$NOTREPO")"; fi
result="$(run_is_private_repo "$NOTREPO")"
if [ "$result" = "false" ]; then pass "repodir-meta/non-repo/fails-open"
else fail "repodir-meta/non-repo/fails-open — got: $result"; fi
if [ "$(gha_lines)" = "0" ]; then pass "repodir-meta/non-repo/zero-gh-calls"
else fail "repodir-meta/non-repo/zero-gh-calls — argv was '$(gha_first)'"; fi

# --- repoDir command substitution: the payload must never execute -------------
# Why this is the sharp end of the same claim: the metacharacter rows above are
# satisfied by mere QUOTING, but `$(...)` and backticks are expanded by POSIX sh
# INSIDE double quotes. While isPrivateRepo() built a shell string —
# execSync(`git -C "${repoDir}" remote get-url origin`) — anyone who could steer
# repoDir ran commands as the user. repoDir is attacker-reachable in practice:
# resolveRepoDir() takes it from CLAUDE_PROJECT_DIR or from the `-C <path>`
# argument parsed out of a Bash-tool command string. spawnSync with an argv array
# removes the shell from the path entirely, so there is nothing left to expand.
#
# Verification is by SIDE EFFECT, the only signal that separates "never executed"
# from "executed and the output was discarded". Each payload touches a uniquely
# named marker at an ABSOLUTE path, so a shell anywhere in the chain leaves
# evidence no matter what its working directory was.
INJ_MARKER_DIR="$TMPDIR_BASE/repodir-inj-markers"
mkdir -p "$INJ_MARKER_DIR"

# Rows here are NOT normalised through `xargs` (unlike the URL tables above):
# xargs applies its own quote and backslash processing, which would rewrite the
# very bytes these cases exist to deliver. Plain whitespace trimming only.
inj_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

while IFS='|' read -r case_name marker payload_tpl; do
    [ -z "${case_name// /}" ] && continue
    case "$case_name" in \#*) continue ;; esac
    case_name="$(inj_trim "$case_name")"
    marker="$(inj_trim "$marker")"
    payload_tpl="$(inj_trim "$payload_tpl")"
    payload="${payload_tpl//@DIR@/$INJ_MARKER_DIR}"

    setup_mock_gh_argv true
    rm -f "$INJ_MARKER_DIR/$marker"
    # A path that does not exist: git must fail, so the documented fail-safe
    # (false) is the ONLY correct answer and no identity exists to ask gh about.
    result="$(run_is_private_repo "$TMPDIR_BASE/no-such-checkout/$payload" 2>/dev/null)"

    if [ -e "$INJ_MARKER_DIR/$marker" ]; then
        fail "repodir-injection/$case_name/no-side-effect — the payload executed"
    else
        pass "repodir-injection/$case_name/no-side-effect"
    fi
    if [ "$(gha_lines)" = "0" ]; then
        pass "repodir-injection/$case_name/never-reaches-gh"
    else
        fail "repodir-injection/$case_name/never-reaches-gh — argv was: $(gha_first)"
    fi
    # Documented contract: a failed git read fails open with `false`. An
    # exception escaping instead would print nothing here, so this also pins
    # "does not throw".
    if [ "$result" = "false" ]; then
        pass "repodir-injection/$case_name/fails-open-false"
    else
        fail "repodir-injection/$case_name/fails-open-false — got: '$result'"
    fi
done <<'TABLE'
# case             | marker file        | repoDir payload
cmd-subst          | MARKER-CMDSUBST    | $(touch @DIR@/MARKER-CMDSUBST)
backtick           | MARKER-BACKTICK    | `touch @DIR@/MARKER-BACKTICK`
cmd-subst-embedded | MARKER-EMBEDDED    | pre$(touch @DIR@/MARKER-EMBEDDED)post
cmd-subst-after-semicolon | MARKER-SEMI | dir;$(touch @DIR@/MARKER-SEMI)
backtick-nested-quotes    | MARKER-NESTQ | dir"`touch @DIR@/MARKER-NESTQ`"
TABLE

# The strong form: a payload-shaped directory that IS a real checkout. The rows
# above can be satisfied by a fix that merely BREAKS the path (sanitising or
# stripping the payload) — git fails either way, so "nothing happened" cannot
# tell the two apart. Here the payload IS the directory name, so an expansion
# rewrites the path and git finds nothing, while byte-for-byte delivery finds the
# repo and produces the gh call. The payload also touches a marker, giving the
# side-effect signal a second, independent channel.
#
# The marker name carries no directory part on purpose: a slash would make the
# fixture name a nested path rather than one directory, and the assertion would
# stop being about the payload.
setup_mock_gh_argv false
INJ_LIVE_BASE="live-$RANDOM$RANDOM-\$(touch MARKER-LIVE)"
REPO_T="$(inj_repo_dir "$INJ_LIVE_BASE" "https://github.com/live-owner/live-repo.git" 2>/dev/null || true)"
if [ -n "$REPO_T" ] && [ -d "$TMPDIR_BASE/$INJ_LIVE_BASE/.git" ]; then
    result="$(run_is_private_repo "$REPO_T" 2>/dev/null)"
    if [ "$(gha_first)" = "api repos/live-owner/live-repo --jq .private" ]; then
        pass "repodir-injection/live-checkout/path-delivered-verbatim"
    else
        fail "repodir-injection/live-checkout/path-delivered-verbatim — argv was '$(gha_first)'"
    fi
    # A shell expanding the payload would drop MARKER-LIVE in whatever directory
    # it happened to be standing in, so both the fixture tree and the test's own
    # working directory are searched.
    if [ -e "./MARKER-LIVE" ] || [ -n "$(find "$TMPDIR_BASE" -name MARKER-LIVE -print -quit 2>/dev/null)" ]; then
        fail "repodir-injection/live-checkout/no-side-effect — the payload executed"
    else
        pass "repodir-injection/live-checkout/no-side-effect"
    fi
    if [ "$result" = "false" ]; then
        pass "repodir-injection/live-checkout/verdict"
    else
        fail "repodir-injection/live-checkout/verdict — got: '$result'"
    fi
else
    # A filesystem that cannot hold the name is a FIXTURE limit, not a finding:
    # say so rather than passing silently. The rows above still carry the claim.
    pass "repodir-injection/live-checkout/skipped-filesystem-cannot-hold-name"
fi

# Anti-vacuous control for the marker technique itself: prove that a marker WOULD
# appear if a shell ever expanded one of these payloads. Without this, every
# "no-side-effect" pass above could rest on a typo in the marker path.
rm -f "$INJ_MARKER_DIR/MARKER-CONTROL"
eval "printf '%s' \"\$(touch '$INJ_MARKER_DIR/MARKER-CONTROL')\"" >/dev/null 2>&1 || true
if [ -e "$INJ_MARKER_DIR/MARKER-CONTROL" ]; then
    pass "repodir-injection/marker-technique-is-wired-up"
else
    fail "repodir-injection/marker-technique-is-wired-up — control payload left no marker"
fi

# --- anti-vacuous control -----------------------------------------------------
# Every "zero-gh-calls" assertion above rests on the recorder working. Prove it
# records when something genuinely invokes it.
setup_mock_gh_argv false
PATH="$MOCK_BIN:$PATH" gh api repos/probe/probe --jq .private >/dev/null 2>&1 || true
if [ "$(gha_lines)" = "1" ] && [ "$(gha_first)" = "api repos/probe/probe --jq .private" ]; then
    pass "gh target/argv-recorder-is-wired-up"
else
    fail "gh target/argv-recorder-is-wired-up — $(gha_lines) line(s), first '$(gha_first)'"
fi

# Leave the shared mock in a known state for any group sourced after this one.
rm -f "$GHA_LOG"
setup_mock_gh_public
