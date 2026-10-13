#!/usr/bin/env bash
set -Eeuo pipefail

# Run as the ordinary WSL user. Secrets and certificates stay outside Git.
version=v2.15.4
registry=harbor.local:8443
lab_dir="$HOME/austin-harbor"
cert_dir="$lab_dir/certs"
installer="$lab_dir/harbor-online-installer-$version.tgz"

command -v docker >/dev/null
command -v openssl >/dev/null
command -v python3 >/dev/null
docker compose version >/dev/null
if [[ -e "$lab_dir/harbor/harbor.yml" ]]; then
  echo "Harbor is already configured at $lab_dir/harbor; leaving it untouched" >&2
  exit 2
fi

umask 077
mkdir -p "$cert_dir" "$lab_dir/data"
curl --fail --location --retry 3 --silent --show-error \
  "https://github.com/goharbor/harbor/releases/download/$version/harbor-online-installer-$version.tgz" \
  --output "$installer"
tar -xzf "$installer" -C "$lab_dir"

openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout "$cert_dir/ca.key" -out "$cert_dir/ca.crt" \
  -subj '/CN=Austin Harbor Lab CA' \
  -addext 'basicConstraints=critical,CA:TRUE' >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes \
  -keyout "$cert_dir/harbor.local.key" -out "$cert_dir/harbor.local.csr" \
  -subj '/CN=harbor.local' \
  -addext 'subjectAltName=DNS:harbor.local,DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1
cat > "$cert_dir/server.ext" <<'EOF'
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:harbor.local,DNS:localhost,IP:127.0.0.1
EOF
openssl x509 -req -in "$cert_dir/harbor.local.csr" \
  -CA "$cert_dir/ca.crt" -CAkey "$cert_dir/ca.key" -CAcreateserial \
  -out "$cert_dir/harbor.local.crt" -days 365 -sha256 \
  -extfile "$cert_dir/server.ext" >/dev/null 2>&1

openssl rand -hex 24 > "$lab_dir/admin-password"
openssl rand -hex 24 > "$lab_dir/db-password"
chmod 600 "$lab_dir/admin-password" "$lab_dir/db-password" "$cert_dir"/*.key

python3 - "$lab_dir" <<'PY'
from pathlib import Path
import sys

lab = Path(sys.argv[1])
config = (lab / 'harbor/harbor.yml.tmpl').read_text()
replacements = {
    'hostname: reg.mydomain.com': 'hostname: harbor.local',
    '  port: 80\n': '  port: 8082\n',
    '  port: 443\n': '  port: 8443\n',
    '  certificate: /your/certificate/path': f'  certificate: {lab}/certs/harbor.local.crt',
    '  private_key: /your/private/key/path': f'  private_key: {lab}/certs/harbor.local.key',
    'harbor_admin_password: Harbor12345': f'harbor_admin_password: {(lab / "admin-password").read_text().strip()}',
    '  password: root123\n': f'  password: {(lab / "db-password").read_text().strip()}\n',
    'data_volume: /data': f'data_volume: {lab}/data',
}
for old, new in replacements.items():
    if config.count(old) != 1:
        raise SystemExit(f'Unexpected Harbor template: {old!r} appears {config.count(old)} times')
    config = config.replace(old, new, 1)
target = lab / 'harbor/harbor.yml'
target.write_text(config)
target.chmod(0o600)
PY

echo "Prepared Harbor $version at $lab_dir/harbor for https://$registry"
echo "Next run the root trust script, then: cd $lab_dir/harbor && ./install.sh"
echo "Initial admin password is in $lab_dir/admin-password (mode 600)."
