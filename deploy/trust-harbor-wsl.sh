#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root after prepare-harbor-wsl.sh. Does not restart Docker or containers.
if (( EUID != 0 )); then
  echo 'Run this script as root' >&2
  exit 2
fi
ca_file=${1:?usage: trust-harbor-wsl.sh /home/USER/austin-harbor/certs/ca.crt}
test -f "$ca_file"

if ! grep -Eq '^[[:space:]]*generateHosts[[:space:]]*=[[:space:]]*false[[:space:]]*$' /etc/wsl.conf; then
  if grep -Eq '^[[:space:]]*\[network\][[:space:]]*$' /etc/wsl.conf; then
    echo 'Edit the existing [network] section in /etc/wsl.conf to set generateHosts=false' >&2
    exit 2
  fi
  printf '\n[network]\ngenerateHosts=false\n' >> /etc/wsl.conf
fi
if ! grep -Eq '^[[:space:]]*127\.0\.0\.1[[:space:]].*\bharbor\.local\b' /etc/hosts; then
  printf '\n127.0.0.1 harbor.local\n' >> /etc/hosts
fi
install -d -m 755 '/etc/docker/certs.d/harbor.local:8443'
install -m 644 "$ca_file" '/etc/docker/certs.d/harbor.local:8443/ca.crt'
install -m 644 "$ca_file" '/usr/local/share/ca-certificates/austin-harbor-lab.crt'
update-ca-certificates >/dev/null
echo 'Configured persistent harbor.local DNS and local CA trust.'
echo 'Run wsl --shutdown from Windows once to apply the WSL network setting.'
