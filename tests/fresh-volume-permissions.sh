#!/bin/bash
set -euo pipefail

image="${1:-autodeploy:fresh-volume-test}"
suffix="${RANDOM}-$$"
container="autodeploy-fresh-volume-test-${suffix}"
volume="autodeploy-fresh-volume-test-${suffix}"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker volume create "$volume" >/dev/null
docker run -d \
  --name "$container" \
  --mount "type=volume,source=${volume},target=/data" \
  --env REPO_NAME=fresh-volume-test \
  --env AUTODEPLOY_HTTP_PASSWORD=test-placeholder \
  "$image" >/dev/null

# Directory creation precedes chown; wait for initialization to finish, which
# is especially important when testing a foreign architecture under emulation.
ready=0
for _ in $(seq 1 60); do
  output="$(docker logs "$container" 2>&1)"
  if [[ "$output" == *'启动完成'* ]]; then
    ready=1
    break
  fi
  sleep 0.5
done
if [ "$ready" != 1 ]; then
  printf 'container failed to initialize:\n%s\n' "$output" >&2
  exit 1
fi

if ! docker exec --user git "$container" sh -c \
  'mkdir -p /data/deploy/.versions/fresh-volume-test && mktemp -d /data/deploy/.versions/fresh-volume-test/.staging-XXXXXX >/dev/null'; then
  owner="$(docker exec "$container" stat -c '%U:%G %a %n' /data/deploy /data/deploy/.versions)"
  echo "fresh-volume versions directory is not writable by git (owner=$owner)" >&2
  exit 1
fi

owner="$(docker exec "$container" stat -c '%U:%G %a' /data/deploy /data/deploy/.versions)"
if [ "$owner" != $'git:git 755\ngit:git 755' ]; then
  echo "unexpected fresh-volume deploy directory ownership:" >&2
  echo "$owner" >&2
  exit 1
fi

echo "fresh-volume versions directory is writable by git"
