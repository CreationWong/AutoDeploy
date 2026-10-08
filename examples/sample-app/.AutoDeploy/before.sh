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

set -e
echo "[CI] before.sh: 部署前检查通过 (${AUTODEPLOY_BRANCH}@${AUTODEPLOY_COMMIT:0:7})"
