# One resolver for the destination URL and a project's origin URL (hooks/lib/plan-sync.js):
# forge type, web host, project path, host equivalence and the blob URL built from them.
# Sourced by ../feature-2513-plan-sync-lib.sh inside its case block.
# Every row names the GitLab host settings it runs under:
#   none  = GITLAB_HOSTNAME and GITLAB_SSH_HOSTNAME empty
#   self  = GITLAB_HOSTNAME=gitlab.example.com
#   alias = self + GITLAB_SSH_HOSTNAME=ssh.gitlab.example.com
# A profile is supplied either as a process export or as $AGENTS_MAIN_ROOT/.env (the config file);
# both sources must give the same verdicts. A project .env.local is never a source.
# One node process evaluates all rows of a profile; each row is still one assertion.

HE_ENV_FILE="$AGENTS_MAIN_ROOT/.env"

# he_settings <profile> — prints the GITLAB_* lines of <profile>, one KEY=VAL per line.
he_settings() {
  case "$1" in
    none) printf 'GITLAB_HOSTNAME=\nGITLAB_SSH_HOSTNAME=\n' ;;
    self) printf 'GITLAB_HOSTNAME=gitlab.example.com\nGITLAB_SSH_HOSTNAME=\n' ;;
    alias) printf 'GITLAB_HOSTNAME=gitlab.example.com\nGITLAB_SSH_HOSTNAME=ssh.gitlab.example.com\n' ;;
  esac
}

# he_env <profile> <export|file> — applies <profile> in the current (sub)shell.
he_env() {
  rm -f "$HE_ENV_FILE"
  if [ "$2" = file ]; then
    unset GITLAB_HOSTNAME GITLAB_SSH_HOSTNAME
    he_settings "$1" > "$HE_ENV_FILE"
  else
    export GITLAB_HOSTNAME="" GITLAB_SSH_HOSTNAME=""
    while IFS='=' read -r k v; do [ -n "$k" ] && export "$k=$v"; done <<< "$(he_settings "$1")"
  fi
}

read -r -d '' HE_JS <<'JS'
const [mode, profile, table] = process.argv.slice(1);
const need = mode === "equal" ? ["sameRemoteHost"] : mode === "blob" ? ["resolveRemoteTarget", "blobUrlFor"] : ["resolveRemoteTarget"];
const miss = need.filter((n) => typeof ps[n] !== "function");
if (miss.length) { process.stdout.write("NOT_IMPLEMENTED: " + miss.join(",")); process.exit(0); }
const str = (v) => (typeof v === "string" && v ? v : "-");
for (const line of table.split("\n")) {
  const f = line.split("|");
  if (f.length < 5 || f[1] !== profile) continue;
  let got; let want;
  try {
    if (mode === "target") {
      const t = ps.resolveRemoteTarget(f[2]) || {};
      const w = f.slice(3, 6);
      const g = [str(t.type) === "-" ? "unknown" : t.type, str(t.host), str(t.project)];
      got = g.map((v, i) => (w[i] === "*" ? "*" : v)).join("|");
      want = w.join("|");
    } else if (mode === "equal") {
      got = String(ps.sameRemoteHost(f[2], f[3]));
      want = f[4];
    } else {
      const t = ps.resolveRemoteTarget(f[2]);
      let u = null;
      try { u = t ? ps.blobUrlFor(t, "main", f[3]) : null; } catch (_) { u = null; }
      got = str(u) === "-" ? "none" : u;
      want = f[4];
    }
  } catch (e) { got = "threw:" + (e && e.message); }
  console.log([f[0], got, want].join("^"));
}
JS

# he_run <target|equal|blob> <profile> <table> [export|file] — one assertion per row of
# <profile>, plus a row-count check so an empty or truncated node output cannot pass.
he_run() {
  local mode="$1" profile="$2" table="$3" src="${4:-export}" out n=0 name got want
  out="$(he_env "$profile" "$src"; psf_node "$HE_JS" "$mode" "$profile" "$table")"
  rm -f "$HE_ENV_FILE"
  case "$out" in
    NOT_IMPLEMENTED:*) fail "$mode ($profile, $src)" "not implemented ($out)"; return ;;
  esac
  while IFS='^' read -r name got want; do
    [ -z "$name" ] && continue
    n=$((n + 1))
    expect_eq "$mode [$src]: $name" "$got" "$want"
  done <<< "$out"
  expect_eq "$mode ($profile, $src): every table row was evaluated" "$n" \
    "$(printf '%s\n' "$table" | grep -c "^[^|]*|$profile|")"
}

echo "=== resolve: forge type | web host | project path ('-' = none, '*' = not pinned) ==="
read -r -d '' HE_TARGETS <<'TABLE'
github-scp|none|git@github.com:test-owner/test-repo.git|github|github.com|test-owner/test-repo
github-ssh-url|none|ssh://git@github.com/test-owner/test-repo.git|github|github.com|test-owner/test-repo
github-https|none|https://github.com/test-owner/test-repo.git|github|github.com|test-owner/test-repo
github-https-no-suffix|none|https://github.com/test-owner/test-repo|github|github.com|test-owner/test-repo
github-uppercase-host|none|git@GitHub.COM:test-owner/test-repo.git|github|github.com|test-owner/test-repo
github-https-port|none|https://github.com:443/test-owner/test-repo.git|github|github.com|test-owner/test-repo
github-ssh-alt-url|none|ssh://git@ssh.github.com:443/test-owner/test-repo.git|github|github.com|test-owner/test-repo
github-ssh-alt-scp|none|git@ssh.github.com:test-owner/test-repo.git|github|github.com|test-owner/test-repo
github-three-segments|none|https://github.com/a/b/c.git|unknown|*|*
github-one-segment|none|https://github.com/only-owner|unknown|*|*
github-lookalike-subdomain|none|git@sub.github.com:test-owner/test-repo.git|unknown|sub.github.com|*
github-lookalike-suffix|none|git@github.com.example.com:test-owner/test-repo.git|unknown|github.com.example.com|*
gitlab-com-scp|none|git@gitlab.com:test-group/test-project.git|gitlab|gitlab.com|test-group/test-project
gitlab-com-https|none|https://gitlab.com/test-group/test-project.git|gitlab|gitlab.com|test-group/test-project
gitlab-com-nested|none|https://gitlab.com/test-group/sub/deep/test-project.git|gitlab|gitlab.com|test-group/sub/deep/test-project
gitlab-com-one-segment|none|https://gitlab.com/only-group|unknown|*|*
gitlab-lookalike-suffix|none|git@gitlab.com.example.com:test-group/test-project.git|unknown|gitlab.com.example.com|*
self-hosted-not-declared|none|git@gitlab.example.com:test-group/test-project.git|unknown|gitlab.example.com|*
plain-host|none|ssh://git@plans.example.com/test-owner/test-repo.git|unknown|plans.example.com|*
plain-host-port|none|ssh://git@plans.example.com:2222/test-owner/test-repo.git|unknown|plans.example.com|*
plain-host-uppercase|none|ssh://git@Plans.Example.COM/test-owner/test-repo.git|unknown|plans.example.com|*
empty|none||unknown|-|-
local-path|none|/srv/plans/bare.git|unknown|-|-
relative-path|none|./rel/bare.git|unknown|-|-
self-hosted-scp|self|git@gitlab.example.com:test-group/test-project.git|gitlab|gitlab.example.com|test-group/test-project
self-hosted-ssh-port|self|ssh://git@gitlab.example.com:2222/test-group/test-project.git|gitlab|gitlab.example.com|test-group/test-project
self-hosted-https-nested|self|https://gitlab.example.com/test-group/sub/test-project.git|gitlab|gitlab.example.com|test-group/sub/test-project
self-hosted-https-8443|self|https://gitlab.example.com:8443/test-group/test-project.git|gitlab|gitlab.example.com|test-group/test-project
self-hosted-http|self|http://gitlab.example.com/test-group/test-project.git|gitlab|gitlab.example.com|test-group/test-project
self-hosted-uppercase|self|git@GitLab.Example.COM:test-group/test-project.git|gitlab|gitlab.example.com|test-group/test-project
self-hosted-lookalike|self|git@sub.gitlab.example.com:test-group/test-project.git|unknown|sub.gitlab.example.com|*
ssh-alias-not-declared|self|git@ssh.gitlab.example.com:test-group/test-project.git|unknown|ssh.gitlab.example.com|*
gitlab-com-next-to-self-hosted|self|git@gitlab.com:test-group/test-project.git|gitlab|gitlab.com|test-group/test-project
github-next-to-self-hosted|self|git@github.com:test-owner/test-repo.git|github|github.com|test-owner/test-repo
ssh-alias-scp|alias|git@ssh.gitlab.example.com:test-group/test-project.git|gitlab|gitlab.example.com|test-group/test-project
ssh-alias-url-port-nested|alias|ssh://git@ssh.gitlab.example.com:2222/test-group/sub/test-project.git|gitlab|gitlab.example.com|test-group/sub/test-project
web-host-next-to-alias|alias|https://gitlab.example.com/test-group/test-project.git|gitlab|gitlab.example.com|test-group/test-project
TABLE
he_run target none "$HE_TARGETS"
he_run target self "$HE_TARGETS"
he_run target alias "$HE_TARGETS"
# The same verdicts when the GitLab settings come from the config file instead of an export.
he_run target self "$HE_TARGETS" file
he_run target alias "$HE_TARGETS" file

echo "=== equivalence: are two remote URLs on the same web host (scheme and port included) ==="
read -r -d '' HE_EQUAL <<'TABLE'
github-scp-vs-https|none|git@github.com:test-owner/test-repo.git|https://github.com/other-owner/other-repo.git|true
github-vs-ssh-alt-url|none|git@github.com:test-owner/test-repo.git|ssh://git@ssh.github.com:443/other-owner/other-repo.git|true
github-vs-ssh-alt-scp|none|https://github.com/test-owner/test-repo|git@ssh.github.com:other-owner/other-repo.git|true
github-vs-uppercase|none|git@github.com:test-owner/test-repo.git|https://GITHUB.com/test-owner/test-repo.git|true
github-vs-port|none|git@github.com:test-owner/test-repo.git|https://github.com:443/test-owner/test-repo.git|true
github-vs-lookalike-subdomain|none|git@github.com:test-owner/test-repo.git|git@sub.github.com:test-owner/test-repo.git|false
github-vs-lookalike-suffix|none|git@github.com:test-owner/test-repo.git|git@github.com.example.com:test-owner/test-repo.git|false
github-vs-gitlab-com|none|git@github.com:test-owner/test-repo.git|git@gitlab.com:test-owner/test-repo.git|false
gitlab-com-other-project|none|git@gitlab.com:test-group/test-project.git|https://gitlab.com/other-group/sub/other-project.git|true
gitlab-com-vs-undeclared-self-hosted|none|git@gitlab.com:test-group/test-project.git|git@gitlab.example.com:test-group/test-project.git|false
plain-vs-plain-port|none|ssh://git@plans.example.com/test-owner/test-repo.git|ssh://git@plans.example.com:2222/a/b.git|true
plain-vs-plain-uppercase|none|ssh://git@plans.example.com/test-owner/test-repo.git|https://PLANS.example.com/a/b.git|true
plain-vs-other-plain|none|ssh://git@plans.example.com/test-owner/test-repo.git|ssh://git@other.example.com/test-owner/test-repo.git|false
plain-vs-its-subdomain|none|ssh://git@plans.example.com/test-owner/test-repo.git|ssh://git@sub.plans.example.com/test-owner/test-repo.git|false
empty-vs-empty|none|||false
github-vs-empty|none|git@github.com:test-owner/test-repo.git||false
empty-vs-github|none||git@github.com:test-owner/test-repo.git|false
local-path-vs-itself|none|/srv/plans/bare.git|/srv/plans/bare.git|false
garbage-vs-itself|none|not a url|not a url|false
self-hosted-scp-vs-https-port|self|git@gitlab.example.com:test-group/test-project.git|https://gitlab.example.com:8443/other-group/other-project.git|true
self-hosted-https-8443-vs-https|self|https://gitlab.example.com:8443/test-group/test-project.git|https://gitlab.example.com/test-group/test-project.git|false
self-hosted-http-vs-https|self|http://gitlab.example.com/test-group/test-project.git|https://gitlab.example.com/test-group/test-project.git|false
self-hosted-http-80-vs-http|self|http://gitlab.example.com:80/test-group/test-project.git|http://gitlab.example.com/other-group/other-project.git|true
self-hosted-https-443-vs-https|self|https://gitlab.example.com:443/test-group/test-project.git|https://gitlab.example.com/other-group/other-project.git|true
self-hosted-vs-gitlab-com|self|git@gitlab.example.com:test-group/test-project.git|git@gitlab.com:test-group/test-project.git|false
self-hosted-vs-github|self|git@gitlab.example.com:test-group/test-project.git|git@github.com:test-group/test-project.git|false
self-hosted-vs-undeclared-alias|self|https://gitlab.example.com/test-group/test-project.git|git@ssh.gitlab.example.com:test-group/test-project.git|false
alias-vs-web-host|alias|git@ssh.gitlab.example.com:test-group/test-project.git|https://gitlab.example.com/other-group/other-project.git|true
alias-vs-alias-port|alias|git@ssh.gitlab.example.com:test-group/test-project.git|ssh://git@ssh.gitlab.example.com:2222/a/b.git|true
alias-vs-gitlab-com|alias|git@ssh.gitlab.example.com:test-group/test-project.git|git@gitlab.com:test-group/test-project.git|false
TABLE
he_run equal none "$HE_EQUAL"
he_run equal self "$HE_EQUAL"
he_run equal alias "$HE_EQUAL"
he_run equal alias "$HE_EQUAL" file

echo "=== blob URL of a plan file at the destination ('none' = no URL can be shown) ==="
read -r -d '' HE_BLOB <<'TABLE'
github-scp|none|git@github.com:test-owner/test-repo.git|s1-intent.md|https://github.com/test-owner/test-repo/blob/main/s1-intent.md
github-https|none|https://github.com/test-owner/test-repo.git|s1-outline.md|https://github.com/test-owner/test-repo/blob/main/s1-outline.md
github-ssh-alt-url|none|ssh://git@ssh.github.com:443/test-owner/test-repo.git|s1-detail.md|https://github.com/test-owner/test-repo/blob/main/s1-detail.md
github-ssh-alt-scp|none|git@ssh.github.com:test-owner/test-repo.git|s1-intent.md|https://github.com/test-owner/test-repo/blob/main/s1-intent.md
github-file-name-encoded|none|git@github.com:test-owner/test-repo.git|s 1#x-intent.md|https://github.com/test-owner/test-repo/blob/main/s%201%23x-intent.md
github-subdir-encoded|none|git@github.com:test-owner/test-repo.git|d ir/a?b.md|https://github.com/test-owner/test-repo/blob/main/d%20ir/a%3Fb.md
github-three-segments|none|https://github.com/a/b/c.git|s1-intent.md|none
github-lookalike|none|git@github.com.example.com:test-owner/test-repo.git|s1-intent.md|none
gitlab-com-one-level|none|git@gitlab.com:test-group/test-project.git|s1-intent.md|https://gitlab.com/test-group/test-project/-/blob/main/s1-intent.md
gitlab-com-nested|none|https://gitlab.com/test-group/sub/deep/test-project.git|s1-outline.md|https://gitlab.com/test-group/sub/deep/test-project/-/blob/main/s1-outline.md
gitlab-com-file-name-encoded|none|git@gitlab.com:test-group/test-project.git|s 1#x-detail.md|https://gitlab.com/test-group/test-project/-/blob/main/s%201%23x-detail.md
gitlab-com-one-segment|none|https://gitlab.com/only-group|s1-intent.md|none
self-hosted-not-declared|none|git@gitlab.example.com:test-group/test-project.git|s1-intent.md|none
plain-host|none|ssh://git@plans.example.com/test-owner/test-repo.git|s1-intent.md|none
local-path|none|/srv/plans/bare.git|s1-intent.md|none
self-hosted-scp|self|git@gitlab.example.com:test-group/test-project.git|s1-intent.md|https://gitlab.example.com/test-group/test-project/-/blob/main/s1-intent.md
self-hosted-ssh-port-nested|self|ssh://git@gitlab.example.com:2222/test-group/sub/test-project.git|s1-detail.md|https://gitlab.example.com/test-group/sub/test-project/-/blob/main/s1-detail.md
self-hosted-http|self|http://gitlab.example.com/test-group/test-project.git|s1-intent.md|http://gitlab.example.com/test-group/test-project/-/blob/main/s1-intent.md
self-hosted-https-8443|self|https://gitlab.example.com:8443/test-group/test-project.git|s1-intent.md|https://gitlab.example.com:8443/test-group/test-project/-/blob/main/s1-intent.md
self-hosted-https-443|self|https://gitlab.example.com:443/test-group/test-project.git|s1-intent.md|https://gitlab.example.com/test-group/test-project/-/blob/main/s1-intent.md
ssh-alias-not-declared|self|git@ssh.gitlab.example.com:test-group/test-project.git|s1-intent.md|none
ssh-alias-scp|alias|git@ssh.gitlab.example.com:test-group/test-project.git|s1-intent.md|https://gitlab.example.com/test-group/test-project/-/blob/main/s1-intent.md
ssh-alias-url-nested|alias|ssh://git@ssh.gitlab.example.com:2222/test-group/sub/test-project.git|s1-outline.md|https://gitlab.example.com/test-group/sub/test-project/-/blob/main/s1-outline.md
TABLE
he_run blob none "$HE_BLOB"
he_run blob self "$HE_BLOB"
he_run blob alias "$HE_BLOB"
he_run blob self "$HE_BLOB" file

echo "=== a project .env.local never declares a GitLab host ==="
HE_PROJ="$PSF_ROOT/he-project"; mkdir -p "$HE_PROJ"
psf_project_env_local "$HE_PROJ" "GITLAB_HOSTNAME=gitlab.example.com" "GITLAB_SSH_HOSTNAME=ssh.gitlab.example.com"
OUT="$(he_env none file; export CLAUDE_PROJECT_DIR="$HE_PROJ"; cd "$HE_PROJ" || exit 1
  psf_node 'if (typeof ps.resolveRemoteTarget !== "function") { process.stdout.write("NOT_IMPLEMENTED: resolveRemoteTarget"); process.exit(0); }
const t = ps.resolveRemoteTarget(process.argv[1]) || {};
process.stdout.write(String(t.type || "unknown"));' "git@gitlab.example.com:test-group/test-project.git")"
rm -f "$HE_ENV_FILE"
expect_eq "project .env.local declaring GITLAB_HOSTNAME is ignored (host stays unknown)" "$OUT" "unknown"

echo "=== the GitHub-only parser is gone: one resolver serves every caller ==="
OUT="$(psf_node 'process.stdout.write(typeof ps.parseGitHubRemote + "|" + typeof ps.resolveRemoteTarget);')"
expect_eq "parseGitHubRemote not exported, resolveRemoteTarget exported" "$OUT" "undefined|function"
if HITS="$(grep -rn 'parseGitHubRemote' "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-sync.js" "$SCRIPT_CHECKOUT_ROOT/hooks/lib/plan-sync" 2>/dev/null)"; then
  fail "no parseGitHubRemote left in the plan-sync sources" "$HITS"
else
  pass "no parseGitHubRemote left in the plan-sync sources"
fi
