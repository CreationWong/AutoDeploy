# 日常管理与故障排查

本文示例使用容器名 `autodeploy`。如果按[新手教程](getting-started.md)用 Compose 启动，请在 `compose.yaml` 所在目录将 `docker exec autodeploy` 或 `docker exec -it autodeploy` 替换为 `docker compose exec autodeploy`，将 `docker logs autodeploy` 替换为 `docker compose logs autodeploy`。

## Git 推送

| 协议 | 地址 | 认证 |
| --- | --- | --- |
| SSH | `ssh://git@<host>:<SSH_PORT>/~/app.git`（默认 2222） | `AUTHORIZED_KEYS` 或挂载 `/data/authorized_keys` |
| HTTP | `http://<user>@127.0.0.1:<HTTP_PORT>/app.git`（默认本机 8080）；远程使用 `https://<user>@<域名>/app.git` | `AUTODEPLOY_HTTP_USER` / `AUTODEPLOY_HTTP_PASSWORD`，或读取 `/data/credentials/http-password` |

- 裸仓库固定为 `${REPO_NAME}.git`（默认 `app.git`）。
- 只有匹配的分支/标签才触发部署，支持逗号分隔和通配（如 `main,release/*` 或 `*`）。
- 默认触发规则来自容器环境变量 `DEPLOY_BRANCH` / `DEPLOY_TAG` / `DEPLOY_TAG_MODE`；项目可在 `AutoDeploy.config.yaml` 的 `deploy` 段按项目覆盖（见[项目配置参考](configuration.md)）。
- 一次推送命中多个分支/标签时，只部署第一个匹配的引用。
- 没有部署配置时直接跳过代码导出，避免纯 Git 仓库产生临时工作副本；配置必须是普通文件，拒绝符号链接和同名目录。
- 轮换 HTTP 密码：删除 `/data/htpasswd` 后重启，或设置 `AUTODEPLOY_HTTP_PASSWORD`。
- 随机密码文件仅 root 可读；显式设置密码时删除旧随机密码文件。已有卷仅保存旧密码散列时不会恢复明文，需要按上述方式轮换。密码不要写入 Git remote URL，交给 Git 的交互提示或安全凭据管理器。

## 推送地址日志

轻量镜像通过 `AUTODEPLOY_SSH_PORT` / `AUTODEPLOY_HTTP_PORT` 显示外部端口，compose 会自动注入与发布端口一致的值。使用 `docker run` 时可显式设置这两个变量；未设置则显示地址模板。HTTP 用户名来自现有凭据文件（首次创建时使用 `AUTODEPLOY_HTTP_USER`）。

启用 Docker CLI 且可访问 Docker 服务时，启动日志和 `autodeploy show` 优先读取当前容器实际发布的端口。例如 `-p 8096:80` 会显示 `http://autodeploy@<host>:8096/app.git`；没有发布 22 端口且未设置外部 SSH 端口时，会显示 SSH 未发布。

可用 `-e AUTODEPLOY_HOST=git.example.com` 指定客户端访问的域名/IP；未指定时，日志使用端口绑定的具体 IP，绑定在 `0.0.0.0` / `::` 则显示 `<host>` 并提示替换。容器无法可靠推断宿主机的公网 IP 或外部域名。

实际端口检测需要 Docker CLI、可访问的 Docker 服务和默认容器 hostname。未挂载 `docker.sock`、构建时禁用 Docker CLI 或自定义 hostname 导致检测失败时，日志使用配置的外部端口；没有配置才显示地址模板。网关覆盖文件会采用 `GATEWAY_SSH_PORT` / `GATEWAY_HTTP_PORT`，也可用 `AUTODEPLOY_SSH_PORT` / `AUTODEPLOY_HTTP_PORT` 显式描述其他外部入口。直接发布的实际端口优先于配置值。端口在每次启动和执行 `autodeploy show` 时重新读取。

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

## 回滚与失败恢复

先用 `autodeploy show` 确认部署状态，再用 `autodeploy log 20` 查找要恢复的提交。在下面的命令中，把 `COMMIT_ID` 替换为实际提交 ID：

```bash
docker exec autodeploy autodeploy deploy COMMIT_ID
```

`autodeploy retry` 会重新部署上次成功提交，不是重试最近失败的提交。要重试失败版本，用 `autodeploy deploy` 指定其提交 ID 或分支。

存在可恢复的上一成功版本时，部署失败会尝试自动回退并再次执行健康检查；首次部署失败则停止失败服务。回退后的 `status` 可能为 `success`，但 `failed_commit` 仍记录失败尝试，应同时检查日志与当前运行的提交。应用切换可能短暂中断；自动回退不等于零停机，也不会自动撤销数据库迁移、外部 API 调用等副作用。

手动回滚不改写 Git 分支历史。后续向部署分支推送新提交时，仍会部署该次推送的版本。事务、快照与中断恢复细节见[开发文档](development.md#部署事务与恢复)。

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

安全问题请按 [安全政策](../SECURITY.md)通过私有渠道报告。该政策也说明了支持版本和部署权限边界。

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

## 保留数据与升级

`/data` 卷保存仓库、部署版本、凭据和状态。升级前备份该卷及业务应用自己的数据；为获得一致的备份，可安排维护窗口先停止 AutoDeploy，再使用你的卷备份工具。Docker Compose 的 `down` 默认保留命名卷，`down -v` 会删除卷，不能用于日常更新。

使用发布镜像时，在原 Compose 文件中改为选定的新版本标签，再运行：

```bash
docker compose pull autodeploy
docker compose up -d autodeploy
docker compose logs --tail=100 autodeploy
docker compose exec autodeploy autodeploy show
```

保留原来的项目名、卷映射和配置。源码构建部署使用 `docker compose up -d --build`。业务容器的数据卷、外部数据库与业务用户的 HOME 不等于 AutoDeploy 的 `/data` 卷，需要分别安排持久化和备份。
