#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export AUTODEPLOY_DATA_DIR="$tmp"
export HOSTNAME=autodeploy-test-container
unset AUTODEPLOY_HOST AUTODEPLOY_HTTP_PORT AUTODEPLOY_SSH_PORT AUTODEPLOY_HTTP_USER
REPO_NAME=app
DEPLOY_BRANCH=main
CONFIG_NAME=AutoDeploy.config.yaml
mock_bindings=$'80/tcp\t0.0.0.0\t8096'
mock_status=0
docker() {
  [ "$1" = inspect ] && [ "${@: -1}" = "$HOSTNAME" ] || return 1
  printf '%s\n' "$mock_bindings"
  return "$mock_status"
}
log() { printf '[AutoDeploy] %s\n' "$*"; }
# Avoid a real daemon or timeout subprocess; docker above is the test seam.
timeout() { shift; "$@"; }

# Exercise the startup logging block in the old entrypoint before the helper exists.
if [ ! -f "$root/scripts/autodeploy-endpoints" ]; then
  output="$(eval "$(sed -n '/^SSH_PORT=/,/^log "启动完成/p' "$root/entrypoint.sh")")"
else
  . "$root/scripts/autodeploy-endpoints"
  output="$(autodeploy_log_endpoints)"
fi
assert_contains() {
  if [[ "$output" != *"$1"* ]]; then
    printf 'missing: %s\noutput:\n%s\n' "$1" "$output" >&2
    exit 1
  fi
}
assert_absent() {
  if [[ "$output" == *"$1"* ]]; then
    printf 'unexpected: %s\noutput:\n%s\n' "$1" "$output" >&2
    exit 1
  fi
}

assert_contains 'http://autodeploy@<host>:8096/app.git'
assert_contains 'SSH 未发布宿主机端口'
assert_absent ':8080/'
assert_absent ':2222/'

# Actual bindings win over stale defaults passed by compose.
AUTODEPLOY_HTTP_PORT=8080
AUTODEPLOY_HOST=deploy.example.test
mock_bindings=$'80/tcp\t0.0.0.0\t8096\n22/tcp\t127.0.0.1\t22022'
REPO_NAME=project
DEPLOY_BRANCH='release/*'
printf 'saved-user:unused-test-hash\n' > "$tmp/htpasswd"
AUTODEPLOY_HTTP_USER=changed-user
output="$(autodeploy_log_endpoints)"
assert_contains 'http://saved-user@deploy.example.test:8096/project.git'
assert_contains 'ssh://git@deploy.example.test:22022/~/project.git'
assert_contains '部署分支: release/*'
assert_absent 'unused-test-hash'

# Preserve specific bind addresses, bracket IPv6, and deduplicate wildcards.
unset AUTODEPLOY_HOST AUTODEPLOY_HTTP_PORT
mock_bindings=$'80/tcp\t127.0.0.1\t8096\n80/tcp\t::1\t8097\n22/tcp\t0.0.0.0\t22022\n22/tcp\t::\t22022'
output="$(autodeploy_log_endpoints)"
assert_contains 'http://saved-user@127.0.0.1:8096/project.git'
assert_contains 'http://saved-user@[::1]:8097/project.git'
[ "$(printf '%s\n' "$output" | grep -c 'ssh://git@<host>:22022/')" = 1 ]

# No published ports must not be confused with a failed Docker inspection.
mock_bindings=''
output="$(autodeploy_log_endpoints)"
assert_contains 'HTTP 未发布宿主机端口'
assert_absent 'HTTP 推送地址:'

# A gateway or a socket-free install may explicitly supply external ports.
AUTODEPLOY_HTTP_PORT=18080
AUTODEPLOY_SSH_PORT=22022
output="$(autodeploy_log_endpoints)"
assert_contains 'http://saved-user@<host>:18080/project.git'
assert_contains 'ssh://git@<host>:22022/~/project.git'
mock_status=1
output="$(autodeploy_log_endpoints)"
assert_contains 'http://saved-user@<host>:18080/project.git'

unset AUTODEPLOY_HTTP_PORT AUTODEPLOY_SSH_PORT
output="$(autodeploy_log_endpoints)"
assert_contains '无法检测宿主机端口'
assert_contains ':<HTTP_PORT>/project.git'
assert_absent ':8080/'
assert_absent ':2222/'

AUTODEPLOY_HOST='2001:db8::1'
output="$(autodeploy_log_endpoints)"
assert_contains 'http://saved-user@[2001:db8::1]:<HTTP_PORT>/project.git'

echo 'push address regression tests passed'
