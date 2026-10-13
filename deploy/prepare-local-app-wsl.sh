#!/usr/bin/env bash
set -Eeuo pipefail

lab_dir="$HOME/austin-cicd"
install -d -m 700 "$lab_dir" "$lab_dir/schema"
if [[ ! -f "$lab_dir/.env" ]]; then
  umask 077
  printf 'MYSQL_ROOT_PASSWORD=%s\nREDIS_PASSWORD=%s\n' \
    "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" > "$lab_dir/.env"
  chmod 600 "$lab_dir/.env"
fi
install -m 644 deploy/compose.yml "$lab_dir/compose.yml"
install -m 755 deploy/deploy.sh "$lab_dir/deploy.sh"
install -m 644 doc/sql/austin.sql "$lab_dir/schema/austin.sql"
echo "Prepared Compose files at $lab_dir; existing .env was preserved."
