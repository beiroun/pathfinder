# Pathfinder deployment runbook

One host, Docker Compose, published images. The host keeps this directory only: `docker-compose.yml`,
`Caddyfile`, `.env` and the `edge-data/` directory the edge proxy writes its certificates into. Component
sources are never cloned on the server and nothing is built there.

## Prerequisites

- Linux host with Docker Engine and the Compose plugin (`docker compose version`).
- DNS: an A record for each public name, both pointing at this host. The names are issued a certificate over an
  HTTP challenge, so they must resolve **before** the first start of the edge container.

  | Name | `.env` | Serves |
  |---|---|---|
  | `pathfinder.<domain>` | `PF_SERVER_HOST` | the redirect every printed code points at (`/r/<slug>`), the API |
  | `pathfinder-console.<domain>` | `PF_CONSOLE_HOST` | the management console (and its own `/api` to the server) |

  The server's name is printed into every QR code. Pick one you will keep.

- Firewall open to the internet: TCP 80 and 443 (edge proxy). Port 80 stays open even though everything
  redirects to HTTPS - the ACME challenge needs it. Everything else stays on loopback: the database, the server
  and the console's nginx.
- Images: `docker-compose.yml` pins `ghcr.io/beiroun/pathfinder-server` and `pathfinder-console` by version. A
  version exists once the component repository carries the matching `vX.Y.Z` tag (the release workflow builds and
  publishes it). A freshly published GHCR package is private by default - switch it to Public once in the package
  settings, or `docker login ghcr.io` on the host with a token that has `read:packages`.

## First bring-up

```bash
git clone https://github.com/beiroun/pathfinder.git /opt/pathfinder
cd /opt/pathfinder/deployment
cp .env.example .env            # fill the two names, PF_ACME_EMAIL, PF_DB_PASSWORD, PF_JWT_SECRET, PF_ADMIN_USERS
# the edge proxy runs as uid 1001 and needs its data directory to belong to that uid; compose does not create
# missing host paths here (create_host_path: false), so a forgotten directory fails `up` at once
mkdir -p edge-data && sudo chown -R 1001:1001 edge-data
docker compose pull
docker compose up -d
docker compose logs -f server | grep -iE "flyway|console user|started"
docker compose logs edge | grep -iE "certificate|obtain|error"   # expect "certificate obtained successfully"
```

Then open `https://pathfinder-console.<domain>`, log in with a pair from `PF_ADMIN_USERS`, create a code and
scan it with a phone: the redirect lands on the platform's link and the scan shows up in the statistics.

Secrets: `PF_DB_PASSWORD` (`openssl rand -hex 24`) is fixed by the first start - changing it later needs
`ALTER ROLE` in the database as well. `PF_JWT_SECRET` (`openssl rand -hex 32`) can be rotated any time; it logs
everybody out. Console users are `login:password` pairs; a changed password or role is applied on the next
`docker compose up -d server`, a login removed from the list is disabled.

## System service

`pathfinder.service` runs this directory as one unit: `docker compose up -d` on start, `docker compose down` on
stop. The committed unit points at `/opt/pathfinder/deployment`; installing renders it with the real path of
the checkout:

```bash
cd /opt/pathfinder/deployment            # wherever the umbrella repository is cloned
sed "s#/opt/pathfinder/deployment#$PWD#" pathfinder.service > /etc/systemd/system/pathfinder.service
systemctl daemon-reload
systemctl enable --now pathfinder
systemctl status pathfinder              # "active (exited)" is right: the unit is a oneshot, the containers run
```

| Action | Command |
|---|---|
| start / stop the whole system | `systemctl start pathfinder` / `systemctl stop pathfinder` |
| apply a `git pull`, pulled images or an edited `.env` | `systemctl reload pathfinder` (recreates what changed) |
| logs of one service | `docker compose logs -f <service>` (the unit itself logs only the compose calls: `journalctl -u pathfinder`) |

`stop` removes the containers, so their `docker compose logs` go with them; the `postgres-data` volume and every
file in this directory stay. A crashed container is restarted by Docker itself (`restart: always`), the unit is
not involved. Re-render the unit after a change of `pathfinder.service` in the repository (same `sed`, then
`systemctl daemon-reload`).

## TLS

The edge proxy (Caddy) obtains and renews both certificates itself over an ACME HTTP challenge and keeps them in
`edge-data/`. There is no certbot, no cron job and no renewal hook to maintain. Private keys never leave the
host - `edge-data/` is gitignored, and so is `.env`.

After any change of a name in `.env`: `docker compose up -d edge`, then
`docker compose logs edge | grep -iE "certificate|obtain|error"`. A name that does not resolve to this host
fails the challenge; Caddy then retries with a growing backoff, so fix the DNS record and
`docker compose restart edge` instead of waiting.

## Updating a component

1. Bump the image tag of the service in `docker-compose.yml` (component repositories publish
   `ghcr.io/beiroun/<repo>:X.Y.Z` on their `vX.Y.Z` tags; `latest` does not exist).
2. Commit and push the umbrella repository.
3. On the server:

```bash
cd /opt/pathfinder/deployment && git pull
docker compose pull <service>
docker compose up -d <service>
```

With the system service installed, the last two lines are `systemctl reload pathfinder`.

### Pushing from the laptop (`push.sh`)

The same update without logging in by hand: `push.sh` uploads the deployment files over sftp and runs the steps
above on the host - `docker compose pull`, then `systemctl reload pathfinder`, then `docker compose ps`. Where
the host is and how to log in come from `deployment/.deploy.env` (gitignored; copy `.deploy.env.example` and
fill `PF_DEPLOY_TARGET`, `PF_DEPLOY_PORT`, `PF_DEPLOY_DIR` and `PF_DEPLOY_KEY`). sftp runs in batch mode and
cannot ask for a password, so the login is a key: `ssh-keygen -t ed25519 -f ~/.ssh/pathfinder -N ''`, then
`ssh-copy-id -i ~/.ssh/pathfinder.pub -p <port> <user@host>` once (that asks the password), then
`PF_DEPLOY_KEY=~/.ssh/pathfinder`. A password is possible instead (`PF_DEPLOY_PASSWORD`, needs `sshpass` on
the laptop), the key is cleaner.

```bash
deployment/push.sh                 # docker-compose.yml, Caddyfile, pathfinder.service -> pull -> reload
deployment/push.sh .env            # one named file instead, on purpose only - the live copy belongs to the host
deployment/push.sh --restart       # stop + start of the whole stack instead of a reload
deployment/push.sh --dry-run       # show the sftp batch and the remote commands, change nothing
```

When `pathfinder.service` is among the sent files the unit is re-rendered with the host's path and
`systemctl daemon-reload` runs, as in "System service". The files still go through git as before - the script
only replaces the `git pull` on the host with an upload of what is on the laptop, committed or not.

## Pinned versions

Nothing runs or builds from a floating version (rule of 2026-10-22). Every external input is pinned exactly, and a
bump is a deliberate change of the pin:

| Where | Pin |
|---|---|
| this compose | `postgres:18.6-trixie@sha256:edb0c08d…` (PostgreSQL 18.6-1.pgdg13+2), `caddy:2.11.7@sha256:3095ad24…`; own images by exact `X.Y.Z` |
| server image | Dockerfile frontend `docker/dockerfile:1.28.0@sha256:…`, `eclipse-temurin:25.0.4.1_1-jdk-noble` / `-jre-noble` by digest, Gradle `9.8.0` with `distributionSha256Sum`, libraries by exact version (Spring Boot BOM) |
| console image | the same frontend, `node:24.22.1-trixie-slim`, `nginx:1.30.6-trixie` by digest, npm packages from `package-lock.json` (`npm ci`) |
| CI | GitHub Actions by commit SHA (version in a comment), buildx `v0.38.1`, BuildKit `moby/buildkit:v0.34.1@sha256:…`, runner `ubuntu-24.04` |

A digest is pinned next to the tag (`image:tag@sha256:…`): the tag says what it is, the digest makes it immutable
- Docker pulls by the digest. It is the multi-platform index, so the same line works on an amd64 host and an arm64
laptop. Tags are not immutable on Docker Hub: `caddy:2.11.7` was rebuilt on 2026-10-21, a week after this file
first named it.

Bumping a pin: pick the exact new version, check **before** writing it down that it resolves and downloads
(registry API: tag -> index digest -> linux/amd64 manifest -> every layer blob answers; `git ls-remote` for an
action's tag), write tag and digest together, let CI build it, then update. A database bump is its own event: a
minor of the same major is a restart, a new major needs `pg_upgrade` or a dump.

## Rollback

Revert the tag in `docker-compose.yml` (or `git revert` the bump), `git pull` on the server,
`docker compose up -d <service>`. The previous image is still in the local cache, so the rollback is seconds.
Database migrations are forward-only: rolling the server back past a migration needs a restore of
`postgres-data`, not just an older image.

## Checks

```bash
docker compose ps
curl -s http://127.0.0.1:8080/api/v1/info                           # server, directly on loopback
curl -s http://127.0.0.1:8080/system/health                         # {"status":"UP"}
curl -s http://127.0.0.1:8081/api/v1/info                           # console nginx -> server
curl -s https://pathfinder-console.<domain>/api/v1/info             # edge -> console nginx -> server
curl -s https://pathfinder.<domain>/api/v1/info                     # edge -> server
curl -sI https://pathfinder.<domain>/r/<slug> | head -3             # 302 + Location of a real code
curl -s -o /dev/null -w '%{http_code}\n' https://pathfinder.<domain>/system/info   # 404: closed on the edge
docker compose exec edge find /data/caddy/certificates -name '*.crt'   # which names hold a certificate
docker compose logs --since 10m server | grep "Scan redirected"     # one line per scan: slug, platform, target
```

## Backup

What matters on the host: `.env` and the `postgres-data` volume (Docker name `pathfinder_postgres-data`; the
codes, their targets and the scan counters). `docker compose exec postgres pg_dump -U pathfinder pathfinder >
pathfinder-$(date +%F).sql` for a logical dump. Images are reproducible from the registry and need no backup.

`edge-data/` is worth keeping too, though it is not critical: the certificates would be re-issued on a fresh
host automatically. What a backup saves is the ACME account and a brush with the CA's rate limits when a host
is rebuilt repeatedly.
