# 开发与发布

本文面向 AutoDeploy 的维护者和贡献者。业务项目配置与部署步骤见 [README](../README.md)。

## 本地检查

检查代码使用 Python 标准库，不需要安装 Python 包。准备 Python 3.10+、Git、Bash 4+、ShellCheck 和 Docker，然后在仓库根目录执行：

```bash
python3 -B ci/checks.py lint
python3 -B ci/checks.py unit
python3 -B ci/checks.py scanner-selftest
python3 -B ci/checks.py containers --build
```

| 检查 | 覆盖内容 |
| --- | --- |
| `lint` | 部署脚本的 Bash 语法、ShellCheck，以及 Python 文件语法 |
| `unit` | 推送地址日志、版本号格式、标签与 main 的 Git 历史关系 |
| `scanner-selftest` | 确认敏感信息扫描器接受正常文件并拒绝测试密钥 |
| `containers` | 在真实容器中验证全新数据卷权限及推送端口日志 |

容器检查使用独立的临时容器和数据卷，完成后自动清理。`--build` 构建 `autodeploy:ci`；如已有镜像，可使用 `--image <镜像>`。指定 `--platform linux/amd64` 或 `--platform linux/arm64` 可以分别验证两个架构；测试其他架构时，Docker 必须具备相应模拟器。

检查过程由 Python 调用项目实际使用的工具。部署脚本仍以 Bash 运行；敏感信息扫描器仍使用 `.opencode/skills/sensitive-info-check/scan.sh`，Python 自检验证其真实结果。

## GitHub Actions

| 事件 | 检查 | 镜像发布 |
| --- | --- | --- |
| 向任意分支推送提交，包括 Dev 和功能分支 | 运行 CI | 不发布 |
| PR 合并到任意分支 | 目标分支收到合并后的提交时运行 CI | 不发布 |
| 创建、更新或重新打开 PR | 运行 CI | 不发布 |
| 推送指向 main 历史提交的版本标签 | 校验标签并运行 CI | CI 通过后发布到 GHCR |
| 推送未合并分支上的版本标签 | 校验后跳过 | 不发布 |

[ci.yml](../.github/workflows/ci.yml) 检查所有分支的提交，并在 PR 创建、代码更新、信息修改或重新打开时运行，也供版本发布复用。PR 检查使用 GitHub 生成的合并提交，验证更改与目标分支合并后的结果。[publish-ghcr.yml](../.github/workflows/publish-ghcr.yml) 只接收版本标签推送，PR 事件不会触发镜像发布。

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
