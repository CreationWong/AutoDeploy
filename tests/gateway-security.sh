#!/bin/bash
# Requires Linux Docker, curl, and both images already available locally.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:-autodeploy:security-test}"
gateway_image="${2:-nginx:1.27-alpine}"
suffix="${RANDOM}-$$"
backend="autodeploy-gateway-backend-test-$suffix"
gateway="autodeploy-gateway-test-$suffix"
network="autodeploy-gateway-test-$suffix"
cleanup() {
  docker rm -fv "$gateway" "$backend" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker image inspect "$image" "$gateway_image" >/dev/null
docker network create --internal "$network" >/dev/null
docker run -d --pull never --name "$backend" \
  --network "$network" --network-alias autodeploy \
  -e AUTODEPLOY_HTTP_PASSWORD=test-placeholder "$image" >/dev/null
docker run -d --pull never --name "$gateway" --network "$network" \
  -p 127.0.0.1::80 \
  -v "$root/examples/nginx-gateway/nginx.conf:/etc/nginx/nginx.conf:ro" \
  "$gateway_image" >/dev/null
port="$(docker inspect --format '{{(index (index .NetworkSettings.Ports "80/tcp") 0).HostPort}}' "$gateway")"
url="http://127.0.0.1:$port"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 1 "$url/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
curl -fsS --max-time 2 "$url/healthz" >/dev/null

# Declare a 1 MiB body but send none. A buffering proxy would wait for the
# missing body; the fixed gateway must return the backend's 401 immediately.
status="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'Expect:' -H 'Content-Length: 1048576' --data-binary '' \
  "$url/app.git/git-receive-pack")"
[ "$status" = 401 ] || { echo "expected early 401, got $status" >&2; exit 1; }

# Headers alone verify the 128 MiB cap without uploading a large request.
status="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'Expect:' -H 'Content-Length: 134217729' --data-binary '' \
  "$url/app.git/git-receive-pack")"
[ "$status" = 413 ] || { echo "expected upload limit 413, got $status" >&2; exit 1; }

status="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
  -u autodeploy:test-placeholder "$url/app.git/info/refs?service=git-upload-pack")"
[ "$status" = 200 ] || { echo "authenticated Git HTTP failed: $status" >&2; exit 1; }
echo 'gateway early authentication and upload limit regression tests passed'
