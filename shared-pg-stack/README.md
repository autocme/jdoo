# shared-pg-stack — shared Postgres + PgBouncer (one per worker node)

Backs the jdoo SaaS "shared PG" topology: every tenant `jdoo` stack on a node talks to
this node's **PgBouncer** (`shared-pgbouncer:6432`, session pooling) instead of a
per-tenant Postgres container. The Odoo master provisions/tears down tenant roles &
databases **directly on Postgres** over the local docker socket.

## Deploy (once per worker node)

```bash
docker network create pg-net                 # shared with tenant stacks (idempotent)
cp .env.example .env && edit .env            # set PG_SUPERPASS + AUTH_PASS (alnum)
docker compose up -d                         # or deploy as a j.dokploy.instance compose stack
docker compose ps                            # postgres healthy, pgbouncer up
```

Topology: `postgres` is on the private `pg-backend` net only (no published port).
`pgbouncer` is on `pg-backend` + `pg-net`. Tenants join `pg-net` and resolve
`shared-pgbouncer`. The master reaches Postgres via `docker exec shared-postgres`.

## What the master does (control plane — j_dokploy_saas)

Provision (before a tenant deploys), run on the tenant's node:
```bash
docker exec -i shared-postgres psql -U postgres <<SQL
  -- <t> = sanitized tenant db == role ; <pw> = tenant role password
  SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE', :'r', :'pw')
    WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'r') \gexec
  SELECT format('CREATE DATABASE %I OWNER %I', :'db', :'r')
    WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db') \gexec
  SELECT format('REVOKE CONNECT ON DATABASE %I FROM PUBLIC', :'db') \gexec
SQL
```
Teardown (after compose.delete):
```bash
docker exec -i shared-postgres psql -U postgres <<SQL
  SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = :'db' AND pid <> pg_backend_pid();
  SELECT format('DROP DATABASE IF EXISTS %I WITH (FORCE)', :'db') \gexec
  SELECT format('DROP ROLE IF EXISTS %I', :'r') \gexec
SQL
```
The tenant role is `NOSUPERUSER NOCREATEDB`, owns exactly one DB, and `REVOKE CONNECT
… FROM PUBLIC` blocks every other role from connecting to it → tenant isolation.

## Health / load checks

```bash
docker exec shared-postgres psql -U postgres -c "SELECT count(*) FROM pg_stat_activity;"
docker exec shared-postgres psql -U postgres -c "SHOW max_connections;"
docker exec shared-pgbouncer psql -h 127.0.0.1 -p 6432 -U pgbouncer_auth -d pgbouncer -c "SHOW POOLS;"
```

## Notes
- `pool_mode=session` is mandatory (Odoo bus LISTEN/NOTIFY + prepared statements).
- `auth_query` + `auth_dbname=postgres` → adding/removing tenant roles needs NO reload.
- `AUTH_PASS` must be identical for both containers (same `.env`) and alphanumeric.
