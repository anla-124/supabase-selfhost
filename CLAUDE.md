# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Dokploy-compatible, self-hosted Supabase stack. All services are behind Kong (port 8000) as the single entry point — no other ports are exposed externally. Dokploy's Traefik handles TLS and routing to Kong.

## Architecture

```
Browser → Traefik (Dokploy) → Kong :8000 → internal services
                                  ├── /auth/v1/*      → GoTrue :9999
                                  ├── /rest/v1/*      → PostgREST :3000
                                  ├── /realtime/v1/*  → Realtime :4000 (WebSocket)
                                  ├── /storage/v1/*   → Storage :5000
                                  ├── /pg-meta/*      → Meta :8080
                                  └── studio.host     → Studio :3000 (hostname-based)
```

**Services:** PostgreSQL 17 · Kong · GoTrue · PostgREST · Realtime · Storage · imgproxy · postgres-meta · Studio

**Database superuser is `supabase_admin`**, not `postgres`. The official `supabase/postgres` image creates roles with hardcoded passwords, so `db-setup` runs after DB is healthy to reset all role passwords to `POSTGRES_PASSWORD`.

## Key Files

| File | What to know |
|------|--------------|
| `docker-compose.yml` | All 9 services. Uses `x-supabase-common` anchor for shared config. No `container_name` or `ports:` (Dokploy manages both). |
| `volumes/api/kong.yml` | Kong declarative routing. Uses `${VAR}` placeholder syntax — **not** real env vars. Kong DB-less mode can't expand them natively. |
| `volumes/api/kong-startup.sh` | `sed` script that substitutes `${VAR}` placeholders in kong.yml before Kong starts. If you add a new env var to kong.yml, you must add a matching sed line here. |
| `.env.example` | All required env vars with comments. `.env` is gitignored. |
| `volumes/db/init/01_pgvector.sql` | Optional pgvector + uuid-ossp extensions (safety net — already in the image). |

## Critical Gotchas

**SITE_URL vs SUPABASE_PUBLIC_URL** — `SITE_URL` must point to the **app** (e.g., `https://app.yourdomain.com`), not the Supabase URL. OAuth callbacks redirect to `SITE_URL/auth/callback`. Getting this wrong silently breaks login.

**Kong env var substitution** — When editing `kong.yml`, use `${VAR_NAME}` as a literal string placeholder. Then add the corresponding sed substitution in `kong-startup.sh`. The startup script converts these to real values before Kong loads the config.

**Open auth routes have no key-auth** — `/auth/v1/verify`, `/auth/v1/callback`, `/auth/v1/authorize` are public (no API key required). These are browser redirect flows where sending an API key header is impossible. Don't add key-auth back to these routes.

**db-setup is not optional** — Without it, auth/storage/rest services can't connect (wrong passwords) and storage fails with RLS errors (missing `BYPASSRLS` on `supabase_storage_admin`).

**Optional providers** — Google OAuth is off unless `GOTRUE_EXTERNAL_GOOGLE_ENABLED=true`; SMTP vars (`SMTP_*`) map to `GOTRUE_SMTP_*` and only matter when `GOTRUE_MAILER_AUTOCONFIRM=false` or for emails.

**WebSocket support** — Must be enabled on the `supabase.yourdomain.com` Dokploy domain settings for Realtime to work.

**STUDIO_HOSTNAME** — Must be set in `.env` and Dokploy Environment Variables, or the hostname-based Studio route in Kong won't resolve.

**STACK_NAME** — Required in `.env`. Kong gets the alias `<STACK_NAME>-kong` on `dokploy-network`; it must be unique per Supabase stack on the host. Internal upstreams in `kong.yml` use fixed `*-internal` aliases on the stack's private default network (no per-stack substitution needed).

**Cloudflare Access** — If the Supabase URL is behind Cloudflare Access, apps in the same Docker network should use `SUPABASE_INTERNAL_URL=http://<STACK_NAME>-kong:8000` for server-side calls, bypassing Cloudflare (which returns HTML challenge pages to non-browser requests). Use the `<STACK_NAME>-kong` alias (not bare `kong`) so the lookup resolves deterministically when multiple Supabase stacks share `dokploy-network`.

## Database Roles

| Role | Used by | Notes |
|------|---------|-------|
| `supabase_admin` | db-setup, meta, realtime | Superuser |
| `supabase_auth_admin` | GoTrue | Auth operations |
| `supabase_storage_admin` | Storage | Has BYPASSRLS (set by db-setup) |
| `authenticator` | PostgREST | Least privileged, switches to anon/authenticated |
| `service_role` | Admin API calls | Has BYPASSRLS by default, granted storage schema access by db-setup |

## Kong Consumer Roles

| Consumer | Auth method | ACL group | Access |
|----------|------------|-----------|--------|
| ANON | `apikey` header (ANON_KEY) | anon | Public API endpoints |
| SERVICE_ROLE | `apikey` header (SERVICE_ROLE_KEY) | admin | All API endpoints |
| DASHBOARD | HTTP Basic Auth (username/password) | admin | Studio + pg-meta only |

## When Editing

- **Adding a new Kong route:** Edit `kong.yml`, follow existing patterns. If it needs env vars, add sed substitution in `kong-startup.sh` and pass the var through `docker-compose.yml` Kong environment section.
- **Changing PostgreSQL version:** Update image tag in `docker-compose.yml`. Minor version bumps are safe. Major version changes (e.g., 17→18) require `pg_upgrade`.
- **Adding a new auth provider:** Add `GOTRUE_EXTERNAL_<PROVIDER>_*` env vars to the auth service in `docker-compose.yml` and to `.env.example`.
- **Storage "Failed to fetch buckets":** Check that `supabase_storage_admin` has `BYPASSRLS` (`SELECT rolbypassrls FROM pg_roles WHERE rolname='supabase_storage_admin'`). If correct, restart the storage container.
