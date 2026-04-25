# Private Information Scanning

Automated scanning to prevent private information from being committed to public repositories.

## How It Works

Checkpoints scan for private information:

| Checkpoint | When | Mechanism |
|:---|:---|:---|
| Git commit (files) | Every `git commit` | Pre-commit hook (`claude-global/hooks/pre-commit`) |
| Git commit (message) | Every `git commit` | Commit-msg hook (`claude-global/hooks/commit-msg`) |
| Claude Code edit | Every Edit/Write tool call | PreToolUse hook (`claude-global/hooks/scan-outbound.js`) |
| Claude Code commit | Every `git commit` via Bash tool | PreToolUse hook (`claude-global/hooks/scan-outbound.js`) |

All call `bin/scan-outbound.sh` as the scanner (single source of truth for patterns).

**Private repos are skipped**: detected dynamically via `gh api` (GitHub CLI). If the repo's `private` flag is `true`, scanning is skipped. If `gh` is unavailable or the API call fails, scanning proceeds (fail-open, safe default).

## Detection Patterns

| Type | Pattern | Examples |
|:---|:---|:---|
| RFC 1918 IPv4 | `10.x.x.x`, `172.16-31.x.x`, `192.168.x.x` | `192.168.1.1`, `10.0.0.1` |
| Email addresses | `user@domain.tld` | `user@example.com` |
| MAC addresses | `XX:XX:XX:XX:XX:XX` / `XX-XX-XX-XX-XX-XX` | `aa:bb:cc:dd:ee:ff` |
| Absolute local paths | `/Users/<name>`, `/home/<name>`, `C:\Users\<name>` | `/Users/john/docs` |
| Hard secrets | AWS/Anthropic/OpenAI/GitHub/Slack/Google/HuggingFace/Groq/Replicate/Cohere API keys, PEM private keys | `AKIA...`, `sk-ant-api03-...`, `ghp_...`, `-----BEGIN RSA PRIVATE KEY-----` |
| Hidden Unicode (Trojan Source) | Zero-width: U+200B, U+200C, U+200D, U+FEFF. Bidi overrides: U+202D, U+202E, U+2066–2069 | CVE-2021-42574 |
| Blocklist patterns | User-defined in `dotfiles-private/.private-info-blocklist` | Hostnames, domain names |

## Setup

Automatically enabled after running `install.sh` / `install.ps1`. The global git config (`.config/git/config`) sets `core.hooksPath` to `~/dotfiles/claude-global/hooks`, activating the pre-commit hook for all repos.

### Prerequisites

- `gh` CLI installed and authenticated (`gh auth login`)
- Private repo detection works automatically — no setup needed

## Allowlist (Exception Patterns)

Add exceptions to `.private-info-allowlist`, one pattern per line.
An optional private allowlist (`../dotfiles-private/.private-info-allowlist`) is also loaded
for environment-specific patterns. When `dotfiles-private/` is absent, only the local allowlist is used.

```
# Global pattern (applies to all files)
git@github.com
noreply.github.com

# Per-file pattern (format: filepath:pattern — filepath supports glob matching)
docs/networking.md:192.168
tests/*:@example.com
```

## Blocklist (Additional Detection Patterns)

The blocklist lives in the sibling private repo (`dotfiles-private/.private-info-blocklist`)
to avoid exposing blocked patterns in a public repo. One regex per line:

```
# Hostname patterns
myhost\.local
internal\.example\.com

# Block unwanted commit message content
Co-Authored-By
```

## Manual Scanning

Scan specific files:

```bash
bin/scan-outbound.sh path/to/file1 path/to/file2
```

Scan from stdin:

```bash
echo "some content" | bin/scan-outbound.sh --stdin
echo "some content" | bin/scan-outbound.sh --stdin filename-label
```

Scan all tracked files in a repo:

```bash
git ls-files | while read f; do [ -f "$f" ] && bin/scan-outbound.sh "$f"; done
```

## Troubleshooting

### Commit blocked by false positive

Add the pattern to `.private-info-allowlist` and re-commit.

### Pre-commit hook not running

Verify that `core.hooksPath` is set:

```bash
git config --get core.hooksPath
# Should show: ~/dotfiles/claude-global/hooks
```

### Claude Code hook not blocking

Ensure `settings.json` has the hooks section (check `~/.claude/settings.json`).

## Files

| File | Purpose |
|:---|:---|
| `bin/scan-outbound.sh` | Scanner script (detection patterns) |
| `claude-global/hooks/pre-commit` | Git pre-commit hook (staged files) |
| `claude-global/hooks/commit-msg` | Git commit-msg hook (commit message) |
| `claude-global/hooks/scan-outbound.js` | Claude Code PreToolUse hook |
| `claude-global/hooks/lib/is-private-repo.js` | Shared module: dynamic private repo detection via `gh api` |
| `.private-info-allowlist` | Exception patterns |
| `../dotfiles-private/.private-info-allowlist` | Environment-specific exception patterns (private repo) |
| `../dotfiles-private/.private-info-blocklist` | Additional detection patterns (private repo) |

## Related

For code-level security vulnerability scanning (injection, traversal, SQL, etc.), see `/review-code-security`.
