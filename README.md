# AutoDeploy

一个自带 Git 服务器与自动部署能力的 Docker 容器。

用户把代码 `git push` 到这个容器后，容器会在项目根目录扫描 `AutoDeploy.config.yaml`：

- 没有找到 → 只保留推送，不部署，日志输出 `跳过部署`；
- 找到 → 按配置部署服务到本容器（`process`）或通过 docker compose 启动子容器（`docker-compose`）。

## 架构

```
git push (SSH:2222 / HTTP:8080)
        │
        ▼
  OpenSSH ── git-shell ──┐
                         ├──> 裸仓库 /data/git-home/app.git
  nginx + fcgiwrap ──────┘        │ post-receive 钩子
                                  ▼
                      导出代码 -> /data/deploy/app
                                  │
                     扫描 AutoDeploy.config.yaml
                       │ 无                    │ 有
                       ▼                       ▼
                    跳过部署      autodeploy-deploy（root）
                                             │
                        ┌────────────────────┴────────────────────┐
                        ▼                                         ▼
              type: process                            type: docker-compose
     生成 start.sh + supervisor 配置                  docker compose up -d
       进程常驻在本容器内                          （需挂载 /var/run/docker.sock）
```

## 快速开始

### 方式一：docker compose（快速体验）

```bash
# 1. 构建并启动 AutoDeploy 容器
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" docker compose up -d --build

# 2. 查看启动日志（HTTP 密码随机生成时会打印）
docker logs autodeploy

# 3. 推送示例项目
cd examples/sample-app
git init -b main && git add . && git commit -m init
git remote add origin ssh://git@localhost:2222/~/app.git
git push origin main

# 4. 验证部署结果（示例应用监听容器内 3000 端口）
docker exec autodeploy supervisorctl status
docker exec autodeploy curl -s http://127.0.0.1:3000/
```

### 方式二：docker run

```bash
docker build -t autodeploy:latest .

docker run -d --name autodeploy --restart unless-stopped \
  -p 2222:22 -p 8080:80 \
  -v autodeploy-data:/data \
  -e AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -e AUTODEPLOY_HTTP_USER=autodeploy \
  -e AUTODEPLOY_HTTP_PASSWORD= \
  -e AUTODEPLOY_SSH_PORT=2222 \
  -e AUTODEPLOY_HTTP_PORT=8080 \
  autodeploy:latest
```

> 部署 `type: docker-compose` 的项目时，需追加 `-v /var/run/docker.sock:/var/run/docker.sock`；若应用健康检查使用 `host.docker.internal`，再追加 `--add-host=host.docker.internal:host-gateway`（Docker Desktop 已内置，Linux 需要）。

### 方式三：nginx 网关（零端口，生产推荐）

AutoDeploy 不发布任何端口，由单独的 nginx 容器统一入口（需要 Docker Compose v2.24+，使用 `!reset`）：

```bash
# 1. 创建共享网络
docker network create autodeploy-gateway

# 2. 部署 AutoDeploy（零端口，加入共享网络）
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  docker compose -f docker-compose.yml -f docker-compose.gateway.yml up -d --build

# 3. 启动 nginx 网关（单独容器）
cd examples/nginx-gateway && docker compose up -d

# 4. 查看 AutoDeploy 生成的 HTTP 密码
docker logs autodeploy | grep 密码

# 5. 经网关推送项目
git remote add origin http://autodeploy:<密码>@localhost:8080/app.git
git push origin main
```

网关路由（`examples/nginx-gateway/nginx.conf`）：

- 默认 server → `autodeploy:80`（Git HTTP）
- `stream` 的 22 → `autodeploy:22`（Git SSH）
- `blog.localhost` → `my-app-web:4000`；`app.localhost` → `autodeploy:3000`（容器内 process 应用）

业务项目（`type: docker-compose`）接入同一网络，端口不发布到宿主机：

```yaml
# 项目自己的 docker-compose.yml
services:
  web:
    build: .
    container_name: my-app-web
    networks: [gateway]
networks:
  gateway:
    external: true
    name: autodeploy-gateway
```

健康检查用网络内 DNS：`url: http://my-app-web:<端口>/`。本地测试直接用 `*.localhost` 域名（浏览器自动解析到 127.0.0.1）；生产换真实域名并在网关终止 TLS。

### 推送与端口

HTTP 推送：

```bash
git push http://autodeploy:<密码>@localhost:8080/app.git main
```

宿主端口可自行指定（容器内部固定监听 22/80）：compose 用环境变量，docker run 直接改 `-p`（同时设置 `AUTODEPLOY_SSH_PORT` / `AUTODEPLOY_HTTP_PORT` 只影响启动日志提示）：

```bash
# compose
AUTODEPLOY_SSH_PORT=22022 AUTODEPLOY_HTTP_PORT=18080 docker compose up -d

# docker run
docker run -d --name autodeploy -p 22022:22 -p 18080:80 \
  -e AUTODEPLOY_SSH_PORT=22022 -e AUTODEPLOY_HTTP_PORT=18080 \
  -v autodeploy-data:/data autodeploy:latest
```

## 推送地址

| 协议 | 地址 | 认证 |
| --- | --- | --- |
| SSH | `ssh://git@<host>:<SSH_PORT>/~/app.git`（默认 2222） | `AUTHORIZED_KEYS` 环境变量或 `/data/authorized_keys` 挂载文件 |
| HTTP | `http://<user>@<host>:<HTTP_PORT>/app.git`（默认 8080） | `AUTODEPLOY_HTTP_USER` / `AUTODEPLOY_HTTP_PASSWORD`，或首次启动随机生成并打印 |

裸仓库固定为 `${REPO_NAME}.git`（默认 `app.git`）。默认只有 `DEPLOY_BRANCH` 匹配的分支触发部署，支持逗号分隔或通配符（如 `main,release/*` 或 `*`）。

## AutoDeploy.config.yaml

放在项目根目录（可用 `AUTODEPLOY_CONFIG_NAME` 改名）。公共字段：

| 字段 | 说明 |
| --- | --- |
| `version` | 必填，当前只支持 `1` |
| `name` | 可选，应用名，默认取 `REPO_NAME`；决定状态/日志目录与 supervisor 程序名 |
| `type` | `process`（默认）或 `docker-compose` |
| `env` | 注入应用/部署命令的环境变量映射 |
| `healthcheck` | 可选：`url` 或 `port` + `timeout`（秒，默认 30），部署后轮询，失败则标记部署失败 |
| `environment` | 可选：基础环境构建（见下），任何 `type` 都在部署前执行 |

### environment（根据配置构建基础环境）

部署脚本会按 `environment` 在容器内准备运行时，无需为了换运行时重新构建镜像：

| 字段 | 说明 |
| --- | --- |
| `packages` | 需要安装的 apt 包列表，已安装的自动跳过 |
| `setup` | 以 root 执行的初始化命令列表（如添加软件源、安装语言运行时） |
| `force` | 为 `true` 时忽略缓存强制重建 |

配置内容会做 sha256 缓存，未变化时输出 `基础环境未变化，跳过构建`。`packages`/`setup` 安装在容器可写层，容器被重建（非 `docker restart`）后入口脚本会按持久化快照自动重放，应用不会因运行时丢失而启动失败。

```yaml
version: 1
name: my-app
type: process
environment:
  packages:
    - python3
  setup:
    - curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    - apt-get install -y nodejs
env:
  NODE_ENV: production
install:
  - npm ci
start: node server.js
```

### type: process（默认，运行在本容器内）

| 字段 | 说明 |
| --- | --- |
| `workdir` | 可选，工作目录（相对项目根，默认 `.`） |
| `user` | 可选，运行用户，默认 `git` |
| `install` | 可选，部署前按顺序执行的命令列表 |
| `build` | 可选，构建命令列表 |
| `start` | 必填，启动命令；由 supervisor 托管，崩溃自动重启，容器重启后自动拉起 |

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

> `process` 会直接在本容器内执行应用。运行时的两种准备方式：轻量的用上面的 `environment.packages` / `environment.setup` 在部署时安装；重型的（如整套 Node/JDK 工具链）建议用构建参数 `BASE_IMAGE` 直接换底座，例如：`docker compose build --build-arg BASE_IMAGE=node:20-bookworm-slim`。

### type: docker-compose（需要挂载 docker.sock）

| 字段 | 说明 |
| --- | --- |
| `file` | 可选，compose 文件路径，默认自动查找 `compose.yaml` / `compose.yml` / `docker-compose.yml` / `docker-compose.yaml` |
| `services` | 可选，只启动指定服务 |
| `build` | 可选，是否 `up --build`，默认 `true` |
| `env` | 透传给 compose 命令的环境变量（可用于 `${VAR}` 插值） |

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

> compose 容器运行在宿主机 Docker 上，不是 AutoDeploy 容器内部（基础 compose 已挂载 `/var/run/docker.sock` 并配置 `extra_hosts`，不使用可移除）。服务端口由应用自己的 compose 用 `ports:` 发布到宿主机，AutoDeploy 不再为应用写死端口；如需从 AutoDeploy 容器内做健康检查，把 `healthcheck.url` 指向 `http://host.docker.internal:<端口>/`。

## .AutoDeploy 自定义脚本（部署前 CI/CD）

项目根目录可创建 `.AutoDeploy/` 目录放置钩子脚本，按部署生命周期自动执行：

| 脚本 | 执行时机 |
| --- | --- |
| `.AutoDeploy/before.sh` | `environment` 构建完成后、正式部署（install/build/start）之前；失败则中止部署 |
| `.AutoDeploy/after.sh` | 健康检查通过后；失败则本次部署标记为 `failed` |

- 以 root 执行，工作目录为项目根，脚本随 `git archive` 推送；
- 自动注入配置里的 `env`，以及 `AUTODEPLOY_NAME`、`AUTODEPLOY_TYPE`、`AUTODEPLOY_COMMIT`、`AUTODEPLOY_BRANCH`、`AUTODEPLOY_PROJECT_DIR`；
- 常见用法：跑测试/代码检查、发通知、数据库迁移、清理缓存；
- 无论是否可执行都会用 bash 运行。

```bash
# .AutoDeploy/before.sh
#!/bin/bash
set -e
npm ci && npm test

# .AutoDeploy/after.sh
#!/bin/bash
set -e
curl -fsS -X POST "https://hooks.example.com/deploy?name=${AUTODEPLOY_NAME}&commit=${AUTODEPLOY_COMMIT}"
```

### GitHub Actions 风格 workflow

`.AutoDeploy/workflows/*.yml`（或 `.yaml`）按 GitHub Actions 语法执行，时机在 `before.sh` 之后、正式部署之前，按文件名顺序：

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
      - name: 跑测试
        working-directory: .
        run: |
          pip install -r requirements.txt
          pytest -q
```

- 支持：`jobs`（按定义顺序）、`steps`、`run`（含多行）、`name`、workflow/job/step 三级 `env`（就近覆盖）、`working-directory`、`defaults.run.shell` / `defaults.run.working-directory`、`continue-on-error`、`actions/checkout`（跳过，代码已检出）、`GITHUB_ENV` 跨步骤传递变量；
- 自动注入：`CI=true`、`GITHUB_WORKSPACE`、`GITHUB_SHA`、`GITHUB_REF_NAME`、`AUTODEPLOY_*`；
- 不支持：`uses`（除 actions/checkout）、`strategy/matrix`、`services`、`container`（报错中止）；`if`、`needs` 忽略并警告；`on`、`runs-on` 仅兼容忽略；
- 步骤以 root 执行，部署前会把工作目录交还给 `git` 用户。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `AUTODEPLOY_SSH_PORT` | `2222` | 宿主机映射的 SSH 端口（docker compose 变量，容器内固定 22） |
| `AUTODEPLOY_HTTP_PORT` | `8080` | 宿主机映射的 HTTP 端口（docker compose 变量，容器内固定 80） |
| `REPO_NAME` | `app` | 裸仓库名（`${REPO_NAME}.git`），也作为默认应用名 |
| `DEPLOY_BRANCH` | `main` | 触发部署的分支，支持逗号分隔和 `*` 通配 |
| `AUTODEPLOY_CONFIG_NAME` | `AutoDeploy.config.yaml` | 部署配置文件名 |
| `AUTHORIZED_KEYS` | 空 | SSH 公钥内容（可多行），与 `/data/authorized_keys` 合并 |
| `AUTODEPLOY_HTTP_USER` | `autodeploy` | HTTP Basic 用户名 |
| `AUTODEPLOY_HTTP_PASSWORD` | 空 | HTTP Basic 密码，留空则首次随机生成 |
| `AUTODEPLOY_APP_USER` | `git` | `process` 类型默认运行用户，可被配置文件的 `user` 覆盖 |
| `AUTODEPLOY_DATA_DIR` | `/data` | 数据目录 |
| `BASE_IMAGE`（构建参数） | `debian:bookworm-slim` | 容器底座镜像，重型运行时可直接换底座 |
| `YQ_VERSION`（构建参数） | `v4.44.3` | 部署脚本用于解析 YAML 的 yq 版本 |
| `INSTALL_DOCKER_CLI`（构建参数） | `1` | 是否安装 docker CLI / compose 插件 |

## 数据与日志（都在 `/data` 卷内）

```
/data
├── git-home/app.git          # 裸仓库
├── git-home/.ssh/authorized_keys
├── deploy/app                # 最近一次推送的代码工作目录
├── state/<name>/deploy.json  # 最近部署状态（commit、branch、success/failed）
├── state/<name>/environment.yml      # 当前生效的 environment 快照
├── state/<name>/environment.boot     # 上次构建环境的容器实例 ID
├── state/<name>/start.sh     # process 类型的启动脚本
├── state/<name>/supervisor.conf
├── logs/<name>/deploy.log    # 部署日志
└── logs/<name>/app.log       # 应用 stdout / stderr
```

## 安全说明

- SSH 只允许 `git` 用户、仅公钥认证，shell 限制为 `git-shell`；
- `git` 用户仅能通过 sudo 免密执行 `/usr/local/bin/autodeploy-deploy` 这一条命令；
- 部署脚本会校验目标目录必须位于 `/data/deploy` 内；
- 能推送到该仓库的人等于能在容器内以 `git` 用户执行安装/构建/启动命令，请妥善保管推送凭据；
- HTTP 密码非空时由 `/dev/urandom` 生成（真随机、无固定种子），仅首次启动打印并持久化在 `/data/htpasswd`；需要轮换时删除该文件后重启，或设置 `AUTODEPLOY_HTTP_PASSWORD`；
- SSH 主机密钥在首次启动时随机生成并持久化在 `/data/ssh`，不烤进镜像。

## 仓库开发辅助（Ponytail）

`opencode.json` 已声明 [ponytail](https://github.com/DietrichGebert/ponytail) 插件，opencode 启动时会自动安装并按 YAGNI 规则约束代码改动。默认强度 `full`，可用 `/ponytail lite|full|ultra|off` 切换，或用 `PONYTAIL_DEFAULT_MODE` 环境变量指定。修改配置后需要退出并重启 opencode 才会生效。

## 常见问题

- **推送成功但没部署？** 确认分支在 `DEPLOY_BRANCH` 内、根目录存在 `AutoDeploy.config.yaml`，并查看 `docker logs autodeploy` 或 `/data/logs/<name>/deploy.log`。
- **进程没起来？** `docker exec autodeploy supervisorctl status`，再看 `app.err.log`。
- **推送输出 `[AutoDeploy] 错误: ...` 但 push 仍然成功？** post-receive 在对象入库后运行，无法拒绝推送；实际状态记录在 `/data/state/<name>/deploy.json`（`success` / `failed`），部署失败时旧进程继续运行。
- **容器重建后部署还在吗？** 在。裸仓库、工作目录、supervisor 配置、日志都持久化在 `/data`，入口脚本会恢复进程托管。
