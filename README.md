# AutoDeploy

自带 Git 服务器与自动部署能力的 Docker 容器：把代码 `git push` 进来，容器扫描项目根目录的 `AutoDeploy.config.yaml`——没有就只入库不部署，有就按配置部署。

- `type: process`：以 supervisor 托管进程，运行在 AutoDeploy 容器内部；
- `type: docker-compose`：调用宿主机 Docker，以兄弟容器运行应用的 compose。

## 工作原理

```
git push (SSH / HTTP)
        │
        ▼
  OpenSSH ── git-shell ──┐
                         ├──> 裸仓库 /data/git-home/app.git
  nginx + fcgiwrap ──────┘        │ post-receive 钩子
                                  ▼
       导出代码 -> /data/deploy/.versions/app/<commit>
         deploy/app 符号链接 -> 当前版本
                                  │
                    扫描 AutoDeploy.config.yaml
                      │ 无                    │ 有
                      ▼                       ▼
                   跳过部署      autodeploy-deploy（sudo，root）
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

部署状态写入 `/data/state/<name>/deploy.json`（`success` / `failed`），部署失败会自动回退到上一可用版本（见"部署失败自动回退"）。

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

宿主端口可改（容器内固定监听 22/80）：

```bash
AUTODEPLOY_SSH_PORT=22022 AUTODEPLOY_HTTP_PORT=18080 docker compose up -d
```

### 方式二：docker run

```bash
docker build -t autodeploy:latest .

docker run -d --name autodeploy --restart unless-stopped \
  -p 2222:22 -p 8080:80 \
  -v autodeploy-data:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --add-host=host.docker.internal:host-gateway \
  -e AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -e AUTODEPLOY_HTTP_USER=autodeploy \
  -e AUTODEPLOY_HTTP_PASSWORD= \
  -e AUTODEPLOY_SSH_PORT=2222 \
  -e AUTODEPLOY_HTTP_PORT=8080 \
  autodeploy:latest
```

> `docker.sock` 与 `--add-host` 是 `type: docker-compose` 部署需要的；只跑 `process` 类型可去掉。`AUTODEPLOY_HTTP_PASSWORD` 留空则首次启动随机生成并打印。

### 方式三：nginx 网关（零端口，生产推荐）

AutoDeploy 不发布任何端口，由单独的 nginx 容器统一入口（需要 Docker Compose v2.24+，使用 `!reset`）：

```bash
# 1. 创建共享网络（名字可用 AUTODEPLOY_NETWORK 覆盖）
docker network create autodeploy-gateway

# 2. 部署 AutoDeploy（零端口，加入共享网络）
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  docker compose -f docker-compose.yml -f docker-compose.gateway.yml up -d --build

# 3. 启动 nginx 网关（单独容器，默认发布 2222/8080）
cd examples/nginx-gateway && docker compose up -d

# 4. 查看 AutoDeploy 生成的 HTTP 密码
docker logs autodeploy | grep 密码

# 5. 经网关推送项目
git remote add origin http://autodeploy:<密码>@localhost:8080/app.git
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

健康检查用网络内 DNS：`url: http://my-app-web:<端口>/`。本地可用 `*.localhost` 域名（浏览器自动解析到 127.0.0.1）；生产换真实域名并在网关终止 TLS。

## Git 推送

| 协议 | 地址 | 认证 |
| --- | --- | --- |
| SSH | `ssh://git@<host>:<SSH_PORT>/~/app.git`（默认 2222） | `AUTHORIZED_KEYS` 或挂载 `/data/authorized_keys` |
| HTTP | `http://<user>@<host>:<HTTP_PORT>/app.git`（默认 8080） | `AUTODEPLOY_HTTP_USER` / `AUTODEPLOY_HTTP_PASSWORD`，或首次启动随机生成并打印 |

- 裸仓库固定为 `${REPO_NAME}.git`（默认 `app.git`）。
- 只有匹配的分支/标签才触发部署，支持逗号分隔和通配（如 `main,release/*` 或 `*`）。
- 默认触发规则来自容器环境变量 `DEPLOY_BRANCH` / `DEPLOY_TAG` / `DEPLOY_TAG_MODE`；项目可在 `AutoDeploy.config.yaml` 的 `deploy` 段按项目覆盖（见下）。
- 一次推送命中多个分支/标签时，只部署第一个匹配的引用。
- 轮换 HTTP 密码：删除 `/data/htpasswd` 后重启，或设置 `AUTODEPLOY_HTTP_PASSWORD`。

## AutoDeploy.config.yaml

放在项目根目录（可用 `AUTODEPLOY_CONFIG_NAME` 改名）。

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
| `user` | 可选，运行用户，默认 `git` |
| `install` | 可选，部署前按顺序执行的命令列表 |
| `build` | 可选，构建命令列表 |
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

每个提交部署到独立版本目录 `deploy/.versions/<repo>/<commit>`，`deploy/<repo>` 是指向当前版本的符号链接，切换用原子 `rename` 完成（不会出现目录空窗）。部署前从 `deploy.json` 记录上一可用版本，失败（进程未起、compose 失败、健康检查未通过、`after.sh` 失败）时：

1. 先把失败的提交写入 `state/<name>/failed.json` 并在 `deploy.json.failed_commit` 记录（"标记这个提交"）；
2. 存在上一可用版本 → 把 `deploy/<repo>` 符号链接原子切回上一版本目录，重放旧配置的 `environment`，重新拉起该版本并**再跑一次健康检查**，通过后写回 `success`（`failed_commit` 仍指向失败提交），服务保持可用；
3. 没有上一可用版本（首次部署）→ 停止失败的服务（process 停 supervisor、compose 停项目）、移除失败版本目录与符号链接，仅保留失败标记。

回退只是重指符号链接，不需要复制代码；`docker-compose` 回退会重建 compose 栈并清理孤儿容器（同样需要 Docker）。容器重启时若发现 `deploy.json` 仍为 `deploying`（部署中途被杀），入口脚本会按 `state/<name>/previous.commit` 把符号链接切回上一版本。`autodeploy show` 会显示 `failed_commit` 与 `failed.json` 标记。

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
| `autodeploy log [N]` | 查看当前项目提交历史（默认 10 条，含分支装饰） |

- 可修改 KEY：`REPO_NAME`、`DEPLOY_BRANCH`、`DEPLOY_TAG`、`DEPLOY_TAG_MODE`、`AUTODEPLOY_CONFIG_NAME`；
- 修改对下一次 `git push` 生效，并持久化到 `/data/settings.env`，容器重建后由入口脚本重新加载；
- 项目级触发规则优先：`AutoDeploy.config.yaml` 的 `deploy` 段会覆盖上述默认值；
- `REPO_NAME` 只改变部署目录/默认应用名，不会重命名已存在的裸仓库。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `AUTODEPLOY_SSH_PORT` | `2222` | 宿主机映射的 SSH 端口（compose 变量，容器内固定 22） |
| `AUTODEPLOY_HTTP_PORT` | `8080` | 宿主机映射的 HTTP 端口（compose 变量，容器内固定 80） |
| `REPO_NAME` | `app` | 裸仓库名（`${REPO_NAME}.git`），也作为默认应用名 |
| `DEPLOY_BRANCH` | `main` | 默认触发部署的分支，支持逗号分隔和 `*` 通配（可被 `deploy.branches` 覆盖） |
| `DEPLOY_TAG` | 空 | 默认触发部署的标签，支持逗号分隔和 `*` 通配，空=不启用（可被 `deploy.tags` 覆盖） |
| `DEPLOY_TAG_MODE` | `commit` | 标签命中后的行为：`commit` / `branch`（可被 `deploy.tag_mode` 覆盖） |
| `AUTODEPLOY_CONFIG_NAME` | `AutoDeploy.config.yaml` | 部署配置文件名 |
| `AUTHORIZED_KEYS` | 空 | SSH 公钥内容（可多行），与 `/data/authorized_keys` 合并 |
| `AUTODEPLOY_HTTP_USER` | `autodeploy` | HTTP Basic 用户名 |
| `AUTODEPLOY_HTTP_PASSWORD` | 空 | HTTP Basic 密码，留空则首次随机生成 |
| `AUTODEPLOY_APP_USER` | `git` | `process` 默认运行用户，可被配置文件的 `user` 覆盖 |
| `AUTODEPLOY_DATA_DIR` | `/data` | 数据目录 |
| `AUTODEPLOY_NETWORK` | `autodeploy-gateway` | 网关模式下共享网络名 |
| `GATEWAY_HTTP_PORT` / `GATEWAY_SSH_PORT` | `8080` / `2222` | 网关容器发布端口 |
| `BASE_IMAGE`（构建参数） | `debian:bookworm-slim` | 底座镜像，重型运行时换底座 |
| `INSTALL_DOCKER_CLI`（构建参数） | `1` | 是否安装 docker CLI / compose 插件 |
| `YQ_VERSION`（构建参数） | `v4.44.3` | 部署脚本解析 YAML 的 yq 版本 |

## 数据与日志

都在 `/data` 卷内：

```
/data
├── git-home/app.git                  # 裸仓库
├── git-home/.ssh/authorized_keys
├── htpasswd                          # HTTP Basic 凭据
├── deploy/app                        # current 符号链接 -> .versions/<repo>/<commit>
├── deploy/.versions/<repo>/<commit>  # 每个版本的代码（保留最近 5 个）
├── state/<name>/deploy.json          # 最近部署状态（含 failed_commit）
├── state/<name>/failed.json          # 最近一次失败的提交标记
├── state/<name>/previous.commit      # 上一可用版本 commit（崩溃恢复用）
├── state/<name>/environment.yml      # 当前生效的 environment 快照
├── state/<name>/environment.boot     # 上次构建环境的容器实例 ID
├── state/<name>/start.sh             # process 类型启动脚本
├── state/<name>/supervisor.conf
├── logs/<name>/deploy.log            # 部署日志（超 10MB 轮转为 deploy.log.1）
├── logs/<name>/app.log               # 应用 stdout
└── logs/<name>/app.err.log           # 应用 stderr
```

## 安全说明

- SSH 只允许 `git` 用户、仅公钥认证，shell 限制为 `git-shell`；
- `git` 用户只能通过 sudo 免密执行 `/usr/local/bin/autodeploy-deploy`；
- 部署脚本校验目标目录必须位于 `/data/deploy` 内；
- **推送权限 ≈ 容器内 root**：`.AutoDeploy/before.sh`、workflows、`environment.setup` 均以 root 执行，`git` 用户可免密 `sudo autodeploy-deploy`，且 `process` 类型默认就以 `git` 运行。能推送到该仓库的人可在容器内以 root 执行任意代码，请把推送凭据当 root 凭据保管；
- **挂载 `docker.sock` ≈ 宿主机 root**：仅当需要 `type: docker-compose` 时挂载，否则从 `docker-compose.yml` 移除该 volume（或用 profile 控制）；
- HTTP 默认是明文 Basic 认证，生产务必经 TLS 网关（见"方式三"），不要把凭据直接暴露在公网；
- HTTP 密码由 `/dev/urandom` 生成（真随机、无固定种子），仅首次启动打印并持久化在 `/data/htpasswd`；
- SSH 主机密钥首次启动随机生成并持久化在 `/data/ssh`，不烤进镜像。

## 常见问题

- **推送成功但没部署？** 确认分支在 `DEPLOY_BRANCH` 内、根目录存在 `AutoDeploy.config.yaml`，查看 `docker logs autodeploy` 或 `/data/logs/<name>/deploy.log`。
- **进程没起来？** `docker exec autodeploy supervisorctl status`，再看 `app.err.log`。
- **推送输出 `[AutoDeploy] 错误: ...` 但 push 成功？** post-receive 在对象入库后运行，无法拒绝推送；实际状态看 `/data/state/<name>/deploy.json`。
- **容器重建后部署还在吗？** 在。裸仓库、工作目录、supervisor 配置、日志、基础环境快照都持久化在 `/data`，入口脚本自动恢复。
- **应用端口怎么暴露？** `docker-compose` 类型由应用 compose 的 `ports:` 发布；`process` 类型加入外部网络后用 nginx 网关代理，均不需要改 AutoDeploy 自身。

## 开发辅助

- `opencode.json` 已声明 [ponytail](https://github.com/DietrichGebert/ponytail) 插件，opencode 启动时自动安装并按 YAGNI 规则约束代码改动。默认强度 `full`，可用 `/ponytail lite|full|ultra|off` 切换。修改配置后需重启 opencode 生效。
- `.opencode/skills/` 内置两个 skill：`sensitive-info-check`（提交/推送前扫描密钥与隐私信息，可用 `scan.sh --staged|--outgoing`）与 `security-audit`（Cloudflare 多阶段安全审计，校验器需要 Node）。
