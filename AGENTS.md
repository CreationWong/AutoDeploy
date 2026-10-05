# AGENTS.md

## 部署顺序（先起服务，再推项目）

1. 先部署 AutoDeploy 服务本身（本仓库容器）。
2. 之后所有业务项目都通过它启用的 Git 推送部署，不再单独部署业务容器。

推送地址：`ssh://git@<host>:<SSH_PORT>/~/${REPO_NAME}.git` 或 `http://<user>@<host>:<HTTP_PORT>/${REPO_NAME}.git`。容器只在项目根存在 `AutoDeploy.config.yaml` 时部署该项目。

## 关键约定

- AutoDeploy 自身默认只暴露 Git 端口；业务端口由项目自己的 compose `ports` 发布，或让项目接入外部 nginx 网关网络（零端口暴露）。
- 详细用法与字段说明见 `README.md`。

## 提交/推送前检查

执行 `git commit` 或 `git push` 前，必须加载并遵循 `sensitive-info-check` skill，扫描暂存区与待推送提交，确认无密钥、凭据、隐私信息后再操作。命中时先处理，不得直接提交或推送。

## 安全审计

需要对代码库做安全审计/漏洞排查时，加载 `security-audit` skill 并按其流程执行。其 `validate-findings.cjs` / `validate-coverage-ledger.cjs` 需要 Node，容器默认未安装，建议在宿主机运行审计。
