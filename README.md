# AutoDeploy

一个通过 `git push` 驱动的轻量自托管部署服务。AutoDeploy 在单个容器内提供 SSH/HTTP Git 服务，收到推送后读取项目根目录的 `AutoDeploy.config.yaml`，完成构建、启动、健康检查和失败回退。

> 当前版本：`V0.1.3`。[Docker Hub 镜像](https://hub.docker.com/r/creationwong/autodeploy/tags?name=V0.1.3) `creationwong/autodeploy:V0.1.3` 支持 `linux/amd64` 和 `linux/arm64`。

Copyright (C) 2026 CreationWong。项目采用 [GNU General Public License 第 3 版](LICENSE)（`GPL-3.0-only`）。

## 功能亮点

- **推送即部署**：支持 SSH 与 HTTP Git 推送，不依赖 GitHub/GitLab webhook；
- **两种运行方式**：`process` 由 Supervisor 托管，`docker-compose` 运行独立业务容器；
- **安全切换版本**：每次部署使用独立版本目录，健康检查通过后才原子切换；
- **失败自动回退**：构建、启动、健康检查或部署后钩子失败时恢复上一可用版本；
- **项目内声明配置**：分支/标签规则、环境准备、构建命令和健康检查随代码版本管理；
- **部署前流水线**：支持 `.AutoDeploy/before.sh` 和精简的 GitHub Actions 风格 workflow；
- **持久化与可观测**：裸仓库、版本、状态和日志统一保存在 `/data`。

## 选择部署模式

| 模式 | 适合场景 | 运行位置 | 主要注意事项 |
| --- | --- | --- | --- |
| `process` | Python/Node 等单进程服务、小型应用 | AutoDeploy 容器内 | 运行时需通过 `environment` 安装，或自定义基础镜像 |
| `docker-compose` | Hexo、前后端项目、数据库依赖、多服务应用 | 独立兄弟容器 | 需要挂载宿主机 `docker.sock` |

项目根目录没有 `AutoDeploy.config.yaml` 时，推送内容只进入裸仓库，不会触发部署。

## 文档导航

- [快速开始](#快速开始)
- [Git 推送地址与触发规则](#git-推送)
- [项目配置字段](#autodeployconfigyaml)
- [Hexo 部署示例](#hexo-部署示例)
- [部署失败自动回退](#部署失败自动回退)
- [版本标签自动发布到 GHCR](#版本标签自动发布到-ghcr)
- [开发与贡献](#开发与贡献)
- [安全说明](#安全说明)
- [常见问题](#常见问题)

默认构建为轻量镜像，不安装 Docker CLI / Compose 插件。使用 `docker-compose.docker.yml` 时会自动启用所需工具；业务项目仍统一通过 Git 推送部署。

## 工作原理

```
git push (SSH / HTTP)
        │
        ▼
  OpenSSH ── git-shell ──┐
                         ├──> 裸仓库 /data/git-home/app.git
  nginx + fcgiwrap ──────┘        │ post-receive 钩子
                                  ▼
                    检查 AutoDeploy.config.yaml
                      │ 无                    │ 普通文件
                      ▼                       ▼
                   跳过部署      导出代码到 .versions/app/<commit>-<attempt>
                                              │
                                              ▼
                               autodeploy-deploy（sudo，root）
                                              │
                         执行顺序：environment → before.sh
                         → workflows → 部署 → 健康检查 → after.sh
                                              │
                         ┌────────────────────┴────────────────────┐
                         ▼                                         ▼
               type: process                            type: docker-compose
      生成 start.sh + supervisor 配置                  docker compose up -d
        进程常驻在本容器内                          （需挂载 /var/run/docker.sock）
```

健康检查通过后，`/data/deploy/app` 符号链接切换到成功版本。部署状态写入 `/data/state/<name>/deploy.json`（`success` / `failed`），部署失败会自动回退到上一可用版本（见"部署失败自动回退"）。

## 快速开始

部署顺序固定为：**先启动 AutoDeploy 服务，再把业务项目推送给它**。业务项目不需要手动在服务器上执行 `docker compose up`。

### 前置条件

- Docker Engine 或 Docker Desktop；
- 使用 `docker-compose` 类型时，宿主机需要 Docker Compose v2；
- 客户端安装 Git，并能访问服务器的 SSH 或 HTTP Git 端口；
- 只向可信用户开放推送权限，原因见[安全说明](#安全说明)。

### 1. 使用发布镜像启动 AutoDeploy（推荐）

下面的命令启动默认轻量镜像，开放 SSH，并将 HTTP Git 绑定在本机：

```bash
docker volume create autodeploy-data

docker run -d \
  --name autodeploy \
  --restart unless-stopped \
  -p 2222:22 \
  -p 127.0.0.1:8080:80 \
  -v autodeploy-data:/data \
  -e AUTODEPLOY_SSH_PORT=2222 \
  -e AUTODEPLOY_HTTP_PORT=8080 \
  -e AUTODEPLOY_HTTP_USER=autodeploy \
  -e AUTODEPLOY_HTTP_PASSWORD= \
  creationwong/autodeploy:V0.1.3
```

确认服务健康；启动日志不包含密码，以 root 读取首次生成的密码：

```bash
docker inspect --format '{{.State.Health.Status}}' autodeploy
docker logs autodeploy
docker exec --user root autodeploy cat /data/credentials/http-password
```

需要 SSH 推送时，在 `docker run` 中增加：

```bash
-e AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)"
```

> 默认镜像不包含 Docker CLI。部署 `docker-compose` 项目时，请使用下方源码构建的 `docker-compose.docker.yml` 覆盖文件，启用 Docker CLI 和 socket。

### 2. 推送第一个业务项目

项目根目录必须包含 `AutoDeploy.config.yaml`。仓库自带的 Python 示例可以直接体验：

```bash
cd examples/sample-app
git init -b main
git add .
git commit -m "init"

# Git 会提示输入上一步读取的 HTTP 密码
git remote add autodeploy http://autodeploy@localhost:8080/app.git
git push autodeploy main
```

也可以通过 SSH 推送：

```bash
git remote add autodeploy ssh://git@localhost:2222/~/app.git
git push autodeploy main
```

### 3. 验证部署

```bash
docker exec autodeploy autodeploy show
docker exec autodeploy supervisorctl status
docker exec autodeploy curl -fsS http://127.0.0.1:3000/
```

`autodeploy show` 中应用状态为 `success` 即表示部署完成。Git push 成功不等同于部署成功，原因见[常见问题](#常见问题)。

### 从源码启动

需要修改 AutoDeploy 本身时再使用源码构建：

```bash
git clone https://github.com/CreationWong/AutoDeploy.git
cd AutoDeploy

AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  docker compose up -d --build
docker logs autodeploy
```

宿主端口可改（容器内固定监听 22/80）：

```bash
AUTODEPLOY_SSH_PORT=22022 AUTODEPLOY_HTTP_PORT=18080 docker compose up -d
```

### 源码构建后使用 docker run

```bash
docker build -t autodeploy:latest .

docker run -d --name autodeploy --restart unless-stopped \
  -p 2222:22 -p 127.0.0.1:8080:80 \
  -v autodeploy-data:/data \
  -e AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -e AUTODEPLOY_HTTP_USER=autodeploy \
  -e AUTODEPLOY_HTTP_PASSWORD= \
  autodeploy:latest
```

> 默认不安装 Docker CLI、不挂载 Docker socket。只有需要 `type: docker-compose` 时，才用 `docker build --build-arg INSTALL_DOCKER_CLI=1 -t autodeploy:latest .` 构建，再给 `docker run` 增加 `-v /var/run/docker.sock:/var/run/docker.sock`；也可使用下面的 compose 覆盖文件自动启用两者。HTTP 仅绑定本机，远程推送使用 SSH 或 HTTPS 网关。`AUTODEPLOY_HTTP_PASSWORD` 留空则首次启动生成密码，以 root 读取：

```bash
docker exec --user root autodeploy cat /data/credentials/http-password

# 显式启用兄弟容器部署（授予 Docker 管理权限）
docker compose -f docker-compose.yml -f docker-compose.docker.yml up -d --build
```

### 推送地址日志

轻量镜像通过 `AUTODEPLOY_SSH_PORT` / `AUTODEPLOY_HTTP_PORT` 显示外部端口，compose 会自动注入与发布端口一致的值。使用 `docker run` 时可显式设置这两个变量；未设置则显示地址模板。HTTP 用户名来自现有凭据文件（首次创建时使用 `AUTODEPLOY_HTTP_USER`）。

启用 Docker CLI 且可访问 Docker 服务时，启动日志和 `autodeploy show` 优先读取当前容器实际发布的端口。例如 `-p 8096:80` 会显示 `http://autodeploy@<host>:8096/app.git`；没有发布 22 端口且未设置外部 SSH 端口时，会显示 SSH 未发布。

可用 `-e AUTODEPLOY_HOST=git.example.com` 指定客户端访问的域名/IP；未指定时，日志使用端口绑定的具体 IP，绑定在 `0.0.0.0` / `::` 则显示 `<host>` 并提示替换。容器无法可靠推断宿主机的公网 IP 或外部域名。

实际端口检测需要 Docker CLI、可访问的 Docker 服务和默认容器 hostname。未挂载 `docker.sock`、构建时禁用 Docker CLI 或自定义 hostname 导致检测失败时，日志使用配置的外部端口；没有配置才显示地址模板。网关覆盖文件会采用 `GATEWAY_SSH_PORT` / `GATEWAY_HTTP_PORT`，也可用 `AUTODEPLOY_SSH_PORT` / `AUTODEPLOY_HTTP_PORT` 显式描述其他外部入口。直接发布的实际端口优先于配置值。端口在每次启动和执行 `autodeploy show` 时重新读取。

### nginx 网关（零端口，生产推荐）

AutoDeploy 不发布任何端口，由单独的 nginx 容器统一入口（需要 Docker Compose v2.24+，使用 `!reset`）：

```bash
# 1. 创建共享网络（名字可用 AUTODEPLOY_NETWORK 覆盖）
docker network create autodeploy-gateway

# 2. 部署 AutoDeploy（零端口，加入共享网络）
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  docker compose -f docker-compose.yml -f docker-compose.gateway.yml up -d --build

# 3. 启动 nginx 网关（SSH 发布 2222，HTTP 仅本机 8080）
cd examples/nginx-gateway && docker compose up -d

# 4. 查看 AutoDeploy 生成的 HTTP 密码
docker exec --user root autodeploy cat /data/credentials/http-password

# 5. 经网关推送项目
git remote add origin http://autodeploy@localhost:8080/app.git
git push origin main
```

网关路由见 `examples/nginx-gateway/nginx.conf`：

- 默认 server → `autodeploy:80`（Git HTTP）；`stream` 的 22 → `autodeploy:22`（Git SSH）；
- `blog.localhost` → `my-app-web:4000`；`app.localhost` → `autodeploy:3000`（容器内 process 应用）。

业务项目接入共享网络，端口不发布到宿主机：

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

健康检查用网络内 DNS：`url: http://my-app-web:<端口>/`。本地可用 `*.localhost` 域名（浏览器自动解析到 127.0.0.1）。示例不提供 TLS，HTTP 默认仅绑定本机；远程 HTTP 推送必须在该本机入口前配置 HTTPS 反向代理，或使用 SSH。不要通过开放明文端口来启用远程推送。网关与后端均限制单次请求体为 128 MiB；需要更大 Git pack 时同时调整两处上限。网关以 HTTP/1.1 流式转发请求体，让后端及时拒绝无效凭据。

业务 compose 部署需在启动 AutoDeploy 时同时加入 `-f docker-compose.docker.yml`；网关覆盖文件本身不会启用 Docker socket。

## Git 推送

| 协议 | 地址 | 认证 |
| --- | --- | --- |
| SSH | `ssh://git@<host>:<SSH_PORT>/~/app.git`（默认 2222） | `AUTHORIZED_KEYS` 或挂载 `/data/authorized_keys` |
| HTTP | `http://<user>@127.0.0.1:<HTTP_PORT>/app.git`（默认本机 8080）；远程使用 `https://<user>@<域名>/app.git` | `AUTODEPLOY_HTTP_USER` / `AUTODEPLOY_HTTP_PASSWORD`，或读取 `/data/credentials/http-password` |

- 裸仓库固定为 `${REPO_NAME}.git`（默认 `app.git`）。
- 只有匹配的分支/标签才触发部署，支持逗号分隔和通配（如 `main,release/*` 或 `*`）。
- 默认触发规则来自容器环境变量 `DEPLOY_BRANCH` / `DEPLOY_TAG` / `DEPLOY_TAG_MODE`；项目可在 `AutoDeploy.config.yaml` 的 `deploy` 段按项目覆盖（见下）。
- 一次推送命中多个分支/标签时，只部署第一个匹配的引用。
- 没有部署配置时直接跳过代码导出，避免纯 Git 仓库产生临时工作副本；配置必须是普通文件，拒绝符号链接和同名目录。
- 轮换 HTTP 密码：删除 `/data/htpasswd` 后重启，或设置 `AUTODEPLOY_HTTP_PASSWORD`。
- 随机密码文件仅 root 可读；显式设置密码时删除旧随机密码文件。已有卷仅保存旧密码散列时不会恢复明文，需要按上述方式轮换。密码不要写入 Git remote URL，交给 Git 的交互提示或安全凭据管理器。

## AutoDeploy.config.yaml

放在项目根目录（可用 `AUTODEPLOY_CONFIG_NAME` 改名）。配置文件名仅允许字母、数字、点、下划线和连字符，不能是 `.`、`..` 或路径。启动、手动设置与部署入口会使用相同规则校验。

### 公共字段

| 字段 | 说明 |
| --- | --- |
| `version` | 必填，当前只支持 `1` |
| `name` | 可选，应用名，默认取 `REPO_NAME`；决定状态/日志目录与 supervisor 程序名 |
| `type` | `process`（默认）或 `docker-compose` |
| `env` | 注入应用、部署命令、钩子与 workflow 的环境变量映射 |
| `healthcheck` | 可选：`url` 或 `port` + `timeout`（秒，默认 30），部署后轮询，失败标记部署失败 |
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

说明：`deploy.branches` 未写则回退到环境变量 `DEPLOY_BRANCH`；`branch` 模式下会在匹配 `deploy.branches`（或其回退值）的分支中查找包含该标签提交的分支并部署其最新提交。

### environment（基础环境构建）

按配置在容器内准备运行时，无需为换运行时重建镜像：

| 字段 | 说明 |
| --- | --- |
| `packages` | 需要安装的 apt 包列表，已安装的自动跳过 |
| `setup` | 以 root 执行的初始化命令列表（添加软件源、安装语言运行时等） |
| `force` | 为 `true` 时忽略缓存强制重建 |

配置内容按 sha256 缓存，未变化输出 `基础环境未变化，跳过构建`。安装在容器可写层；容器被重建后入口脚本会按持久化快照自动重放，应用不会因运行时丢失而启动失败。

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
```

### type: process（运行在本容器内）

| 字段 | 说明 |
| --- | --- |
| `workdir` | 可选，工作目录（相对项目根，默认 `.`） |
| `user` | 可选，运行用户，默认 `autodeploy-app`；禁止 root、git 及管理组身份 |
| `install` | 可选，以受信任的 `git` 部署用户执行的命令列表 |
| `build` | 可选，以受信任的 `git` 部署用户执行的构建命令列表 |
| `start` | 必填，启动命令；supervisor 托管，崩溃自动重启，容器重建后自动拉起 |
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

> 运行时准备：轻量的用 `environment.packages` / `environment.setup`；重型的（整套 Node/JDK 工具链）用构建参数换底座，如 `docker compose build --build-arg BASE_IMAGE=node:20-bookworm-slim`。

业务进程使用独立身份，不能修改部署代码、启动脚本、日志路径或 Git 凭据。发布前将代码与构建产物交还给 `git`，统一开放读取/目录遍历权限，并移除组和其它用户的写权限。运行时可写数据放在自己的 `HOME`（默认 `/home/autodeploy-app`）或专门配置的业务数据目录，勿写入部署目录；该 HOME 默认不持久化。自定义 `user` 必须已存在，且不能属于 `root`、`git`、`docker`、`sudo`、`wheel` 组。安装/构建的 HOME 为 Git 用户目录，运行时 HOME 为业务用户目录。

升级时，入口脚本会将已有 Supervisor 快照中的 root/git 运行身份迁移为默认业务用户，并保护启动脚本与日志目录。显式配置的 `user: root` / `user: git` 需要从项目配置移除，否则后续部署会被拒绝；依赖部署目录可写或高权限的应用也需要调整后重新推送。

### type: docker-compose（兄弟容器）

| 字段 | 说明 |
| --- | --- |
| `file` | 可选，compose 文件路径，默认自动查找 `compose.yaml` / `compose.yml` / `docker-compose.yml` / `docker-compose.yaml` |
| `services` | 可选，只启动指定服务 |
| `build` | 可选，是否 `up --build`，默认 `true` |
| `env` | 透传给 compose（可用于 `${VAR}` 插值，写入 `--env-file`） |

服务端口由应用自己的 compose 用 `ports:` 发布，或加入外部网络由网关代理，AutoDeploy 不写死应用端口。容器内做健康检查时用 `host.docker.internal` 或网络内 DNS。

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

## Hexo 部署示例

Hexo 推荐使用 `docker-compose` 类型：Node 镜像负责生成静态页面，最终镜像只保留 Nginx 和生成后的 `public/`。AutoDeploy 容器本身不需要安装 Node。

确保 Hexo 项目的 `package.json` 有构建脚本，并提交 `package-lock.json`：

```json
{
  "scripts": {
    "build": "hexo generate"
  }
}
```

在项目根目录添加 `AutoDeploy.config.yaml`：

```yaml
version: 1
name: hexo-blog
type: docker-compose
file: docker-compose.yml
services: [web]
build: true
healthcheck:
  url: http://host.docker.internal:14000/
  timeout: 180
```

添加 `docker-compose.yml`：

```yaml
services:
  web:
    build: .
    container_name: hexo-blog-web
    restart: unless-stopped
    ports:
      - "14000:80"
```

添加 `Dockerfile`：

```dockerfile
FROM node:22-alpine AS builder

WORKDIR /site
COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM nginx:1.27-alpine
COPY --from=builder /site/public /usr/share/nginx/html
```

提交并推送后，通过 `http://<host>:14000` 访问站点：

```bash
git add AutoDeploy.config.yaml docker-compose.yml Dockerfile package.json package-lock.json
git commit -m "deploy: configure Hexo for AutoDeploy"
git push autodeploy main
```

注意：

- Hexo 主题如果使用 Git submodule，`git archive` 不会包含子模块工作树。建议把主题代码直接纳入仓库，或在 Docker 构建阶段安装；
- 使用外部 Nginx 网关时，可以移除 `ports`，把 `web` 加入共享网络，并把健康检查改为网络内地址（如 `http://hexo-blog-web/`）；
- 首次构建需要下载 Node 镜像和 npm 依赖，健康检查超时建议设置为 120 秒以上。

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
      - name: 跑测试
        run: |
          pip install -r requirements.txt
          pytest -q
```

- 支持：`jobs`（按定义顺序）、`steps`、`run`（含多行）、`name`、workflow/job/step 三级 `env`（就近覆盖）、`working-directory`、`defaults.run.shell` / `defaults.run.working-directory`、`continue-on-error`、`actions/checkout`（跳过，代码已检出）、`GITHUB_ENV` 跨步骤传变量；
- 自动注入：`CI=true`、`GITHUB_WORKSPACE`、`GITHUB_SHA`、`GITHUB_REF_NAME`、`AUTODEPLOY_*`；
- 不支持：`uses`（除 actions/checkout）、`strategy/matrix`、`services`、`container`（报错中止）；`if`、`needs` 忽略并警告；`on`、`runs-on` 仅兼容忽略；
- 步骤以 root 执行，部署前会把工作目录交还给 `git` 用户。

## 部署失败自动回退

每次部署尝试使用独立版本目录 `deploy/.versions/<repo>/<commit>-<attempt>`，同一提交重试不会覆盖已有目录。`deploy/<repo>` 只在健康检查和 `after.sh` 通过后原子切换；部署期间读取本次版本的固定路径。仓库锁覆盖切换、回退和清理，等待锁的导出目录保持 staging 状态。部署前从独立的 `last-success.json` 记录上一可用版本，失败（环境准备、before/workflow、进程启动、compose、健康检查或 after 阶段）时：

1. 先把失败的提交写入 `state/<name>/failed.json` 并在 `deploy.json.failed_commit` 记录（"标记这个提交"）；
2. 存在上一可用版本 → 把 `deploy/<repo>` 符号链接原子切回上一版本目录，重放旧配置的 `environment`，重新拉起该版本并**再跑一次健康检查**，通过后写回 `success`（`failed_commit` 仍指向失败提交），服务保持可用；
3. 没有上一可用版本（首次部署）→ 停止失败的服务（process 停 supervisor、compose 停项目）、移除失败版本目录与符号链接，仅保留失败标记。

回退不需要复制代码，也不重跑旧版本的 install/build；部署前失败时保留仍在运行的旧服务。`docker-compose` 回退会重建 compose 栈并清理孤儿容器。容器重启时通过 `pending.json` / `deploying` 状态检测中断，按 `previous.json` 恢复旧目录和该版本保存的启动脚本、Supervisor 配置；compose 类型重放旧栈。缺少启动快照时禁用自动启动并提示手动部署，避免用新命令启动旧代码。最近 5 个版本之外仍会保护当前和回退目录。`autodeploy show` 会显示 `failed_commit` 与 `failed.json` 标记。

## 容器内管理命令

容器内置 `autodeploy` 命令，进入容器后即可查看/修改设置与提交历史：

```bash
docker exec -it autodeploy autodeploy show               # 设置 + 最近提交 + 部署状态
docker exec -it autodeploy autodeploy log 20             # 当前项目最近 20 条提交
docker exec -it autodeploy autodeploy set DEPLOY_BRANCH 'main,release/*'
docker exec -it autodeploy autodeploy set DEPLOY_TAG 'v*'
docker exec -it autodeploy autodeploy deploy v1.2.0      # 手动部署指定 ref
docker exec -it autodeploy autodeploy retry              # 重跑上次成功提交
docker exec -it autodeploy autodeploy logs my-app 100    # 查看应用日志
docker exec -it autodeploy autodeploy help
```

| 命令 | 说明 |
| --- | --- |
| `autodeploy show` | 显示设置（REPO_NAME/触发规则/配置名/端口/用户名）、裸仓库最近提交、各应用部署状态 |
| `autodeploy set <KEY> <VALUE>` | 修改默认设置，写入 `/data/settings.env` 并即时更新 `/etc/autodeploy/env` |
| `autodeploy deploy <branch\|tag\|commit>` | 手动部署指定 ref（可对历史提交/标签，用于回滚） |
| `autodeploy retry` | 重新部署上次成功提交 |
| `autodeploy logs [name] [N]` | 查看应用日志（deploy.log / app.log / app.err.log，默认第一个应用、50 行） |
| `autodeploy log [N]` | 查看当前项目提交历史（默认 10 条，包含分支和标签） |
| `autodeploy license` | 查看 GNU GPL 第 3 版许可全文 |

- 可修改 KEY：`REPO_NAME`、`DEPLOY_BRANCH`、`DEPLOY_TAG`、`DEPLOY_TAG_MODE`、`AUTODEPLOY_CONFIG_NAME`；
- 修改对下一次 `git push` 生效，并持久化到 `/data/settings.env`，容器重建后由入口脚本重新加载；
- 项目级触发规则优先：`AutoDeploy.config.yaml` 的 `deploy` 段会覆盖上述默认值；
- `REPO_NAME` 只改变部署目录/默认应用名，不会重命名已存在的裸仓库。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `AUTODEPLOY_SSH_PORT` | compose 默认 `2222`，并注入容器 | compose 的 SSH 发布端口；日志无法读取实际映射或使用外部网关时的端口提示（容器内固定 22） |
| `AUTODEPLOY_HTTP_PORT` | compose 默认本机 `8080`，并注入容器 | compose 的 HTTP 发布端口，仅绑定 127.0.0.1；也可作为外部入口的日志提示（容器内固定 80） |
| `AUTODEPLOY_HOST` | 空 | 日志中的外部域名/IP；留空使用具体绑定 IP，通配绑定使用 `<host>` |
| `REPO_NAME` | `app` | 裸仓库名（`${REPO_NAME}.git`），也作为默认应用名 |
| `DEPLOY_BRANCH` | `main` | 默认触发部署的分支，支持逗号分隔和 `*` 通配（可被 `deploy.branches` 覆盖） |
| `DEPLOY_TAG` | 空 | 默认触发部署的标签，支持逗号分隔和 `*` 通配，空=不启用（可被 `deploy.tags` 覆盖） |
| `DEPLOY_TAG_MODE` | `commit` | 标签命中后的行为：`commit` / `branch`（可被 `deploy.tag_mode` 覆盖） |
| `AUTODEPLOY_CONFIG_NAME` | `AutoDeploy.config.yaml` | 部署配置文件名 |
| `AUTHORIZED_KEYS` | 空 | SSH 公钥内容（可多行），与 `/data/authorized_keys` 合并 |
| `AUTODEPLOY_HTTP_USER` | `autodeploy` | HTTP Basic 用户名 |
| `AUTODEPLOY_HTTP_PASSWORD` | 空 | HTTP Basic 密码，留空则首次随机生成 |
| `AUTODEPLOY_APP_USER` | `autodeploy-app` | `process` 默认运行用户，可被配置文件的 `user` 覆盖；必须为非管理身份 |
| `AUTODEPLOY_DATA_DIR` | `/data` | 数据目录 |
| `AUTODEPLOY_NETWORK` | `autodeploy-gateway` | 网关模式下共享网络名 |
| `GATEWAY_HTTP_PORT` / `GATEWAY_SSH_PORT` | `8080` / `2222` | 网关发布端口，HTTP 仅绑定 127.0.0.1 |
| `BASE_IMAGE`（构建参数） | `debian:bookworm-slim` | 底座镜像，重型运行时换底座 |
| `INSTALL_DOCKER_CLI`（构建参数） | `0` | 默认省去 Docker CLI / Compose 插件；`docker-compose.docker.yml` 自动设为 `1` |
| `YQ_VERSION`（构建参数） | `v4.44.3` | 部署脚本解析 YAML 的 yq 版本 |

## 数据与日志

仓库、部署状态、应用版本和日志保存在 `/data` 数据卷中：

```
/data
├── git-home/app.git                  # 裸仓库
├── git-home/.ssh/authorized_keys
├── htpasswd                          # HTTP Basic 凭据
├── credentials/http-password         # 随机生成的明文密码，仅 root 可读
├── deploy/app                        # current 符号链接 -> .versions/<repo>/<commit>
├── deploy/.versions/<repo>/<commit>-<attempt>  # 每次尝试的代码，保护当前和回退目录
├── state/<name>/deploy.json          # 最近部署状态（含 failed_commit）
├── state/<name>/failed.json          # 最近一次失败的提交标记
├── state/<name>/previous.commit      # 上一可用版本 commit（崩溃恢复用）
├── state/<name>/previous.json        # 上一可用版本目录和启动快照位置
├── state/<name>/last-success.json    # 最后成功版本，不被失败尝试覆盖
├── state/<name>/pending.json         # 尚未完成的部署事务
├── state/<name>/releases/<version>/  # 按版本保存的启动脚本和 Supervisor 配置
├── state/<name>/environment.yml      # 当前生效的 environment 快照
├── state/<name>/environment.boot     # 上次构建环境的容器实例 ID
├── state/<name>/start.sh             # process 类型启动脚本
├── state/<name>/supervisor.conf
├── logs/<name>/deploy.log            # 部署日志（超 10MB 轮转为 deploy.log.1）
├── logs/<name>/app.log               # 应用 stdout
└── logs/<name>/app.err.log           # 应用 stderr
```

## 安全说明

安全问题请按 [安全政策](SECURITY.md)通过私有渠道报告。该政策也说明了支持版本和部署权限边界。

- SSH 只允许 `git` 用户、仅公钥认证，shell 限制为 `git-shell`；
- SSH 禁止所有转发（包括 Unix socket）、PTY 与用户 rc 脚本；
- `git` 用户只能通过 sudo 免密执行 `/usr/local/bin/autodeploy-deploy`；
- 部署脚本校验目标目录必须位于 `/data/deploy` 内；
- **推送权限 ≈ 容器内 root**：`.AutoDeploy/before.sh`、workflows、`environment.setup` 均以 root 执行，安装/构建使用具有 sudo 部署权限的 `git` 身份。能推送的人仍是受信任管理员，请把推送凭据当 root 凭据保管；常驻业务进程默认使用独立的 `autodeploy-app` 用户，并通过 `setpriv --no-new-privs` 禁止经 setuid 等机制获得新权限；
- **挂载 `docker.sock` ≈ 宿主机 root**：默认不挂载，仅通过 `docker-compose.docker.yml` 显式启用，或手动为 `docker run` 增加挂载；
- HTTP Basic 认证默认仅供本机访问，生产远程访问必须经 HTTPS；示例网关也默认只把 HTTP 绑定在本机，不包含证书配置；
- HTTP 密码由 `/dev/urandom` 生成，不写日志；明文保存在 root-only 的 `/data/credentials/http-password`，认证散列保存在 `/data/htpasswd`；新设密码使用 bcrypt，密码经 stdin 传给 htpasswd；
- 初始化 HTTP 凭据后清除明文密码环境变量；部署子脚本和业务进程从空环境启动，只注入基础变量与项目声明的 env，不继承部署凭据。需要代理或其它运行变量时请在项目 env 中显式声明；
- SSH 主机密钥在首次启动时生成，保存在 `/data/ssh`，不随镜像分发。

构建上下文采用白名单，仅包含 Dockerfile、许可证、版权声明、入口脚本、运行脚本与服务配置，避免 `.env`、本地工具和其他无关文件被发送给构建器。nginx 访问与错误日志输出到容器日志；默认 compose 使用 `json-file` 并配置每份 10 MiB、最多 3 份的轮转。使用 `docker run` 时可增加 `--log-opt max-size=10m --log-opt max-file=3`。

## 常见问题

- **推送成功但没部署？** 确认分支在 `DEPLOY_BRANCH` 内、根目录存在 `AutoDeploy.config.yaml`，查看 `docker logs autodeploy` 或 `/data/logs/<name>/deploy.log`。
- **进程没起来？** `docker exec autodeploy supervisorctl status`，再看 `app.err.log`。
- **推送输出 `[AutoDeploy] 错误: ...` 但 push 成功？** post-receive 在对象入库后运行，无法拒绝推送；实际状态看 `/data/state/<name>/deploy.json`。
- **容器重建后部署还在吗？** 在。裸仓库、工作目录、supervisor 配置、日志、基础环境快照都持久化在 `/data`，入口脚本自动恢复。
- **应用端口怎么暴露？** `docker-compose` 类型由应用 compose 的 `ports:` 发布；`process` 类型加入外部网络后用 nginx 网关代理，均不需要改 AutoDeploy 自身。

## 开发与贡献

本地检查使用 Python 3.10+。环境要求、检查命令、GitHub Actions 触发条件和发布步骤见 [开发文档](docs/development.md)。

## 版本标签自动发布到 GHCR

[发布流水线](.github/workflows/publish-ghcr.yml) 按 **发布内容进入 main → 推送版本标签 → CI 通过 → 发布镜像** 的顺序执行。维护者先将更改提交到远端 main，或将 PR 合并到 main，再创建并推送指向该提交的版本标签。发布任务在 CI 通过后复核 main 历史，并确认构建提交与已检查的提交一致，然后构建 `linux/amd64` 和 `linux/arm64` 镜像并发布到 GHCR。

版本标签支持 `V0.1.3`、`v0.1.3` 和 `V0.1.3-rc.1` 等格式。镜像标签保留版本标签原文，地址为 `ghcr.io/creationwong/autodeploy:<版本标签>`。

所有分支的提交，以及 PR 的创建、更新和重新打开，都会运行 CI；仅修改文档的提交或 PR 会跳过检查。PR 合并后，目标分支的新提交也按相同规则运行检查。镜像发布仅由指向 main 历史提交的版本标签触发，并始终运行完整 CI；PR、未合并分支上的标签和非版本标签均不发布镜像。

例如，`V0.1.3` 发布完成后，可运行：

```bash
docker pull ghcr.io/creationwong/autodeploy:V0.1.3
```

发布使用 GitHub 提供的 `GITHUB_TOKEN`，无需另行配置登录密钥。镜像可在仓库关联的 Packages 中查看；维护者将包可见性设为 Public 后，用户即可匿名拉取。完整发布步骤见 [开发文档](docs/development.md#发布版本)。

## 许可证与再分发

AutoDeploy 的项目代码由 **CreationWong** 版权所有：`Copyright (C) 2026 CreationWong`，按 **GNU General Public License 第 3 版**（SPDX：`GPL-3.0-only`）授权。许可全文见 [LICENSE](LICENSE)，版权及第三方说明见 [NOTICE](NOTICE)。本项目不提供任何担保，包括适销性或特定用途适用性的默示担保。

你可以按 GPLv3 条款使用、修改和再分发本项目，包括商业使用。再分发时需遵守许可全文，特别是：

- 保留版权、许可及无担保声明，并随分发提供 GPLv3 全文；
- 分发修改版时，明确标注修改事实及相关日期，按 GPLv3 授权受其覆盖的修改版；
- 分发镜像或其他非源码形式时，按 GPLv3 第 6 条提供该版本完整的对应源码，包括构建和安装所需文件；
- 第三方组件保留各自的版权和许可，并按其许可履行源码提供等要求。镜像中的 Debian、Git、nginx、OpenSSH、Docker CLI、yq 等组件不因本项目声明而变更许可。

按当前 Dockerfile 构建的镜像会附带 `/usr/share/doc/autodeploy/LICENSE`、`NOTICE`，以及 `/usr/share/doc/autodeploy/source/` 中与该次构建一致的 AutoDeploy 源码、配置和 Dockerfile。可运行 `autodeploy license` 查看许可全文，也可导出项目源码：

```bash
container_id=$(docker create ghcr.io/creationwong/autodeploy:V0.1.3)
docker cp "$container_id:/usr/share/doc/autodeploy/source" ./autodeploy-source
docker rm "$container_id"
```

该源码目录覆盖 AutoDeploy 本身；再分发整个镜像时还需处理第三方组件各自的许可和对应源码要求。公开 Git 仓库应保留每个发布版本的源码及构建文件，使镜像接收者能够获取准确对应的版本。
