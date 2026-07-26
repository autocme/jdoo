#!/bin/bash
# =============================================================================
# First-boot init (docker-entrypoint-initdb.d): create the low-privilege
# `pgbouncer_auth` role + a SECURITY DEFINER lookup used by PgBouncer's auth_query.
# Runs ONCE on cluster init. Idempotent (ALTER on re-run).
#
# Why SECURITY DEFINER: reading pg_authid.rolpassword (the SCRAM verifier) is
# superuser-only; the function (owned by the superuser) lets the low-priv auth role
# read exactly one row per lookup and nothing else.
# =============================================================================
set -euo pipefail
: "${AUTH_PASS:?AUTH_PASS required for pgbouncer_auth}"   # alphanumeric only
case "$AUTH_PASS" in *[!A-Za-z0-9]*) echo "[shared-pg-stack] FATAL: AUTH_PASS must be alphanumeric [A-Za-z0-9]" >&2; exit 1;; esac

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<SQL
DO \$do\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgbouncer_auth') THEN
    EXECUTE format('CREATE ROLE pgbouncer_auth LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE', '${AUTH_PASS}');
  ELSE
    EXECUTE format('ALTER ROLE pgbouncer_auth LOGIN PASSWORD %L', '${AUTH_PASS}');
  END IF;
END
\$do\$;

-- Tenant isolation is NOT done here. It is `REVOKE CONNECT ON DATABASE <db> FROM PUBLIC`,
-- applied per tenant database by the master at provisioning time (single owner:
-- j_server_base/utils/shared_pg.py), because that is the grant that decides whether a
-- tenant role can open a session against a sibling.
--
-- An earlier revision revoked SELECT on pg_database/pg_roles here to hide the cluster
-- inventory. Do NOT reintroduce it: Odoo resolves which database to serve through
-- list_dbs(), which reads pg_database joined against pg_user, so revoking it leaves every
-- tenant redirecting /web to the database selector with nothing to select — a healthy
-- container that serves no pages (verified live). It also bought nothing: Odoo's query is
-- already scoped to `datdba = current_user`, and a tenant's db name is its own subdomain.

CREATE SCHEMA IF NOT EXISTS pgbouncer_auth AUTHORIZATION "$POSTGRES_USER";
REVOKE ALL ON SCHEMA pgbouncer_auth FROM PUBLIC;
GRANT USAGE ON SCHEMA pgbouncer_auth TO pgbouncer_auth;

CREATE OR REPLACE FUNCTION pgbouncer_auth.get_auth(p_username text)
  RETURNS TABLE (username text, password text)
  LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog AS
\$func\$
  SELECT rolname::text, rolpassword::text
  FROM pg_authid
  WHERE rolname = p_username AND rolcanlogin
    AND NOT rolsuper AND NOT rolreplication AND NOT rolbypassrls
    AND NOT rolcreaterole AND NOT rolcreatedb;
\$func\$;
REVOKE ALL ON FUNCTION pgbouncer_auth.get_auth(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgbouncer_auth.get_auth(text) TO pgbouncer_auth;
SQL

echo "[shared-pg-stack] pgbouncer_auth role + pgbouncer_auth.get_auth() ready."
