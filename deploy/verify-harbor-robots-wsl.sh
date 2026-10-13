#!/usr/bin/env bash
set -Eeuo pipefail

lab_dir="$HOME/austin-harbor"
image=harbor.local:8443/demo/austin:robot-smoke
docker image inspect austin-cicd:local-fixed >/dev/null

scratch=$(mktemp -d)
if [[ "$scratch" != /tmp/* ]]; then
  echo 'Unexpected temporary directory' >&2
  exit 2
fi
trap 'rm -rf -- "$scratch"' EXIT
chmod 700 "$scratch"

login_as() {
  local role=$1
  local config="$scratch/$role"
  local credentials
  mapfile -t credentials < <(python3 - "$lab_dir/robots/$role.json" <<'PY'
import json
import sys
data = json.load(open(sys.argv[1]))
print(data['name'])
print(data['secret'])
PY
)
  [[ ${#credentials[@]} == 2 ]] || { echo "Missing $role credentials" >&2; exit 2; }
  mkdir -p "$config"
  printf '%s\n' "${credentials[1]}" | DOCKER_CONFIG="$config" docker login harbor.local:8443 \
    --username "${credentials[0]}" --password-stdin >/dev/null
  unset credentials
}

login_as ci-push
docker tag austin-cicd:local-fixed "$image"
DOCKER_CONFIG="$scratch/ci-push" docker push "$image" >/dev/null

login_as deploy-pull
DOCKER_CONFIG="$scratch/deploy-pull" docker pull "$image" >/dev/null
denied=harbor.local:8443/demo/austin:robot-pull-denied
docker tag austin-cicd:local-fixed "$denied"
if DOCKER_CONFIG="$scratch/deploy-pull" docker push "$denied" >"$scratch/denied.log" 2>&1; then
  echo 'Pull-only robot unexpectedly gained push permission' >&2
  exit 1
fi
echo 'CI robot pushed, deployment robot pulled, and deployment robot was denied push.'
