# Vikunja Full Stack (Docker Compose)

This repository runs a complete self-hosted Vikunja stack with:

- Vikunja (API + frontend)
- ParadeDB/PostgreSQL (database)
- Redis (cache/rate-limit store)
- Cloudflare Tunnel (remote HTTPS ingress)
- Prometheus (metrics scraping)
- Loki + Promtail (log aggregation and shipping)
- Grafana (metrics dashboards)
- Automated DB dumps
- Automated GitHub backup of DB dumps + uploaded files

## Services and Ports

| Service | Container | Port | Purpose |
| --- | --- | --- | --- |
| Vikunja | `vikunja` | `3456` | Main app/API |
| Grafana | `vikunja-grafana` | `3000` | Metrics UI |
| Prometheus | `vikunja-prometheus` | `9090` | Metrics collection |
| Loki | `vikunja-loki` | internal | Log store |
| Promtail | `vikunja-promtail` | internal | Docker log shipper |
| ParadeDB/Postgres | `vikunja-db` | internal | Primary DB |
| Redis | `vikunja-redis` | internal | Cache/rate-limit store |
| Cloudflared | `vikunja-tunnel` | n/a | Cloudflare tunnel agent |
| DB backup | `vikunja-db-backup` | internal | Scheduled SQL dumps |
| Git backup | `vikunja-git-backup` | internal | Scheduled push to GitHub |

## Prerequisites

1. Docker Engine + Docker Compose plugin installed and running.
2. Git installed.
3. Ports `3456`, `3000`, and `9090` available on your host.
4. A Cloudflare tunnel token (for remote access).
5. SMTP credentials (if you want reminder emails enabled as currently configured).
6. A GitHub PAT + private repo for backup pushes.

## 1. Configure Environment Variables

Create/update `.env` in the repo root:

```dotenv
# Core app
VIKUNJA_DOMAIN=tasks.example.com
JWT_SECRET=replace_with_long_random_secret
TIMEZONE=America/New_York

# Database
DB_USER=vikunja
DB_PASSWORD=replace_with_strong_db_password
DB_NAME=vikunja

# Cloudflare tunnel (required for cloudflared service)
CLOUDFLARE_TUNNEL_TOKEN=replace_with_cloudflare_tunnel_token

# SMTP (required because mailer is enabled in docker-compose.yml)
SMTP_HOST=smtp.example.com
SMTP_PORT=465
SMTP_USER=your_smtp_user
SMTP_PASSWORD=your_smtp_password
SMTP_FROM=vikunja@example.com

# Unsplash backgrounds (optional)
UNSPLASH_ACCESS_TOKEN=
UNSPLASH_APP_ID=

# Metrics auth (used by both Vikunja + Prometheus scrape config)
METRICS_USERNAME=admin
METRICS_PASSWORD=replace_with_metrics_password

# Grafana
GRAFANA_USER=admin
GRAFANA_PASSWORD=replace_with_grafana_password
GRAFANA_DOMAIN=grafana.example.com

# Git backup identity + destination
GIT_BACKUP_NAME=Your Name
GIT_BACKUP_EMAIL=you@example.com
GITHUB_BACKUP_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx
GITHUB_BACKUP_REPO=your-org/your-private-backup-repo
```

Generate strong secrets quickly:

```bash
openssl rand -hex 32   # JWT_SECRET
openssl rand -base64 24 # passwords
```

Security note: `.env` contains secrets. Keep it out of source control and rotate any credential that has ever been shared.

## 2. Start the Stack

From the repo root:

```bash
docker compose pull
docker compose up -d
docker compose ps
```

Expected long-running containers:

- `vikunja`
- `vikunja-db`
- `vikunja-redis`
- `vikunja-tunnel`
- `vikunja-prometheus`
- `vikunja-loki`
- `vikunja-promtail`
- `vikunja-grafana`
- `vikunja-db-backup`
- `vikunja-git-backup`

Expected one-shot containers (exit successfully):

- `vikunja-init`
- `vikunja-prom-init`

## 3. First-Time Vikunja Bootstrap

1. Open `http://localhost:3456` (or your `VIKUNJA_DOMAIN` URL through Cloudflare).
2. Register the first account (registration is currently enabled).
3. After first admin account creation, disable open registration:
   - In [`docker-compose.yml`](./docker-compose.yml), set `VIKUNJA_SERVICE_ENABLEREGISTRATION: "false"`.
   - In [`config.yml`](./config.yml), set `service.enableregistration: false`.
4. Apply changes:

```bash
docker compose up -d vikunja
```

## 4. Verify Everything Works

### App

```bash
curl -I http://localhost:3456
docker compose logs --tail=100 vikunja
```

### DB + Redis

```bash
docker compose exec db pg_isready -U "${DB_USER:-vikunja}"
docker compose logs --tail=100 redis
```

### Prometheus

1. Open `http://localhost:9090/targets`
2. Confirm both targets are `UP`:
   - `vikunja`
   - `prometheus`

### Grafana

1. Open `http://localhost:3000`
2. Login with `GRAFANA_USER` / `GRAFANA_PASSWORD`
3. Confirm Prometheus datasource is present (auto-provisioned from [`grafana/provisioning/datasources/prometheus.yml`](./grafana/provisioning/datasources/prometheus.yml))
4. Confirm Loki datasource is present (auto-provisioned from [`grafana/provisioning/datasources/loki.yml`](./grafana/provisioning/datasources/loki.yml))
5. Open the `Vikunja / Vikunja Logs` dashboard (auto-provisioned from [`grafana/provisioning/dashboards/json/vikunja-logs.json`](./grafana/provisioning/dashboards/json/vikunja-logs.json))

### Loki + Promtail

```bash
docker compose logs --tail=100 loki
docker compose logs --tail=100 promtail
```

Promtail labels each log stream with:

- `compose_project`
- `compose_service`
- `container`
- `image`

### Cloudflare tunnel

```bash
docker compose logs --tail=100 cloudflared
```

You should see successful tunnel connection logs (not auth/token errors).

### Backups

```bash
docker compose logs --tail=100 db-backup
docker compose logs --tail=100 git-backup
```

Backup schedule as configured:

- DB dumps: daily at `03:00` (`TIMEZONE` in `.env`)
- Git backup push: daily at `03:30`

## 5. Day-2 Operations

Start/stop:

```bash
docker compose up -d
docker compose down
```

Update all images:

```bash
docker compose pull
docker compose up -d
```

Tail logs:

```bash
docker compose logs -f vikunja db redis prometheus loki promtail grafana cloudflared db-backup git-backup
```

Re-run init permissions step if file ownership breaks:

```bash
docker compose run --rm init
```

If metrics credentials change, regenerate Prometheus config:

```bash
docker compose rm -f prom-init
docker compose up -d prom-init
docker compose restart prometheus
```

## 6. Backup and Restore

### What gets backed up

1. SQL dumps to `backups/db/` (compressed `.sql.gz`)
2. Vikunja uploaded files from `files/`
3. Backup snapshot pushed to `git-backup-repo/` and then to `GITHUB_BACKUP_REPO`

Git backup behavior is defined in [`scripts/git-backup.sh`](./scripts/git-backup.sh). It keeps the latest 3 SQL dumps and force-pushes `main`.

### Restore database from a dump

1. Stop app writes:

```bash
docker compose stop vikunja
```

2. Restore:

```bash
gunzip -c backups/db/<backup-file>.sql.gz | docker compose exec -T db psql -U "${DB_USER:-vikunja}" -d "${DB_NAME:-vikunja}"
```

3. Start app:

```bash
docker compose start vikunja
```

## 7. Directory Layout

- [`docker-compose.yml`](./docker-compose.yml): service orchestration
- [`config.yml`](./config.yml): Vikunja app config
- `.env`: secrets and runtime settings
- `db/`: PostgreSQL data directory (persistent)
- `files/`: Vikunja file uploads
- `plugins/`: Vikunja plugins directory
- [`loki/config.yml`](./loki/config.yml): Loki backend config
- [`promtail/config.yml`](./promtail/config.yml): Promtail scrape/label rules
- [`grafana/provisioning/datasources/loki.yml`](./grafana/provisioning/datasources/loki.yml): Loki datasource provisioning
- `backups/db/`: scheduled DB dumps
- `git-backup-repo/`: local git mirror for pushed backups
- [`scripts/git-backup.sh`](./scripts/git-backup.sh): git backup job logic

## Troubleshooting

- `cloudflared` keeps restarting:
  - `CLOUDFLARE_TUNNEL_TOKEN` is missing/invalid.
- Prometheus shows Vikunja target `DOWN`:
  - `METRICS_USERNAME`/`METRICS_PASSWORD` mismatch between Vikunja and generated Prometheus config.
- No logs in Grafana Loki queries:
  - check `promtail` is running and can read `/var/lib/docker/containers`.
  - check Loki datasource health in Grafana.
- Email reminders fail:
  - SMTP vars are wrong, or provider blocks auth/TLS settings.
- Backups are not pushing:
  - `GITHUB_BACKUP_TOKEN` lacks repo write scope, or `GITHUB_BACKUP_REPO` is wrong.
- Permission errors on `files/` or `plugins/`:
  - run `docker compose run --rm init`.
