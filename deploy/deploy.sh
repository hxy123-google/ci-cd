#!/usr/bin/env bash
set -Eeuo pipefail

image=${1:?usage: deploy.sh harbor-host/project/austin:sha-<40-character commit>}
if [[ ! "$image" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]{1,5})?/[a-z0-9][a-z0-9._-]*/austin:sha-[0-9a-f]{40}$ ]]; then
  echo "Expected a Harbor image tagged with a full commit SHA" >&2
  exit 2
fi

cd "$HOME/austin-cicd"
test -f .env || { echo "Create ~/austin-cicd/.env first" >&2; exit 2; }
test -f schema/austin.sql || { echo "Missing schema/austin.sql" >&2; exit 2; }

health_attempts=${AUSTIN_HEALTH_ATTEMPTS:-36}
health_delay=${AUSTIN_HEALTH_DELAY_SECONDS:-5}
[[ "$health_attempts" =~ ^[1-9][0-9]*$ ]] || { echo 'AUSTIN_HEALTH_ATTEMPTS must be positive' >&2; exit 2; }
[[ "$health_delay" =~ ^[0-9]+$ ]] || { echo 'AUSTIN_HEALTH_DELAY_SECONDS must be nonnegative' >&2; exit 2; }

previous=""
if [[ -f current-image ]]; then
  previous=$(<current-image)
fi

wait_for_health() {
  local attempt
  for (( attempt=1; attempt<=health_attempts; attempt++ )); do
    if curl --fail --silent --show-error --max-time 3 \
      http://127.0.0.1:7777/actuator/health 2>/dev/null | grep -q '^{"status":"UP"'; then
      return 0
    fi
    sleep "$health_delay"
  done
  return 1
}

restore_on_failure() {
  local status=$?
  trap - EXIT
  if (( status != 0 )) && [[ -n "$previous" && "$previous" != "$image" ]]; then
    echo "Deployment failed; restoring $previous" >&2
    AUSTIN_IMAGE="$previous" docker compose -f compose.yml up -d --no-deps austin || true
    if wait_for_health; then
      echo "Previous version is healthy" >&2
    else
      echo "Previous version did not become healthy; inspect docker compose logs" >&2
    fi
  fi
  exit "$status"
}

export AUSTIN_IMAGE="$image"
docker compose -f compose.yml up -d mysql redis
docker compose -f compose.yml pull austin

trap restore_on_failure EXIT
docker compose -f compose.yml up -d --no-deps austin
wait_for_health || { echo "New version failed health check" >&2; exit 1; }

if [[ -n "$previous" && "$previous" != "$image" ]]; then
  printf '%s\n' "$previous" > previous-image
fi
printf '%s\n' "$image" > current-image
echo "Deployed $image and passed /actuator/health"
