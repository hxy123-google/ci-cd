#!/usr/bin/env bash
set -Eeuo pipefail

# Synthetic SHA-shaped tags are confined to a separate Harbor lab-test project.
# They verify deployment behavior; they do not claim to identify Git commits.
registry=harbor.local:8443
project=lab-test
good="$registry/$project/austin:sha-1111111111111111111111111111111111111111"
bad="$registry/$project/austin:sha-2222222222222222222222222222222222222222"
lab_dir="$HOME/austin-harbor"
app_dir="$HOME/austin-cicd"

test -f "$lab_dir/admin-password"
test -f "$app_dir/.env"
docker image inspect austin-cicd:local-fixed >/dev/null
if ! docker image inspect redis:7-alpine >/dev/null 2>&1; then
  docker pull redis:7-alpine >/dev/null
fi

scratch=$(mktemp -d)
if [[ "$scratch" != /tmp/* ]]; then
  echo 'Unexpected temporary directory' >&2
  exit 2
fi
trap 'rm -rf -- "$scratch"' EXIT
chmod 700 "$scratch"
printf 'machine harbor.local login admin password %s\n' "$(<"$lab_dir/admin-password")" > "$scratch/netrc"
chmod 600 "$scratch/netrc"

response_code=$(curl --silent --show-error --output "$scratch/response" \
  --write-out '%{http_code}' --netrc-file "$scratch/netrc" \
  --header 'Content-Type: application/json' \
  --data '{"project_name":"lab-test","metadata":{"public":"false"}}' \
  "https://$registry/api/v2.0/projects")
if [[ "$response_code" != 201 && "$response_code" != 409 ]]; then
  echo "Harbor lab-test project creation failed (HTTP $response_code)" >&2
  cat "$scratch/response" >&2
  exit 1
fi

export DOCKER_CONFIG="$scratch/docker"
mkdir -p "$DOCKER_CONFIG"
cat "$lab_dir/admin-password" | docker login "$registry" \
  --username admin --password-stdin >/dev/null
docker tag austin-cicd:local-fixed "$good"
docker tag redis:7-alpine "$bad"
docker push "$good" >/dev/null
docker push "$bad" >/dev/null

AUSTIN_HEALTH_ATTEMPTS=30 AUSTIN_HEALTH_DELAY_SECONDS=2 \
  bash "$app_dir/deploy.sh" "$good"
if AUSTIN_HEALTH_ATTEMPTS=12 AUSTIN_HEALTH_DELAY_SECONDS=2 \
  bash "$app_dir/deploy.sh" "$bad"; then
  echo 'The intentionally broken image unexpectedly passed health checking' >&2
  exit 1
fi
actual=$(<"$app_dir/current-image")
[[ "$actual" == "$good" ]] || { echo "Rollback recorded $actual instead of $good" >&2; exit 1; }
curl --fail --silent --show-error http://127.0.0.1:7777/actuator/health \
  | grep -q '^{"status":"UP"'
echo 'Real Compose failure and automatic rollback succeeded.'
