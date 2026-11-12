# 从零开始：用 Git Push 部署第一个网站

这篇教程带你在自己的电脑上部署一个简单网站，完成“启动服务 → 推送代码 → 浏览器访问 → 更新 → 回滚”的完整流程。无需注册域名，也无需先把项目上传到 GitHub。

示例使用 AutoDeploy `V0.1.3` 的 `process` 模式：网站运行在 AutoDeploy 内部，nginx 网关负责让浏览器访问它。业务代码始终通过 Git 推送部署。

## 1. 准备环境

需要安装并启动 Docker Engine 或 Docker Desktop，同时准备 Docker Compose v2 和 Git。Windows 请将 Docker Desktop 切换到 Linux 容器，并在 WSL 或 Git Bash 中执行本教程的 Bash 命令；macOS、Linux 可使用终端。

先检查：

```bash
docker version
docker compose version
git --version
```

`docker version` 应能显示服务端信息。若提示无法连接 Docker，先启动 Docker 服务。以下步骤在同一台电脑上执行；使用远程服务器的方法见文末。

教程使用本机 `8080` 和 `8088` 端口。如果端口已被其他程序使用，可在下面的 Compose 文件中修改左侧宿主端口，并同步调整后续 URL。请选一个新的目录，不要在已有业务仓库内操作。

## 2. 创建部署服务

```bash
mkdir autodeploy-tutorial
cd autodeploy-tutorial
```

在该目录创建 `compose.yaml`，写入：

```yaml
name: autodeploy-tutorial

services:
  autodeploy:
    image: ghcr.io/creationwong/autodeploy:V0.1.3
    restart: unless-stopped
    ports:
      - "127.0.0.1:8080:80"
    environment:
      REPO_NAME: app
      DEPLOY_BRANCH: main
      AUTODEPLOY_HTTP_USER: autodeploy
      AUTODEPLOY_HTTP_PORT: "8080"
    volumes:
      - data:/data
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  gateway:
    image: nginx:stable-alpine
    restart: unless-stopped
    depends_on:
      autodeploy:
        condition: service_healthy
    ports:
      - "127.0.0.1:8088:80"
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  data:
```

在同一目录创建 `nginx.conf`，写入：

```nginx
events {}

http {
    server {
        listen 80;
        resolver 127.0.0.11 valid=10s ipv6=off;
        set $app_upstream autodeploy:3000;

        location / {
            proxy_pass http://$app_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
        }
    }
}
```

保存时确认文件没有被编辑器加上 `.txt` 后缀。

这里有三个不同用途的端口：

| 端口 | 用途 |
| --- | --- |
| 电脑的 `8080` | Git HTTP 推送入口，需要用户名和密码 |
| 电脑的 `8088` | 浏览器访问网站的入口 |
| 容器内的 `3000` | 示例网站监听端口，由网关转发，不直接发布到电脑 |

网关使用 [nginx 官方镜像](https://hub.docker.com/_/nginx)。两个容器共享 Compose 网络，因此网关可以通过服务名 `autodeploy` 找到应用。

启动服务：

```bash
docker compose up -d
docker compose ps
docker compose logs --tail=50 autodeploy
```

等待 `autodeploy` 显示 `healthy`，日志中出现“启动完成”。第一次启动会下载镜像，需要联网。此时还没有部署网站，访问 `8088` 返回 `502` 是正常的。

本教程只使用本机 HTTP 推送，没有配置 SSH 公钥；日志中的“SSH 推送不可用”提示不影响后续步骤。

## 3. 获取推送密码

仍在 `autodeploy-tutorial` 目录执行：

```bash
docker compose exec --user root autodeploy cat /data/credentials/http-password
```

记下输出的密码，推送时会用到。用户名为 `autodeploy`。密码不写入 Git 地址、项目文件或提交记录。

这里绑定的是 `127.0.0.1`，只能从本机访问。不要把明文 HTTP Git 端口直接开放到公网。

## 4. 准备网站代码

创建独立的业务项目目录：

```bash
mkdir -p site/public
cd site
```

现在的位置是 `autodeploy-tutorial/site`。

创建 `public/index.html`：

```html
<!doctype html>
<html lang="zh-CN">
  <meta charset="utf-8">
  <title>我的第一个 AutoDeploy 网站</title>
  <h1>Hello, AutoDeploy!</h1>
  <p>这是通过 Git Push 部署的第一个版本。</p>
</html>
```

再创建 `AutoDeploy.config.yaml`，注意大小写和文件位置：

```yaml
version: 1
name: hello-site
type: process

environment:
  packages:
    - python3

start: python3 -m http.server 3000 --bind 0.0.0.0 --directory public

healthcheck:
  url: http://127.0.0.1:3000/
  timeout: 30
```

配置表示：准备 Python，使用它启动演示网站，启动后检查 HTTP 根路径。只将 `public` 目录作为网站内容，配置文件不会被当作网页公开。Python 自带的 HTTP 服务用于学习演示，正式网站应换成适合业务的服务程序。

目录结构应为：

```text
autodeploy-tutorial/
├── compose.yaml
├── nginx.conf
└── site/
    ├── AutoDeploy.config.yaml
    └── public/
        └── index.html
```

`app.git` 是服务器上的仓库名，`hello-site` 是配置中的应用名；两者用途不同，不必同名。当前一个 AutoDeploy 实例配置一个 Git 仓库。

## 5. 第一次推送

在 `site` 目录初始化 Git：

```bash
git init -b main
```

如果这是第一次使用 Git，需要设置提交作者。将下列占位内容换成你希望记录在提交中的名称和邮箱；这不是 AutoDeploy 的登录凭据：

```bash
git config user.name "你的显示名称"
git config user.email "you@example.com"
```

提交并添加部署地址：

```bash
git add AutoDeploy.config.yaml public/index.html
git commit -m "Create my first website"
git remote add autodeploy http://autodeploy@127.0.0.1:8080/app.git
git push autodeploy main
```

Git 提示输入密码时，粘贴第 3 步的密码。终端输入密码可能没有回显，这是正常现象。

推送时会显示部署日志。不要只看 Git 是否推送成功：代码已入库后，部署仍可能失败，下一步还要确认应用状态。

## 6. 打开网站并确认状态

先回到部署服务目录：

```bash
cd ..
docker compose exec autodeploy autodeploy show
docker compose exec autodeploy autodeploy logs hello-site 50
```

确认 `hello-site` 的状态为 `success`，再打开：

[http://127.0.0.1:8088](http://127.0.0.1:8088)

看到 **Hello, AutoDeploy!** 就完成了第一次部署。`8080` 是 Git 入口，不是网站入口。

## 7. 更新网站

把 `site/public/index.html` 中的标题改成 `Hello, AutoDeploy v2!`，保存后从 `autodeploy-tutorial` 目录执行：

```bash
cd site
git add public/index.html
git commit -m "Update website to v2"
git push autodeploy main
```

推送结束后刷新网页即可看到更新。如果页面没有变化，先强制刷新浏览器，再检查部署状态。

日常发布就是这个流程：修改代码、提交、推送。不需要进入服务器手动复制文件或启动业务服务。

## 8. 练习回滚

回到 `autodeploy-tutorial` 目录，将应用重新部署到本教程的第一个提交：

```bash
cd ..
FIRST_COMMIT="$(git -C site rev-list --max-parents=0 HEAD)"
docker compose exec autodeploy autodeploy deploy "$FIRST_COMMIT"
docker compose exec autodeploy autodeploy show
```

刷新浏览器，页面应恢复为第一个版本。手动回滚只改变运行版本，不改写本地 Git 历史；恢复到当前 `main` 可执行：

```bash
docker compose exec autodeploy autodeploy deploy main
```

存在上一成功版本时，部署失败也会尝试自动回退。应用切换可能短暂中断，数据库修改等外部副作用不在自动回退范围内。

## 9. 查看日志与保留数据

以下命令均在 `compose.yaml` 所在目录执行：

```bash
# AutoDeploy 服务日志
docker compose logs --tail=100 autodeploy

# 应用部署日志与运行日志
docker compose exec autodeploy autodeploy logs hello-site 100

# 网关日志
docker compose logs --tail=100 gateway

# 临时停止；下次用 docker compose start 恢复
docker compose stop
```

仓库、部署版本、状态与凭据保存在 `data` 命名卷中。普通重启不会删除它；`docker compose down -v` 会删除卷，日常停止或升级时不要使用该命令。

## 10. 常见问题

| 现象 | 检查方法 |
| --- | --- |
| 无法连接 Docker | 确认 Docker Engine / Docker Desktop 已启动，且使用 Linux 容器 |
| 提示端口已占用 | 修改 Compose 左侧宿主端口，并同步修改 Git 地址或网站 URL |
| Git 提示认证失败 | 用户名为 `autodeploy`；重新读取密码，检查凭据管理器是否缓存了旧密码 |
| 推送成功但没部署 | 配置必须位于 `site` 仓库根目录并已提交；默认推送分支为 `main` |
| 网页返回 502 | 查看应用状态、应用日志和 gateway 日志；确认应用监听 `0.0.0.0:3000` |
| 文件显示为 `.yaml.txt` | 打开系统的文件扩展名显示，改成准确的文件名 |
| 修改后提示 Everything up-to-date | 修改尚未提交，先运行 `git status`，再 `git add` 和 `git commit` |

也可以绕过网关，在容器内部检查应用：

```bash
docker compose exec autodeploy curl -fsS http://127.0.0.1:3000/
```

## 11. 换成远程服务器

服务器部署时，将第 2 步的 Compose 与 nginx 文件放到服务器上，Docker 管理命令也在服务器执行；网站代码和 Git 命令保留在自己的电脑上。推送密码需要按第 3 步从服务器的新实例读取。

最容易复用本教程的方法，是保持服务器端口绑定 `127.0.0.1`，在自己的电脑另开终端建立 SSH 隧道。把 `your_user` 和 `your_server` 换成服务器的系统登录用户、域名或 IP；这里的用户不是 AutoDeploy 的 `git` 用户：

```bash
ssh -N \
  -L 8080:127.0.0.1:8080 \
  -L 8088:127.0.0.1:8088 \
  your_user@your_server
```

保持该终端开启，Git 推送地址和浏览器地址仍可沿用本教程。若自己的电脑还运行着本地教程实例，请先停止它，避免 `8080`、`8088` 冲突。

这个方式适合自己体验。正式对外提供网站时，在网关配置域名与 HTTPS；远程 Git 推送使用 SSH 或 HTTPS。推送凭据具有部署执行权限，只交给可信管理员。

## 下一步

- [项目配置参考](https://github.com/CreationWong/AutoDeploy/blob/main/docs/configuration.md)：配置运行命令、分支规则、健康检查和部署钩子。
- [部署指南](https://github.com/CreationWong/AutoDeploy/blob/main/docs/deployment.md)：启用 SSH、Docker Compose 业务部署和外部网关。
- [日常管理](https://github.com/CreationWong/AutoDeploy/blob/main/docs/operations.md)：日志、凭据、回滚、数据和升级。
- [安全政策](https://github.com/CreationWong/AutoDeploy/blob/main/SECURITY.md)：了解部署权限边界。
