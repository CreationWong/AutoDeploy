# 项目配置参考

在这里查询项目字段。首次使用见[新手教程](getting-started.md)，服务环境变量见[部署指南](deployment.md#环境变量)。

## 配置文件

将 `AutoDeploy.config.yaml` 放在项目根目录，可用 `AUTODEPLOY_CONFIG_NAME` 改名。文件名只能包含字母、数字、点、下划线和连字符，不能是 `.`、`..` 或路径。

### 公共字段

| 字段 | 说明 |
| --- | --- |
| `version` | 配置版本，建议显式填写 `1`，当前只支持 `1` |
| `name` | 可选，应用名，默认取 `REPO_NAME`；决定状态/日志目录与 supervisor 程序名 |
| `type` | `process`（默认）或 `docker-compose` |
| `env` | 注入应用、部署命令、钩子与 workflow 的环境变量映射 |
| `healthcheck` | 可选：`url` 或 `port` + `timeout`（秒，默认 30）；`port` 会检查该端口的 HTTP 根路径，不是通用 TCP 探测 |
| `environment` | 可选：基础环境构建（见下），任何 `type` 都在部署前执行 |
| `deploy` | 可选：覆盖该项目的触发规则（见下），不写则用容器环境变量 |

### deploy（触发规则，可选）

按项目覆盖"哪些分支/标签触发部署"，优先于容器环境变量 `DEPLOY_BRANCH` / `DEPLOY_TAG` / `DEPLOY_TAG_MODE`：

| 字段 | 说明 |
| --- | --- |
| `deploy.branches` | 触发部署的分支列表/字符串，支持逗号分隔与 `*` 通配（如 `[main, "release/*"]`） |
| `deploy.tags` | 触发部署的标签列表/字符串，支持逗号分隔与 `*` 通配（如 `["v*"]`） |
| `deploy.tag_mode` | 标签命中后的行为：`commit`（默认，部署标签指向的提交）或 `branch`（部署该标签所在分支的最新提交） |

```yaml
version: 1
name: my-app
type: process
deploy:
  branches: [main, "release/*"]
  tags: ["v*"]
  tag_mode: commit
start: node server.js
```

未设置 `deploy.branches` 时使用 `DEPLOY_BRANCH`。`branch` 模式会在匹配分支中查找包含该标签提交的分支，再部署其最新提交。

### environment（基础环境构建）

按配置在容器内准备运行时，无需为换运行时重建镜像：

| 字段 | 说明 |
| --- | --- |
| `packages` | 需要安装的 apt 包列表，已安装的自动跳过 |
| `setup` | 以 root 执行的初始化命令列表（添加软件源、安装语言运行时等） |
| `force` | 为 `true` 时忽略缓存强制重建 |

环境配置不变时跳过构建。容器重建后会按已保存的配置恢复环境，再启动应用；恢复需要软件源和网络可用。

```yaml
version: 1
name: my-app
type: process
environment:
  packages:
    - python3
  setup:
    - python3 --version
```

### type: process（运行在本容器内）

| 字段 | 说明 |
| --- | --- |
| `workdir` | 可选，工作目录（相对项目根，默认 `.`） |
| `user` | 可选，运行用户，默认 `autodeploy-app`；禁止 root、git 及管理组身份 |
| `install` | 可选，以受信任的 `git` 部署用户执行的命令列表 |
| `build` | 可选，以受信任的 `git` 部署用户执行的构建命令列表 |
| `start` | 必填，启动命令；supervisor 托管，崩溃自动重启，容器重建后尝试恢复启动 |
| `healthcheck.url` | 用 `http://127.0.0.1:<端口>/` |

```yaml
version: 1
name: my-app
type: process
env:
  NODE_ENV: production
  PORT: "3000"
install:
  - npm ci
build:
  - npm run build
start: node server.js
healthcheck:
  url: http://127.0.0.1:3000/
  timeout: 30
```

> 运行时准备：简单依赖使用 `environment.packages` / `environment.setup`。需要预装 Node、JDK 等完整工具链时，按项目要求选择兼容的基础镜像，见[构建与运行源码](development.md#构建与运行源码)。

业务进程以独立用户运行，部署代码和构建产物只读，也不能修改启动脚本、日志路径或 Git 凭据。可写数据请放在用户 HOME 或专用数据目录；默认 HOME 为 `/home/autodeploy-app`，不持久化。

自定义 `user` 必须已存在，且不属于 `root`、`git`、`docker`、`sudo`、`wheel` 组。安装和构建使用 Git 用户 HOME，运行时使用业务用户 HOME。

升级时会把旧快照中的 root/git 运行用户迁移为默认业务用户。项目中显式配置的 `user: root` / `user: git` 仍会被拒绝，请移除后重新推送。依赖高权限或写入部署目录的应用也需调整。

### type: docker-compose（兄弟容器）

| 字段 | 说明 |
| --- | --- |
| `file` | 可选，compose 文件路径，默认自动查找 `compose.yaml` / `compose.yml` / `docker-compose.yml` / `docker-compose.yaml` |
| `services` | 可选，只启动指定服务 |
| `build` | 可选，是否 `up --build`，默认 `true` |
| `env` | 透传给 compose（可用于 `${VAR}` 插值，写入 `--env-file`） |

业务端口由项目 Compose 的 `ports:` 或外部网关提供。健康检查使用 `host.docker.internal` 或网络内地址。

```yaml
version: 1
name: my-api
type: docker-compose
file: docker-compose.yml
services: [web]
build: true
env:
  APP_PORT: "8081"
```

## .AutoDeploy（部署前 CI/CD）

### shell 钩子

| 脚本 | 执行时机 | 失败后果 |
| --- | --- | --- |
| `.AutoDeploy/before.sh` | `environment` 构建后、正式部署前 | 中止部署，旧服务继续运行 |
| `.AutoDeploy/after.sh` | 健康检查通过后 | 本次部署标记 `failed` |

- 以 root 执行，工作目录为项目根，随 `git archive` 推送；
- 注入配置里的 `env`，以及 `AUTODEPLOY_NAME`、`AUTODEPLOY_TYPE`、`AUTODEPLOY_COMMIT`、`AUTODEPLOY_BRANCH`、`AUTODEPLOY_PROJECT_DIR`；
- 常见用法：跑测试/代码检查、发通知、数据库迁移、清理缓存；
- 无需可执行位，统一用 bash 运行。

```bash
# .AutoDeploy/before.sh
#!/bin/bash
set -e
npm ci && npm test
```

### GitHub Actions 风格 workflow

`.AutoDeploy/workflows/*.yml`（或 `.yaml`）在 `before.sh` 之后、正式部署之前，按文件名顺序执行：

```yaml
name: ci
on: [push]
env:
  PYTHONUNBUFFERED: "1"
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: 检查 Python 语法
        run: |
          python3 -m compileall -q .
```

| 能力 | 支持情况 |
| --- | --- |
| 执行顺序 | job 按定义顺序，step 依次执行 |
| 命令 | `run` 支持多行，shell 支持 bash/sh |
| 环境变量 | workflow/job/step 的 `env` 就近覆盖；`GITHUB_ENV` 可传给后续步骤 |
| 工作目录 | 支持 `working-directory` 和 `defaults.run.working-directory` |
| 默认 shell | 支持 `defaults.run.shell` |
| 失败继续 | 支持 `continue-on-error` |
| `uses` | 仅接受 `actions/checkout`，因代码已检出而跳过 |
| 不支持 | `strategy/matrix`、`services`、`container`：报错停止 |
| 忽略 | `if`、`needs`：警告后忽略；`on`、`runs-on`：直接忽略 |

自动注入 `CI=true`、`GITHUB_WORKSPACE`、`GITHUB_SHA`、`GITHUB_REF_NAME` 和 `AUTODEPLOY_*`。步骤以 root 执行，部署前将工作目录交还给 `git`。
