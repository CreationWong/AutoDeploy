# AGENTS.md

## 部署顺序（先起服务，再推项目）

1. 先部署 AutoDeploy 服务本身（本仓库容器）。
2. 之后所有业务项目都通过它启用的 Git 推送部署，不再单独部署业务容器。

推送地址：`ssh://git@<host>:<SSH_PORT>/~/${REPO_NAME}.git` 或 `http://<user>@<host>:<HTTP_PORT>/${REPO_NAME}.git`。容器只在项目根存在 `AutoDeploy.config.yaml` 时部署该项目。

## 关键约定

- AutoDeploy 自身默认只暴露 Git 端口；业务端口由项目自己的 compose `ports` 发布，或让项目接入外部 nginx 网关网络（零端口暴露）。
- 详细用法与字段说明见 `README.md`。
