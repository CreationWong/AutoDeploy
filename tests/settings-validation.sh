#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$root/src/scripts/autodeploy-runtime"

autodeploy_validate_settings app AutoDeploy.config.yaml commit
autodeploy_validate_settings project-1.2_test .deploy.yaml branch
for repo in '../escape' '/absolute' '-option' '.' '..' '' 'two words' $'bad\nname'; do
  if autodeploy_validate_settings "$repo" AutoDeploy.config.yaml commit 2>/dev/null; then
    printf 'accepted invalid repository: %q\n' "$repo" >&2
    exit 1
  fi
done
for config in '../config' '/config' 'dir/config' '.' '..' '' 'bad\name' $'bad\nname'; do
  if autodeploy_validate_settings app "$config" commit 2>/dev/null; then
    printf 'accepted invalid config name: %q\n' "$config" >&2
    exit 1
  fi
done
if autodeploy_validate_settings app AutoDeploy.config.yaml invalid 2>/dev/null; then
  echo 'accepted invalid tag mode' >&2
  exit 1
fi
echo 'settings validation regression tests passed'
