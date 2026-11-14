# AutoDeploy

**用一次 Git Push，完成应用部署。**

AutoDeploy 是一个自托管部署服务。先在 Docker 主机上启动它，再推送项目代码，即可自动构建、启动和检查应用。

适合个人项目、小型团队和内部服务。部署配置与代码放在同一个仓库中。

[从零开始部署第一个网站](docs/getting-started.md) · [部署指南](docs/deployment.md) · [配置参考](docs/configuration.md)

## 从提交到上线

```text
修改代码 → git push → 准备环境与构建 → 启动应用 → 健康检查
                                                   │
                              成功：完成发布 ←─────┤
                              失败：尝试恢复上一成功版本
```

在项目根目录添加 `AutoDeploy.config.yaml`，之后用 `git push` 发布。

## 你可以用它做什么

- **部署已有项目**：通过 SSH 或 HTTP Git 接入，不依赖 GitHub / GitLab webhook。
- **运行单个服务或一组容器**：小型应用用 `process`，已有 Compose 项目用 `docker-compose`。
- **把发布规则放进仓库**：运行命令、分支与标签规则、健康检查随代码一起管理。
- **在上线前执行检查**：通过部署钩子或精简的 workflow 执行测试、构建和准备工作。
- **处理失败发布**：记录失败提交；有可恢复的上一成功版本时，尝试回退并重新检查。
- **查看与管理运行状态**：查询日志、手动部署历史提交，保留仓库、部署记录和凭据。

GHCR 版本镜像包含 Docker CLI 和 Compose 插件；从源码构建时默认不安装。仅运行 `process` 项目无需挂载 Docker socket，管理业务容器时再显式挂载。

## 选择适合项目的运行方式

| 方式 | 适合的项目 | 使用前准备 |
| --- | --- | --- |
| `process` | Python / Node 服务、演示站点、小型工具 | 配置运行时与启动命令，应用在 AutoDeploy 内运行 |
| `docker-compose` | 已有容器化项目、前后端组合、多服务应用 | 启用 Docker CLI 和宿主机 socket，由项目自己的 Compose 定义业务服务 |

一个 AutoDeploy 实例对应一个 Git 仓库；该仓库可以包含多个 Compose 服务。多个独立项目可以分别运行 AutoDeploy 实例。

## 配置是什么样的

下面的配置用 Python 启动 `public/` 中的演示网页：

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

没有配置文件时，推送只保存代码。正式项目请替换示例的启动命令。

完成首次接入后，日常更新只需要：

```bash
git add public/index.html
git commit -m "Update website"
git push autodeploy main
```

[新手教程](docs/getting-started.md)提供完整步骤：启动服务、推送网站、更新和回滚。

## 获取 AutoDeploy

当前版本：**V0.1.3**。发布镜像支持 **linux/amd64** 和 **linux/arm64**。

```bash
docker pull ghcr.io/creationwong/autodeploy:V0.1.3
```

[查看发布镜像](https://github.com/CreationWong/AutoDeploy/pkgs/container/autodeploy) · [Docker Hub](https://hub.docker.com/r/creationwong/autodeploy) · [服务器部署步骤](docs/deployment.md)

业务端口由项目的 Compose 或网关提供。Git 端口只接收代码，不能用于访问网站。

## 使用文档

| 我想做什么 | 阅读文档 |
| --- | --- |
| 第一次部署，看到自己的页面 | [新手教程](docs/getting-started.md) |
| 在服务器安装，配置 SSH 或网关 | [部署指南](docs/deployment.md) |
| 查询字段，配置运行时、构建、分支和钩子 | [配置参考](docs/configuration.md) |
| 查看日志、回滚、处理故障和升级 | [日常管理](docs/operations.md) |
| 部署 Hexo 等已有项目 | [应用示例](docs/examples.md) |
| 修改 AutoDeploy、运行检查或发布版本 | [开发与发布](docs/development.md) |

## 安全说明

AutoDeploy 面向可信管理员的自托管场景。推送权限具有部署执行权限；启用 Docker socket 后还具有宿主机容器管理权限，只向可信用户提供凭据。

远程 Git 推送请使用 SSH 或 HTTPS。本机 HTTP 示例不应直接暴露到公网。应用切换可能短暂中断，自动回退不等于零停机，也不会撤销数据库迁移等外部副作用。

详见[安全政策](SECURITY.md)与[运维安全说明](docs/operations.md#安全说明)。

## 参与项目

反馈问题请提交 [Issue](https://github.com/CreationWong/AutoDeploy/issues)。贡献代码前请读[开发文档](docs/development.md)，安全问题请按[安全政策](SECURITY.md)私下报告。

## 许可证

Copyright (C) 2026 CreationWong。AutoDeploy 采用 **GNU GPL 第 3 版（GPL-3.0-only）**，不提供担保。许可全文见 [LICENSE](LICENSE)，版权及第三方说明见 [NOTICE](NOTICE)，再分发说明见[开发文档](docs/development.md#许可证与再分发)。
