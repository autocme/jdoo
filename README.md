# jdoo

Universal Odoo Docker setup. One configuration, all versions (15.0 - 19.0+).

## Features

- **One-command version switching** — change `ODOO_VERSION` and rebuild
- **Auto-computed settings** — Python, PostgreSQL, port, and project name derived automatically
- **Auto-tuned resources** — workers, memory limits, and PostgreSQL computed from CPU/RAM
- **Resource watcher** — optional live monitoring that reconfigures on resource changes
- **Dokploy / PaaS ready** — works with plain `docker compose` without wrapper scripts
- **Multi-stage Docker build** — lean runtime image (~1.4 GB instead of ~2.1 GB)
- **9-step smart entrypoint** — handles resources, config, packages, DB init, upgrades, and PDF fix
- **Stateless package management** — Python/NPM packages checked and installed on every startup
- **Multi-database auto-upgrade** — detects and upgrades all databases on restart
- **JCICD integration** — optional external volume for synced addons via CI/CD pipeline
- **Architecture support** — amd64 and arm64

## Dependencies

| Project | Role | Description |
|---------|------|-------------|
| [autocme/oc](https://github.com/autocme/oc) | **Build-time** | Optimized Odoo source code (~80% smaller than official), cloned into the Docker image via `ODOO_REPO` |
| [autocme/oa](https://github.com/autocme/oa) | **Runtime** | Odoo core addons, synced to `/repos/{version}/oa` by JCICD |
| [autocme/JCICD](https://github.com/autocme/JCICD) | **CI/CD** (optional) | Pipeline engine that syncs repos, triggers upgrades, and manages deployments |

> **oc vs oa**: `oc` is the Odoo source baked into the Docker image at build time.
> `oa` is the addons repo synced at runtime by JCICD into `/repos/{version}/oa`.
> To use the official Odoo repo instead of `oc`, set `ODOO_REPO=https://github.com/odoo/odoo.git` in `.env`.

## Quick Start

### Local Development (with `./jdoo` wrapper)

```bash
# 1. Copy and edit configuration
cp .env.example .env
nano .env                     # set ODOO_VERSION and passwords

# 2. Build and start
./jdoo up -d --build

# 3. Open Odoo
# http://localhost:8019  (port = 80 + major version)
```

> `./jdoo` auto-computes PYTHON_VERSION, PG_VERSION, ODOO_PORT, and COMPOSE_PROJECT_NAME.

### Dokploy / Direct Docker Compose

```bash
# 1. Set ODOO_VERSION in .env (only this is required)
ODOO_VERSION=19.0

# 2. Auto-compute PYTHON_VERSION and PG_VERSION
bash compute-env.sh

# 3. Build and start (with resource limits)
docker compose up -d --build \
  --scale odoo=1 \
  && docker update --cpus 4 --memory 8g $(docker compose ps -q odoo) \
  && docker update --cpus 2 --memory 4g $(docker compose ps -q db)

# Or simply without resource limits (auto-detects host resources)
docker compose up -d --build

# 4. Open Odoo
# http://localhost:8069  (Dokploy handles external port via reverse proxy)
```

> `compute-env.sh` auto-computes `PYTHON_VERSION` and `PG_VERSION` from `ODOO_VERSION`.
> Workers, memory, and PostgreSQL tuning are auto-computed inside containers.
> When resource limits are set (via `docker update` or `deploy.resources` in compose),
> the entrypoint auto-tunes workers/memory based on the **container's** allocated resources, not the host.

## Version Matrix

| ODOO_VERSION | PYTHON_VERSION | PG_VERSION |
|:------------:|:--------------:|:----------:|
| 15.0         | 3.10           | 14         |
| 16.0         | 3.10           | 15         |
| 17.0         | 3.12           | 16         |
| 18.0         | 3.12           | 16         |
| 19.0         | **3.12** (default) | **17** (default) |

## Deploying on Dokploy

1. Create a new **Compose** application in Dokploy
2. Point it to your jdoo git repository
3. Set environment variables in the Dokploy UI:

| Variable | Value | Required? |
|----------|-------|-----------|
| `ODOO_VERSION` | `19.0` | Always |
| `POSTGRES_PASSWORD` | your password | Recommended |
| `ODOO_ADMIN_PASSWORD` | your password | Recommended |

4. Set Pre-Deploy Command: `bash compute-env.sh`
5. Deploy — Dokploy runs `compute-env.sh` (auto-computes versions) then `docker compose up -d --build`
6. Configure domain in Dokploy (maps to container port 8069)

> `PYTHON_VERSION` and `PG_VERSION` are auto-computed from `ODOO_VERSION` by `compute-env.sh`.
> To override, set them explicitly in the Dokploy UI.

**What auto-computes inside containers:**
- **Odoo container**: workers, cron threads, memory limits (from CPU/RAM via cgroups)
- **PG container**: shared_buffers, effective_cache_size, work_mem, maintenance_work_mem (from RAM)

### Addons on Dokploy

The default `conf.addons_path` includes:

```
/repos/{version}/oa       # Odoo core addons via JCICD (read-only, if mounted)
```

> `oa` is [autocme/oa](https://github.com/autocme/oa) — Odoo core addons synced by JCICD.

**Adding custom addons:** Create a `docker-compose.override.yml` in your repo to mount an external volume:

```yaml
services:
  odoo:
    volumes:
      - my-addons:/mnt/extra-addons:ro
volumes:
  my-addons:
    external: true
```

**With JCICD:** Mount the syncer volume and the entrypoint auto-detects it:

```yaml
services:
  odoo:
    volumes:
      - repos:/mnt/synced-addons:ro
volumes:
  repos:
    external: true
```

> The entrypoint automatically adds `/mnt/synced-addons` to `conf.addons_path` when content is detected.

**Extending addons_path:** To add extra directories, override `conf.addons_path` in the Dokploy UI:

```
conf.addons_path=/opt/odoo/addons,/opt/odoo/odoo/addons,/mnt/extra-addons,/mnt/synced-addons
```

## Full Example: Deploy Odoo 17

```bash
# Clone the project
git clone <repo-url> jdoo
cd jdoo

# Configure
cp .env.example .env
```

Edit `.env`:

```ini
ODOO_VERSION=17.0

# Security - CHANGE IN PRODUCTION!
POSTGRES_USER=odoo
POSTGRES_PASSWORD=my_secure_password
ODOO_ADMIN_PASSWORD=my_admin_password

# Optional: auto-create database on first start
INITDB_OPTIONS=-n mydb -m base,web --unless-initialized
```

```bash
# Build and start
./jdoo up -d --build

# Check status
./jdoo ps

# View logs
./jdoo logs -f odoo

# Open browser
# http://localhost:8017/web/database/manager
```

Output:

```
[jdoo] Odoo 17.0 | Python 3.12 | PG 16 | Port 8017 | Project jdoo17
[jdoo] PG: shared=2048MB | cache=4096MB | work=64MB | maint=819MB | conn=100
```

## Switching Versions

```bash
# Stop current version and remove its volumes
./jdoo down -v

# Edit .env
nano .env    # change ODOO_VERSION=18.0

# Build and start new version
./jdoo up -d --build
```

Each version gets its own containers, volumes, and port automatically — no conflicts.

## Project Structure

```
jdoo/
├── .env.example              # Configuration template (copy to .env)
├── .gitignore                # Protects .env and sensitive files
├── Dockerfile                # Multi-stage build (builder + runtime)
├── docker-compose.yml        # Services, volumes, networks
├── docker-compose.syncer.yml # JCICD volume override (optional)
├── entrypoint.sh             # 9-step Odoo startup orchestration
├── healthcheck.sh            # Smart healthcheck with state awareness
├── upgrade.sh                # Standalone upgrade script (callable via docker exec)
├── addons-path.sh            # Query configured addons paths
├── pg-auto-tune.sh           # PostgreSQL auto-tuning entrypoint
├── compute-env.sh            # Auto-compute PYTHON/PG versions (for Dokploy)
├── jdoo                      # Smart wrapper (optional, for local dev)
├── extra-addons/             # Your custom addons (mounted read-only)
└── test-all.sh               # Automated test suite
```

## Configuration

All configuration is done through `.env`. The `docker-compose.yml` never needs direct editing.

### Required

| Variable | Example | Description |
|----------|---------|-------------|
| `ODOO_VERSION` | `19.0` | Odoo version to build (15.0 - 19.0+) |

### Version-Dependent (auto-computed by `./jdoo` or `compute-env.sh`)

| Variable | Default | Description |
|----------|---------|-------------|
| `PYTHON_VERSION` | `3.12` | Python base image (auto: `3.10` for Odoo 15-16) |
| `PG_VERSION` | `17` | PostgreSQL version (auto: see Version Matrix) |
| `ODOO_PORT` | `8069` | HTTP port (`./jdoo` sets `80+major`) |
| `COMPOSE_PROJECT_NAME` | `jdoo` | Container/volume prefix (`./jdoo` sets `jdoo+major`) |

### Auto-Computed Resources (from container CPU/RAM)

| Variable | Description |
|----------|-------------|
| `WORKERS` | Odoo HTTP worker processes |
| `MAX_CRON_THREADS` | Cron worker threads |
| `LIMIT_MEMORY_SOFT` | Per-worker soft memory limit (bytes) |
| `LIMIT_MEMORY_HARD` | Per-worker hard memory limit (bytes) |

> Formulas and examples: see [Step 2: Resource Auto-Tuning](#step-2-resource-auto-tuning).

### Auto-Computed PostgreSQL (from container RAM)

| Variable | Description |
|----------|-------------|
| `PG_SHARED_BUFFERS` | PostgreSQL shared buffers |
| `PG_EFFECTIVE_CACHE_SIZE` | Query planner cache hint |
| `PG_WORK_MEM` | Per-operation sort/hash memory |
| `PG_MAINTENANCE_WORK_MEM` | VACUUM/CREATE INDEX memory |
| `PG_MAX_CONNECTIONS` | Maximum database connections |

> Formulas and examples: see [PostgreSQL Auto-Tuning](#postgresql-auto-tuning).

### Security

| Variable | Default | Description |
|----------|---------|-------------|
| `POSTGRES_USER` | `odoo` | PostgreSQL username |
| `POSTGRES_PASSWORD` | `odoo` | PostgreSQL password — **change in production** |
| `ODOO_ADMIN_PASSWORD` | `admin_` | Odoo master password — **change in production** |

### Container

| Variable | Default | Description |
|----------|---------|-------------|
| `LONGPOLLING_PORT` | `8072` | Host port for longpolling/websocket |
| `PUID` | `1000` | Container user UID (match host user) |
| `PGID` | `1000` | Container group GID (match host user) |
| `ODOO_REPO` | [`autocme/oc`](https://github.com/autocme/oc) | Odoo source code repo cloned at build time (see [Dependencies](#dependencies)) |

### Features

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTO_UPGRADE` | `FALSE` | Auto-upgrade modules on container restart |
| `UPGRADE_IGNORE_CORE` | `TRUE` | Skip core addons during upgrade (faster) |
| `INITDB_OPTIONS` | *(empty)* | Database init options (empty = use Odoo UI) |
| `ODOO_DB_NAME` | *(empty)* | Target database (empty = auto-detect all) |
| `PY_INSTALL` | `phonenumbers,python-stdnum,num2words` | Python packages installed at startup |
| `NPM_INSTALL` | `rtlcss,less` | NPM packages installed at startup |
| `FIX_REPORT_URL` | `FALSE` | Fix `report.url` for wkhtmltopdf PDF rendering inside container |
| `RESOURCE_WATCHER` | `FALSE` | Monitor CPU/RAM changes and auto-restart Odoo |
| `SYNCER_VOLUME_NAME` | *(empty)* | JCICD external volume name (auto-includes syncer compose) |
| `CICD_ROLE` | `staging` | Container label for CI/CD role (`staging` / `production`) |

## Odoo Configuration (conf.*)

Any `conf.*` environment variable in `docker-compose.yml` becomes an Odoo config entry in `/etc/odoo/erp.conf`:

```yaml
environment:
  conf.db_host: db           # → db_host = db
  conf.log_level: info       # → log_level = info
```

### Version-Specific Mappings

| Config Key | Odoo 15-16 | Odoo 17+ |
|------------|------------|----------|
| `longpolling_port` | Used as-is | Auto-renamed to `gevent_port` |

Always use `conf.longpolling_port` — the entrypoint translates it automatically for Odoo 17+.

## Startup Sequence (9 Steps)

```
Step 1  Setup user permissions       Adjust odoo UID/GID to match PUID/PGID
Step 2  Compute resources            Auto-detect CPU/RAM, calculate workers/memory
Step 3  Generate configuration       conf.* env vars → /etc/odoo/erp.conf
Step 4  Install Python packages      PY_INSTALL (stateless, skips installed)
Step 5  Install NPM packages         NPM_INSTALL (stateless, skips installed)
Step 6  Initialize database          INITDB_OPTIONS via click-odoo-initdb
Step 7  Auto-upgrade modules         click-odoo-update per database
Step 8  Fix report.url               Sets http://localhost:${ODOO_PORT} (only if FIX_REPORT_URL=TRUE)
Step 9  Start Odoo                   exec gosu odoo python odoo-bin
```

### Step 2: Resource Auto-Tuning

The entrypoint detects container CPU and RAM (via cgroup v2/v1 or `/proc`) and computes:

| Setting | Formula | 4 CPU / 8GB RAM | 8 CPU / 32GB RAM |
|---------|---------|:---------------:|:----------------:|
| workers | CPU * 2 | 8 | 16 |
| max_cron_threads | 1 or 2 | 2 | 2 |
| limit_memory_soft | 85% RAM / procs | ~700MB | ~1.5GB |
| limit_memory_hard | soft * 1.3 | ~910MB | ~1.9GB |

Override any value in `.env` (e.g., `WORKERS=4`). If set, auto-compute is skipped for that variable.

**Setting container resource limits:**

Use `docker-compose.override.yml` to allocate specific CPU/RAM per container:

```yaml
services:
  odoo:
    deploy:
      resources:
        limits:
          cpus: "4"
          memory: 8G
        reservations:
          cpus: "2"
          memory: 4G
  db:
    deploy:
      resources:
        limits:
          cpus: "2"
          memory: 4G
        reservations:
          cpus: "1"
          memory: 2G
```

Or apply limits at runtime:

```bash
docker update --cpus 4 --memory 8g <odoo-container>
docker update --cpus 2 --memory 4g <db-container>
```

> The entrypoint reads **container** limits (not host), so setting `--cpus 4 --memory 8g`
> on a 32-core host will compute workers/memory based on 4 CPUs and 8GB.

### PostgreSQL Auto-Tuning

The `pg-auto-tune.sh` script wraps the PostgreSQL Docker entrypoint. It detects container RAM and computes:

| Setting | Formula | 8GB RAM | 32GB RAM |
|---------|---------|:-------:|:--------:|
| shared_buffers | min(25% RAM, 4GB) | 2048MB | 4096MB |
| effective_cache_size | 50% RAM | 4096MB | 16384MB |
| work_mem | 64MB | 64MB | 64MB |
| maintenance_work_mem | min(10% RAM, 2GB) | 819MB | 2048MB |

Override any value in `.env` (e.g., `PG_SHARED_BUFFERS=512MB`).

### Step 8: PDF Report Fix (Optional)

wkhtmltopdf generates PDFs by fetching CSS/JS from Odoo via HTTP inside the container.
When `FIX_REPORT_URL=TRUE`, the entrypoint sets `report.url = http://localhost:${ODOO_PORT}` in all databases,
ensuring PDF reports render correctly regardless of the external `web.base.url` setting.

**Disabled by default.** Enable it if PDF reports have missing styles:

```ini
FIX_REPORT_URL=TRUE
```

## Resource Watcher (Optional)

When `RESOURCE_WATCHER=TRUE`, the entrypoint runs a background monitor that checks CPU/RAM
every 30 seconds. If a change is detected (e.g., via `docker update --cpus 8 --memory 16g`),
it automatically recalculates settings and gracefully restarts Odoo.

```ini
# Enable in .env
RESOURCE_WATCHER=TRUE

# Custom check interval (default: 30 seconds)
RESOURCE_WATCHER_INTERVAL=60
```

When disabled (default), Odoo runs as PID 1 via `exec` for optimal signal handling.

## Custom Addons

Place addons in `extra-addons/`:

```
extra-addons/
├── my_module/
│   ├── __init__.py
│   └── __manifest__.py
└── another_module/
    ├── __init__.py
    └── __manifest__.py
```

Mounted read-only at `/mnt/extra-addons`, already included in `addons_path`.

## Database Initialization

**Disabled by default.** Create databases from the Odoo UI at `/web/database/manager`.

To auto-create a database on first startup:

```ini
INITDB_OPTIONS=-n mydb -m base,web --unless-initialized
```

## Auto-Upgrade

When `AUTO_UPGRADE=TRUE`, on every container restart:

1. Discovers all non-system databases (or uses `ODOO_DB_NAME` if set)
2. Checks each database for changed module hashes (`--list-only`)
3. Runs `click-odoo-update --i18n-overwrite` only if changes detected
4. Uses `--ignore-core-addons` when `UPGRADE_IGNORE_CORE=TRUE` (faster)
5. Continues to the next database even if one fails

> **Note:** During auto-upgrade, Odoo's HTTP server is not running yet (upgrade runs at Step 7,
> Odoo starts at Step 9). The smart healthcheck returns healthy during this phase
> to prevent orchestrators from restarting the container. See [Container Health States](#container-health-states).

## External Upgrade (upgrade.sh)

The container includes a standalone `upgrade.sh` script that can be called externally via `docker exec`.
This gives orchestrators like [JCICD](https://github.com/autocme/JCICD) the ability to
trigger upgrades on-demand and check the result via exit code.

**How it works:**

1. **Pauses Odoo** (SIGSTOP) — freezes all Odoo processes without killing them, preventing DB conflicts
2. **Discovers databases** — queries PostgreSQL for all non-system databases (or uses `-d`)
3. **Upgrades each database sequentially** — one at a time, reports per-DB result
4. **Resumes Odoo** (SIGCONT) — unfreezes processes regardless of result
5. On success: returns exit 0 — caller should `docker restart` to load new module code
6. On failure: returns exit 1 — sets `UPGRADE_FAILED` state, Odoo resumes with old code

```bash
# Upgrade all databases
docker exec <container> /usr/local/bin/upgrade.sh

# Upgrade a specific database
docker exec <container> /usr/local/bin/upgrade.sh -d mydb

# Dry-run: check what needs upgrading (no changes)
docker exec <container> /usr/local/bin/upgrade.sh --check
```

**Exit codes:**

| Code | Meaning |
|------|---------|
| `0` | All databases upgraded (or up-to-date) — restart container to load new code |
| `1` | One or more databases failed — Odoo resumes with old code |

**Example output:**

```
[INFO] Pausing Odoo processes: 1 8 9 10
[INFO] Databases to process: 2 (mydb testdb)
[INFO] === [1/2] mydb ===
[INFO] [OK] mydb: upgraded successfully.
[INFO] === [2/2] testdb ===
[INFO] [SKIP] testdb: up-to-date.
[INFO] ==========================================
[INFO] Upgrade Summary: 2 database(s)
[INFO]   Succeeded: 1
[INFO]   Skipped:   1 (up-to-date)
[INFO]   Failed:    0
[INFO] ==========================================
[INFO] Resuming Odoo processes: 1 8 9 10
[INFO] All upgrades succeeded. Restart the container to load new code.
```

### JCICD Integration

JCICD can use `upgrade.sh` in its sync workflow:

```
JCICD flow:
  1. git pull (sync new code)         → /repos/{branch}/{repo}
  2. docker exec upgrade.sh           → pauses Odoo, upgrades DBs, resumes Odoo
  3. Check exit code                  → 0 = success, 1 = failure
  4. docker restart <container>       → Odoo loads updated module code
```

**Health output during upgrade:**

| Health Output | Meaning | JCICD Action |
|---------------|---------|---------------------|
| `UPGRADING` | Upgrade in progress, Odoo paused | Keep waiting |
| `UPGRADE_FAILED` | Upgrade failed, Odoo resumed with old code | Mark job failed |
| `RUNNING` | Odoo is up after restart | Job complete |

### Recommended Workflows

**Workflow A: Auto-upgrade on restart (simple)**

Set `AUTO_UPGRADE=TRUE` in `.env`. The entrypoint runs the upgrade at Step 7
(before Odoo starts). JCICD just restarts the container and polls the healthcheck.

**Workflow B: External upgrade via docker exec (recommended with JCICD)**

Set `AUTO_UPGRADE=FALSE` in `.env` to prevent the entrypoint from running upgrades on restart.
JCICD calls `upgrade.sh` explicitly after syncing code, checks the exit code,
then restarts the container to load updated modules.

> **Important:** When using `upgrade.sh`, set `AUTO_UPGRADE=FALSE` to avoid running
> the upgrade twice (once by the script, once by the entrypoint on restart).

## Addons Path Query (addons-path.sh)

Returns the configured `addons_path` from `erp.conf`, one path per line.
Useful for JCICD and other orchestrators to discover where addons live.

```bash
docker exec <container> /usr/local/bin/addons-path.sh
```

```
/repos/19.0/oa
```

## Container Health States

The entrypoint writes the current state to a file, and `healthcheck.sh` reads it to decide the response.
This prevents orchestrators (Dokploy, Swarm, Kubernetes) from killing the container during long operations.

| State | When | Healthcheck | Docker Status |
|-------|------|-------------|---------------|
| `STARTING` | Steps 1-5 (permissions, config, packages) | exit 0 | healthy |
| `INITIALIZING` | Step 6 (database initialization) | exit 0 | healthy |
| `UPGRADING` | Step 7 (module auto-upgrade) | exit 0 | healthy |
| `UPGRADE_RETRY` | Upgrade retry in progress | exit 0 | healthy |
| `RUNNING` | Step 9 (Odoo HTTP responding) | checks HTTP | healthy |
| `RUNNING_LOADING` | Step 9 (Odoo process alive, loading modules) | exit 0 | healthy |
| `UPGRADE_FAILED` | Module upgrade failed | exit 1 | unhealthy |
| `RUNNING_NO_PROCESS` | Odoo process not found (crashed) | exit 1 | unhealthy |

When the state is `RUNNING`, the healthcheck performs a 3-layer check:

1. **Process check** — is `odoo-bin` process alive? If not → `RUNNING_NO_PROCESS` (unhealthy)
2. **HTTP check** — does `/web/login` respond? If yes → `RUNNING` (healthy)
3. **Loading grace** — process alive but HTTP not ready → `RUNNING_LOADING` (healthy, still booting)

**Check the current state:**

```bash
docker inspect --format='{{json .State.Health.Log}}' <container> | jq -r '.[-1].Output'
```

## Runtime Packages

### PY_INSTALL

```ini
PY_INSTALL=phonenumbers,python-stdnum==1.13,num2words
```

Comma-separated. Stateless (checks before installing). Supports version pinning.

> **Note:** The runtime image has no compiler. Only packages with pre-built wheels work.
> This covers 99% of packages (phonenumbers, num2words, etc.).

### NPM_INSTALL

```ini
NPM_INSTALL=rtlcss,less
```

Comma-separated. Installed globally. Stateless.

## The `./jdoo` Wrapper (Optional)

`./jdoo` is a convenience wrapper for local development that auto-computes version-dependent settings:

```bash
./jdoo up -d --build     # start (auto-computes PYTHON_VERSION, PG_VERSION, etc.)
./jdoo down              # stop
./jdoo down -v           # stop and remove volumes
./jdoo logs -f odoo      # view logs
./jdoo ps                # container status
./jdoo build --no-cache  # full rebuild
./jdoo exec odoo bash    # shell into container
```

It reads `ODOO_VERSION` from `.env`, computes missing variables, exports them,
then passes all arguments to `docker compose`.

> **Not required** for Dokploy or other PaaS — those work with plain `docker compose` directly.

## Common Operations

```bash
# Start (local dev)
./jdoo up -d --build

# Start (Dokploy / plain docker compose)
bash compute-env.sh && docker compose up -d --build

# Stop
docker compose down

# Stop and clean volumes (fresh start)
docker compose down -v

# View logs
docker compose logs -f odoo

# Odoo shell
docker compose exec odoo gosu odoo python odoo-bin shell -c /etc/odoo/erp.conf -d mydb

# PostgreSQL CLI
docker compose exec db psql -U odoo -d postgres

# Restart (triggers auto-upgrade if enabled)
docker compose restart odoo
```

## Testing

```bash
chmod +x test-all.sh
./test-all.sh
```

Runs 9 test categories: container status, version detection, entrypoint init,
configuration, database connection, healthcheck, file permissions, volumes, and addons.

## Troubleshooting

### Container won't start

```bash
docker compose logs odoo 2>&1 | head -50
```

### Module upgrade fails

```bash
# Run upgrade via upgrade.sh (pauses Odoo, upgrades, resumes)
docker exec <container> /usr/local/bin/upgrade.sh -d mydb

# Or run click-odoo-update directly
docker compose exec odoo gosu odoo click-odoo-update -c /etc/odoo/erp.conf -d mydb
```

### Permission errors

```bash
# Check your host UID/GID
id
# Set matching values in .env
# PUID=1000
# PGID=1000
```

### Port conflict

```ini
# Override port in .env
ODOO_PORT=9019
```

### PDF reports have no styling

Set `FIX_REPORT_URL=TRUE` in `.env` to enable the automatic fix (Step 8). Then verify:

```bash
# Verify report.url inside the database
docker compose exec db psql -U odoo -d mydb -c \
  "SELECT value FROM ir_config_parameter WHERE key = 'report.url';"
# Should show: http://localhost:${ODOO_PORT}
```

## Production Checklist

- [ ] Change `POSTGRES_PASSWORD` to a strong password
- [ ] Change `ODOO_ADMIN_PASSWORD` to a strong password
- [ ] Configure reverse proxy with SSL (nginx, traefik, etc.)
- [ ] Set up automated database backups
- [ ] Verify auto-computed workers/memory match your needs (override in `.env` if needed)
- [ ] Match `PUID`/`PGID` to host user for correct file permissions
- [ ] Keep `AUTO_UPGRADE=FALSE` (default) when using CI/CD or `upgrade.sh`
- [ ] Run `bash compute-env.sh` after changing `ODOO_VERSION` (or use `./jdoo`)

## CI/CD Labels

The `docker-compose.yml` includes container labels for orchestrator integration:

| Label | Default | Description |
|-------|---------|-------------|
| `restart-after` | `{ODOO_VERSION}/oa` | JCICD triggers restart when this repo is synced |
| `cicd-role` | `staging` | Identifies the deployment role (`staging` / `production`) |

These labels allow JCICD and other CI/CD tools to discover and manage containers automatically.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Host / Dokploy                                             │
│                                                             │
│  ┌──────────────────┐      ┌─────────────────────────────┐  │
│  │  PostgreSQL       │◄────►│  Odoo (jdoo)                │  │
│  │  :5432            │      │  :${ODOO_PORT}              │  │
│  │                   │      │  :8072 (websocket)          │  │
│  │  pg-auto-tune.sh  │      │  entrypoint.sh (9 steps)    │  │
│  │  (auto-tuned)     │      │  (auto-tuned workers/mem)   │  │
│  └──────┬────────────┘      └──────┬──────────────────────┘  │
│         │                          │                         │
│    db-data vol               odoo-data vol                   │
│                               extra-addons/ (ro)             │
│                               repos/ (ro, JCICD)      │
│                               synced-addons/ (optional)      │
└─────────────────────────────────────────────────────────────┘
```
