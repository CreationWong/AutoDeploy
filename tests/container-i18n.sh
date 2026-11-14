#!/bin/bash
# 验证真实容器内语言默认值、持久化、单次覆盖及 Git hook 的设置传播。
set -euo pipefail
image="${1:-autodeploy:ci}"
container="autodeploy-i18n-test-${RANDOM}-$$"
trap 'docker rm -fv "$container" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$container" --network none "$image" >/dev/null
ready() {
  for _ in $(seq 1 60); do
    if docker exec "$container" supervisorctl status fcgiwrap 2>/dev/null | grep -q RUNNING; then return; fi
    sleep 0.5
  done
  return 1
}
ready
output="$(docker exec "$container" autodeploy help)"
[[ "$output" == *'AutoDeploy management commands'* ]]
docker exec "$container" autodeploy set AUTODEPLOY_LANG zh
output="$(docker exec "$container" autodeploy help)"
[[ "$output" == *'AutoDeploy 管理命令'* ]]
output="$(docker exec -e AUTODEPLOY_LANG=en "$container" autodeploy show)"
[[ "$output" == *'AutoDeploy settings'* ]]
output="$(docker exec "$container" autodeploy show)"
[[ "$output" == *'AutoDeploy 设置'* ]]
if docker exec "$container" autodeploy set AUTODEPLOY_LANG invalid; then exit 1; fi
# 非法 ref 不会修改任何部署，验证 hook 从持久化 env 读取语言。
output="$(docker exec "$container" autodeploy deploy missing-i18n-ref 2>&1 || true)"
[[ "$output" == *'无法解析 ref'* ]]
# 部署入口通过 sudo 清理环境后仍能读取同一语言配置。
output="$(docker exec --user git "$container" sudo -n /usr/local/bin/autodeploy-deploy 2>&1 || true)"
[[ "$output" == *'用法: autodeploy-deploy'* ]]
docker restart "$container" >/dev/null
ready
output="$(docker exec "$container" autodeploy help)"
[[ "$output" == *'AutoDeploy 管理命令'* ]]
docker exec "$container" autodeploy set AUTODEPLOY_LANG en
output="$(docker exec "$container" autodeploy deploy missing-i18n-ref 2>&1 || true)"
[[ "$output" == *'cannot resolve ref'* ]]
# 镜像中的对应源码必须保留可重建的 src 目录布局。
docker exec "$container" test -f /usr/share/doc/autodeploy/source/src/scripts/autodeploy-i18n
echo 'language defaults, persistence, overrides and hook propagation passed'
