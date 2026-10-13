#!/usr/bin/env bash
set -Eeuo pipefail

image_source=${1:-austin-cicd:local}
image_target=harbor.local:8443/demo/austin:lab-smoke
lab_dir="$HOME/austin-harbor"
test -f "$lab_dir/admin-password" || { echo 'Prepare Harbor first' >&2; exit 2; }
docker image inspect "$image_source" >/dev/null

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
  --data '{"project_name":"demo","metadata":{"public":"false"}}' \
  https://harbor.local:8443/api/v2.0/projects)
if [[ "$response_code" != 201 && "$response_code" != 409 ]]; then
  echo "Harbor project creation failed (HTTP $response_code)" >&2
  cat "$scratch/response" >&2
  exit 1
fi

export DOCKER_CONFIG="$scratch/docker"
mkdir -p "$DOCKER_CONFIG"
cat "$lab_dir/admin-password" | docker login harbor.local:8443 \
  --username admin --password-stdin >/dev/null
docker tag "$image_source" "$image_target"
docker push "$image_target"
docker pull "$image_target"
echo "Pushed and pulled $image_target through Harbor"
