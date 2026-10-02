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

HTTP 推送：

```bash
git push http://autodeploy:<密码>@localhost:8080/app.git main
```

## 推送地址

| 协议 | 地址 | 认证 |
| --- | --- | --- |
| SSH | `ssh://git@<host>:2222/~/app.git` | `AUTHORIZED_KEYS` 环境变量或 `/data/authorized_keys` 挂载文件 |
| HTTP | `http://<user>@<host>:8080/app.git` | `AUTODEPLOY_HTTP_USER` / `AUTODEPLOY_HTTP_PASSWORD`，或首次启动随机生成并打印 |

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

配置内容会做 sha256 缓存，未变化时输出 `基础环境未变化，跳过构建`。

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

> compose 容器运行在宿主机 Docker 上，不是 AutoDeploy 容器内部。需要在 `docker-compose.yml` 中取消注释 `/var/run/docker.sock` 挂载。

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
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
├── state/<name>/environment.sha256   # 基础环境缓存指纹
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
