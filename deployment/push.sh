#!/usr/bin/env bash
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Andrei Baranov (84softworks). Licensed under the Business Source License 1.1 - see LICENSE.
#
# Pushes the deployment files of this directory to the host over sftp and applies them: images are pulled and the
# system service is reloaded (changed containers are recreated). Run from the laptop; the host needs nothing
# beyond sshd, docker and the installed pathfinder.service (RUNBOOK.md "System service").
#
#   deployment/push.sh                  send docker-compose.yml, Caddyfile, pathfinder.service; pull; reload
#   deployment/push.sh .env             send one named file instead (any file of this directory)
#   deployment/push.sh --restart        stop the whole stack and start it again instead of a reload - only when
#                                       a reload cannot do it (Postgres restarts too)
#   deployment/push.sh --dry-run        print what would be sent and run, touch nothing
#
# Where the host is and how to log in come from deployment/.deploy.env (gitignored - the real address, port and
# key stay out of this public repository; see .deploy.env.example) or from the environment:
#   PF_DEPLOY_TARGET    user@host of the server                (required)
#   PF_DEPLOY_PORT      ssh port                               (default 22)
#   PF_DEPLOY_DIR       the umbrella's deployment/ on the host (default /opt/pathfinder/deployment)
#   PF_DEPLOY_KEY       private key for the login               (recommended; without it the ssh agent / default
#                                                                keys are tried - sftp runs in batch mode and
#                                                                cannot ask for a password)
#   PF_DEPLOY_PASSWORD  password for the login                  (fallback; needs sshpass on the laptop)
#
# .env is NOT in the default set: the live copy belongs to the host, and a stale laptop copy would silently
# overwrite it. Name it explicitly to push a local copy on purpose.
set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

# The deployment directory is the script's own or the nearest parent that holds the compose file and the unit: a
# copy (or symlink) of this script kept in deployment/private next to .deploy.env - gitignored, a natural place
# for the host's address - finds the files one level up instead of failing on its own directory.
deploy_dir=$script_dir
while [[ ! -f "$deploy_dir/docker-compose.yml" || ! -f "$deploy_dir/pathfinder.service" ]]; do
  if [[ $deploy_dir == / ]]; then
    echo "no deployment directory (docker-compose.yml + pathfinder.service) at or above $script_dir" >&2
    exit 1
  fi
  deploy_dir=$(dirname "$deploy_dir")
done

# The host and the login: a variable set in the calling shell wins (a one-off push elsewhere), otherwise the env
# file next to the script (deployment/private/.deploy.env), otherwise the one in the deployment directory.
shell_target=${PF_DEPLOY_TARGET:-}
shell_port=${PF_DEPLOY_PORT:-}
shell_dir=${PF_DEPLOY_DIR:-}
shell_key=${PF_DEPLOY_KEY:-}
shell_password=${PF_DEPLOY_PASSWORD:-}
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

action=reload
dry_run=0
files=()

usage() {
  sed -n '4,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --restart) action=restart ;;
    --dry-run) dry_run=1 ;;
    -h | --help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) files+=("$1") ;;
  esac
  shift
done

if [[ -z $target ]]; then
  echo "PF_DEPLOY_TARGET is not set: put user@host into deployment/.deploy.env (see .deploy.env.example)" >&2
  exit 2
fi

# ---- Login: a key (IdentitiesOnly so a wrong agent key does not burn the server's attempt limit), or a password
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

# runner prefixes every ssh/sftp call; empty unless a password is used (bash 3.2 needs the ${arr[@]+...} form)
runner=()
if [[ -n $password ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "PF_DEPLOY_PASSWORD needs sshpass on the laptop (brew install hudochenkov/sshpass/sshpass)." >&2
    echo "Cleaner: a key - ssh-keygen -t ed25519 -f ~/.ssh/pathfinder -N '' && ssh-copy-id -i ~/.ssh/pathfinder.pub -p $port $target, then PF_DEPLOY_KEY=~/.ssh/pathfinder" >&2
    exit 2
  fi
  # -e reads the password from SSHPASS, so it never appears in the process list
  export SSHPASS=$password
  runner=(sshpass -e)
fi

login_hint() {
  echo >&2
  echo "Login to $target failed. Either hand the script a key:" >&2
  echo "  ssh-keygen -t ed25519 -f ~/.ssh/pathfinder -N '' && ssh-copy-id -i ~/.ssh/pathfinder.pub -p $port $target" >&2
  echo "  then PF_DEPLOY_KEY=~/.ssh/pathfinder in deployment/.deploy.env" >&2
  echo "or a password: PF_DEPLOY_PASSWORD=... (needs sshpass). sftp runs in batch mode and cannot ask for one." >&2
}

if [[ ${#files[@]} -eq 0 ]]; then
  files=(docker-compose.yml Caddyfile pathfinder.service)
fi

for file in "${files[@]}"; do
  if [[ $file == */* || ! -f "$deploy_dir/$file" ]]; then
    echo "not a file of $deploy_dir: $file" >&2
    exit 1
  fi
done

# Site-local files are never created by this script as directories or left half-written: sftp writes them whole.
sftp_batch=$(
  printf 'cd %s\n' "$remote_dir"
  for file in "${files[@]}"; do
    printf 'put %s\n' "$deploy_dir/$file"
  done
)

unit_sent=0
for file in "${files[@]}"; do
  [[ $file == pathfinder.service ]] && unit_sent=1
done

# On the host: re-render the unit when it was sent (the committed file carries the canonical path), pull the
# images the compose file now pins, then reload (or restart) the service and show what runs.
remote_script=$(
  cat <<EOS
set -euo pipefail
cd '$remote_dir'
if [[ $unit_sent -eq 1 ]]; then
  sed "s#/opt/pathfinder/deployment#\$PWD#" pathfinder.service > /etc/systemd/system/pathfinder.service
  systemctl daemon-reload
  echo "unit re-rendered for \$PWD"
fi
docker compose pull --quiet
systemctl $action pathfinder
docker compose ps
EOS
)

login_how="ssh agent / default keys"
[[ -n $key ]] && login_how="key $key"
[[ -n $password ]] && login_how="password via sshpass"
echo "target: $target (port $port, $login_how), dir: $remote_dir"
echo "files:  ${files[*]}"
echo "then:   docker compose pull; systemctl $action pathfinder"

if [[ $dry_run -eq 1 ]]; then
  echo
  echo "--- sftp batch ---"
  echo "$sftp_batch"
  echo "--- remote ---"
  echo "$remote_script"
  exit 0
fi

if ! ${runner[@]+"${runner[@]}"} sftp "${sftp_opts[@]}" -b - "$target" <<<"$sftp_batch"; then
  login_hint
  exit 1
fi
${runner[@]+"${runner[@]}"} ssh "${ssh_opts[@]}" "$target" "$remote_script"
