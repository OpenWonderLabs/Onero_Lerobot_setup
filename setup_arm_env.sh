#!/usr/bin/env bash
# setup_arm_env.sh — 主臂环境一键部署
#
# 流程：
#   [1/3] 安装前置依赖（已内联，无需 install_deps.sh）
#   [2/3] 部署 Zenoh（Router 级联，PC 网线直连机器人）
#   [3/3] 交互式配置左右臂 USB-CAN 固定端口：
#         插左臂 -> 自动检测新增 /dev/ttyACM* -> 写入 usbcan.rules 的 ttyMasterCANL
#         插右臂 -> 自动检测新增 /dev/ttyACM* -> 写入 usbcan.rules 的 ttyMasterCANR
#         自动安装规则并 reload，生成 /dev/ttyMasterCANL 与 /dev/ttyMasterCANR
#
# 用法（在本脚本所在目录执行）：
#   chmod +x setup_arm_env.sh
#   ./setup_arm_env.sh
#
# 可选环境变量：
#   SKIP_DEPS=1           跳过依赖安装
#   SKIP_ZENOH=1          跳过 Zenoh Router 部署
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

# 依赖安装参数（原 install_deps.sh）
WORK_DIR="${WORK_DIR:-./dev}"
RBDL_VERSION="v3.3.1"
JOBS="$(nproc)"

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

# ==================== 依赖安装（原 install_deps.sh 内联） ====================
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

install_apt_packages() {
    log "更新 apt 索引..."
    sudo apt-get update -y

    log "安装编译工具与通用依赖（已存在则跳过）..."
    local pkg
    for pkg in git cmake build-essential pkg-config \
               libeigen3-dev liburdfdom-dev libtinyxml2-dev \
               net-tools python3-colcon-common-extensions; do
        apt_install_if_missing "${pkg}"
    done

    log "安装并启用 openssh-server..."
    apt_install_if_missing openssh-server
    sudo systemctl enable ssh
    sudo systemctl restart ssh
    sudo systemctl status ssh --no-pager || true

    log "[1/4] nlohmann-json3-dev"
    apt_install_if_missing nlohmann-json3-dev

    log "[3/4] libmodbus-dev"
    apt_install_if_missing libmodbus-dev

    log "[4/4] ${PINOCCHIO_PKG}"
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
    log "[2/4] 从源码安装 RBDL ${RBDL_VERSION}..."

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
    install_apt_packages
    install_rbdl_from_source
    verify_dependencies
    log "前置依赖安装完成。"
}

# Zenoh Router 级联部署（方式 B）：PC 常驻 router 并上联机器人 7447。
# 等价于：sudo bash ./deploy-pc.sh --h1-ip 10.42.0.2 --user "$USER"
deploy_zenoh() {
    log "========== 第 2 步：部署 Zenoh（Router 级联，网线直连 PC） =========="
    if [[ "${SKIP_ZENOH:-0}" == "1" ]]; then
        warn "SKIP_ZENOH=1，跳过 Zenoh 部署。"
        return 0
    fi

    # 兼容两种存放位置：./scripts/deploy-pc.sh 或 ./deploy-pc.sh
    local deploy_dir=""
    if [[ -f "./scripts/deploy-pc.sh" ]]; then
        deploy_dir="./scripts"
    elif [[ -f "./deploy-pc.sh" ]]; then
        deploy_dir="."
    else
        die "未找到 deploy-pc.sh（可放在 ./scripts/ 或脚本同级目录）。"
    fi

    local asset
    for asset in deploy.py apt-package-guard.py robot-zenoh-connect zenoh-router.service; do
        [[ -f "${deploy_dir}/${asset}" ]] || die "缺少 Zenoh 部署资源：${deploy_dir}/${asset}"
    done

    local deploy="${deploy_dir}/deploy-pc.sh"
    log "执行：sudo bash ${deploy} --h1-ip ${H1_IP} --user ${TARGET_USER}"
    sudo bash "${deploy}" --h1-ip "${H1_IP}" --user "${TARGET_USER}"
    log "Zenoh Router 部署完成。"

    printf '\n\033[1;33m[注意]\033[0m Zenoh 已按照【网线直连 PC】的方式完成配置（PC <-> 机器人 end1，%s:7447）。\n' "${H1_IP}"
    printf '        请确保网线已正常接上；重新打开终端（或 source ~/.bashrc）后生效。\n\n'
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
    log "========== 第 3 步：配置左右臂 USB-CAN 固定端口 =========="

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
    log "========== 第 4 步：安装主臂运行时 =========="

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

main() {
    if [[ "${EUID}" -eq 0 ]]; then
        die "请不要用 sudo 运行整个脚本；脚本会在需要时自动申请 sudo。"
    fi

    require_cmd sudo
    require_cmd udevadm

    log "主臂环境部署开始"
    log "脚本目录：${SCRIPT_DIR}"

    # 提前缓存 sudo 凭据，避免交互中途再次要求密码
    sudo -v

    install_dependencies
    deploy_zenoh
    configure_usb_can
    install_runtime

    log "========== 部署完成 =========="
    printf '  左臂固定端口：%s  (KERNELS=="%s")\n' "${LEFT_DEV}" "${LEFT_KERNELS}"
    printf '  右臂固定端口：%s  (KERNELS=="%s")\n' "${RIGHT_DEV}" "${RIGHT_KERNELS}"
    printf '  验证命令：ls -l /dev/ttyMasterCAN*\n'
    printf '  主臂程序：arm_record_node（LeRobot 连接时自动启动，也可手动执行）\n'
    if [[ -f "${SCRIPT_DIR}/start_arm_record.sh" ]]; then
        printf '  本地启动脚本：./start_arm_record.sh\n'
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
