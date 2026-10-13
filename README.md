# Pathfinder

**One QR code, the right destination for every device.** A printed code
encodes a single short link; when it is scanned, Pathfinder looks at the device
and sends it to the App Store, Google Play, Huawei AppGallery or a plain web
page. Every scan is counted per platform, and the codes are managed in a small
web console.

This is the **umbrella repository**: the project charter, licensing and the
deployment of the whole system. Code lives in the component repositories below.

---

## Components

| Repository | Role | Image |
|---|---|---|
| [`pathfinder-server`](https://github.com/beiroun/pathfinder-server) | The public redirect (`/r/<slug>`), platform detection by User-Agent, scan counters, QR image rendering, the management API with console logins | `ghcr.io/beiroun/pathfinder-server` |
| [`pathfinder-console`](https://github.com/beiroun/pathfinder-console) | Management console: create and edit codes, preview and download the image (PNG / SVG), copy the public link, read the per-platform statistics | `ghcr.io/beiroun/pathfinder-console` |
| `pathfinder` (this repo) | Charter, licensing, `docker-compose` of the whole system, deployment runbook, push script | — |

## How it fits together

```
 printed QR code ──scan──▶  https://pathfinder.<domain>/r/<slug>
                                        │
                                        ▼
                              ┌──────────────────┐   User-Agent -> iOS / Huawei / Android / desktop
                              │ pathfinder-server│──▶ 302 to the matching target, scan counted
                              └────────┬─────────┘
                                       │ JDBC
                              ┌────────▼─────────┐        /api (same origin, via nginx)
                              │    PostgreSQL    │   ◀──  ┌────────────────────┐
                              └──────────────────┘        │ pathfinder-console │
                                                          └────────────────────┘
```

- **Per-code targets.** Every code has its own four links: iOS, Huawei /
  Honor / HarmonyOS, Android and a desktop fallback. A blank platform link
  falls back to the desktop one, so a scan never lands on an empty address.
- **Resolution order matters.** iOS → Huawei → Android → everything else.
  Huawei is checked before Android because its devices also say "Android".
- **The slug is on paper.** It never changes after the code is created; the
  targets can change any time and take effect on the next scan.
- **Console access from the environment.** Administrators (edit) and viewers
  (read) are declared in `.env`; the server creates and updates those accounts
  on every start. There is no sign-up and no user management UI, on purpose.

## Principles

- **Own images for everything.** Each component repository builds its image
  from pinned sources and publishes it to GHCR on a tagged release
  (`vX.Y.Z` → `ghcr.io/beiroun/<repo>:X.Y.Z`, no `latest`). Only Docker
  Official Images are used as bases.
- **The host keeps only this repository.** A `docker-compose.yml`, a
  `Caddyfile` and `.env` — no component sources, no builds on the server.
  Updating a component means bumping an image tag.
- **One public name per face, one edge.** `pathfinder.<domain>` is the server
  (the address printed into the codes and the API), `pathfinder-console.<domain>`
  the console. The only container on 80/443 is the edge proxy, which obtains
  and renews both certificates itself; the console, the API and the database
  listen on loopback.
- **One host, Docker Compose, host networking.** The whole system runs on a
  single VPS.
- **Secrets stay out of git.** Passwords, logins and host names live in
  `deployment/.env`; the repository carries `.env.example`.

## Deployment (this repository)

```
deployment/
  docker-compose.yml    postgres, server, console, edge - pinned image tags
  Caddyfile             public names -> loopback services, automatic TLS
  .env.example          host names, ACME address, database password, console users
  pathfinder.service    the stack as one systemd unit
  push.sh               upload the files from the laptop, pull images, reload the service
  .deploy.env.example   where push.sh sends the files (the host's address stays out of git)
  RUNBOOK.md            bring-up, TLS, update, rollback, checks, backup
```

`docker compose up -d` in `deployment/` runs the whole system. See
[`deployment/RUNBOOK.md`](deployment/RUNBOOK.md).

Certificates and private keys are written by the edge proxy into
`deployment/edge-data/` on the host and are never committed: this repository
contains the names, not the key material.

## License

Pathfinder is released under the **Business Source License 1.1** — see
[`LICENSE`](LICENSE). The same license and parameters apply to every component
repository. Non-production use is free; production use beyond the Additional
Use Grant requires a commercial license from the Licensor.

Third-party components (PostgreSQL, Caddy, nginx, Spring, React, …) keep their
own licenses — see [`NOTICE`](NOTICE).

---

*Built by [Andrei Baranov](https://github.com/beiroun) · 84softworks*
