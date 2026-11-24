#!/usr/bin/env bash
# 一键部署入口：临时拉取部署包 -> 执行 setup_arm_env.sh -> 清理临时目录。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/woan-denglanjin/lerobot-h1-setup/main/install.sh | bash
#
# 可用环境变量覆盖：
#   H1_REPO_URL   仓库地址（默认值为下方 REPO_URL）
#   H1_BRANCH     分支名（默认 main）

set -euo pipefail

REPO_URL="${1:-${H1_REPO_URL:-https://github.com/woan-denglanjin/lerobot-h1-setup.git}}"
BRANCH="${H1_BRANCH:-main}"

say() { printf '[robot-h1] %s\n' "$*" >&2; }
die() { say "错误：$*"; exit 1; }

if [[ "${EUID}" -eq 0 ]]; then
    die "请用普通用户运行，不要加 sudo；脚本会在需要时自行申请。"
fi

command -v curl >/dev/null 2>&1 || die "缺少 curl。"
command -v sudo >/dev/null 2>&1 || die "缺少 sudo。"

# 提前缓存 sudo 凭据
sudo -v

ensure_pkg() {
    local cmd="$1" pkg="$2"
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        say "安装依赖 ${pkg} ..."
        DEBIAN_FRONTEND=noninteractive sudo apt-get update -qq
        DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${pkg}"
    fi
}
ensure_pkg git git
ensure_pkg unzip unzip

TMP_DIR="$(mktemp -d /tmp/robot-h1.XXXXXX)"
cleanup() { rm -rf "${TMP_DIR}"; }
trap cleanup EXIT

say "拉取部署包 ..."
git clone --depth 1 --branch "${BRANCH}" "${REPO_URL}" "${TMP_DIR}/robot_ws"

cd "${TMP_DIR}/robot_ws"
chmod +x setup_arm_env.sh

say "开始部署，请按终端提示操作 ..."
./setup_arm_env.sh

say "部署完成：主臂运行时位于 ~/robot-h1，入口为 ~/.local/bin/arm_record_node。"
say "新终端执行 source ~/h1_env.sh 即可完成环境激活。"
say "之后运行 LeRobot 采集时会自动启动主臂程序。"
