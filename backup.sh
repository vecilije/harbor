#!/bin/sh
# Dumps every database of ENGINE (postgres or mongo) into /backups/<db>/ once a day
# at BACKUP_HOUR (UTC) and deletes dumps older than BACKUP_KEEP_DAYS.
#
#   backup.sh                      run on schedule (the service command)
#   backup.sh now                  dump all databases once
#   backup.sh restore <db> <file>  replace a database's contents with a dump
set -eu

password=$(cat /run/secrets/root_password)

case "$ENGINE" in
  postgres)
    export PGHOST=postgres PGUSER=postgres PGPASSWORD="$password"
    list_databases() {
      psql -d postgres -Atc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'"
    }
    dump() { pg_dump -Fc -d "$1" -f "$2"; }
    restore() { pg_restore --clean --if-exists --single-transaction -d "$1" "$2"; }
    ;;
  mongo)
    list_databases() {
      mongosh --quiet --host mongo -u root -p "$password" --authenticationDatabase admin --eval \
        'db.adminCommand({ listDatabases: 1, nameOnly: true }).databases.map(d => d.name).filter(n => !["admin", "config", "local"].includes(n)).join("\n")'
    }
    dump() { mongodump --quiet --host mongo -u root -p "$password" --authenticationDatabase admin --db "$1" --gzip --archive="$2"; }
    restore() { mongorestore --host mongo -u root -p "$password" --authenticationDatabase admin --nsInclude "$1.*" --drop --gzip --archive="$2"; }
    ;;
  *)
    echo "ENGINE must be postgres or mongo" >&2
    exit 2
    ;;
esac

backup_all() {
  status=0
  stamp=$(date -u +%Y%m%d-%H%M%S)
  databases=$(list_databases) || {
    echo "backup: cannot list databases" >&2
    return 1
  }
  for db in $databases; do
    mkdir -p "/backups/$db"
    file="/backups/$db/$db-$stamp.dump"
    if dump "$db" "$file.partial"; then
      mv "$file.partial" "$file"
      echo "backup: $file"
    else
      rm -f "$file.partial"
      echo "backup: $db failed" >&2
      status=1
    fi
  done
  find /backups -type f -mtime +"${BACKUP_KEEP_DAYS:-14}" -delete
  return $status
}

case "${1:-}" in
  now)
    backup_all
    ;;
  restore)
    [ $# -eq 3 ] || { echo "usage: backup.sh restore <db> <file>" >&2; exit 2; }
    restore "$2" "$3"
    echo "restored $2 from $3"
    ;;
  "")
    while :; do
      now=$(date -u +%s)
      next=$((now / 86400 * 86400 + ${BACKUP_HOUR:-3} * 3600))
      [ "$next" -gt "$now" ] || next=$((next + 86400))
      sleep $((next - now))
      backup_all || true
    done
    ;;
  *)
    echo "usage: backup.sh [now | restore <db> <file>]" >&2
    exit 2
    ;;
esac
