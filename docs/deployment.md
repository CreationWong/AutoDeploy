# 部署 AutoDeploy 服务

先部署 AutoDeploy，再通过 Git 推送部署业务项目。第一次使用请先完成[新手教程](getting-started.md)，本页介绍服务器接入、Docker Compose 业务模式和网关配置。

## 使用发布镜像

当前版本为 `V0.1.3`，支持 `linux/amd64` 和 `linux/arm64`。以下命令在运行 Docker 的机器上执行，SSH 公钥必须来自你准备用于推送的客户端；已有公钥时不要覆盖原密钥。

```bash
docker run -d \
  --name autodeploy \
  --restart unless-stopped \
  --log-opt max-size=10m --log-opt max-file=3 \
  -p 2222:22 -p 127.0.0.1:8080:80 \
  -v autodeploy-data:/data \
  -e AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  -e AUTODEPLOY_SSH_PORT=2222 \
  -e AUTODEPLOY_HTTP_PORT=8080 \
  ghcr.io/creationwong/autodeploy:V0.1.3

docker logs autodeploy
docker inspect --format '{{.State.Health.Status}}' autodeploy
```

没有该公钥文件时，先在客户端生成专用密钥，或在本机体验时省略 `AUTHORIZED_KEYS`，改用本机 HTTP Git 入口。公钥可以传给服务器，私钥始终保留在客户端。AutoDeploy 不提供密码式 SSH 登录。

在业务项目中配置部署 remote，地址中的 `SERVER_HOST` 要换成实际服务器域名或 IP：

```bash
git remote add autodeploy ssh://git@SERVER_HOST:2222/~/app.git
git push autodeploy main
```

如果使用了专用密钥，请在客户端 SSH 配置中为该主机指定 `IdentityFile`。首次连接应与服务器上的主机公钥指纹核对：

```bash
docker exec autodeploy ssh-keygen -lf /data/ssh/ssh_host_ed25519_key.pub
```

服务器需允许客户端访问 Git SSH 端口 `2222`。HTTP Git 端口 `8080` 默认只允许服务器本机访问，远程访问使用 SSH 推送、SSH 隧道或 HTTPS 网关。服务健康仅表示 AutoDeploy 入口可用，业务部署结果仍要用 `autodeploy show` 和业务健康检查确认。

## 启用 Docker Compose 业务部署

发布的轻量镜像支持 `process`。要部署 `type: docker-compose` 项目，需要给 AutoDeploy 安装 Docker CLI / Compose 插件，并挂载宿主机 socket；仅安装宿主机的 Compose 不足以让容器内获得这些工具。

从源码仓库启动带工具的 AutoDeploy：

```bash
git clone https://github.com/CreationWong/AutoDeploy.git
cd AutoDeploy
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  docker compose -f docker-compose.yml -f docker-compose.docker.yml up -d --build
```

这是启动部署服务本身。之后给业务项目添加 `AutoDeploy.config.yaml` 和它自己的 Compose 文件，再推送给 AutoDeploy；不需要手动启动业务容器。已有同名 AutoDeploy 容器时，先按原部署方式安排迁移并复用数据卷，不要直接再启动第二个同名容器。

业务端口由业务项目自己的 `ports` 发布，或加入网关网络。挂载 Docker socket 相当于授予宿主机容器管理权限，仅向可信部署者开放。更多构建选项见[开发文档](development.md#构建与运行源码)。

## nginx 网关与业务访问

下面命令在 AutoDeploy 源码仓库根目录执行。示例使用本机 HTTP 入口，不包含 TLS；公网部署需要另行配置 HTTPS。

AutoDeploy 不发布任何端口，由单独的 nginx 容器统一入口（需要 Docker Compose v2.24+，使用 `!reset`）：

```bash
# 1. 创建共享网络（名字可用 AUTODEPLOY_NETWORK 覆盖）
docker network create autodeploy-gateway

# 2. 部署 AutoDeploy（零端口，加入共享网络）
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  docker compose -f docker-compose.yml -f docker-compose.gateway.yml up -d --build

# 3. 启动 nginx 网关（SSH 发布 2222，HTTP 仅本机 8080）
(cd examples/nginx-gateway && docker compose up -d)

# 4. 查看 AutoDeploy 生成的 HTTP 密码
docker exec --user root autodeploy cat /data/credentials/http-password

# 5. 经网关推送项目
# 以下两条在业务项目目录执行
git remote add autodeploy http://autodeploy@localhost:8080/app.git
git push autodeploy main
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

构建参数见[开发文档](development.md#构建与运行源码)，配置优先级、推送地址和密码轮换见[日常管理](operations.md)。
