#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Andrei Baranov (84softworks). Licensed under the Business Source License 1.1 - see LICENSE.
#
# Deploys Pathfinder onto a host whose ports 80/443 already belong to another product's edge proxy (ThunderVox):
# no edge of its own, loopback ports moved off the neighbour's (docker-compose.shared-edge.yml), and its two site
# blocks handed to the neighbour's Caddy. Idempotent: the first run brings Pathfinder up, every later run applies
# the current files of this directory. Run from the laptop.
#
#   deployment/cohost.sh              check the host, send the files, start or reload pathfinder.service, then
#                                     render shared-edge.caddy into the neighbour's sites directory and reload it
#   deployment/cohost.sh --dry-run    print what would be checked, sent and run; touch nothing
#
# What the neighbour has to offer (ThunderVox from v0.19 of its umbrella): its edge container mounts a host
# directory at /etc/caddy/sites and its Caddyfile says `import sites/*.caddy`. The script finds that directory
# through `docker inspect`, so only the container's name is configured.
#
# Configuration - deployment/.deploy.env (gitignored; see .deploy.env.example) or the environment:
#   PF_DEPLOY_TARGET           user@host                                        (required)
#   PF_DEPLOY_PORT             ssh port                                         (default 22)
#   PF_DEPLOY_DIR              where this directory lives on the host           (default /opt/pathfinder/deployment)
#   PF_DEPLOY_KEY              private key for the login                        (recommended)
#   PF_DEPLOY_PASSWORD         password for the login                           (fallback; needs sshpass)
#   PF_SHARED_EDGE_CONTAINER   the neighbour's edge container                   (default thundervox-edge)
#
# .env travels with every run (the previous copy on the host is kept as .env.prev) and must select the shared
# edge: COMPOSE_FILE=docker-compose.yml:docker-compose.shared-edge.yml. Nothing on the host is removed.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# The deployment directory: the script's own or the nearest parent with the compose files (a copy of this script
# in deployment/private next to .deploy.env finds them one level up)
deploy_dir=$script_dir
while [[ ! -f "$deploy_dir/docker-compose.yml" || ! -f "$deploy_dir/docker-compose.shared-edge.yml" ]]; do
  if [[ $deploy_dir == / ]]; then
    echo "no deployment directory (docker-compose.yml + docker-compose.shared-edge.yml) at or above $script_dir" >&2
    exit 1
  fi
  deploy_dir=$(dirname "$deploy_dir")
done

# A variable set in the calling shell wins, then the env file next to the script, then the deployment directory's
shell_target=${PF_DEPLOY_TARGET:-}
shell_port=${PF_DEPLOY_PORT:-}
shell_dir=${PF_DEPLOY_DIR:-}
shell_key=${PF_DEPLOY_KEY:-}
shell_password=${PF_DEPLOY_PASSWORD:-}
shell_edge=${PF_SHARED_EDGE_CONTAINER:-}
for env_file in "$script_dir/.deploy.env" "$deploy_dir/.deploy.env"; do
  if [[ -f $env_file ]]; then
    # shellcheck disable=SC1090
    source "$env_file"
    break
  fi
done

target=${shell_target:-${PF_DEPLOY_TARGET:-}}
port=${shell_port:-${PF_DEPLOY_PORT:-22}}
remote_dir=${shell_dir:-${PF_DEPLOY_DIR:-/opt/pathfinder/deployment}}
key=${shell_key:-${PF_DEPLOY_KEY:-}}
password=${shell_password:-${PF_DEPLOY_PASSWORD:-}}
edge_container=${shell_edge:-${PF_SHARED_EDGE_CONTAINER:-thundervox-edge}}

dry_run=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) dry_run=1 ;;
    -h | --help) sed -n '4,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z $target ]]; then
  echo "PF_DEPLOY_TARGET is not set: put user@host into deployment/.deploy.env (see .deploy.env.example)" >&2
  exit 2
fi

# ---- The laptop's .env: the one file whose mistakes would only show on the host. Values are never printed ----
env_path="$deploy_dir/.env"
if [[ ! -f $env_path ]]; then
  echo "no deployment/.env - copy .env.example and fill it" >&2
  exit 2
fi
env_value() {
  # The last assignment wins, as in Compose; surrounding quotes are not part of the value
  sed -n "s/^$1=//p" "$env_path" | tail -1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}
expected_compose_file="docker-compose.yml:docker-compose.shared-edge.yml"
if [[ $(env_value COMPOSE_FILE) != "$expected_compose_file" ]]; then
  echo ".env must select the shared edge: COMPOSE_FILE=$expected_compose_file" >&2
  exit 2
fi
# PF_ACME_EMAIL is unused with a shared edge (the neighbour's account issues the certificates), but Compose reads
# the whole docker-compose.yml, the disabled edge service included, and that one fails on an empty value
for name in PF_SERVER_HOST PF_CONSOLE_HOST PF_DB_PASSWORD PF_JWT_SECRET PF_ADMIN_USERS PF_ACME_EMAIL; do
  if [[ -z $(env_value "$name") ]]; then
    echo ".env: $name is empty" >&2
    exit 2
  fi
done
server_host=$(env_value PF_SERVER_HOST)
console_host=$(env_value PF_CONSOLE_HOST)
host_name_pattern='^[A-Za-z0-9.-]+$'
if [[ ! $server_host =~ $host_name_pattern || ! $console_host =~ $host_name_pattern ]]; then
  echo ".env: PF_SERVER_HOST / PF_CONSOLE_HOST must be bare host names (no scheme, no path)" >&2
  exit 2
fi

# ---- Login: a key (IdentitiesOnly, so a wrong agent key does not burn the server's attempt limit), a password
#      through sshpass, or whatever the ssh agent offers ----
ssh_opts=(-p "$port")
sftp_opts=(-P "$port")
if [[ -n $key ]]; then
  key=${key/#\~/$HOME}
  if [[ ! -f $key ]]; then
    echo "PF_DEPLOY_KEY is not a file: $key" >&2
    exit 2
  fi
  ssh_opts+=(-i "$key" -o IdentitiesOnly=yes)
  sftp_opts+=(-i "$key" -o IdentitiesOnly=yes)
fi
runner=()
if [[ -n $password ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "PF_DEPLOY_PASSWORD needs sshpass on the laptop (brew install hudochenkov/sshpass/sshpass)" >&2
    exit 2
  fi
  # -e reads the password from SSHPASS, so it never appears in the process list
  export SSHPASS=$password
  runner=(sshpass -e)
fi

files=(docker-compose.yml docker-compose.shared-edge.yml console-shared-edge.conf shared-edge.caddy pathfinder.service .env)

# ---- Step 1 on the host: refuse early, before anything is sent, when the host cannot take Pathfinder ----
preflight=$(
  cat <<EOF
set -euo pipefail
fail() { echo "preflight: \$*" >&2; exit 3; }
command -v docker >/dev/null || fail "docker is not installed"
docker compose version >/dev/null 2>&1 || fail "the docker compose plugin is missing"
command -v curl >/dev/null || fail "curl is not installed"
[[ \$(docker inspect -f '{{.State.Running}}' '$edge_container' 2>/dev/null) == true ]] \\
  || fail "the neighbour's edge container '$edge_container' is not running"
sites_dir=\$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/sites"}}{{.Source}}{{end}}{{end}}' '$edge_container')
[[ -n \$sites_dir ]] || fail "'$edge_container' mounts no /etc/caddy/sites - deploy the neighbour's shared-sites edge first (ThunderVox: deploy/push.sh docker-compose.yml Caddyfile)"
docker exec '$edge_container' grep -q '^import sites/' /etc/caddy/Caddyfile \\
  || fail "the Caddyfile of '$edge_container' does not import sites/*.caddy - deploy the neighbour's Caddyfile first"
# Pathfinder's loopback ports are either free or held by Pathfinder itself (a repeated run)
for port_in_use in 5433 8090 8091; do
  if ss -ltnH "sport = :\$port_in_use" | grep -q .; then
    docker ps --format '{{.Names}}' | grep -q '^pathfinder-' \\
      || fail "127.0.0.1:\$port_in_use is taken by something that is not Pathfinder"
  fi
done
mkdir -p '$remote_dir'
echo "preflight ok: edge $edge_container, its sites directory \$sites_dir"
EOF
)

# ---- Step 2: the files. .env is moved aside to .env.prev first (one generation, to undo a wrong push) ----
sftp_batch=$(
  printf 'cd %s\n' "$remote_dir"
  printf -- '-rm .env.prev\n'
  printf -- '-rename .env .env.prev\n'
  for file in "${files[@]}"; do
    printf 'put %s\n' "$deploy_dir/$file"
  done
)

# ---- Step 3: start or reload Pathfinder, wait until it answers on loopback, then hand its names to the edge ----
apply=$(
  cat <<EOF
set -euo pipefail
cd '$remote_dir'
chmod 600 .env .env.prev 2>/dev/null || true
# Both compose files and .env must parse before anything is (re)started; there is no edge-data here - the
# certificates are the neighbour's
docker compose config --quiet
sed "s#/opt/pathfinder/deployment#\$PWD#" pathfinder.service > /etc/systemd/system/pathfinder.service
systemctl daemon-reload
systemctl enable pathfinder >/dev/null 2>&1
docker compose pull --quiet
if systemctl is-active --quiet pathfinder; then systemctl reload pathfinder; else systemctl start pathfinder; fi

echo "waiting for the server on 127.0.0.1:8090 ..."
for attempt in \$(seq 1 60); do
  curl -fsS -o /dev/null http://127.0.0.1:8090/system/health && break
  [[ \$attempt -eq 60 ]] && { docker compose ps; docker compose logs --tail 50 server; echo "the server did not come up" >&2; exit 4; }
  sleep 2
done
curl -fsS -o /dev/null http://127.0.0.1:8091/api/v1/info || { echo "the console's nginx does not reach the server" >&2; exit 4; }
echo "pathfinder answers on loopback"

# The edge: render the site blocks, keep the previous file, validate the neighbour's whole config with them, and
# put the previous file back if it does not validate - a broken file would fail the neighbour's edge at its next start
sites_dir=\$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/caddy/sites"}}{{.Source}}{{end}}{{end}}' '$edge_container')
site_file="\$sites_dir/pathfinder.caddy"
[[ -f \$site_file ]] && cp -p "\$site_file" "\$site_file.prev"
sed -e 's/__PF_SERVER_HOST__/$server_host/g' -e 's/__PF_CONSOLE_HOST__/$console_host/g' shared-edge.caddy > "\$site_file.new"
chmod 644 "\$site_file.new"
mv "\$site_file.new" "\$site_file"
if ! docker exec '$edge_container' caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  docker exec '$edge_container' caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile || true
  if [[ -f "\$site_file.prev" ]]; then mv "\$site_file.prev" "\$site_file"; else rm -f "\$site_file"; fi
  echo "the edge config with pathfinder.caddy does not validate - the previous state is back, the edge untouched" >&2
  exit 5
fi
docker exec '$edge_container' caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
echo "edge reloaded with $server_host and $console_host"

docker compose ps
# Through the edge on this host (no DNS, no CDN): the certificate may still be on its way, so -k
for probe in "$server_host/system/health" "$console_host/api/v1/info"; do
  name=\${probe%%/*}
  code=\$(curl -sk -o /dev/null -w '%{http_code}' --resolve "\$name:443:127.0.0.1" "https://\$probe" || true)
  echo "https://\$probe via the local edge: \$code (000 = no certificate yet)"
done
echo "certificate log of the edge (issuance runs in the background, the first one takes up to a minute):"
sleep 20
docker logs --since 3m '$edge_container' 2>&1 | grep -E "$server_host|$console_host" | grep -iE "obtain|certificate|error|challenge" | tail -n 8 || true
EOF
)

login_how="ssh agent / default keys"
[[ -n $key ]] && login_how="key $key"
[[ -n $password ]] && login_how="password via sshpass"
echo "target: $target (port $port, $login_how), dir: $remote_dir, neighbour edge: $edge_container"
echo "names:  $server_host, $console_host"
echo "files:  ${files[*]}"

if [[ $dry_run -eq 1 ]]; then
  printf '\n--- preflight on the host ---\n%s\n' "$preflight"
  printf '\n--- sftp batch ---\n%s\n' "$sftp_batch"
  printf '\n--- apply on the host ---\n%s\n' "$apply"
  exit 0
fi

ssh_run() { ${runner[@]+"${runner[@]}"} ssh "${ssh_opts[@]}" "$target" "$1"; }

if ! ssh_run "$preflight"; then
  echo "nothing was sent or changed on the host" >&2
  exit 1
fi
${runner[@]+"${runner[@]}"} sftp "${sftp_opts[@]}" -b - "$target" <<<"$sftp_batch"
ssh_run "$apply"

cat <<EOF

Done. From outside: https://$console_host (log in with a pair from PF_ADMIN_USERS),
                    https://$server_host/system/health
The first certificate is issued in the background within a minute (Cloudflare 525 until then). Undo: put .env.prev
back, or remove pathfinder.caddy from the neighbour's sites directory and reload its edge; \`systemctl disable --now
pathfinder\` stops Pathfinder.
EOF
