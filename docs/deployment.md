# 部署 AutoDeploy 服务

先启动 AutoDeploy，再推送业务代码。本页介绍服务器、Compose 和网关配置；本机体验见[新手教程](getting-started.md)。

## 使用发布镜像

`V0.1.3` 支持 `linux/amd64` 和 `linux/arm64`。在 Docker 主机上执行以下命令，使用推送客户端的 SSH 公钥：

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

没有公钥时，在客户端生成专用密钥，不要覆盖已有密钥。私钥留在客户端，公钥提供给服务器。SSH 仅支持公钥登录；本机体验可省略 `AUTHORIZED_KEYS`，改用 HTTP。

在业务项目中配置部署 remote，地址中的 `SERVER_HOST` 要换成实际服务器域名或 IP：

```bash
git remote add autodeploy ssh://git@SERVER_HOST:2222/~/app.git
git push autodeploy main
```

如果使用了专用密钥，请在客户端 SSH 配置中为该主机指定 `IdentityFile`。首次连接应与服务器上的主机公钥指纹核对：

```bash
docker exec autodeploy ssh-keygen -lf /data/ssh/ssh_host_ed25519_key.pub
```

开放服务器的 SSH 端口 `2222`。HTTP 端口 `8080` 仅限本机，远程使用 SSH、SSH 隧道或 HTTPS 网关。AutoDeploy 显示健康不代表业务已部署成功，请用 `autodeploy show` 确认。

## 启用 Docker Compose 业务部署

默认镜像用于 `process`。部署 `docker-compose` 项目还需在 AutoDeploy 容器内安装 Docker CLI / Compose，并挂载宿主机 socket。只在宿主机安装 Compose 不够。

从源码仓库启动带工具的 AutoDeploy：

```bash
git clone https://github.com/CreationWong/AutoDeploy.git
cd AutoDeploy
AUTHORIZED_KEYS="$(cat ~/.ssh/id_ed25519.pub)" \
  docker compose -f docker-compose.yml -f docker-compose.docker.yml up -d --build
```

以上命令只启动 AutoDeploy。业务项目添加配置和 Compose 文件后，通过 Git 推送部署。已有同名容器时，请迁移并复用原数据卷，不要重复创建。

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

健康检查使用网络内地址，如 `http://my-app-web:<端口>/`。本机浏览器可用 `*.localhost`。远程访问需配置 HTTPS，或改用 SSH 推送，不要开放明文 HTTP 端口。

网关和后端的请求体上限均为 128 MiB。需要上传更大的 Git pack 时，两处都要调整。网关流式转发请求，后端可提前拒绝无效凭据。

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
| `AUTODEPLOY_LANG` | `en` | Dev 源码新增：运行时输出语言，`en` 英文、`zh` 中文；可通过 `autodeploy set` 持久化，见[输出语言](operations.md#输出语言) |
| `AUTODEPLOY_DATA_DIR` | `/data` | 数据目录 |
| `AUTODEPLOY_NETWORK` | `autodeploy-gateway` | 网关模式下共享网络名 |
| `GATEWAY_HTTP_PORT` / `GATEWAY_SSH_PORT` | `8080` / `2222` | 网关发布端口，HTTP 仅绑定 127.0.0.1 |

构建参数见[开发文档](development.md#构建与运行源码)，配置优先级、推送地址和密码轮换见[日常管理](operations.md)。
