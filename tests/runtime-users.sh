#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/scripts/autodeploy-runtime"

# Account metadata is the boundary: exercise aliases and supplementary groups,
# not just a denylist of account names. No OS accounts or privileges are changed.
id() {
  case "$1:$2" in
    -u:root|-u:root-alias) printf '0\n' ;;
    -u:git|-u:git-alias) printf '1000\n' ;;
    -u:missing) return 1 ;;
    -u:*) printf '1001\n' ;;
    -G:autodeploy-app) printf '1001 2001\n' ;;
    -G:git-group) printf '1001 1000\n' ;;
    -G:root-group) printf '1001 0\n' ;;
    -G:docker-group) printf '1001 999\n' ;;
    -G:sudo-group) printf '1001 27\n' ;;
    -G:wheel-group) printf '1001 10\n' ;;
    -G:lookup-failed) return 1 ;;
    *) return 1 ;;
  esac
}
getent() {
  [ "$1" = group ] || return 1
  case "$2" in
    root) printf 'root:x:0:\n' ;;
    git) printf 'git:x:1000:\n' ;;
    docker) printf 'docker:x:999:\n' ;;
    sudo) printf 'sudo:x:27:\n' ;;
    wheel) printf 'wheel:x:10:\n' ;;
    *) return 1 ;;
  esac
}

autodeploy_runtime_user_allowed autodeploy-app || { echo 'isolated runtime user rejected' >&2; exit 1; }
for user in root root-alias git git-alias missing git-group root-group docker-group sudo-group wheel-group lookup-failed 'bad/name' $'bad\nuser' ''; do
  if autodeploy_runtime_user_allowed "$user"; then
    printf 'privileged/invalid runtime identity accepted: %q\n' "$user" >&2
    exit 1
  fi
done
echo 'runtime identity regression tests passed'
