# 应用示例

已有项目可参考以下示例。首次体验见[新手教程](getting-started.md)。

## Hexo 部署示例

先按[部署指南](deployment.md#启用-docker-compose-业务部署)启用 Docker CLI 和宿主机 socket；AutoDeploy 还需配置 `host.docker.internal:host-gateway`，以便访问示例发布的业务端口。

Hexo 使用 `docker-compose` 部署：Node 镜像构建页面，Nginx 镜像提供访问。AutoDeploy 无需安装 Node。

在 `package.json` 中添加构建脚本，并提交 `package-lock.json`：

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
