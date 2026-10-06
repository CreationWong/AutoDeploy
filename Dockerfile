ARG BASE_IMAGE=debian:bookworm-slim
FROM ${BASE_IMAGE}

ARG INSTALL_DOCKER_CLI=1
ARG YQ_VERSION=v4.44.3

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    AUTODEPLOY_DATA_DIR=/data

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      apache2-utils \
      ca-certificates \
      curl \
      fcgiwrap \
      git \
      gnupg \
      nginx \
      openssh-server \
      sudo \
      supervisor \
      util-linux \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    if [ "$INSTALL_DOCKER_CLI" = "1" ]; then \
      . /etc/os-release; \
      case "$ID" in \
        debian|ubuntu) repo="$ID"; codename="$VERSION_CODENAME";; \
        *) echo "unknown distro $ID, skip docker cli"; exit 0;; \
      esac; \
      install -m 0755 -d /etc/apt/keyrings; \
      curl -fsSL "https://download.docker.com/linux/$repo/gpg" -o /etc/apt/keyrings/docker.asc; \
      chmod a+r /etc/apt/keyrings/docker.asc; \
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$repo $codename stable" > /etc/apt/sources.list.d/docker.list; \
      apt-get update; \
      apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin; \
      rm -rf /var/lib/apt/lists/*; \
    fi

RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) yq_arch=amd64;; \
      arm64) yq_arch=arm64;; \
      *) echo "unsupported arch for yq: $arch" >&2; exit 1;; \
    esac; \
    curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${yq_arch}" -o /usr/local/bin/yq; \
    chmod 755 /usr/local/bin/yq; \
    yq --version

RUN set -eux; \
    if ! id git >/dev/null 2>&1; then \
      useradd --create-home --home-dir /data/git-home --shell /usr/bin/git-shell git; \
    fi; \
    mkdir -p /data /etc/autodeploy /var/log/autodeploy /var/log/supervisor; \
    chown -R git:git /data /var/log/autodeploy; \
    rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

COPY conf/sshd_config /etc/ssh/sshd_config
COPY conf/supervisord.conf /etc/supervisor/supervisord.conf
COPY conf/nginx-autodeploy.conf /etc/nginx/conf.d/autodeploy.conf
COPY conf/autodeploy.sudoers /etc/sudoers.d/autodeploy

RUN set -eux; \
    rm -f /etc/nginx/sites-enabled/default; \
    sed -i 's/^user .*/user git;/' /etc/nginx/nginx.conf; \
    chown -R git:git /var/lib/nginx /var/log/nginx; \
    chmod 440 /etc/sudoers.d/autodeploy; \
    visudo -cf /etc/sudoers.d/autodeploy

COPY scripts/autodeploy-deploy /usr/local/bin/autodeploy-deploy
COPY scripts/autodeploy /usr/local/bin/autodeploy
COPY scripts/autodeploy-endpoints /usr/local/bin/autodeploy-endpoints
COPY scripts/post-receive /usr/local/bin/autodeploy-post-receive
COPY entrypoint.sh /usr/local/bin/autodeploy-entrypoint

RUN chmod 755 \
      /usr/local/bin/autodeploy-deploy \
      /usr/local/bin/autodeploy \
      /usr/local/bin/autodeploy-endpoints \
      /usr/local/bin/autodeploy-post-receive \
      /usr/local/bin/autodeploy-entrypoint

EXPOSE 22 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -fsS http://127.0.0.1/healthz >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/autodeploy-entrypoint"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/supervisord.conf"]
