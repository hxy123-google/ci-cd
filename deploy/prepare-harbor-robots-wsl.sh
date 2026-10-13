#!/usr/bin/env bash
set -Eeuo pipefail

# Create separate least-privilege credentials for GitHub image publishing and deployment.
# Secrets stay in the WSL user's home directory, outside this repository.
python3 - <<'PY'
import base64
import json
import os
import ssl
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import HTTPSHandler, ProxyHandler, Request, build_opener

lab = Path.home() / 'austin-harbor'
password = (lab / 'admin-password').read_text().strip()
cert = lab / 'certs/ca.crt'
secret_dir = lab / 'robots'
secret_dir.mkdir(mode=0o700, exist_ok=True)
os.chmod(secret_dir, 0o700)

auth = base64.b64encode(('admin:' + password).encode()).decode()
opener = build_opener(ProxyHandler({}), HTTPSHandler(context=ssl.create_default_context(cafile=str(cert))))
base = 'https://harbor.local:8443/api/v2.0'

def api(path, data=None):
    headers = {'Authorization': 'Basic ' + auth, 'Accept': 'application/json'}
    if data is not None:
        headers['Content-Type'] = 'application/json'
        data = json.dumps(data).encode()
    request = Request(base + path, data=data, headers=headers)
    try:
        with opener.open(request, timeout=30) as response:
            return json.load(response)
    except HTTPError as error:
        raise SystemExit(f'Harbor API {path} returned HTTP {error.code}: {error.read().decode()}') from error

robots = api('/robots?page_size=100')
for short_name, actions in [('ci-push', ['pull', 'push']), ('deploy-pull', ['pull'])]:
    target = secret_dir / (short_name + '.json')
    if target.exists():
        saved = json.loads(target.read_text())
        if not saved.get('name') or not saved.get('secret'):
            raise SystemExit(f'Incomplete saved credentials: {target}')
        print(f'{short_name}: existing credential file kept at {target}')
        continue
    if any(robot.get('name', '').endswith('demo+' + short_name) for robot in robots):
        raise SystemExit(f'Robot {short_name} already exists in Harbor, but its secret file is missing; refresh its secret in Harbor')
    payload = {
        'name': short_name,
        'description': 'Austin local CI/CD exercise',
        'level': 'project',
        'duration': 365,
        'permissions': [{
            'kind': 'project',
            'namespace': 'demo',
            'access': [{'resource': 'repository', 'action': action} for action in actions],
        }],
    }
    created = api('/robots', payload)
    if not created.get('name') or not created.get('secret'):
        raise SystemExit(f'Harbor did not return the {short_name} credentials')
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump({'name': created['name'], 'secret': created['secret']}, stream)
        stream.write('\n')
    print(f'{short_name}: saved credentials at {target} (mode 600)')
PY
