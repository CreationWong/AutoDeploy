#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 CreationWong
#
# This file is part of AutoDeploy.
#
# AutoDeploy is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, version 3 of the License.
#
# AutoDeploy is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with AutoDeploy. If not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

DATA_DIR="${AUTODEPLOY_DATA_DIR:-/data}"
REPO_NAME="${REPO_NAME:-app}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
DEPLOY_TAG="${DEPLOY_TAG:-}"
DEPLOY_TAG_MODE="${DEPLOY_TAG_MODE:-commit}"
CONFIG_NAME="${AUTODEPLOY_CONFIG_NAME:-AutoDeploy.config.yaml}"
SSH_USER="git"

log() { printf '[AutoDeploy] %s\n' "$*"; }
warn() { printf "$(autodeploy_text '[AutoDeploy] Warning: %s\n')" "$*" >&2; }
# shellcheck source=src/scripts/autodeploy-endpoints
. /usr/local/bin/autodeploy-endpoints
# shellcheck source=src/scripts/autodeploy-runtime
. /usr/local/bin/autodeploy-runtime

SETTINGS_FILE="$DATA_DIR/settings.env"
if [ -r "$SETTINGS_FILE" ]; then
  set -a
  . "$SETTINGS_FILE"
  set +a
  REPO_NAME="${REPO_NAME:-app}"
  DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
  DEPLOY_TAG="${DEPLOY_TAG:-}"
  DEPLOY_TAG_MODE="${DEPLOY_TAG_MODE:-commit}"
  CONFIG_NAME="${AUTODEPLOY_CONFIG_NAME:-AutoDeploy.config.yaml}"
  log "$(autodeploy_msg 'Loaded persistent settings: %s' "$SETTINGS_FILE")"
fi

autodeploy_validate_settings "$REPO_NAME" "$CONFIG_NAME" "$DEPLOY_TAG_MODE"

mkdir -p "$DATA_DIR"/{git-home,deploy/.versions,state,logs,ssh} \
         /etc/autodeploy /etc/supervisor/conf.d /var/log/autodeploy /var/log/supervisor /run/sshd
chmod 755 /run/sshd
find "$DATA_DIR/deploy/.versions" -type d -name '.staging-*' -exec rm -rf {} + 2>/dev/null || true
mkdir -p /run/fcgiwrap
rm -f /run/fcgiwrap/socket
chown "$SSH_USER:$SSH_USER" /run/fcgiwrap
chmod 755 /run/fcgiwrap

if ! id "$SSH_USER" >/dev/null 2>&1; then
  useradd --create-home --home-dir "$DATA_DIR/git-home" --shell /usr/bin/git-shell "$SSH_USER"
fi

GIT_HOME="$DATA_DIR/git-home"
mkdir -p "$GIT_HOME/.ssh"
chown root:root "$DATA_DIR" "$DATA_DIR/state" "$DATA_DIR/logs" "$DATA_DIR/ssh"
chmod 755 "$DATA_DIR" "$DATA_DIR/state" "$DATA_DIR/logs"
chmod 700 "$DATA_DIR/ssh"
chown "$SSH_USER:$SSH_USER" \
  "$DATA_DIR/deploy" \
  "$DATA_DIR/deploy/.versions"
chown -R "$SSH_USER:$SSH_USER" "$GIT_HOME"
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
  warn "$(autodeploy_msg 'SSH push disabled: no public keys. Set AUTHORIZED_KEYS or mount %s/authorized_keys' "$DATA_DIR")"
fi

HTPASSWD="$DATA_DIR/htpasswd"
PASSWORD_DIR="$DATA_DIR/credentials"
PASSWORD_FILE="$PASSWORD_DIR/http-password"
if [ -L "$PASSWORD_DIR" ] || [ -L "$PASSWORD_FILE" ] || [ -L "$HTPASSWD" ]; then
  warn "$(autodeploy_text 'Cannot initialize HTTP credentials: path is a symlink')"
  exit 1
fi
install -d -m 700 -o root -g root "$PASSWORD_DIR"
HTTP_USER="${AUTODEPLOY_HTTP_USER:-autodeploy}"
if [ -n "${AUTODEPLOY_HTTP_PASSWORD:-}" ]; then
  printf '%s\n' "$AUTODEPLOY_HTTP_PASSWORD" | htpasswd -iBc "$HTPASSWD" "$HTTP_USER" >/dev/null
  rm -f "$PASSWORD_FILE"
  log "$(autodeploy_msg 'HTTP password updated from AUTODEPLOY_HTTP_PASSWORD; user: %s' "$HTTP_USER")"
elif [ ! -s "$HTPASSWD" ]; then
  RANDOM_PASSWORD="$(head -c 18 /dev/urandom | base64 | tr -d '/+=\n')"
  (umask 077; printf '%s\n' "$RANDOM_PASSWORD" > "$PASSWORD_FILE")
  chown root:root "$PASSWORD_FILE"
  chmod 600 "$PASSWORD_FILE"
  printf '%s\n' "$RANDOM_PASSWORD" | htpasswd -iBc "$HTPASSWD" "$HTTP_USER" >/dev/null
  log "$(autodeploy_msg 'Generated a random HTTP push password; username: %s' "$HTTP_USER")"
  log "$(autodeploy_msg 'Read %s as root (passwords are not logged)' "$PASSWORD_FILE")"
else
  HTTP_USER="$(autodeploy_http_user)"
  log "$(autodeploy_msg 'Reusing HTTP credentials: %s (username: %s)' "$HTPASSWD" "$HTTP_USER")"
  log "$(autodeploy_text '  To reset the password, delete this file and restart, or set AUTODEPLOY_HTTP_PASSWORD')"
fi
chown root:"$SSH_USER" "$HTPASSWD"
chmod 640 "$HTPASSWD"
# 推送凭据不能继承到 fcgiwrap 或业务进程。
unset AUTODEPLOY_HTTP_PASSWORD RANDOM_PASSWORD

{
  printf 'REPO_NAME=%q\n' "$REPO_NAME"
  printf 'DEPLOY_BRANCH=%q\n' "$DEPLOY_BRANCH"
  printf 'DEPLOY_TAG=%q\n' "$DEPLOY_TAG"
  printf 'DEPLOY_TAG_MODE=%q\n' "$DEPLOY_TAG_MODE"
  printf 'AUTODEPLOY_CONFIG_NAME=%q\n' "$CONFIG_NAME"
  printf 'AUTODEPLOY_LANG=%q\n' "${AUTODEPLOY_LANG:-en}"
  printf 'AUTODEPLOY_APP_USER=%q\n' "${AUTODEPLOY_APP_USER:-autodeploy-app}"
} > /etc/autodeploy/env
chown root:"$SSH_USER" /etc/autodeploy/env
chmod 640 /etc/autodeploy/env

REPO_DIR="$GIT_HOME/${REPO_NAME}.git"
if [ ! -d "$REPO_DIR" ]; then
  git -c init.defaultBranch=main init --bare -q "$REPO_DIR"
  log "$(autodeploy_msg 'Created bare repository %s.git' "${REPO_NAME}")"
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
for env_snap in "$DATA_DIR"/state/*/environment.yml; do
  [ -e "$env_snap" ] || continue
  RESTORE_ENV=1
  break
done
for state_file in "$DATA_DIR"/state/*/deploy.json; do
  [ -f "$state_file" ] || continue
  state_dir="$(dirname "$state_file")"
  if [ "$(yq -r '.status // ""' "$state_file" 2>/dev/null || true)" != "deploying" ] && [ ! -f "$state_dir/pending.json" ]; then
    continue
  fi
  attempt_file="$state_file"
  [ ! -f "$state_dir/pending.json" ] || attempt_file="$state_dir/pending.json"
  state_name="$(basename "$(dirname "$state_file")")"
  link="$DATA_DIR/deploy/${REPO_NAME}"
  prev="$(cat "$DATA_DIR/state/${state_name}/previous.commit" 2>/dev/null || true)"
  previous="$state_dir/previous.json"
  prev_dir=""
  runtime=""
  if [ -f "$previous" ]; then
    prev_dir="$(yq -r '.directory // ""' "$previous")"
    runtime="$(yq -r '.runtime_dir // ""' "$previous")"
  fi
  [ -n "$prev_dir" ] || prev_dir="$DATA_DIR/deploy/.versions/${REPO_NAME}/${prev}"
  if [ -n "$prev" ] && [ -d "$prev_dir" ]; then
    warn "$(autodeploy_msg 'Interrupted deployment detected; restoring previous version: %s' "${prev:0:12}")"
    ln -sfn "$prev_dir" "${link}.new"
    mv -Tf "${link}.new" "$link"
    previous_type="$(yq -r '.type // "process"' "$previous" 2>/dev/null || printf process)"
    failed_dir="$(yq -r '.directory // ""' "$attempt_file")"
    if [ "$previous_type" = "process" ] && [ -d "$failed_dir" ]; then
      /usr/local/bin/autodeploy-deploy --stop-compose "$failed_dir" || warn "$(autodeploy_text 'Failed to stop failed compose services')"
    fi
    if [ "$previous_type" = "process" ]; then
      if [ -f "$runtime/start.sh" ] && [ -f "$runtime/supervisor.conf" ]; then
        cp -p "$runtime/start.sh" "$state_dir/start.sh"
        cp -p "$runtime/supervisor.conf" "$state_dir/supervisor.conf"
        ln -sf "$state_dir/supervisor.conf" "/etc/supervisor/conf.d/autodeploy-${state_name}.conf"
      else
        warn "$(autodeploy_msg 'Startup snapshot missing; autostart disabled. Redeploy: %s' "$state_name")"
        rm -f "$state_dir/supervisor.conf" "/etc/supervisor/conf.d/autodeploy-${state_name}.conf"
      fi
    else
      rm -f "$state_dir/supervisor.conf" "$state_dir/start.sh" "/etc/supervisor/conf.d/autodeploy-${state_name}.conf"
      if ! /usr/local/bin/autodeploy-deploy --restore-compose "$prev_dir"; then
        warn "$(autodeploy_msg 'Failed to restore previous compose version: %s' "$state_name")"
      fi
    fi
    failed_commit="$(yq -r '.commit // ""' "$attempt_file")"
    if [ -f "$previous" ]; then
      APP_FAILED_COMMIT="$failed_commit" AUTODEPLOY_STATUS_MESSAGE="$(autodeploy_text 'Deployment interrupted; previous configuration restored. Check service status')" yq '.status = "failed" | .failed_commit = strenv(APP_FAILED_COMMIT) | .message = strenv(AUTODEPLOY_STATUS_MESSAGE)' \
        "$previous" > "$state_file.tmp"
      mv "$state_file.tmp" "$state_file"
    fi
    rm -f "$state_dir/pending.json"
  else
    warn "$(autodeploy_msg 'Deployment interrupted; no rollback version. Service disabled: %s' "$REPO_NAME")"
    failed_dir="$(yq -r '.directory // ""' "$attempt_file")"
    if [ -d "$failed_dir" ]; then
      /usr/local/bin/autodeploy-deploy --stop-compose "$failed_dir" || warn "$(autodeploy_text 'Failed to stop failed compose services')"
    fi
    rm -f "$state_dir/supervisor.conf" "$state_dir/start.sh" "/etc/supervisor/conf.d/autodeploy-${state_name}.conf"
    AUTODEPLOY_STATUS_MESSAGE="$(autodeploy_text 'First deployment interrupted; service disabled. Redeploy')" yq -i '.status = "failed" | .message = strenv(AUTODEPLOY_STATUS_MESSAGE)' "$state_file"
    rm -f "$state_dir/pending.json"
  fi
done
if [ "$RESTORE_ENV" = "1" ] && [ -f "$DATA_DIR/deploy/${REPO_NAME}/${CONFIG_NAME}" ]; then
  if ! /usr/local/bin/autodeploy-deploy --prepare-env "$DATA_DIR/deploy/${REPO_NAME}"; then
    warn "$(autodeploy_text 'Failed to restore base environment; application may not start')"
  fi
fi

# Upgrade persisted process snapshots before Supervisor starts them. Old versions
# used git (or root), so changing only the deployment default would leave them privileged.
for app_conf in "$DATA_DIR"/state/*/supervisor.conf; do
  [ -f "$app_conf" ] || continue
  state_dir="$(dirname "$app_conf")"
  state_name="$(basename "$state_dir")"
  runtime_user="$(sed -n 's/^user=//p' "$app_conf")"
  runtime_uid="$(id -u "$runtime_user" 2>/dev/null || true)"
  if [ "$runtime_uid" = 0 ] || [ "$runtime_uid" = "$(id -u git)" ]; then
    runtime_user="${AUTODEPLOY_APP_USER:-autodeploy-app}"
    if autodeploy_runtime_user_allowed "$runtime_user" && [ -f "$state_dir/start.sh" ]; then
      sed -i "s/^user=.*/user=$runtime_user/" "$app_conf"
      runtime_home="$(getent passwd "$runtime_user" | cut -d: -f6)"
      migrated_start="$(mktemp "$state_dir/.start.XXXXXX")"
      home_replaced=0
      while IFS= read -r line || [ -n "$line" ]; do
        if [ "$home_replaced" = 0 ] && [[ "$line" == 'export HOME='* ]]; then
          printf 'export HOME=%q\n' "$runtime_home"
          home_replaced=1
        else
          printf '%s\n' "$line"
        fi
      done < "$state_dir/start.sh" > "$migrated_start"
      mv "$migrated_start" "$state_dir/start.sh"
      log "$(autodeploy_msg 'Migrated application runtime identity: %s -> %s' "$state_name" "$runtime_user")"
    fi
  fi
  runtime_directory="$(yq -r '.directory // ""' "$state_dir/deploy.json" 2>/dev/null || true)"
  sed -i 's|^command=/usr/bin/env -i /bin/bash |command=/usr/bin/setpriv --no-new-privs /usr/bin/env -i /bin/bash |' "$app_conf"
  if ! autodeploy_runtime_user_allowed "$runtime_user" || \
     ! autodeploy_prepare_runtime_tree "$runtime_directory" || \
     ! autodeploy_secure_runtime_files "$runtime_user" "$state_dir" "$DATA_DIR/logs/$state_name"; then
    warn "$(autodeploy_msg 'Unsafe runtime identity or file permissions; autostart disabled: %s' "$state_name")"
    rm -f "/etc/supervisor/conf.d/autodeploy-${state_name}.conf"
    # Program names historically normalize dots to hyphens.
    program="autodeploy-$(printf '%s' "$state_name" | sed 's/[^A-Za-z0-9_-]/-/g')"
    rm -f "/etc/supervisor/conf.d/$program.conf"
  fi
done

autodeploy_log_endpoints
log "$(autodeploy_msg 'Startup complete; deployment requires %s' "${CONFIG_NAME}")"

exec "$@"
