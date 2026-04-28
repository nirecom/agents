---
name: create-key
description: Generate a URL-safe password or opaque secret key for connection URLs and config files
---

Generate a cryptographically random key or password for use in configuration.

## Connection URL Passwords

When embedding a password in a connection URL (DATABASE_URL, REDIS_URL, AMQP URL, etc.),
the password component must be URL-safe. Standard base64 (`+/=`) breaks URL parsers
(real example: Prisma `invalid port number`).

**Allowed formats:**
- `hex` (recommended — no special characters)
  - Linux/macOS: `openssl rand -hex 32`
  - PowerShell: `-join ((1..32)|%{'{0:x2}' -f (Get-Random -Max 256)})`
- `base64url` (no padding): `openssl rand -base64 32 | tr '+/' '-_' | tr -d '='`
- Any string: **percent-encode** the password component before embedding in the URL

**Prohibited:** standard base64 (`+/=`) embedded unencoded in a URL password.

**Variable separation (preferred):** Provide both a composed URL and separate
`POSTGRES_PASSWORD` / `POSTGRES_USER` / `POSTGRES_HOST` variables — avoids URL escaping
issues entirely.

## Opaque Secrets

For secrets not embedded in a URL (NextAuth secret, salt, JWT secret, etc.):
`openssl rand -base64 32` or `openssl rand -hex 32` — either is fine.

## Handling and Storage

Once a secret appears in chat, it persists in conversation logs, screenshots, and terminal
scrollback. To minimize exposure:

1. **User-side generation preferred** — present the generation command; the user runs it.
2. **Secret manager preferred** (1Password CLI, Docker secrets, age-sops, doppler, etc.).
3. If Claude must present the value: development secrets only — never production.
4. Remind the user to store the value in a password manager; warn that worktree deletion
   can silently destroy dotenv files containing the only copy.
