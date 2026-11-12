# 应用示例

第一次部署建议使用[新手教程](getting-started.md)中的静态页面。下面展示已有项目如何接入 AutoDeploy。

## Hexo 部署示例

先按[部署指南](deployment.md#启用-docker-compose-业务部署)启用 Docker CLI 和宿主机 socket；AutoDeploy 还需配置 `host.docker.internal:host-gateway`，以便访问示例发布的业务端口。

Hexo 推荐使用 `docker-compose` 类型：Node 镜像负责生成静态页面，最终镜像只保留 Nginx 和生成后的 `public/`。AutoDeploy 容器本身不需要安装 Node。

确保 Hexo 项目的 `package.json` 有构建脚本，并提交 `package-lock.json`：

```json
{
  "scripts": {
    "build": "hexo generate"
  }
}
```

在项目根目录添加 `AutoDeploy.config.yaml`：

```yaml
version: 1
name: hexo-blog
type: docker-compose
file: docker-compose.yml
services: [web]
build: true
healthcheck:
  url: http://host.docker.internal:14000/
  timeout: 180
```

添加 `docker-compose.yml`：

```yaml
services:
  web:
    build: .
    container_name: hexo-blog-web
    restart: unless-stopped
    ports:
      - "14000:80"
```

添加 `Dockerfile`：

```dockerfile
FROM node:22-alpine AS builder

WORKDIR /site
COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

FROM nginx:stable-alpine
COPY --from=builder /site/public /usr/share/nginx/html
```

提交并推送后，通过 `http://<host>:14000` 访问站点：

```bash
git add AutoDeploy.config.yaml docker-compose.yml Dockerfile package.json package-lock.json
git commit -m "deploy: configure Hexo for AutoDeploy"
git push autodeploy main
```

注意：

- Hexo 主题如果使用 Git submodule，`git archive` 不会包含子模块工作树。建议把主题代码直接纳入仓库，或在 Docker 构建阶段安装；
- 使用外部 Nginx 网关时，可以移除 `ports`，把 `web` 加入共享网络，并把健康检查改为网络内地址（如 `http://hexo-blog-web/`）；
- 首次构建需要下载 Node 镜像和 npm 依赖；`healthcheck.timeout` 只控制部署后的健康检查，不包含镜像构建时间。
