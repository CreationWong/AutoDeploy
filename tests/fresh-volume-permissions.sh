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

for _ in $(seq 1 30); do
  if docker exec "$container" test -d /data/deploy 2>/dev/null; then
    break
  fi
  sleep 0.2
done

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
