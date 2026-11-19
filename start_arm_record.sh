#!/usr/bin/env bash
# start_arm_record.sh — launch arm_record_node
#
# Workflow:
#   [1/3] Extract ./install.zip in place (in the script's own directory)
#         (skipped automatically when the zip's sha256 matches the last run)
#   [2/3] source  ./install/setup.bash
#   [3/3] ros2 run armcontrol arm_record_node
#
# All project paths are relative to this script's directory, so the whole
# directory can be moved freely.
#
# Env:
#   FORCE_REINSTALL=1 ./start_arm_record.sh   # re-extract even if zip unchanged

set -euo pipefail

log() { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# 切换到脚本所在目录，后续全部使用相对路径，整个目录可随意移动
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
WS_DIR="."
ZIP_FILE="./install.zip"
HASH_FILE="./.install_zip.sha256"

log "Workspace: 当前脚本目录"
log "Source:    ${ZIP_FILE}"
log "----------------------------------------"

if [[ ! -f "${ZIP_FILE}" ]]; then
    err "Zip file not found: ${ZIP_FILE}"
    err "请把 install.zip 放到本脚本同级目录后重试。"
    exit 1
fi

# 1) Extract install.zip in place (skip when zip unchanged)
log "[1/3] Checking install.zip fingerprint"
CURRENT_HASH="$(sha256sum "${ZIP_FILE}" | awk '{print $1}')"
PREV_HASH=""
[[ -f "${HASH_FILE}" ]] && PREV_HASH="$(cat "${HASH_FILE}" 2>/dev/null || true)"

skip_extract=0
if [[ "${FORCE_REINSTALL:-0}" != "1" \
      && "${CURRENT_HASH}" == "${PREV_HASH}" \
      && -f "${WS_DIR}/install/setup.bash" ]]; then
    skip_extract=1
fi

if [[ "${skip_extract}" == "1" ]]; then
    log "  install.zip unchanged (sha256=${CURRENT_HASH:0:12}...), skipping extract."
else
    if [[ "${FORCE_REINSTALL:-0}" == "1" ]]; then
        log "  FORCE_REINSTALL=1, re-extracting."
    elif [[ -z "${PREV_HASH}" ]]; then
        log "  No previous fingerprint, fresh extract."
    elif [[ ! -f "${WS_DIR}/install/setup.bash" ]]; then
        log "  Workspace install/ missing, re-extracting."
    else
        log "  install.zip changed (old=${PREV_HASH:0:12}... new=${CURRENT_HASH:0:12}...), re-extracting."
    fi

    # Wipe old install/ so files removed from the new zip don't linger as stale.
    if [[ -d "${WS_DIR}/install" ]]; then
        log "  Removing previous ${WS_DIR}/install/"
        rm -rf "${WS_DIR}/install"
    fi

    log "  Extracting ${ZIP_FILE} -> ${WS_DIR}/"
    unzip -oq "${ZIP_FILE}" -d "${WS_DIR}/"
    if [[ ! -d "${WS_DIR}/install" ]]; then
        err "Expected directory missing after unzip: ${WS_DIR}/install"
        err "The archive should contain a top-level 'install/' folder."
        exit 1
    fi

    # Persist the hash AFTER successful extract so a partial failure forces redo.
    echo "${CURRENT_HASH}" > "${HASH_FILE}"
    log "  Fingerprint saved -> ${HASH_FILE}"
fi

# zip 可能丢失可执行权限，这里统一补回（否则 ros2 run 会报 No executable found）
if [[ -d "${WS_DIR}/install" ]]; then
    find "${WS_DIR}/install" -path '*/lib/*' -type f -exec chmod +x {} + 2>/dev/null || true
fi

# 2) Source the workspace overlay
SETUP="${WS_DIR}/install/setup.bash"
if [[ ! -f "${SETUP}" ]]; then
    err "setup.bash not found: ${SETUP}"
    exit 1
fi
log "[2/3] Sourcing ${SETUP}"
# colcon setup files may touch unset variables; relax nounset around source.
set +u
# shellcheck disable=SC1090
source "${SETUP}"
set -u

# 3) Launch the node (exec so signals go straight to ros2)
log "[3/3] Running: ros2 run armcontrol arm_record_node"
exec ros2 run armcontrol arm_record_node
