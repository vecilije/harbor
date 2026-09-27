#!/usr/bin/env bash
# Deploys the harbor stack to the Swarm that DOCKER_HOST points at, then makes sure
# every database in databases.txt exists with its own user and password.
#
# Environment:
#   DOCKER_HOST  e.g. ssh://vm
#   ACME_EMAIL   Let's Encrypt account email
#   SECRETS      JSON object with POSTGRES_ROOT_PASSWORD, MONGO_ROOT_PASSWORD and
#                <ENGINE>_PASSWORD_<NAME> for every line of databases.txt
set -euo pipefail
cd "$(dirname "$0")"

: "${ACME_EMAIL:?}" "${SECRETS:?}"
stack=harbor

fail() { echo "$*" >&2; exit 1; }

# Passwords end up in connection strings, SQL and JavaScript, so keep them to URL-safe characters.
secret() {
  local value
  value=$(jq -r --arg key "$1" '.[$key] // empty' <<<"$SECRETS")
  [[ -n $value ]] || fail "Missing GitHub secret $1"
  [[ $value =~ ^[A-Za-z0-9_-]{16,}$ ]] ||
    fail "$1 must be at least 16 characters of A-Z a-z 0-9 _ - (try: openssl rand -hex 32)"
  printf '%s' "$value"
}

short_hash() { sha256sum | cut -c1-12; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Build the setup scripts first, so a missing secret stops the deploy before anything changes.
postgres_root=$(secret POSTGRES_ROOT_PASSWORD)
mongo_root=$(secret MONGO_ROOT_PASSWORD)
printf '%s' "$postgres_root" >"$tmp/postgres_root_password"
printf '%s' "$mongo_root" >"$tmp/mongo_root_password"
echo "ALTER ROLE postgres WITH PASSWORD '$postgres_root';" >"$tmp/postgres.sql"
echo "db.getSiblingDB('admin').auth('root', '$mongo_root');" >"$tmp/mongo.js"

while IFS= read -r line || [[ -n $line ]]; do
  read -r engine name extra <<<"${line%%#*}"
  [[ -n $engine ]] || continue
  [[ $engine =~ ^(postgres|mongo)$ && $name =~ ^[a-z][a-z0-9_]*$ && -z $extra ]] ||
    fail "databases.txt: expected '<postgres|mongo> <name>', got '$line'"
  password=$(secret "${engine^^}_PASSWORD_${name^^}")
  if [[ $engine == postgres ]]; then
    cat >>"$tmp/postgres.sql" <<SQL
\echo postgres database $name
SELECT 'CREATE ROLE "$name"' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$name')\gexec
ALTER ROLE "$name" WITH LOGIN PASSWORD '$password';
SELECT 'CREATE DATABASE "$name" OWNER "$name"' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$name')\gexec
REVOKE ALL ON DATABASE "$name" FROM PUBLIC;
SQL
  else
    cat >>"$tmp/mongo.js" <<JS
{
  const app = db.getSiblingDB('$name');
  const user = { pwd: '$password', roles: [{ role: 'readWrite', db: '$name' }] };
  if (app.getUser('$name')) app.updateUser('$name', user); else app.createUser({ user: '$name', ...user });
  print('mongo database $name');
}
JS
  fi
done <databases.txt

export ACME_EMAIL SECRETS_DIR=$tmp
POSTGRES_ROOT_PASSWORD_HASH=$(short_hash <"$tmp/postgres_root_password")
MONGO_ROOT_PASSWORD_HASH=$(short_hash <"$tmp/mongo_root_password")
BACKUP_SCRIPT_HASH=$(short_hash <backup.sh)
export POSTGRES_ROOT_PASSWORD_HASH MONGO_ROOT_PASSWORD_HASH BACKUP_SCRIPT_HASH

# public has a fixed subnet so apps can trust the forwarded headers Traefik sends from it.
docker network inspect public >/dev/null 2>&1 ||
  docker network create --driver overlay --attachable --subnet 10.200.0.0/16 public
docker network inspect db >/dev/null 2>&1 ||
  docker network create --driver overlay --attachable db

docker stack deploy --prune --detach=false -c stack.yml "$stack"

# Prints the running container of a service once a check passes inside it. Checks connect
# through the container's own address: while a new data directory is initialised, both
# images run a temporary server that only listens locally.
ready_container() {
  local id
  for _ in {1..60}; do
    id=$(docker ps -q --filter "label=com.docker.swarm.service.name=${stack}_$1" --filter status=running | head -n1)
    if [[ -n $id ]] && docker exec "$id" sh -c "$2" >/dev/null 2>&1; then
      echo "$id"
      return
    fi
    sleep 5
  done
  fail "$1 did not become ready"
}

# Over the local socket, so this works even when the root password is being changed.
postgres=$(ready_container postgres 'pg_isready -q -h "$(hostname)"')
docker exec -i "$postgres" psql -q -v ON_ERROR_STOP=1 -U postgres <"$tmp/postgres.sql"

# --file (unlike stdin) stops at the first error and exits non-zero.
mongo=$(ready_container mongo 'mongosh --quiet --host "$(hostname)" --eval "db.adminCommand({ ping: 1 })"')
docker exec -i "$mongo" sh -c \
  'cat >/tmp/setup.js && mongosh --quiet --host "$(hostname)" --file /tmp/setup.js; status=$?; rm -f /tmp/setup.js; exit $status' \
  <"$tmp/mongo.js"

# Drop secrets and configs left by earlier deploys; Docker refuses to remove ones still in use.
for kind in secret config; do
  docker "$kind" ls -q --filter "label=com.docker.stack.namespace=$stack" |
    xargs -r docker "$kind" rm >/dev/null 2>&1 || true
done
