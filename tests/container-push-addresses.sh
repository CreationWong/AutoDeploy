#!/bin/bash
set -euo pipefail

image="${1:-autodeploy:fresh-volume-test}"
container="autodeploy-push-addresses-test-${RANDOM}-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# A random published port exercises Docker inspection rather than an env default.
docker run -d --name "$container" \
  -p 127.0.0.1::80 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -e AUTODEPLOY_HTTP_USER=address-test-user \
  -e AUTODEPLOY_HTTP_PASSWORD=test-placeholder \
  -e AUTODEPLOY_HTTP_PORT=8080 \
  "$image" >/dev/null

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
  printf 'container failed to start:\n%s\n' "$output" >&2
  exit 1
fi

port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$container")"
expected="http://address-test-user@127.0.0.1:${port}/app.git"
for output in "$output" "$(docker exec "$container" autodeploy show)"; do
  if [[ "$output" != *"$expected"* || "$output" != *'SSH 未发布宿主机端口'* ]]; then
    printf 'expected actual address %s and unpublished SSH:\n%s\n' "$expected" "$output" >&2
    exit 1
  fi
done

echo 'container startup and show report actual published ports'
