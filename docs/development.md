# 开发与发布

本文面向 AutoDeploy 的维护者和贡献者。产品概览见 [README](../README.md)，首次使用见[新手教程](getting-started.md)，业务字段见[配置参考](configuration.md)。

## 构建与运行源码

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

需要 Docker Compose 业务部署时，使用覆盖文件；它同时安装 Docker CLI / Compose 插件并挂载宿主机 socket：

```bash
docker compose -f docker-compose.yml -f docker-compose.docker.yml up -d --build
```

| 构建参数 | 默认值 | 用途 |
| --- | --- | --- |
| `BASE_IMAGE` | `debian:bookworm-slim` | 更换兼容 Debian/Ubuntu 的运行时底座 |
| `INSTALL_DOCKER_CLI` | `0` | 是否安装 Docker CLI / Compose 插件 |
| `YQ_VERSION` | `v4.44.3` | YAML 解析工具版本 |

默认镜像不包含 Docker CLI；入口与部署脚本仍以 Bash 运行。不要直接换用 Alpine：环境准备依赖 apt，用户、权限和服务配置也需要重新适配。

## 本地检查

检查代码使用 Python 标准库，不需要安装 Python 包。准备 Python 3.10+、Git、Bash 4+、ShellCheck 和 Docker，然后在仓库根目录执行：

```bash
python3 -B ci/checks.py lint
python3 -B ci/checks.py unit
python3 -B ci/checks.py scanner-selftest
python3 -B ci/checks.py containers --build
python3 -B ci/checks.py containers --build --docker-cli 1 --image autodeploy:ci-docker
```

| 检查 | 覆盖内容 |
| --- | --- |
| `lint` | 部署脚本的 Bash 语法、ShellCheck，以及 Python 文件语法 |
| `unit` | 推送地址日志、版本号格式、标签与 main 的 Git 历史关系、运行身份与配置校验 |
| `scanner-selftest` | 确认敏感信息扫描器接受正常文件并拒绝测试密钥 |
| `containers` | 在真实容器中验证全新数据卷权限、运行隔离、升级迁移、Git 部署预检；轻量镜像验证网关认证与上传限制，Docker CLI 镜像验证实际推送端口 |

容器检查使用独立的临时容器和数据卷，完成后自动清理。`--build` 构建 `autodeploy:ci`；如已有镜像，可使用 `--image <镜像>`。指定 `--platform linux/amd64` 或 `--platform linux/arm64` 可以分别验证两个架构；测试其他架构时，Docker 必须具备相应模拟器。

检查过程由 Python 调用项目实际使用的工具。部署脚本仍以 Bash 运行；敏感信息扫描器仍使用 `.opencode/skills/sensitive-info-check/scan.sh`，Python 自检验证其真实结果。

## GitHub Actions

| 事件 | 检查 | 镜像发布 |
| --- | --- | --- |
| 向任意分支推送提交，包括 Dev 和功能分支 | 按改动路径运行 CI | 不发布 |
| PR 合并到任意分支 | 目标分支收到合并后的提交时按改动路径运行 CI | 不发布 |
| 创建、更新或重新打开 PR | 按改动路径运行 CI | 不发布 |
| 推送指向 main 历史提交的版本标签 | 校验标签并运行 CI | CI 通过后发布到 GHCR |
| 推送未合并分支上的版本标签 | 校验后跳过 | 不发布 |

[ci.yml](../.github/workflows/ci.yml) 检查所有分支的提交，并在 PR 创建、代码更新、信息修改或重新打开时运行，也供版本发布复用。PR 检查使用 GitHub 生成的合并提交，验证更改与目标分支合并后的结果。[publish-ghcr.yml](../.github/workflows/publish-ghcr.yml) 只接收版本标签推送，PR 事件不会触发镜像发布。

分支提交和 PR 使用 `paths-ignore` 跳过纯文档改动：`docs/` 下的文件，以及任意目录中的 `.md`、`.markdown`、`.rst`、`.adoc` 文件，例如 README、SECURITY 和开发文档。只要改动中包含其他文件，CI 就会运行；判断依据是文件路径，而不是提交消息中的 `docs:` 前缀。

构建使用的 `LICENSE`、`NOTICE` 和敏感信息扫描规则 `patterns.txt` 不属于排除范围。版本标签发布通过 `workflow_call` 调用完整 CI，不受分支或 PR 的文档路径排除影响。

Git 标签本身没有所属分支。发布检查获取完整历史，用 `git merge-base --is-ancestor` 确认标签提交已被远端 main 包含。附注标签和轻量标签均可使用。CI 与镜像构建使用同一个已验证的提交 SHA。CI 通过后，发布任务再次检查 main 历史及标签、构建提交是否与 CI 一致；任一条件不满足，就停止发布。

## 发布版本

1. 完成更改并通过本地检查。提交前按 [AGENTS.md](../AGENTS.md) 加载敏感信息检查 skill 并扫描暂存区。
2. 直接提交到 main，或将 PR 合并到 main。推送前扫描待推送提交。
3. 更新本地 main，确认发布内容已进入远端 main，并为该提交创建新的版本标签。
4. 推送该版本标签。GitHub Actions 校验 main 历史并运行 CI。检查全部通过且发布前复核通过后，构建两个平台的镜像并发布到 GHCR。

发布顺序是：**发布内容进入远端 main → 推送版本标签 → CI 通过 → 发布前复核 → 发布镜像**。PR 创建、更新或合并事件本身都不会发布镜像。在内容合并前推送的标签会被跳过，不会因之后合并 PR 而自动补发。

版本标签采用 `VMAJOR.MINOR.PATCH` 或 `vMAJOR.MINOR.PATCH`，例如 `V0.1.3`；可加 `-rc.1` 等预发布后缀。数字部分不允许多余的前导零，标签总长度不得超过 128 个字符。镜像标签与 Git 标签一致，例如 `ghcr.io/creationwong/autodeploy:V0.1.3`。每次发布使用新的标签。

GHCR 登录使用工作流的 `GITHUB_TOKEN`。只有发布任务拥有 `packages: write`；检查任务仅有仓库读取权限。首次发布后，在包设置中将可见性设为 Public，即可允许匿名拉取。工作流摘要提供镜像名、摘要和平台列表。

## 开发工具

- `opencode.json` 配置了 [ponytail](https://github.com/DietrichGebert/ponytail) 插件。需要调整规则强度时，可使用 `/ponytail lite|full|ultra|off`；修改配置后重启 opencode。
- `.opencode/skills/sensitive-info-check/` 用于提交和推送前的敏感信息检查。
- `.opencode/skills/security-audit/` 提供安全审计流程。其校验器需要 Node.js，建议在宿主机运行。


## 服务组成与部署流程

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

健康检查通过后，`/data/deploy/app` 符号链接切换到成功版本。部署状态写入 `/data/state/<name>/deploy.json`（`success` / `failed`），部署失败会自动回退到上一可用版本。

## 部署事务与恢复

每次部署尝试使用独立版本目录 `deploy/.versions/<repo>/<commit>-<attempt>`，同一提交重试不会覆盖已有目录。`deploy/<repo>` 只在健康检查和 `after.sh` 通过后原子切换；部署期间读取本次版本的固定路径。仓库锁覆盖切换、回退和清理，等待锁的导出目录保持 staging 状态。部署前从独立的 `last-success.json` 记录上一可用版本，失败（环境准备、before/workflow、进程启动、compose、健康检查或 after 阶段）时：

1. 先把失败的提交写入 `state/<name>/failed.json` 并在 `deploy.json.failed_commit` 记录（"标记这个提交"）；
2. 存在上一可用版本 → 把 `deploy/<repo>` 符号链接原子切回上一版本目录，重放旧配置的 `environment`，重新拉起该版本并**再跑一次健康检查**，通过后写回 `success`（`failed_commit` 仍指向失败提交），服务保持可用；
3. 没有上一可用版本（首次部署）→ 停止失败的服务（process 停 supervisor、compose 停项目）、移除失败版本目录与符号链接，仅保留失败标记。

回退不需要复制代码，也不重跑旧版本的 install/build；部署前失败时保留仍在运行的旧服务。`docker-compose` 回退会重建 compose 栈并清理孤儿容器。容器重启时通过 `pending.json` / `deploying` 状态检测中断，按 `previous.json` 恢复旧目录和该版本保存的启动脚本、Supervisor 配置；compose 类型重放旧栈。缺少启动快照时禁用自动启动并提示手动部署，避免用新命令启动旧代码。最近 5 个版本之外仍会保护当前和回退目录。`autodeploy show` 会显示 `failed_commit` 与 `failed.json` 标记。

## 许可证与再分发

AutoDeploy 的项目代码由 **CreationWong** 版权所有：`Copyright (C) 2026 CreationWong`，按 **GNU General Public License 第 3 版**（SPDX：`GPL-3.0-only`）授权。许可全文见 [LICENSE](../LICENSE)，版权及第三方说明见 [NOTICE](../NOTICE)。本项目不提供任何担保，包括适销性或特定用途适用性的默示担保。

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
