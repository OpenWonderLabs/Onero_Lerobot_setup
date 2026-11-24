#!/usr/bin/env bash
# Onero H1 环境激活脚本（由一键部署生成，不要直接执行，请用 source）
#
# 用法：source ~/h1_env.sh
# 数据集默认路径：@DATASETS@
# 如需修改，source 之后再执行：export HF_LEROBOT_HOME=/your/path

if [ -f /opt/ros/jazzy/setup.bash ]; then
    source /opt/ros/jazzy/setup.bash
elif [ -f /opt/ros/humble/setup.bash ]; then
    source /opt/ros/humble/setup.bash
fi

# 先加载 ~/.bashrc（它会重设 PS1）；H1_ENV_LOADED 防止用户把它写进 bashrc 后递归
if [ -z "${H1_ENV_LOADED:-}" ] && [ -f "$HOME/.bashrc" ]; then
    H1_ENV_LOADED=1 source "$HOME/.bashrc"
fi

source "@VENV@/bin/activate"

export HF_LEROBOT_HOME="${HF_LEROBOT_HOME:-@DATASETS@}"
