#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
test_home=$(mktemp -d)
trap 'rm -rf -- "$test_home"' EXIT
export HOME="$test_home"
mkdir -p "$HOME/austin-cicd/schema" "$HOME/bin"
: > "$HOME/austin-cicd/.env"
: > "$HOME/austin-cicd/schema/austin.sql"

cat > "$HOME/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *'up -d --no-deps austin'* ]]; then
  printf '%s\n' "$AUSTIN_IMAGE" > "$HOME/live-image"
fi
EOF

cat > "$HOME/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$(<"$HOME/live-image")" == *'sha-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ]]; then
  printf '{"status":"DOWN"}'
  exit 22
fi
printf '{"status":"UP"}'
EOF

cat > "$HOME/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$HOME/bin/docker" "$HOME/bin/curl" "$HOME/bin/sleep"
export PATH="$HOME/bin:$PATH"

first=harbor.example.com/demo/austin:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
bad=harbor.example.com/demo/austin:sha-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
third=harbor.example.com/demo/austin:sha-cccccccccccccccccccccccccccccccccccccccc

bash "$repo_root/deploy/deploy.sh" "$first"
[[ "$(<"$HOME/austin-cicd/current-image")" == "$first" ]]

if bash "$repo_root/deploy/deploy.sh" "$bad"; then
  echo 'Unhealthy deployment unexpectedly succeeded' >&2
  exit 1
fi
[[ "$(<"$HOME/austin-cicd/current-image")" == "$first" ]]
[[ "$(<"$HOME/live-image")" == "$first" ]]

bash "$repo_root/deploy/deploy.sh" "$third"
[[ "$(<"$HOME/austin-cicd/current-image")" == "$third" ]]
[[ "$(<"$HOME/austin-cicd/previous-image")" == "$first" ]]
echo 'Deploy and rollback simulation passed'
