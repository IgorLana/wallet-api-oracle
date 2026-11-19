# Oracle Database Free - Local Development (C03)

## Purpose

Run a pinned Oracle Database Free image locally with Docker Compose. This commit prepares the infrastructure only. WALLET_OWNER, WALLET_APP, WALLET_AUDIT, database migrations, and PL/SQL objects are **not** yet provisioned.

## Prerequisites

- Docker Desktop (or Docker Engine + Compose) running.
- At least 4 GB of memory available to Docker.
- Port 1521 on localhost available.

## First startup

From the repository root:

```bash
cp .env.example .env
```

Edit `.env` and replace the sample password with a strong local password. Confirm that `.env` is ignored by Git.

```bash
docker compose config --quiet
docker compose up -d
docker compose ps
docker compose logs -f oracle
```

Exit log following using Ctrl+C (the container remains running). Wait until the container reports healthy, and its logs indicate the database is ready.

Do not paste `docker compose config` output into an issue or PR: it can display interpolated secrets. `--quiet` validates without printing the resolved configuration.

## Check the database and FREEPDB1

```bash
docker compose exec oracle sqlplus -L / as sysdba
```

In SQL*Plus, run:

```sql
SELECT name, open_mode FROM v$pdbs WHERE name = 'FREEPDB1';
ALTER SESSION SET CONTAINER = FREEPDB1;
SELECT SYS_CONTEXT('USERENV', 'CON_NAME') AS container_name FROM dual;
SELECT 1 AS test_value FROM dual;
EXIT;
```

Expected: `FREEPDB1` is `READ WRITE`, container name is `FREEPDB1`, and test value is `1`.

## Connection settings for the next commits

- Host, from macOS: `localhost`
- Port: `1521`
- Service: `FREEPDB1`
- JDBC URL: `jdbc:oracle:thin:@//localhost:1521/FREEPDB1`
- Database inside Compose, from another container: `oracle:1521/FREEPDB1`
- Current administrative account: `SYSTEM` or `SYS` (only for local database setup, never for the Spring app)
- Spring application account (later): `WALLET_APP`

## Volume and container lifecycle

```bash
docker compose stop         # stop without deleting
docker compose start        # start again
docker compose down         # remove container/network, keep named data volume
```

**Danger:** `docker compose down -v` also deletes the named volume, permanently destroying local database contents. Use it only when intentionally resetting a disposable development database.

## Important note for C04

The image executes `/container-entrypoint-initdb.d` scripts **only at first database initialization**. Because C03 starts with an empty `db/init/` directory, adding schema bootstrap scripts in C04 will *not* run them automatically against this already initialized volume. In C04, we must deliberately choose either a repeatable bootstrap/migration job or an explicitly documented one-time reset of this still-disposable volume. Never assume adding new initialization scripts changes an existing database.

## Troubleshooting

- `docker: command not found`: install Docker Desktop and restart the terminal.
- `Cannot connect to the Docker daemon`: start Docker Desktop.
- Port 1521 already in use: stop the conflicting service or change the host port and update the connection URL.
- `unhealthy`: inspect `docker compose logs oracle`, memory assigned to Docker, and container startup errors.
- Password changed in `.env` but database still accepts old password: environment variables initialize the database on the first run; changing `.env` does not automatically rotate a password in an existing volume.
