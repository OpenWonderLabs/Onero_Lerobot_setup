#!/usr/bin/env bash
# setup_arm_env.sh — 主臂环境一键部署
#
# 流程：
#   [1/5] 安装前置依赖（含 Python 虚拟环境、ffmpeg/libav 视频依赖）
#   [2/5] 部署 Zenoh（Router 级联，PC 网线直连机器人）
#   [3/5] 安装 LeRobot Python 环境：
#         venv + CUDA 12.8 PyTorch + PyPI 适配器 + MuJoCo
#   [4/5] 交互式配置左右臂 USB-CAN 固定端口：
#         插左臂 -> 自动检测新增 /dev/ttyACM* -> 写入 usbcan.rules 的 ttyMasterCANL
#         插右臂 -> 自动检测新增 /dev/ttyACM* -> 写入 usbcan.rules 的 ttyMasterCANR
#         自动安装规则并 reload，生成 /dev/ttyMasterCANL 与 /dev/ttyMasterCANR
#   [5/5] 安装主臂运行时到 /opt/robot-h1，并生成 /usr/local/bin/arm_record_node
#
# 用法（在本脚本所在目录执行）：
#   chmod +x setup_arm_env.sh
#   ./setup_arm_env.sh
#
# 可选环境变量：
#   SKIP_DEPS=1           跳过依赖安装
#   SKIP_ZENOH=1          跳过 Zenoh Router 部署
#   SKIP_PYTHON=1         跳过 LeRobot Python 环境安装
#   H1_LEROBOT_VENV=...   虚拟环境路径；默认复用当前已激活的 venv，否则 ~/.venvs/h1-lerobot
#   LEROBOT_PKG_SPEC=...  PyPI 安装项，默认 lerobot_robot_onero_h1[lerobot,camera]
#   LEROBOT_SRC_DIR=...   从本地源码安装（PyPI 发布前测试用）
#   H1_IP=10.42.0.2       机器人 end1 地址（网线直连默认固定）
#   ACM_WAIT_SECONDS=15   插入设备后等待枚举的最长时间（秒），默认 15

set -euo pipefail

# 切换到脚本所在目录，后续一律使用相对路径，整个目录可随意移动
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="."
RULES_SRC="./usbcan.rules"
# udev 规则目录是系统固定路径，必须使用绝对路径
RULES_DST="/etc/udev/rules.d/usbcan.rules"
ACM_WAIT_SECONDS="${ACM_WAIT_SECONDS:-15}"

# Zenoh Router 级联部署参数（网线直连机器人 end1 时地址固定）
H1_IP="${H1_IP:-10.42.0.2}"
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"

# 依赖安装参数
WORK_DIR="${WORK_DIR:-./dev}"
RBDL_VERSION="v3.3.1"
JOBS="$(nproc)"

# LeRobot Python 环境参数（RTX 5090 使用 CUDA 12.8 轮子）
H1_LEROBOT_VENV="${H1_LEROBOT_VENV:-${VIRTUAL_ENV:-$HOME/.venvs/h1-lerobot}}"
LEROBOT_PKG_SPEC="${LEROBOT_PKG_SPEC:-lerobot_robot_onero_h1[lerobot,camera]}"
LEROBOT_SRC_DIR="${LEROBOT_SRC_DIR:-}"
MUJOCO_VERSION="${MUJOCO_VERSION:-3.12.0}"
TORCH_VERSION="${TORCH_VERSION:-2.8.0}"
TORCHVISION_VERSION="${TORCHVISION_VERSION:-0.23.0}"
TORCH_INDEX_CUDA="${TORCH_INDEX_CUDA:-https://download.pytorch.org/whl/cu128}"
TORCH_INDEX_CPU="${TORCH_INDEX_CPU:-https://download.pytorch.org/whl/cpu}"
PIP_NETWORK_OPTS=(--timeout 120 --retries 3)

LEFT_NAME="ttyMasterCANL"
RIGHT_NAME="ttyMasterCANR"
LEFT_DEV="/dev/${LEFT_NAME}"
RIGHT_DEV="/dev/${RIGHT_NAME}"

# 已见过的 ttyACM 设备（用于做“新增”差分）
KNOWN_ACMS=()

LEFT_KERNELS=""
RIGHT_KERNELS=""

log()  { printf '\033[1;32m[INFO]\033[0m  %s\n' "$*"; }
# 警告与交互提示统一走 stderr，避免被命令替换捕获
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

die() {
    err "$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"
}

# 读取交互输入时优先走 /dev/tty，避免 stdin 被重定向导致无法交互
read_line() {
    local __var="$1"
    if [[ -r /dev/tty ]]; then
        IFS= read -r "${__var}" </dev/tty || return 1
    else
        IFS= read -r "${__var}" || return 1
    fi
}

press_enter() {
    local prompt="$1"
    printf '\n%s\n' "$prompt" >&2
    printf '>>> 按回车继续... ' >&2
    read_line _ || true
    printf '\n' >&2
}

# 列出当前所有 /dev/ttyACM*（每行一个，已排序）
list_acms() {
    local f
    for f in /dev/ttyACM*; do
        [[ -e "${f}" ]] && printf '%s\n' "${f}"
    done | sort
}

seed_known_acms() {
    local d
    KNOWN_ACMS=()
    while IFS= read -r d; do
        [[ -n "${d}" ]] && KNOWN_ACMS+=("${d}")
    done < <(list_acms)
}

mark_known() {
    KNOWN_ACMS+=("$1")
}

is_known() {
    local d="$1" k
    if (( ${#KNOWN_ACMS[@]} == 0 )); then
        return 1
    fi
    for k in "${KNOWN_ACMS[@]}"; do
        [[ "${k}" == "${d}" ]] && return 0
    done
    return 1
}

# 输出相对于 KNOWN_ACMS 的新增设备
new_acms() {
    local d
    while IFS= read -r d; do
        [[ -z "${d}" ]] && continue
        if ! is_known "${d}"; then
            printf '%s\n' "${d}"
        fi
    done < <(list_acms)
}

# 轮询最多 ACM_WAIT_SECONDS 秒，输出新出现的设备；超时则无输出
wait_for_new_acms() {
    local deadline=$((SECONDS + ACM_WAIT_SECONDS))
    local -a found=()
    local d
    while :; do
        found=()
        while IFS= read -r d; do
            [[ -n "${d}" ]] && found+=("${d}")
        done < <(new_acms)
        if (( ${#found[@]} > 0 )); then
            printf '%s\n' "${found[@]}"
            return 0
        fi
        if (( SECONDS >= deadline )); then
            return 0
        fi
        sleep 0.5
    done
}

# 从设备节点提取 USB 接口级 KERNELS（形如 1-3:1.0）
get_kernels() {
    local dev="$1"
    local kernels
    kernels="$(udevadm info --attribute-walk --name="${dev}" 2>/dev/null \
        | sed -n 's/^[[:space:]]*KERNELS=="\([^"]*\)"/\1/p' \
        | grep ':' \
        | head -n 1 || true)"
    [[ -n "${kernels}" ]] || die "无法从 ${dev} 获取 KERNELS 值，请确认设备已正常枚举。"
    printf '%s\n' "${kernels}"
}

# ==================== 依赖安装 ====================
# 自动识别 Ubuntu 版本：22.04 -> Humble，24.04 -> Jazzy；支持 x86_64 / aarch64。

apt_install_if_missing() {
    local pkg="$1"
    if dpkg -s "${pkg}" >/dev/null 2>&1; then
        log "  ${pkg} 已安装，跳过。"
    else
        sudo apt-get install -y --no-upgrade "${pkg}"
    fi
}

detect_arch() {
    local uname_arch
    uname_arch="$(uname -m)"
    case "${uname_arch}" in
        x86_64|amd64)  ARCH="x86_64"; DPKG_ARCH="amd64" ;;
        aarch64|arm64) ARCH="aarch64"; DPKG_ARCH="arm64" ;;
        armv7l|armv7|armhf)
            die "不支持 32 位 ARM（${uname_arch}），需要 64 位系统。" ;;
        *)
            die "不支持的 CPU 架构：${uname_arch}（支持 x86_64 / aarch64）。" ;;
    esac

    local dpkg_reported
    dpkg_reported="$(dpkg --print-architecture 2>/dev/null || true)"
    if [[ -n "${dpkg_reported}" && "${dpkg_reported}" != "${DPKG_ARCH}" ]]; then
        warn "uname 报告 ${ARCH}（${DPKG_ARCH}），但 dpkg 报告 ${dpkg_reported}；以 dpkg 为准。"
        DPKG_ARCH="${dpkg_reported}"
    fi
    log "检测到架构：${ARCH}（dpkg=${DPKG_ARCH}）"
}

detect_ros_distro() {
    if [[ ! -r /etc/os-release ]]; then
        die "无法读取 /etc/os-release。"
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "仅支持 Ubuntu（检测到 ID=${ID:-unknown}）。"
    fi

    UBUNTU_VERSION="${VERSION_ID:-}"
    case "${UBUNTU_VERSION}" in
        22.04) ROS_DISTRO_AUTO="humble" ;;
        24.04) ROS_DISTRO_AUTO="jazzy" ;;
        *) die "不支持的 Ubuntu 版本：${UBUNTU_VERSION}（支持 22.04 / 24.04）。" ;;
    esac

    ROS_DISTRO="${ROS_DISTRO:-${ROS_DISTRO_AUTO}}"
    PINOCCHIO_PKG="ros-${ROS_DISTRO}-pinocchio"
    log "检测到 Ubuntu ${UBUNTU_VERSION} -> ROS 2 ${ROS_DISTRO}"
    log "Pinocchio 包：${PINOCCHIO_PKG}"
}

ensure_ros2_apt_source() {
    # 已有可用的 ROS 2 源时直接返回
    if apt-cache show "ros-${ROS_DISTRO}-ros-base" >/dev/null 2>&1; then
        return 0
    fi

    local ros_mirror="${ROS_APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu}"
    log "配置 ROS 2 ${ROS_DISTRO} apt 源（${ros_mirror}）..."
    apt_install_if_missing curl
    apt_install_if_missing ca-certificates
    apt_install_if_missing gnupg

    local codename
    codename="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
    if [[ -z "${codename}" ]]; then
        die "无法确定 Ubuntu 代号，不能配置 ROS 2 软件源。"
    fi

    sudo install -m 0755 -d /usr/share/keyrings
    if ! curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /tmp/ros.key 2>/dev/null; then
        warn "从 GitHub 获取 ROS key 失败，改用 packages.ros.org。"
        curl -fsSL http://packages.ros.org/ros.key -o /tmp/ros.key \
            || die "无法下载 ROS 2 apt key，请检查网络。"
    fi
    sudo cp /tmp/ros.key /usr/share/keyrings/ros-archive-keyring.gpg
    rm -f /tmp/ros.key

    echo "deb [arch=${DPKG_ARCH} signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] ${ros_mirror} ${codename} main" \
        | sudo tee /etc/apt/sources.list.d/ros2.list >/dev/null
    sudo apt-get update -y
}

ensure_ros2_installed() {
    if [[ "${SKIP_ROS:-0}" == "1" ]]; then
        warn "SKIP_ROS=1，跳过 ROS 2 检测与安装。"
        return 0
    fi
    if [[ -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]]; then
        log "已检测到 ROS 2 ${ROS_DISTRO}：/opt/ros/${ROS_DISTRO}"
        ensure_ros2_apt_source
        return 0
    fi

    log "未检测到 ROS 2 ${ROS_DISTRO}，开始自动安装..."
    ensure_ros2_apt_source
    sudo apt-get install -y "ros-${ROS_DISTRO}-ros-base" \
        || die "ROS 2 ${ROS_DISTRO} 安装失败。"
    if [[ ! -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]]; then
        die "ROS 2 ${ROS_DISTRO} 安装后仍缺少 /opt/ros/${ROS_DISTRO}/setup.bash。"
    fi
    log "ROS 2 ${ROS_DISTRO} 安装完成。"
}

install_apt_packages() {
    log "更新 apt 索引..."
    sudo apt-get update -y

    log "安装编译工具与通用依赖（已存在则跳过）..."
    local pkg
    for pkg in git cmake build-essential pkg-config \
               libeigen3-dev liburdfdom-dev libtinyxml2-dev \
               net-tools; do
        apt_install_if_missing "${pkg}"
    done

    # colcon 仅源码编译 ROS 包时需要；部分 ROS 2 源/镜像不提供该包，缺失时跳过。
    if ! apt_install_if_missing python3-colcon-common-extensions; then
        warn "python3-colcon-common-extensions 不可用，跳过（运行时部署不需要）。"
    fi

    log "安装 Python 虚拟环境与视频/相机系统依赖（已存在则跳过）..."
    for pkg in python3-venv python3-pip ffmpeg \
               libavcodec-dev libavformat-dev libavutil-dev libavdevice-dev \
               libgl1 libglib2.0-0; do
        apt_install_if_missing "${pkg}"
    done

    log "安装并启用 openssh-server..."
    apt_install_if_missing openssh-server
    sudo systemctl enable ssh
    sudo systemctl restart ssh
    sudo systemctl status ssh --no-pager || true

    log "安装 nlohmann-json3-dev..."
    apt_install_if_missing nlohmann-json3-dev

    log "安装 libmodbus-dev..."
    apt_install_if_missing libmodbus-dev

    log "安装 ${PINOCCHIO_PKG}..."
    if ! apt-cache show "${PINOCCHIO_PKG}" >/dev/null 2>&1; then
        die "${PINOCCHIO_PKG} 不在 apt 源中（arch=${DPKG_ARCH}），请先配置 ROS 2 ${ROS_DISTRO} 软件源。"
    fi
    install_pinocchio_pinned
}

install_pinocchio_pinned() {
    # 优先使用 3.9.x / 3.8.x；若软件源只提供更高版本（如 4.x），回退到 apt 候选版本
    local preferred=()
    case "${UBUNTU_VERSION}" in
        22.04) preferred=("3.9") ;;
        24.04) preferred=("3.9" "3.8") ;;
        *)     preferred=("3.9") ;;
    esac

    local chosen="" prefix=""
    for prefix in "${preferred[@]}"; do
        chosen="$(apt-cache madison "${PINOCCHIO_PKG}" \
                  | awk '{print $3}' \
                  | grep "^${prefix}\\." \
                  | head -n1 || true)"
        if [[ -n "${chosen}" ]]; then
            log "  选择 ${PINOCCHIO_PKG} 版本 ${chosen}（匹配 ${prefix}.x）"
            break
        fi
        warn "  没有可用的 ${prefix}.x 版本。"
    done

    if [[ -z "${chosen}" ]]; then
        chosen="$(apt-cache madison "${PINOCCHIO_PKG}" | awk '{print $3}' | head -n1 || true)"
        if [[ -z "${chosen}" ]]; then
            die "软件源中没有可用的 ${PINOCCHIO_PKG}。"
        fi
        warn "未找到 ${preferred[*]}.x，回退到软件源中的候选版本 ${chosen}。"
    fi

    local installed
    installed="$(dpkg-query -W -f='${Version}' "${PINOCCHIO_PKG}" 2>/dev/null || true)"
    if [[ "${installed}" == "${chosen}" ]]; then
        log "  ${PINOCCHIO_PKG}=${chosen} 已安装。"
    else
        sudo apt-mark unhold "${PINOCCHIO_PKG}" >/dev/null 2>&1 || true
        sudo apt-get install -y --allow-downgrades "${PINOCCHIO_PKG}=${chosen}"
    fi

    sudo apt-mark hold "${PINOCCHIO_PKG}"
    log "  ${PINOCCHIO_PKG} 已固定为 ${chosen}。"
}

# 子 shell 中执行，避免 cd 影响后续相对路径
install_rbdl_from_source() (
    log "从源码安装 RBDL ${RBDL_VERSION}..."

    if ldconfig -p | grep librbdl >/dev/null; then
        warn "链接缓存中已存在 RBDL，跳过编译；设置 FORCE_RBDL=1 可强制重装。"
        if [[ "${FORCE_RBDL:-0}" != "1" ]]; then
            return 0
        fi
    fi

    mkdir -p "${WORK_DIR}"
    cd "${WORK_DIR}"

    if [[ ! -d rbdl ]]; then
        git clone --recursive https://github.com/rbdl/rbdl.git
    fi

    cd rbdl
    git fetch --tags
    git checkout "${RBDL_VERSION}"
    git submodule update --init --recursive

    rm -rf build
    mkdir build && cd build
    cmake .. \
        -DRBDL_BUILD_ADDON_URDFREADER=ON \
        -DCMAKE_BUILD_TYPE=Release
    make -j"${JOBS}"
    sudo make install
    sudo ldconfig
)

verify_dependencies() {
    log "校验依赖安装结果..."
    log "  架构                 ${ARCH} (${DPKG_ARCH})"
    dpkg -s nlohmann-json3-dev    >/dev/null 2>&1 && log "  nlohmann-json3-dev   OK" || warn "  nlohmann-json3-dev   缺失"
    dpkg -s libmodbus-dev         >/dev/null 2>&1 && log "  libmodbus-dev        OK" || warn "  libmodbus-dev        缺失"
    dpkg -s "${PINOCCHIO_PKG}"    >/dev/null 2>&1 && log "  ${PINOCCHIO_PKG}  OK" || warn "  ${PINOCCHIO_PKG}  缺失"
    ldconfig -p | grep librbdl    >/dev/null     && log "  librbdl              OK" || warn "  librbdl              缺失"
}

install_dependencies() {
    log "========== 第 1 步：安装前置依赖 =========="
    if [[ "${SKIP_DEPS:-0}" == "1" ]]; then
        warn "SKIP_DEPS=1，跳过依赖安装。"
        return 0
    fi
    if [[ "$(uname -s)" != "Linux" ]]; then
        die "本脚本仅支持 Linux（Ubuntu 22.04 / 24.04，x86_64 或 aarch64）。"
    fi
    detect_arch
    detect_ros_distro
    ensure_ros2_installed
    install_apt_packages
    install_rbdl_from_source
    verify_dependencies
    log "前置依赖安装完成。"
}

# Zenoh Router 级联部署（方式 B）：PC 常驻 router 并上联机器人 7447。
# 等价于：sudo python3 ./deploy.py pc --h1-ip 10.42.0.2 --user "$USER"
deploy_zenoh() {
    log "========== 第 2 步：部署 Zenoh（Router 级联，网线直连 PC） =========="
    if [[ "${SKIP_ZENOH:-0}" == "1" ]]; then
        warn "SKIP_ZENOH=1，跳过 Zenoh 部署。"
        return 0
    fi

    # 兼容两种存放位置：./scripts/deploy.py 或 ./deploy.py
    local deploy_dir=""
    if [[ -f "./scripts/deploy.py" ]]; then
        deploy_dir="./scripts"
    elif [[ -f "./deploy.py" ]]; then
        deploy_dir="."
    else
        die "未找到 deploy.py（可放在 ./scripts/ 或脚本同级目录）。"
    fi

    local asset
    for asset in deploy.py apt-package-guard.py robot-zenoh-connect zenoh-router.service; do
        [[ -f "${deploy_dir}/${asset}" ]] || die "缺少 Zenoh 部署资源：${deploy_dir}/${asset}"
    done

    log "执行：sudo python3 ${deploy_dir}/deploy.py pc --h1-ip ${H1_IP} --user ${TARGET_USER}"
    sudo python3 "${deploy_dir}/deploy.py" pc --h1-ip "${H1_IP}" --user "${TARGET_USER}"
    log "Zenoh Router 部署完成。"

    printf '\n\033[1;33m[注意]\033[0m Zenoh 已按照【网线直连 PC】的方式完成配置（PC <-> 机器人 end1，%s:7447）。\n' "${H1_IP}"
    printf '        请确保网线已正常接上；重新打开终端（或 source ~/.bashrc）后生效。\n\n'
}

# 安装 LeRobot Python 环境：venv + CUDA PyTorch + PyPI 适配器 + MuJoCo
install_lerobot_python() {
    log "========== 第 3 步：安装 LeRobot Python 环境 =========="
    if [[ "${SKIP_PYTHON:-0}" == "1" ]]; then
        warn "SKIP_PYTHON=1，跳过 Python 环境安装。"
        return 0
    fi

    local venv="${H1_LEROBOT_VENV}"
    local ros_setup="" f
    for f in /opt/ros/jazzy/setup.bash /opt/ros/humble/setup.bash; do
        if [[ -f "${f}" ]]; then
            ros_setup="${f}"
            break
        fi
    done
    [[ -n "${ros_setup}" ]] || die "未找到 ROS 2 Jazzy/Humble，无法安装 LeRobot 环境。"

    require_cmd python3
    python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 12) else 1)' \
        || die "LeRobot 0.6.1 需要 Python >= 3.12（当前：$(python3 --version 2>&1)）。"

    if [[ ! -x "${venv}/bin/python" ]]; then
        log "创建虚拟环境：${venv}"
        python3 -m venv --system-site-packages "${venv}"
    else
        log "复用虚拟环境：${venv}"
        if [[ -f "${venv}/pyvenv.cfg" ]] \
           && ! grep -q '^include-system-site-packages = true' "${venv}/pyvenv.cfg"; then
            warn "该 venv 未启用 --system-site-packages；若无法导入 rclpy，请删除后重装：rm -rf ${venv}"
        fi
    fi

    local torch_index="${TORCH_INDEX_CPU}"
    local want_cuda=""
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        torch_index="${TORCH_INDEX_CUDA}"
        case "${torch_index}" in
            *cu128*) want_cuda="12.8" ;;
            *cu126*) want_cuda="12.6" ;;
            *cu124*) want_cuda="12.4" ;;
        esac
        log "检测到 NVIDIA GPU："
        nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader || true

        # cu128 轮子要求 Turing（sm_75）及以上；更老的 GPU 回退 CPU，
        # 保证遥操/数采仍可用，避免装上无法执行的 GPU 内核。
        local compute_cap cap_major cap_minor
        compute_cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
                       | head -n1 | tr -d '[:space:]' || true)"
        if [[ "${compute_cap}" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
            cap_major="${BASH_REMATCH[1]}"
            cap_minor="${BASH_REMATCH[2]}"
            if (( cap_major < 7 || (cap_major == 7 && cap_minor < 5) )); then
                warn "GPU 计算能力 sm_${cap_major}${cap_minor} 低于 cu128 支持范围，改用 CPU 版 PyTorch。"
                warn "遥操/数采仍可使用；训练/rollout 建议换用 Turing 及以上 GPU。"
                torch_index="${TORCH_INDEX_CPU}"
                want_cuda=""
            fi
        fi
    else
        warn "未检测到可用的 NVIDIA GPU，回退到 CPU 版 PyTorch（遥操/数采可用，训练/rollout 无法使用 GPU）。"
    fi

    (
        set +u
        # shellcheck disable=SC1090
        source "${ros_setup}"
        # shellcheck disable=SC1091
        source "${venv}/bin/activate"
        set -u

        python -c 'import rclpy' >/dev/null 2>&1 \
            || die "虚拟环境无法导入 rclpy；请确认 ROS 2 已安装，并使用 --system-site-packages 创建 venv。"

        python -m pip install "${PIP_NETWORK_OPTS[@]}" --upgrade \
            pip 'setuptools>=71,<80' wheel 'packaging>=24.2,<26'

        # 已有 CUDA 版本且满足 LeRobot 约束时跳过，避免重复下载数 GB
        if python -c "import torch, sys; from packaging.version import Version; v=Version(torch.__version__); sys.exit(0 if (torch.version.cuda or '') == '${want_cuda}' and Version('2.7') <= v < Version('2.12') else 1)" 2>/dev/null; then
            log "PyTorch 已满足要求（$(python -c 'import torch; print(torch.__version__)')），跳过。"
        else
            log "安装 PyTorch ${TORCH_VERSION} / torchvision ${TORCHVISION_VERSION}（${torch_index}）..."
            if ! python -m pip install "${PIP_NETWORK_OPTS[@]}" \
                --index-url "${torch_index}" --force-reinstall \
                "torch==${TORCH_VERSION}" "torchvision==${TORCHVISION_VERSION}"; then
                die "PyTorch 安装失败；请检查显卡驱动、网络和 ${torch_index} 是否可访问。"
            fi
        fi

        if [[ -n "${LEROBOT_SRC_DIR}" ]]; then
            log "从本地源码安装：${LEROBOT_SRC_DIR}"
            if ! python -m pip install "${PIP_NETWORK_OPTS[@]}" \
                -e "${LEROBOT_SRC_DIR}[lerobot,camera]"; then
                die "本地源码安装失败：${LEROBOT_SRC_DIR}"
            fi
        else
            pkg_spec="${LEROBOT_PKG_SPEC}"
            if [[ "${pkg_spec}" == *.whl || "${pkg_spec}" == *.tar.gz || "${pkg_spec}" == *.zip ]]; then
                # 本地包路径不会自动带上 extras，补上后再安装，否则 LeRobot 本身不会装。
                if [[ "${pkg_spec}" != *"["* ]]; then
                    pkg_spec="${pkg_spec}[lerobot,camera]"
                fi
                log "从本地包安装：${pkg_spec}"
                # 同版本 wheel 会被 pip 判定为“已安装”而跳过；先卸载以确保使用最新构建。
                python -m pip uninstall -y lerobot_robot_onero_h1 >/dev/null 2>&1 || true
                if ! python -m pip install "${PIP_NETWORK_OPTS[@]}" "${pkg_spec}"; then
                    die "本地包安装失败：${pkg_spec}"
                fi
            else
                log "从 PyPI 安装：${pkg_spec}"
                if ! python -m pip install "${PIP_NETWORK_OPTS[@]}" "${pkg_spec}"; then
                    die "PyPI 安装失败。若包尚未发布，请设置 LEROBOT_SRC_DIR=/path/to/oneroh1lerobot 后重试。"
                fi
            fi
        fi

        # pi0.5（pi05）策略在 rollout 时需要 transformers，由 LeRobot 的 [pi] extra 提供。
        # 这里显式补装，兼容未在 wheel 元数据中声明该依赖的旧版本。
        if ! python -m pip install "${PIP_NETWORK_OPTS[@]}" "lerobot[pi]==0.6.1"; then
            warn "transformers 安装失败，pi0.5（pi05）rollout 将不可用。"
        fi

        if ! python -m pip install "${PIP_NETWORK_OPTS[@]}" "scipy>=1.14,<2"; then
            die "SciPy 安装失败（LeRobot policy 依赖 scipy>=1.14）。"
        fi

        if ! python -m pip install "${PIP_NETWORK_OPTS[@]}" "mujoco==${MUJOCO_VERSION}"; then
            die "MuJoCo ${MUJOCO_VERSION} 安装失败。"
        fi

        # LeRobot 的 dataset extra 允许 torchcodec<0.12，但 0.8+ 需要 torch 2.9，
        # 与这里固定的 torch 2.8 不兼容；0.7.0 与 torch 2.8 匹配。
        if [[ "$(uname -m)" == "x86_64" ]]; then
            python -m pip install "${PIP_NETWORK_OPTS[@]}" --force-reinstall --no-deps \
                "torchcodec==0.7.0" \
                || warn "torchcodec 0.7.0 安装失败，视频解码将回退到 pyav"
        fi

        log "验证 Python 环境..."
        python - <<'PY'
import importlib.metadata as md

import cv2
import lerobot
import mujoco
import rclpy
import torch
import torchvision
from onero_h1_lerobot import OneroH1Config, OneroH1Robot

print(f"  LeRobot: {md.version('lerobot')}")
print(f"  Adapter: {md.version('lerobot_robot_onero_h1')}")
print(f"  PyTorch: {torch.__version__} (CUDA {torch.version.cuda})")
print(f"  torchvision: {torchvision.__version__}")
print(f"  MuJoCo: {mujoco.__version__}")
print(f"  OpenCV: {cv2.__version__}")
print(f"  rclpy: {rclpy.__file__}")

if torch.cuda.is_available():
    cap = torch.cuda.get_device_capability(0)
    print(f"  GPU: {torch.cuda.get_device_name(0)} (sm_{cap[0]}{cap[1]})")
    x = torch.randn(256, 256, device="cuda")
    y = x @ x
    torch.cuda.synchronize()
    print(f"  GPU smoke: {float(y.abs().mean()):.4f}")
else:
    print("  WARN: CUDA 不可用，训练/rollout 将无法使用 GPU。")

robot = OneroH1Robot(OneroH1Config(id="setup-verification", use_cameras=False))
assert len(robot.action_features) == 16
print("  Action schema: 16 dimensions")
PY

        if [[ -n "${want_cuda}" ]] && ! python -c 'import torch; raise SystemExit(0 if torch.cuda.is_available() else 1)'; then
            die "检测到 NVIDIA GPU，但 PyTorch 无法使用 CUDA；请检查驱动是否支持 CUDA ${want_cuda}。"
        fi
    )

    log "LeRobot Python 环境安装完成。"
    printf '  虚拟环境：%s\n' "${venv}"
    printf '  激活命令：source %s/bin/activate\n' "${venv}"
}

# 提示插入某一侧手臂，返回检测到的设备节点路径
prompt_arm_device() {
    local side="$1"
    local dev=""

    while :; do
        press_enter "请插入【${side}】USB-CAN 线，插入完成后按回车。"
        local -a found=()
        local d
        while IFS= read -r d; do
            [[ -n "${d}" ]] && found+=("${d}")
        done < <(wait_for_new_acms)

        if (( ${#found[@]} == 0 )); then
            warn "在 ${ACM_WAIT_SECONDS}s 内没有检测到新的 /dev/ttyACM*。"
            warn "请确认：1) 设备已插好  2) 线缆/接口正常  3) 重新拔插后再试。"
            continue
        fi

        if (( ${#found[@]} == 1 )); then
            dev="${found[0]}"
        else
            warn "检测到多个新增设备，请选择【${side}】对应的那一个："
            local i
            for i in "${!found[@]}"; do
                printf '    [%d] %s\n' "$((i + 1))" "${found[i]}" >&2
            done
            local choice="1"
            printf '>>> 请输入序号 [1-%d]: ' "${#found[@]}" >&2
            read_line choice || choice="1"
            if ! [[ "${choice}" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#found[@]} )); then
                warn "输入无效，默认使用第 1 个。"
                choice=1
            fi
            dev="${found[$((choice - 1))]}"
        fi
        break
    done

    # 立即显示检测到的新增设备路径，方便确认是不是自己刚插入的那一个
    printf '\033[1;32m[INFO]\033[0m  检测到新增设备：%s\n' "${dev}" >&2
    printf '%s\n' "${dev}"
}

write_rules() {
    local left_kernels="$1"
    local right_kernels="$2"
    local tmp
    tmp="$(mktemp)"
    {
        printf 'SUBSYSTEM=="tty", KERNELS=="%s", SYMLINK+="%s", MODE="0666"\n' \
            "${left_kernels}" "${LEFT_NAME}"
        printf 'SUBSYSTEM=="tty", KERNELS=="%s", SYMLINK+="%s", MODE="0666"\n' \
            "${right_kernels}" "${RIGHT_NAME}"
    } >"${tmp}"

    # 同步一份到工作目录，便于查看和后续复用
    cp "${tmp}" "${RULES_SRC}"
    sudo install -m 0644 "${tmp}" "${RULES_DST}"
    rm -f "${tmp}"

    log "规则已写入：${RULES_SRC}"
    log "规则已安装：${RULES_DST}"
    log "  ${LEFT_NAME}  <- KERNELS==\"${left_kernels}\""
    log "  ${RIGHT_NAME} <- KERNELS==\"${right_kernels}\""
}

apply_rules() {
    log "重新加载 udev 规则并触发设备事件..."
    sudo udevadm control --reload-rules
    sudo udevadm trigger --action=add --subsystem-match=tty
    sudo udevadm settle
}

verify_links() {
    local i
    for i in $(seq 1 10); do
        if [[ -e "${LEFT_DEV}" && -e "${RIGHT_DEV}" ]]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

configure_usb_can() {
    log "========== 第 4 步：配置左右臂 USB-CAN 固定端口 =========="

    press_enter "请先【拔掉】左右两臂的 USB-CAN 线（若已拔掉，直接回车即可）。"
    seed_known_acms
    if (( ${#KNOWN_ACMS[@]} > 0 )); then
        warn "当前仍检测到以下 ttyACM 设备，检测新增时将忽略它们："
        printf '    %s\n' "${KNOWN_ACMS[@]}"
    fi

    local left_dev right_dev
    left_dev="$(prompt_arm_device "左臂")"
    mark_known "${left_dev}"
    LEFT_KERNELS="$(get_kernels "${left_dev}")"
    log "左臂设备：${left_dev}  KERNELS==\"${LEFT_KERNELS}\""

    right_dev="$(prompt_arm_device "右臂")"
    mark_known "${right_dev}"
    if [[ "${right_dev}" == "${left_dev}" ]]; then
        die "左右臂检测到了同一个设备 ${right_dev}，请重新拔插后再运行。"
    fi
    RIGHT_KERNELS="$(get_kernels "${right_dev}")"
    log "右臂设备：${right_dev}  KERNELS==\"${RIGHT_KERNELS}\""

    if [[ "${LEFT_KERNELS}" == "${RIGHT_KERNELS}" ]]; then
        die "左右臂的 KERNELS 相同（${LEFT_KERNELS}），无法区分，请检查设备。"
    fi

    write_rules "${LEFT_KERNELS}" "${RIGHT_KERNELS}"
    apply_rules

    if ! verify_links; then
        warn "固定端口尚未出现，可能是设备未重新触发。"
        press_enter "请把左右两臂 USB-CAN 拔下后重新插好，然后按回车重试。"
        apply_rules
        if ! verify_links; then
            die "仍未生成 ${LEFT_DEV} / ${RIGHT_DEV}，请执行 ls -l /dev/ttyACM* 和 ls -l /dev/ttyMasterCAN* 检查。"
        fi
    fi

    log "固定端口生效："
    ls -l "${LEFT_DEV}" "${RIGHT_DEV}" || true
}

install_runtime() {
    log "========== 第 5 步：安装主臂运行时 =========="

    local archive="${SCRIPT_DIR}/install.zip"
    [[ -f "${archive}" ]] || die "缺少 install.zip，无法安装主臂运行时。"
    require_cmd unzip

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if ! unzip -oq "${archive}" -d "${tmp_dir}"; then
        rm -rf "${tmp_dir}"
        die "解压 ${archive} 失败。"
    fi
    if [[ ! -f "${tmp_dir}/install/setup.bash" ]]; then
        rm -rf "${tmp_dir}"
        die "install.zip 结构异常，未找到 install/setup.bash。"
    fi

    # zip 可能丢失执行权限
    find "${tmp_dir}/install" -path '*/lib/*' -type f -exec chmod +x {} + 2>/dev/null || true

    sudo install -d -m 0755 /opt/robot-h1
    sudo rm -rf /opt/robot-h1/install
    sudo cp -a "${tmp_dir}/install" /opt/robot-h1/install
    rm -rf "${tmp_dir}"

    local wrapper
    wrapper="$(mktemp)"
    cat > "${wrapper}" <<'WRAPPER'
#!/usr/bin/env bash
set -e
for f in /opt/ros/jazzy/setup.bash /opt/ros/humble/setup.bash; do
    if [ -f "$f" ]; then
        source "$f"
        break
    fi
done
if [ -f /etc/zenoh/ros.env ]; then
    set -a
    source /etc/zenoh/ros.env
    set +a
fi
source /opt/robot-h1/install/setup.bash
exec /opt/robot-h1/install/armcontrol/lib/armcontrol/arm_record_node "$@"
WRAPPER
    sudo install -m 0755 "${wrapper}" /usr/local/bin/arm_record_node
    rm -f "${wrapper}"

    log "主臂运行时安装完成："
    printf '  入口：/usr/local/bin/arm_record_node\n'
    printf '  目录：/opt/robot-h1/install\n'
}

# 部署完成后统一自检：环境、CUDA、ROS、Zenoh、设备、主臂程序。
verify_environment() {
    local ok_count=0 warn_count=0 fail_count=0

    chk_ok()   { ok_count=$((ok_count + 1));   printf '  [\033[1;32mOK\033[0m]   %s\n' "$*"; }
    chk_warn() { warn_count=$((warn_count + 1)); printf '  [\033[1;33mWARN\033[0m] %s\n' "$*"; }
    chk_fail() { fail_count=$((fail_count + 1)); printf '  [\033[1;31mFAIL\033[0m] %s\n' "$*"; }

    printf '\n'
    log "========== 环境自检 =========="

    # ROS 2
    if [[ "${SKIP_ROS:-0}" == "1" ]]; then
        chk_warn "ROS 2 检测已跳过（SKIP_ROS=1）"
    elif [[ -n "${ROS_DISTRO:-}" && -f "/opt/ros/${ROS_DISTRO}/setup.bash" ]]; then
        chk_ok "ROS 2 ${ROS_DISTRO} 已安装"
    else
        chk_fail "未找到 ROS 2 环境（/opt/ros/<distro>/setup.bash）"
    fi

    if grep -qs 'RMW_IMPLEMENTATION=rmw_zenoh_cpp' "${HOME}/.bashrc"; then
        chk_ok "~/.bashrc 已配置 rmw_zenoh_cpp"
    else
        chk_warn "~/.bashrc 未配置 RMW_IMPLEMENTATION=rmw_zenoh_cpp"
    fi

    # Zenoh
    if [[ "${SKIP_ZENOH:-0}" == "1" ]]; then
        chk_warn "Zenoh 检测已跳过（SKIP_ZENOH=1）"
    else
        if systemctl is-active --quiet zenoh-router 2>/dev/null; then
            chk_ok "zenoh-router 服务运行中"
        else
            chk_fail "zenoh-router 未运行（systemctl status zenoh-router）"
        fi
        if command -v ss >/dev/null 2>&1 && ss -lnt 2>/dev/null | grep -q ':7447 '; then
            chk_ok "Zenoh 端口 7447 正在监听"
        else
            chk_fail "Zenoh 端口 7447 未监听"
        fi
    fi

    # 机器人连通性
    if timeout 3 bash -c "cat < /dev/null > /dev/tcp/${H1_IP}/7447" 2>/dev/null; then
        chk_ok "可连接机器人 ${H1_IP}:7447"
    else
        chk_warn "无法连接 ${H1_IP}:7447（检查网线直连与机器人电源）"
    fi

    # USB-CAN udev 与设备
    if [[ -f /etc/udev/rules.d/usbcan.rules ]]; then
        chk_ok "USB-CAN udev 规则已安装"
    else
        chk_fail "缺少 /etc/udev/rules.d/usbcan.rules"
    fi
    local dev
    for dev in /dev/ttyMasterCANL /dev/ttyMasterCANR; do
        if [[ -e "${dev}" ]]; then
            chk_ok "设备存在：${dev}"
        else
            chk_warn "未检测到 ${dev}（重新拔插对应 USB-CAN 后重试）"
        fi
    done

    # 主臂程序
    if [[ -x /usr/local/bin/arm_record_node ]]; then
        chk_ok "主臂程序入口：/usr/local/bin/arm_record_node"
    else
        chk_fail "缺少主臂程序 /usr/local/bin/arm_record_node"
    fi

    # Python / LeRobot / GPU
    if [[ "${SKIP_PYTHON:-0}" == "1" ]]; then
        chk_warn "Python 环境检测已跳过（SKIP_PYTHON=1）"
    else
        local py="${H1_LEROBOT_VENV}/bin/python"
        if [[ ! -x "${py}" ]]; then
            chk_fail "未找到虚拟环境 Python：${py}"
        else
            chk_ok "Python 虚拟环境：${H1_LEROBOT_VENV}（$("${py}" -V 2>&1)）"

            local pyver
            pyver="$("${py}" -c 'import importlib.metadata as m; print(m.version("lerobot"))' 2>/dev/null || true)"
            if [[ -n "${pyver}" ]]; then
                chk_ok "LeRobot 已安装：${pyver}"
            else
                chk_fail "无法导入 lerobot（检查 ${H1_LEROBOT_VENV}）"
            fi

            if "${py}" -c "import onero_h1_lerobot" >/dev/null 2>&1; then
                chk_ok "适配器 onero_h1_lerobot 可导入"
            else
                chk_fail "无法导入 onero_h1_lerobot"
            fi

            if [[ -x "${H1_LEROBOT_VENV}/bin/onero-h1-lerobot-rollout" ]]; then
                chk_ok "CLI 可用：onero-h1-lerobot-rollout"
            else
                chk_fail "缺少 CLI：onero-h1-lerobot-rollout"
            fi

            local tfver
            tfver="$("${py}" -c 'import transformers; print(transformers.__version__)' 2>/dev/null || true)"
            if [[ -n "${tfver}" ]]; then
                chk_ok "transformers 已安装：${tfver}（pi0.5 可用）"
            else
                chk_warn "未安装 transformers，pi0.5 策略不可用"
            fi

            local mjver
            mjver="$("${py}" -c 'import mujoco; print(mujoco.__version__)' 2>/dev/null || true)"
            if [[ -n "${mjver}" ]]; then
                chk_ok "MuJoCo 已安装：${mjver}"
            else
                chk_warn "未安装 MuJoCo（仿真不可用）"
            fi

            local torch_info
            torch_info="$("${py}" - <<'PY' 2>/dev/null
import torch
cuda = torch.cuda.is_available()
name = torch.cuda.get_device_name(0) if cuda else "CPU"
cc = ".".join(map(str, torch.cuda.get_device_capability(0))) if cuda else "-"
print(f"{torch.__version__}|{torch.version.cuda or '-'}|{cuda}|{name}|{cc}")
PY
)"
            if [[ -z "${torch_info}" ]]; then
                chk_fail "PyTorch 不可用"
            else
                local tver tcuda tavailable tname tcc
                IFS='|' read -r tver tcuda tavailable tname tcc <<< "${torch_info}"
                chk_ok "PyTorch：${tver}（CUDA 构建 ${tcuda}）"
                if [[ "${tavailable}" == "True" ]]; then
                    chk_ok "CUDA 已启用：${tname}（compute ${tcc}）"
                else
                    chk_warn "CUDA 不可用，将回退 CPU（遥操/采集可用，训练不建议）"
                fi
            fi
        fi
    fi

    # NVIDIA 驱动
    if command -v nvidia-smi >/dev/null 2>&1; then
        local gpu
        gpu="$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | head -1 || true)"
        if [[ -n "${gpu}" ]]; then
            chk_ok "GPU：${gpu}"
        else
            chk_warn "nvidia-smi 无输出（驱动异常）"
        fi
    else
        chk_warn "未检测到 nvidia-smi（无 NVIDIA 驱动时使用 CPU）"
    fi

    printf '\n'
    log "========== 自检结论 =========="
    printf '  通过 %d 项，告警 %d 项，失败 %d 项\n' "${ok_count}" "${warn_count}" "${fail_count}"
    if [[ "${fail_count}" -gt 0 ]]; then
        printf '  结论：存在失败项，请按上方 FAIL 提示处理后重新检查。\n'
    elif [[ "${warn_count}" -gt 0 ]]; then
        printf '  结论：可以开始使用；WARN 项请按需处理。\n'
    else
        printf '  结论：全部检查通过，可以开始使用。\n'
    fi
}

main() {
    if [[ "${EUID}" -eq 0 ]]; then
        die "请不要用 sudo 运行整个脚本；脚本会在需要时自动申请 sudo。"
    fi

    case "$(uname -m)" in
        x86_64|amd64) ;;
        *) die "当前主臂运行时仅提供 x86_64 版本，检测到 $(uname -m)；请使用对应架构的运行时包。" ;;
    esac

    require_cmd sudo
    require_cmd udevadm

    log "主臂环境部署开始"
    log "脚本目录：${SCRIPT_DIR}"

    # 提前缓存 sudo 凭据，避免交互中途再次要求密码
    sudo -v

    install_dependencies
    deploy_zenoh
    install_lerobot_python
    configure_usb_can
    install_runtime

    log "========== 部署完成 =========="
    printf '  左臂固定端口：%s  (KERNELS=="%s")\n' "${LEFT_DEV}" "${LEFT_KERNELS}"
    printf '  右臂固定端口：%s  (KERNELS=="%s")\n' "${RIGHT_DEV}" "${RIGHT_KERNELS}"
    printf '  验证命令：ls -l /dev/ttyMasterCAN*\n'
    printf '  主臂程序：arm_record_node（LeRobot 连接机器人时自动启动）\n'
    if [[ "${SKIP_PYTHON:-0}" != "1" ]]; then
        printf '  LeRobot 环境：%s\n' "${H1_LEROBOT_VENV}"
        printf '  激活：source %s/bin/activate\n' "${H1_LEROBOT_VENV}"
        printf '  只读验证：onero-h1-print-observation --no-cameras --count 3\n'
    fi

    verify_environment
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
