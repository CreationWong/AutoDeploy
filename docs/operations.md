# 日常管理与故障排查

以下命令使用容器名 `autodeploy`。使用 Compose 时，在配置文件所在目录用 `docker compose exec autodeploy` 代替 `docker exec autodeploy`，用 `docker compose logs autodeploy` 代替 `docker logs autodeploy`。

## 输出语言

语言切换目前仅支持 Dev 源码，V0.1.3 镜像尚不支持。运行提示默认英文，文档保持中文。

首次启动：Compose 使用 `AUTODEPLOY_LANG=zh docker compose up -d --build`，`docker run` 增加 `-e AUTODEPLOY_LANG=zh`。已有实例可直接切换：

```bash
docker exec autodeploy autodeploy set AUTODEPLOY_LANG zh
docker exec autodeploy autodeploy help

# 切回英文
docker exec autodeploy autodeploy set AUTODEPLOY_LANG en

# 仅覆盖这一次管理命令的显示语言
docker exec -e AUTODEPLOY_LANG=zh autodeploy autodeploy show
```

语言可设为 `en` 或 `zh`，重启后保留。优先级：单次管理命令的环境变量 > 已保存设置 > 容器启动环境。未知语言或缺少译文时使用英文。历史日志、已保存的状态消息和业务输出不翻译。

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

日志和 `autodeploy show` 会显示 Git 推送地址。端口按以下顺序确定：

1. Docker 检测到的实际发布端口（需要 Docker CLI 和 socket）。
2. `AUTODEPLOY_SSH_PORT` / `AUTODEPLOY_HTTP_PORT` 设置。
3. 无法确定时显示端口占位符，需手动替换。

Compose 自动传入发布端口；网关使用 `GATEWAY_SSH_PORT` / `GATEWAY_HTTP_PORT`。使用 `docker run` 时请自行设置外部端口。检测到端口未发布且未设置外部入口时，会显示未发布提示。

设置 `AUTODEPLOY_HOST` 指定客户端可访问的域名或 IP。未设置时使用具体绑定地址；通配绑定显示 `<host>`，需自行替换。

端口在每次启动和执行 `autodeploy show` 时更新。自定义容器 hostname 可能使端口检测失败。HTTP 用户名以现有凭据文件为准。

## 容器内管理命令

常用管理命令：

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
| `autodeploy show` | 查看设置、最近提交和部署状态 |
| `autodeploy set <KEY> <VALUE>` | 保存默认设置，重启后保留 |
| `autodeploy deploy <branch\|tag\|commit>` | 部署指定分支、标签或提交，可用于回滚 |
| `autodeploy retry` | 重新部署上次成功提交 |
| `autodeploy logs [name] [N]` | 查看应用日志（deploy.log / app.log / app.err.log，默认第一个应用、50 行） |
| `autodeploy log [N]` | 查看当前项目提交历史（默认 10 条，包含分支和标签） |
| `autodeploy license` | 查看 GNU GPL 第 3 版许可全文 |

- 可修改：`REPO_NAME`、`DEPLOY_BRANCH`、`DEPLOY_TAG`、`DEPLOY_TAG_MODE`、`AUTODEPLOY_CONFIG_NAME`、`AUTODEPLOY_LANG`。
- 设置会保存到数据卷，重启后保留；部署规则在下次推送时生效。
- 项目配置的 `deploy` 规则优先于实例默认值。
- 修改 `REPO_NAME` 不会重命名已有仓库。

## 回滚与失败恢复

用 `autodeploy show` 查看状态，用 `autodeploy log 20` 查找提交。将 `COMMIT_ID` 换成要恢复的提交 ID：

```bash
docker exec autodeploy autodeploy deploy COMMIT_ID
```

`autodeploy retry` 会重新部署上次成功提交，不是重试最近失败的提交。要重试失败版本，用 `autodeploy deploy` 指定其提交 ID 或分支。

部署失败时，有上一成功版本就尝试回退并重新检查；首次部署失败则停止失败服务。回退成功后状态可为 `success`，`failed_commit` 仍记录失败提交。请结合日志确认当前版本。

切换版本可能短暂中断。回退不会撤销数据库修改、外部 API 调用等副作用。

手动回滚不修改 Git 历史。下次推送仍部署新提交。恢复机制见[开发文档](development.md#部署事务与恢复)。

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

安全问题请按[安全政策](../SECURITY.md)私下报告。

- **只向可信管理员开放推送。** 钩子、workflow 和环境初始化可用 root 执行命令；安装和构建使用有部署权限的 `git` 用户。
- **默认隔离业务进程。** 业务使用 `autodeploy-app`，禁止新增权限；部署目录限制在 `/data/deploy` 内。
- **按需挂载 Docker socket。** 它授予宿主机容器管理权限，默认关闭。
- **远程访问使用 SSH 或 HTTPS。** HTTP 默认仅绑定本机，示例网关不含证书配置。
- **SSH 仅支持公钥。** 只允许 `git` 用户，禁用转发、终端和用户 rc 脚本。
- **保护凭据和数据卷。** 随机密码只保存在 root 可读的 `/data/credentials/http-password`，不写日志；认证散列使用 bcrypt，保存在 `/data/htpasswd`。
- **业务进程不继承部署凭据。** 初始化后会清除明文密码，部署命令和业务进程仅接收基础变量及项目 `env`。代理等变量需显式配置。
- **主机密钥随数据卷保存。** 首次启动生成于 `/data/ssh`，不随镜像分发。

镜像只打包白名单内的源码、配置和许可文件。nginx 日志写入容器日志。默认 Compose 日志每份最多 10 MiB，保留 3 份；`docker run` 可增加 `--log-opt max-size=10m --log-opt max-file=3`。

## 常见问题

- **推送成功但没部署？** 确认分支在 `DEPLOY_BRANCH` 内、根目录存在 `AutoDeploy.config.yaml`，查看 `docker logs autodeploy` 或 `/data/logs/<name>/deploy.log`。
- **进程没起来？** `docker exec autodeploy supervisorctl status`，再看 `app.err.log`。
- **推送输出 `[AutoDeploy] Error: ...`（中文模式为 `错误: ...`） 但 push 成功？** post-receive 在对象入库后运行，无法拒绝推送；实际状态看 `/data/state/<name>/deploy.json`。
- **容器重建后部署还在吗？** 在。裸仓库、工作目录、supervisor 配置、日志、基础环境快照都持久化在 `/data`，入口脚本自动恢复。
- **应用端口怎么暴露？** `docker-compose` 类型由应用 compose 的 `ports:` 发布；`process` 类型加入外部网络后用 nginx 网关代理，均不需要改 AutoDeploy 自身。

## 保留数据与升级

升级前备份 `/data` 卷和业务数据。为保证备份一致，可先停止 AutoDeploy。`docker compose down` 保留命名卷，`down -v` 会删除卷，日常更新不要使用。

使用发布镜像时，在原 Compose 文件中改为选定的新版本标签，再运行：

```bash
docker compose pull autodeploy
docker compose up -d autodeploy
docker compose logs --tail=100 autodeploy
docker compose exec autodeploy autodeploy show
```

升级时保留原项目名、卷映射和配置。源码部署使用 `docker compose up -d --build`。业务卷、外部数据库和业务用户 HOME 需单独持久化和备份。