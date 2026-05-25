# Self-Hosted Supabase for Dokploy

Dokploy-compatible, self-hosted Supabase stack. Drop-in replacement for managed Supabase.

**Stack:** PostgreSQL 17 · pgvector · GoTrue · PostgREST · Realtime · Storage · Kong · Studio

---

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | All Supabase services, Dokploy-compatible, Postgres 17 |
| `.env.example` | Environment template — copy to `.env` |
| `volumes/api/kong.yml` | Kong API gateway routing |
| `volumes/api/kong-startup.sh` | Substitutes env vars into kong.yml at container start |
| `volumes/db/init/01_pgvector.sql` | Optional extension reference — not mounted or executed by this Compose stack |
| `.gitignore` | Excludes `.env` and data directories |

---

## Deployment

### 1. Clone and configure

```bash
git clone <this-repo>
cd selfhosted-supabase
cp .env.example .env
```

Edit `.env` — every value marked `change-me` must be replaced.

### 2. Generate secrets

```bash
# PostgreSQL password and JWT secret
openssl rand -hex 32   # POSTGRES_PASSWORD
openssl rand -hex 32   # JWT_SECRET
openssl rand -hex 32   # SECRET_KEY_BASE
openssl rand -hex 8    # REALTIME_DB_ENC_KEY (16 chars; Realtime uses AES-128)
openssl rand -hex 32   # PG_META_CRYPTO_KEY
openssl rand -hex 32   # DASHBOARD_PASSWORD
```

### 3. Generate ANON_KEY and SERVICE_ROLE_KEY

Both are HS256 JWTs signed with your `JWT_SECRET`. Run this Node.js script:

```js
// generate-keys.js
const jwt = require('jsonwebtoken');

const secret = 'YOUR_JWT_SECRET_HERE';
const now = Math.floor(Date.now() / 1000);
const exp = 1893456000; // year 2030

const anonKey = jwt.sign(
  { role: 'anon', iss: 'supabase', iat: now, exp },
  secret,
  { algorithm: 'HS256' }
);

const serviceKey = jwt.sign(
  { role: 'service_role', iss: 'supabase', iat: now, exp },
  secret,
  { algorithm: 'HS256' }
);

console.log('ANON_KEY=' + anonKey);
console.log('SERVICE_ROLE_KEY=' + serviceKey);
```

```bash
npm install jsonwebtoken
node generate-keys.js
```

Copy the output into `.env`.

### 4. Set URLs correctly

> **Critical:** `SITE_URL` must be your app's URL, **not** the Supabase URL.
> OAuth redirects go to `SITE_URL/auth/callback`.

```env
SITE_URL=https://app.yourdomain.com
ADDITIONAL_REDIRECT_URLS=https://app.yourdomain.com/**
SUPABASE_PUBLIC_URL=https://supabase.yourdomain.com
API_EXTERNAL_URL=https://supabase.yourdomain.com
```

### 5. Deploy via Dokploy

1. In Dokploy: create a new **Compose** service and point it to this repo
2. Go to the **Environment** tab:
   - Paste all values from your `.env` into the **Environment Variables** field
   - Toggle **Create Environment File** ON — this writes the vars to `.env` on the server before the stack starts. Without this, services won't receive their configuration.
   - Make sure `STUDIO_HOSTNAME` is included (e.g. `STUDIO_HOSTNAME=studio.yourdomain.com`) — Kong uses this to route browser requests to Studio
3. Deploy — watch logs until all services are healthy
4. In Dokploy **Domains**, add two domains — both pointing to the **kong** service → port `8000`:
   - `supabase.yourdomain.com` — API gateway (what the app connects to)
   - `studio.yourdomain.com` — Studio dashboard (Kong routes by hostname, see [Studio Access](#studio-access))
5. Enable **WebSocket support** on the `supabase.yourdomain.com` domain (required for Realtime)

### 6. Run database setup

Open Studio (see [Studio Access](#studio-access)) → SQL Editor → run your app's database setup SQL (create tables, enable RLS, create policies, etc.).

The `db-setup` service also runs automatically on every deploy: it ensures `supabase_storage_admin` has `BYPASSRLS`, resets internal role passwords to `POSTGRES_PASSWORD`, and grants `service_role` access on the `storage` schema.

If Studio later shows `Failed to fetch buckets` while `SELECT * FROM storage.buckets;` works in SQL, restart the `storage` service so it reconnects with fresh role attributes.

### 7. Verify

```bash
# Auth health
curl https://supabase.yourdomain.com/auth/v1/health
# → {"version":"...","name":"GoTrue",...}

# PostgREST OpenAPI
curl -H "apikey: <ANON_KEY>" https://supabase.yourdomain.com/rest/v1/

# pgvector extension (run in Studio SQL editor, only if using vector search)
SELECT extname FROM pg_extension WHERE extname IN ('vector', 'uuid-ossp');
# → 2 rows
```

### 8. Configure your app

Point your app at the self-hosted instance:

```env
NEXT_PUBLIC_SUPABASE_URL=https://supabase.yourdomain.com
NEXT_PUBLIC_SUPABASE_ANON_KEY=<ANON_KEY>
SUPABASE_SERVICE_ROLE_KEY=<SERVICE_ROLE_KEY>
```

**If your app server runs in the same Docker network as Kong** (e.g. also deployed on Dokploy) and the Supabase URL is behind Cloudflare Access, add:

```env
SUPABASE_INTERNAL_URL=http://pdfsearch-kong:8000
```

This routes server-side Supabase calls directly through the internal Docker network, bypassing Cloudflare (which would intercept the request and return an HTML page instead of JSON). Browser/client-side code still uses `NEXT_PUBLIC_SUPABASE_URL` as normal.

**Note the `pdfsearch-kong` alias** instead of the bare `kong` short name: when multiple Supabase stacks run on the same Dokploy host they all share `dokploy-network` and the short alias `kong` becomes ambiguous (round-robin DNS). The stack-specific alias prevents that.

---

## Backup and Restore

The stack stores all persistent state in two named Docker volumes:

| Volume | Contents |
|--------|----------|
| `db_data_v4` | All Postgres data (tables, auth users, realtime state) |
| `storage_data` | Uploaded files (shared between `storage` and `imgproxy`) |

Dokploy project renames, volume deletion, or host migration will lose this data unless you have external backups. Schedule the commands below via Dokploy cron, server cron, or an external backup service.

### Backup

```bash
# Postgres — logical dump (run from the host, replace <container> with the db container name)
docker exec <db-container> pg_dumpall -U supabase_admin > backup-$(date +%Y%m%d).sql

# Storage files — copy the volume contents
docker run --rm \
  -v selfhosted-supabase_storage_data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/storage-$(date +%Y%m%d).tar.gz -C /data .
```

> The volume name prefix (`selfhosted-supabase_`) is set by Docker Compose from the project directory name. Adjust if your Dokploy project name differs.

### Restore

```bash
# Postgres — restore from dump into a fresh/empty db container (disaster recovery only,
# do not replay over an already-initialized running database)
docker exec -i <db-container> psql -v ON_ERROR_STOP=1 -U supabase_admin -d postgres < backup-YYYYMMDD.sql

# Storage files — extract back into the volume
docker run --rm \
  -v selfhosted-supabase_storage_data:/data \
  -v $(pwd):/backup \
  alpine tar xzf /backup/storage-YYYYMMDD.tar.gz -C /data
```

After restoring Postgres, restart all services so connections are re-established with fresh state.

---

## Studio Access

Studio provides full admin access to the database. Kong routes requests to `studio.yourdomain.com` directly to the Studio container using hostname-based routing with HTTP Basic Auth.

### Access

1. Open `https://studio.yourdomain.com` in your browser
2. Enter credentials when prompted:
   - **Username:** value of `DASHBOARD_USERNAME` in your `.env` (default: `supabase`)
   - **Password:** value of `DASHBOARD_PASSWORD` in your `.env`

Kong handles authentication — Studio itself has no login screen.

### Domain setup

The `studio.yourdomain.com` domain must point to the **kong** service on port `8000` in Dokploy (not to the studio service directly). Kong's hostname-based route in `kong.yml` matches the `studio.yourdomain.com` host and proxies it to the internal `studio:3000` container.

### SSH tunnel (alternative)

If you prefer not to expose Studio publicly:

```bash
ssh -L 3000:localhost:3000 user@your-server
# Then open: http://localhost:3000
```

This requires the studio container to be reachable on port 3000 from the Docker host.

---

## WebSocket Configuration for Realtime

Supabase Realtime uses WebSocket connections at `/realtime/v1/websocket`. Traefik must pass WebSocket upgrade headers through to Kong.

In Dokploy UI → `supabase.yourdomain.com` domain → **Advanced settings** → enable **WebSocket support**.

**Verify:** Upload a file and confirm the processing status updates live without page refresh.

---

## Google OAuth Setup

1. Go to [Google Cloud Console](https://console.cloud.google.com) → APIs & Services → Credentials
2. Create an OAuth 2.0 Client ID (Web application)
3. Add to **Authorized redirect URIs**:
   ```
   https://supabase.yourdomain.com/auth/v1/callback
   ```
4. Copy the Client ID and Secret into `.env`:
   ```env
   GOTRUE_EXTERNAL_GOOGLE_CLIENT_ID=your-client-id.apps.googleusercontent.com
   GOTRUE_EXTERNAL_GOOGLE_SECRET=your-client-secret
   ```

---

## SMTP

SMTP is optional for initial setup (`GOTRUE_MAILER_AUTOCONFIRM=true` allows signup without email verification).

Set these in `.env`:

```env
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=your-user
SMTP_PASS=your-password
SMTP_ADMIN_EMAIL=admin@example.com
```

---

## PostgreSQL Version

This stack uses **PostgreSQL 17** (`supabase/postgres:17.6.1.097`). Update the image tag if your app requires a different major version. This prevents `pg_dump` compatibility issues if you migrate from a managed Supabase instance.

---

## Upgrading

When upgrading service image versions:

1. Check the [Supabase self-hosting changelog](https://github.com/supabase/supabase/releases)
2. Update image tags in `docker-compose.yml`
3. For PostgreSQL major version upgrades, follow the [pg_upgrade docs](https://www.postgresql.org/docs/current/pgupgrade.html)
