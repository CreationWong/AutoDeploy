# 开发与发布

本页介绍源码构建、测试和发布。使用步骤见[新手教程](getting-started.md)，项目字段见[配置参考](configuration.md)。

## 项目结构与语言

```text
src/
  entrypoint.sh          # 容器初始化与恢复
  scripts/               # 管理命令、Git hook、部署与共享函数
    autodeploy-i18n       # 英文消息键与中文翻译
  conf/                  # nginx、SSH、Supervisor、sudo 配置
ci/                      # 开发检查与发布工具
tests/                   # 单元与容器回归测试
docs/                    # 中文使用文档
examples/                # 业务项目与网关示例
Dockerfile               # 镜像构建入口
docker-compose*.yml       # AutoDeploy 服务启动配置
```

在仓库根目录执行构建命令。容器内命令位于 `/usr/local/bin`，配置路径不变。镜像附带的源码保留 `src/` 布局，可用原 Dockerfile 重建。

运行提示默认英文，可[切换中文](operations.md#输出语言)。文档和注释不切换；业务输出、历史日志和状态消息保留原文。

新增消息使用英文键：固定文本调用 `autodeploy_text`，动态值调用 `autodeploy_msg 'Message: %s' "$value"`。中文译文放在 `src/scripts/autodeploy-i18n`，保留相同占位符，禁止 `eval`。未知语言和缺失翻译回退英文，无需 gettext。

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

源码默认构建不包含 Docker CLI；GHCR 版本发布显式设置 `INSTALL_DOCKER_CLI=1`，包含 Docker CLI 和 Compose 插件。入口与部署脚本仍以 Bash 运行。不要直接换用 Alpine：环境准备依赖 apt，用户、权限和服务配置也需要重新适配。

## 本地检查

准备 Python 3.10+、Git、Bash 4+、ShellCheck 和 Docker，无需安装 Python 包。在仓库根目录执行：

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

Python 检查入口调用实际 Bash 脚本和敏感信息扫描器，避免测试与运行行为脱节。

## GitHub Actions

| 事件 | 检查 | 镜像发布 |
| --- | --- | --- |
| 向任意分支推送提交，包括 Dev 和功能分支 | 按改动路径运行 CI | 不发布 |
| PR 合并到任意分支 | 目标分支收到合并后的提交时按改动路径运行 CI | 不发布 |
| 创建、更新或重新打开 PR | 按改动路径运行 CI | 不发布 |
| 推送指向 main 历史提交的版本标签 | 校验标签并运行 CI | CI 通过后发布到 GHCR |
| 推送未合并分支上的版本标签 | 校验后跳过 | 不发布 |

[ci.yml](../.github/workflows/ci.yml) 负责分支、PR 和发布前检查。PR 检查使用 GitHub 生成的合并提交。[publish-ghcr.yml](../.github/workflows/publish-ghcr.yml) 只响应版本标签推送。

分支和 PR 的纯文档改动会跳过 CI：`docs/**`，以及 `.md`、`.markdown`、`.rst`、`.adoc` 文件。是否跳过取决于路径，与提交消息的 `docs:` 前缀无关。

构建使用的 `LICENSE`、`NOTICE` 和敏感信息扫描规则 `patterns.txt` 不属于排除范围。版本标签发布通过 `workflow_call` 调用完整 CI，不受分支或 PR 的文档路径排除影响。

版本标签必须指向远端 main 已包含的提交，轻量标签和附注标签均可。CI 和构建使用同一 SHA；发布前再次核验 main、标签和构建提交，不一致就停止。

## 发布版本

1. 完成更改并通过本地检查。提交前按 [AGENTS.md](../AGENTS.md) 加载敏感信息检查 skill 并扫描暂存区。
2. 直接提交到 main，或将 PR 合并到 main。推送前扫描待推送提交。
3. 更新本地 main，确认发布内容已进入远端 main，并为该提交创建新的版本标签。
4. 推送该版本标签。GitHub Actions 校验 main 历史并运行 CI。检查全部通过且发布前复核通过后，构建两个平台的镜像并发布到 GHCR。

发布顺序：**合入远端 main → 推送版本标签 → CI → 复核 → 发布镜像**。合并前推送的标签不会发布，后续合并也不会自动补发。

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

每次部署使用独立目录 `deploy/.versions/<repo>/<commit>-<attempt>`。健康检查和 `after.sh` 通过后才切换 `deploy/<repo>`。部署锁覆盖切换、回退和清理；等待锁的目录保持 staging 状态。上一成功版本记录在 `last-success.json`。任一部署阶段失败时：

1. 将失败提交记录到 `failed.json` 和 `deploy.json.failed_commit`。
2. 有上一版本：切回旧目录、恢复环境并启动，再做健康检查；通过后状态为 `success`，保留失败提交记录。
3. 无上一版本：停止失败服务，删除失败版本目录与链接，保留失败记录。

回退不复制代码，也不重跑 install/build；新服务启动前失败时保留旧服务。Compose 回退会重建旧栈并清理孤儿容器。

重启时根据 `pending.json` 或 `deploying` 检测中断，按 `previous.json` 恢复旧目录及启动快照。快照缺失则禁用自动启动，需手动部署。清理保留最近 5 个版本，并保护当前版本和回退目录。

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
