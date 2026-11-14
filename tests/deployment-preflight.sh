#!/bin/bash
# Run only against a disposable local image, without a Docker socket or network.
set -euo pipefail
image="${1:-autodeploy:security-test}"
container="autodeploy-preflight-test-${RANDOM}-$$"
cleanup() { docker rm -fv "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run -d --pull never --name "$container" --network none "$image" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$container" supervisorctl status fcgiwrap 2>/dev/null | grep -q RUNNING; then
    break
  fi
  sleep 0.5
done
docker exec "$container" supervisorctl status fcgiwrap | grep -q RUNNING

docker exec -i --user git "$container" bash -s <<'FIXTURE'
set -euo pipefail
export GIT_DIR=/data/git-home/app.git
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.test
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.test
versions=/data/deploy/.versions/app
config=AutoDeploy.config.yaml
empty_tree="$(git mktree < /dev/null)"
commit="$(printf 'no config\n' | git commit-tree "$empty_tree")"
output="$(autodeploy-post-receive --ref "$commit")"
[[ "$output" == *'skipping deployment'* ]]
test ! -e "$versions"

# Reject symlink and directory configs before making a staging directory.
blob="$(printf '/tmp/fixture-config\n' | git hash-object -w --stdin)"
for entry in "120000 blob $blob" "040000 tree $empty_tree"; do
  tree="$(printf '%s\t%s\n' "$entry" "$config" | git mktree)"
  commit="$(printf 'invalid config type\n' | git commit-tree "$tree")"
  if output="$(autodeploy-post-receive --ref "$commit" 2>&1)"; then
    echo 'accepted non-regular config' >&2
    exit 1
  fi
  [[ "$output" == *'must be a regular file'* ]]
  test ! -e "$versions"
done

# A regular executable config is also valid; exercise branch-trigger parsing,
# archive export, sudo handoff, and successful deployment as one flow.
blob="$(printf 'version: 1\nname: preflight\nstart: sleep 3600\n' | git hash-object -w --stdin)"
tree="$(printf '100755 blob %s\t%s\n' "$blob" "$config" | git mktree)"
commit="$(printf 'valid config\n' | git commit-tree "$tree")"
output="$(printf '%040d %s refs/heads/main\n' 0 "$commit" | autodeploy-post-receive)"
[[ "$output" == *'Deployment complete'* ]]
test -L /data/deploy/app
FIXTURE

docker exec "$container" bash -c '
  set -e
  supervisorctl status autodeploy-preflight | grep -q RUNNING
  test "$(yq -r .status /data/state/preflight/deploy.json)" = success
  /usr/sbin/sshd -T | grep -qx "disableforwarding yes"
  /usr/sbin/sshd -T | grep -qx "permittty no"
  /usr/sbin/sshd -T | grep -qx "permituserrc no"
'

# Direct and restore entry points also reject a config symlink. Use a dummy
# external file; these checks must not execute its environment.setup command.
docker exec -i "$container" bash -s <<'FIXTURE'
set -euo pipefail
target=/data/deploy/.versions/app/symlink-fixture
mkdir -p "$target"
cat > /tmp/fixture-config <<'CONFIG'
version: 1
name: symlink-fixture
environment:
  setup: ['touch /tmp/unexpected-setup']
start: sleep 3600
CONFIG
ln -s /tmp/fixture-config "$target/AutoDeploy.config.yaml"
for mode in direct --prepare-env --restore-compose --stop-compose; do
  args=("$target")
  [ "$mode" = direct ] || args=("$mode" "$target")
  if output="$(autodeploy-deploy "${args[@]}" 2>&1)"; then
    echo "accepted config symlink in $mode" >&2
    exit 1
  fi
  [[ "$output" == *'must not be a symlink'* ]]
  test ! -e /tmp/unexpected-setup
done
FIXTURE
echo 'Git preflight and SSH restrictions regression tests passed'
