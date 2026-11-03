# Pathfinder deployment runbook

## Portable configuration reference

This public document describes the application contract, not any production
host. Server coordinates, routing, service-manager units and operating procedures
are maintained privately by the operator.

1. Copy `.env.example` to ignored `.env`. Set the real public application names,
   credentials, `PF_DB_PORT`, `PF_SERVER_PORT` and `PF_DB_VOLUME` privately.
   Examples are illustrative, not production settings.
2. Use the existing external database volume when upgrading. Provision a volume
   separately for a new installation; never substitute empty storage for live data.
3. Copy `console.conf.example` to ignored `console.conf`. Configure its listener
   and API upstream consistently with `.env`. Keep database and API listeners private.
4. Validate from this directory with
   `docker compose -p pathfinder -f docker-compose.yml config --quiet`.
   Do not print the rendered configuration because it contains resolved secrets.

## Upload versus activation

`push.sh --dry-run` previews the upload. SSH settings come from ignored
`.deploy.env` or environment overrides; the example file has no real coordinates.
With no file arguments the script uploads Compose and ignored `console.conf`,
then validates remotely. `.env` is sent only when explicitly named.

The script does not pull images, install units, reload proxies or activate
services; `--restart` is rejected. Applying images, nginx configurations and
host lifecycle changes follows the operator's private deployment procedure.

## Updates, acceptance and backup

Publish a component image before changing its exact pin. Preserve existing
storage, credentials, public QR hostnames and slugs. A rollback across a schema
migration needs a database restore, not merely an older image.

Verify API health, console-to-API access, public route restrictions, an existing
QR's destination and scan statistics at the configured endpoints. An upload or
configuration validation alone is not runtime acceptance.

Keep ignored configuration and PostgreSQL backups under the operator's private
backup policy. Never use `docker compose down -v` for deployment or rollback.
