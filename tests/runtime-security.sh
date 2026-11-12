#!/bin/bash
# Linux/Docker integration test. Use a freshly built image, never a production container.
set -euo pipefail
image="${1:-autodeploy:security-test}"
container="autodeploy-security-test-${RANDOM}-$$"
cleanup() { docker rm -fv "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --name "$container" --network none "$image" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$container" supervisorctl status fcgiwrap 2>/dev/null | grep -q RUNNING; then
    break
  fi
  sleep 0.5
done
docker exec "$container" supervisorctl status fcgiwrap | grep -q RUNNING

# No generated plaintext credential in logs; the retained copy is root-only.
docker exec "$container" sh -c '
  test "$(stat -c %U:%G:%a /data/credentials)" = root:root:700
  test "$(stat -c %U:%G:%a /data/credentials/http-password)" = root:root:600
  grep -q "^[^:]*:[$]2[aby][$]" /data/htpasswd
  test ! -S /var/run/docker.sock
'
IFS= read -r password < <(docker exec "$container" cat /data/credentials/http-password)
output="$(docker logs "$container" 2>&1)"
[[ "$output" != *"$password"* ]] || { echo 'generated password leaked to logs' >&2; exit 1; }
unset password output

# Deploy a local fixture without a Git commit, downloads, or external endpoints.
docker exec -i "$container" bash -s <<'FIXTURE'
set -euo pipefail
target=/data/deploy/.versions/app/security-fixture
mkdir -p "$target"
cat > "$target/AutoDeploy.config.yaml" <<'CONFIG'
version: 1
name: security-fixture
type: process
install:
  - id -un > install-user
build:
  - id -un > build-user
  - touch build-private && chmod 600 build-private
  - touch build-writable && chmod 666 build-writable
start: sleep 3600
CONFIG
chown -R git:git "$target"
chmod 700 "$target"
autodeploy-deploy "$target" fixture main
test "$(cat "$target/install-user")" = git
test "$(cat "$target/build-user")" = git
pid="$(supervisorctl pid autodeploy-security-fixture)"
test "$(stat -c %U "/proc/$pid")" = autodeploy-app
grep -q '^NoNewPrivs:[[:space:]]*1$' "/proc/$pid/status"
test "$(stat -c %U:%G:%a /data/state/security-fixture/start.sh)" = root:autodeploy-app:640
test "$(stat -c %U:%G:%a /data/logs/security-fixture)" = root:autodeploy-app:750
FIXTURE

docker exec --user autodeploy-app "$container" bash -c '
  set -e
  ! sudo -n /usr/local/bin/autodeploy-deploy --prepare-env /data/deploy/app >/dev/null 2>&1
  ! test -r /data/credentials/http-password
  ! test -r /data/htpasswd
  ! test -r /data/git-home/.ssh/authorized_keys
  ! test -w /data
  ! test -w /data/deploy/.versions/app/security-fixture
  test -r /data/deploy/.versions/app/security-fixture/AutoDeploy.config.yaml
  test -r /data/deploy/.versions/app/security-fixture/build-private
  ! test -w /data/deploy/.versions/app/security-fixture/build-writable
  ! test -w /data/state/security-fixture/start.sh
  ! test -w /data/logs/security-fixture
  ! test -w /data/logs/security-fixture/app.log
  test -w /home/autodeploy-app
'

# Simulate a persisted snapshot from the previous release and check boot migration.
docker exec "$container" bash -c '
  sed -i "s/^user=.*/user=git/" /data/state/security-fixture/supervisor.conf
  sed -i "s|^command=/usr/bin/setpriv --no-new-privs |command=|" /data/state/security-fixture/supervisor.conf
  sed -i "s|^export HOME=.*|export HOME=/data/git-home|" /data/state/security-fixture/start.sh
  chown git:git /data/state/security-fixture/start.sh /data/logs/security-fixture
  chmod 700 /data/deploy/.versions/app/security-fixture
'
docker restart "$container" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$container" supervisorctl status autodeploy-security-fixture 2>/dev/null | grep -q RUNNING; then
    break
  fi
  sleep 0.5
done
docker exec "$container" bash -c '
  set -e
  supervisorctl status autodeploy-security-fixture | grep -q RUNNING
  pid="$(supervisorctl pid autodeploy-security-fixture)"
  test "$(stat -c %U "/proc/$pid")" = autodeploy-app
  grep -q "^NoNewPrivs:[[:space:]]*1$" "/proc/$pid/status"
  grep -q "^export HOME=/home/autodeploy-app$" /data/state/security-fixture/start.sh
  test "$(stat -c %U:%G:%a /data/state/security-fixture/start.sh)" = root:autodeploy-app:640
  test "$(stat -c %U:%G:%a /data/logs/security-fixture)" = root:autodeploy-app:750
'
echo 'runtime isolation, credential storage and upgrade regression tests passed'
