---
globs: "**/docker-compose.yml,**/docker-compose.yaml,**/docker-compose.*.yml,**/docker-compose.*.yaml,**/compose.yml,**/compose.yaml,**/Dockerfile,**/Dockerfile.*,**/.env,**/.env.*"
---

# Docker Compose: Applying Changes

After implementing any change to a Docker-managed service, always tell the user the
exact command to apply it — never assume the container reloads automatically.

## Command selection

| What changed | Command |
|---|---|
| Source code, Dockerfile, or files copied at build time | `docker compose up -d --build <service>` |
| `docker-compose.yml` or volume-mounted config | `docker compose up -d <service>` |
| `.env` values referenced by `environment:` | `docker compose up -d --force-recreate <service>` |

**Never use `docker restart`** — it does not reload `.env`, config, or compose changes.

**`.env` changes need `--force-recreate`**: plain `docker compose up -d` compares the
compose config hash, not the resolved env values. If only `.env` changed, compose may
report "Running" without recreating the container, and the old environment persists.
Always use `--force-recreate` when only `.env` changed.

To determine which case applies, check the service's `volumes:` in `docker-compose.yml`:
files listed there are mounted at runtime (`up -d` only); everything else is baked into
the image at build time (`--build` required). When in doubt, use `--build`.
