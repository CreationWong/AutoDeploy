#!/bin/bash
set -euo pipefail

DATA_DIR="${AUTODEPLOY_DATA_DIR:-/data}"
REPO_NAME="${REPO_NAME:-app}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
CONFIG_NAME="${AUTODEPLOY_CONFIG_NAME:-AutoDeploy.config.yaml}"
SSH_USER="git"

log() { printf '[AutoDeploy] %s\n' "$*"; }
warn() { printf '[AutoDeploy] 警告: %s\n' "$*" >&2; }

mkdir -p "$DATA_DIR"/{git-home,deploy,state,logs,ssh} \
         /etc/autodeploy /etc/supervisor/conf.d /var/log/autodeploy /var/log/supervisor /run/sshd
chmod 755 /run/sshd
mkdir -p /run/fcgiwrap
rm -f /run/fcgiwrap/socket
chown "$SSH_USER:$SSH_USER" /run/fcgiwrap
chmod 755 /run/fcgiwrap

if ! id "$SSH_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$DATA_DIR/git-home" --shell /usr/bin/git-shell "$SSH_USER"
fi

GIT_HOME="$DATA_DIR/git-home"
mkdir -p "$GIT_HOME/.ssh"
chown -R "$SSH_USER:$SSH_USER" "$DATA_DIR" "$GIT_HOME"
chmod 700 "$GIT_HOME" "$GIT_HOME/.ssh"

for key_type in rsa ed25519; do
  key_file="$DATA_DIR/ssh/ssh_host_${key_type}_key"
  if [ ! -f "$key_file" ]; then
    ssh-keygen -q -t "$key_type" -N '' -f "$key_file"
  fi
done
chmod 600 "$DATA_DIR"/ssh/ssh_host_*_key
chown root:root "$DATA_DIR"/ssh/ssh_host_*_key

AUTH_KEYS="$GIT_HOME/.ssh/authorized_keys"
: > "$AUTH_KEYS"
if [ -s "$DATA_DIR/authorized_keys" ]; then
  cat "$DATA_DIR/authorized_keys" >> "$AUTH_KEYS"
fi
if [ -n "${AUTHORIZED_KEYS:-}" ]; then
  printf '%s\n' "$AUTHORIZED_KEYS" >> "$AUTH_KEYS"
fi
sed -i '/^[[:space:]]*$/d' "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown "$SSH_USER:$SSH_USER" "$AUTH_KEYS"
if [ ! -s "$AUTH_KEYS" ]; then
  warn "未配置任何 SSH 公钥，SSH 推送不可用。请设置 AUTHORIZED_KEYS 或挂载 $DATA_DIR/authorized_keys"
fi

HTPASSWD="$DATA_DIR/htpasswd"
HTTP_USER="${AUTODEPLOY_HTTP_USER:-autodeploy}"
if [ -n "${AUTODEPLOY_HTTP_PASSWORD:-}" ]; then
  htpasswd -bc "$HTPASSWD" "$HTTP_USER" "$AUTODEPLOY_HTTP_PASSWORD" >/dev/null
  log "已用 AUTODEPLOY_HTTP_PASSWORD 更新 HTTP 凭据，用户名: $HTTP_USER"
elif [ ! -s "$HTPASSWD" ]; then
  RANDOM_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=\n')"
  htpasswd -bc "$HTPASSWD" "$HTTP_USER" "$RANDOM_PASSWORD" >/dev/null
  log "================================================================"
  log "HTTP 推送密码已随机生成（仅本次启动日志显示，请及时记录）"
  log "  随机源: /dev/urandom（无固定种子）"
  log "  用户名: $HTTP_USER"
  log "  密  码: $RANDOM_PASSWORD"
  log "================================================================"
else
  log "复用已有 HTTP 凭据文件: $HTPASSWD（用户名: $HTTP_USER）"
  log "  如需重置密码: 删除该文件后重启容器，或设置 AUTODEPLOY_HTTP_PASSWORD"
fi
chown root:"$SSH_USER" "$HTPASSWD"
chmod 640 "$HTPASSWD"

cat > /etc/autodeploy/env <<EOF
REPO_NAME=${REPO_NAME}
DEPLOY_BRANCH=${DEPLOY_BRANCH}
AUTODEPLOY_CONFIG_NAME=${CONFIG_NAME}
EOF
chown root:"$SSH_USER" /etc/autodeploy/env
chmod 640 /etc/autodeploy/env

REPO_DIR="$GIT_HOME/${REPO_NAME}.git"
if [ ! -d "$REPO_DIR" ]; then
  git -c init.defaultBranch=main init --bare -q "$REPO_DIR"
  log "已创建裸仓库 ${REPO_NAME}.git"
fi
git --git-dir="$REPO_DIR" config http.receivepack true
ln -sf /usr/local/bin/autodeploy-post-receive "$REPO_DIR/hooks/post-receive"
chown -R "$SSH_USER:$SSH_USER" "$REPO_DIR"

find /etc/supervisor/conf.d -maxdepth 1 -name 'autodeploy-*.conf' -delete
RESTORE_ENV=0
for app_conf in "$DATA_DIR"/state/*/supervisor.conf; do
  [ -e "$app_conf" ] || continue
  app_name="$(basename "$(dirname "$app_conf")")"
  ln -sf "$app_conf" "/etc/supervisor/conf.d/autodeploy-${app_name}.conf"
  RESTORE_ENV=1
done
if [ "$RESTORE_ENV" = "1" ] && [ -f "$DATA_DIR/deploy/${REPO_NAME}/${CONFIG_NAME}" ]; then
  if ! /usr/local/bin/autodeploy-deploy --prepare-env "$DATA_DIR/deploy/${REPO_NAME}"; then
    warn "基础环境恢复失败，应用可能无法启动"
  fi
fi

SSH_PORT="${AUTODEPLOY_SSH_PORT:-2222}"
HTTP_PORT="${AUTODEPLOY_HTTP_PORT:-8080}"
log "SSH  推送地址: ssh://git@<host>:${SSH_PORT}/~/${REPO_NAME}.git  (部署分支: ${DEPLOY_BRANCH})"
log "HTTP 推送地址: http://<user>@<host>:${HTTP_PORT}/${REPO_NAME}.git"
log "启动完成，扫描到配置 ${CONFIG_NAME} 才会部署"

exec "$@"
