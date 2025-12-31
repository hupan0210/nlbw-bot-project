#!/bin/bash
# ==========================================
# NLBW 机器人自动化部署脚本 v2.0 (Git版)
# ==========================================

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PLAIN='\033[0m'

# 0. 权限与路径检查
[[ $EUID -ne 0 ]] && echo -e "${RED}❌ 错误: 必须使用 root 用户运行！${PLAIN}" && exit 1

# 获取当前脚本所在目录 (即 Git Clone 下来的目录)
CURRENT_DIR=$(cd "$(dirname "$0")";pwd)
WORK_DIR="/root/nlbw"
BOT_DIR="$WORK_DIR/tgbot"

clear
echo -e "${BLUE}================================================${PLAIN}"
echo -e "${BLUE}    🤖 NLBW 机器人部署系统 (Git Production)     ${PLAIN}"
echo -e "${BLUE}================================================${PLAIN}"

# 1. 检查源文件是否存在
if [ ! -f "$CURRENT_DIR/src/main.py" ] || [ ! -f "$CURRENT_DIR/requirements.txt" ]; then
    echo -e "${RED}❌ 错误: 在当前目录下找不到 src/main.py 或 requirements.txt${PLAIN}"
    echo -e "请确保你已经完整拉取了 Git 仓库，并进入了项目根目录运行此脚本。"
    exit 1
fi

# 2. 创建系统级目录
echo -e "${YELLOW}📂 正在构建目录结构: $BOT_DIR ...${PLAIN}"
mkdir -p "$BOT_DIR"

# 3. 安装系统依赖
echo -e "${YELLOW}📦 正在检查系统依赖 (Python, Pip, Vnstat, FFmpeg)...${PLAIN}"
if [ -f /etc/debian_version ]; then
    apt-get update -y >/dev/null 2>&1
    apt-get install -y python3 python3-pip python3-venv vnstat ffmpeg >/dev/null 2>&1
elif [ -f /etc/redhat-release ]; then
    yum install -y python3 python3-pip python3-venv vnstat ffmpeg >/dev/null 2>&1
fi
echo -e "${GREEN}✅ 系统依赖准备就绪${PLAIN}"

# 4. 配置 Python 虚拟环境
echo -e "${YELLOW}🐍 正在配置 Python 虚拟环境...${PLAIN}"
if [ ! -d "$BOT_DIR/venv" ]; then
    python3 -m venv "$BOT_DIR/venv"
fi
source "$BOT_DIR/venv/bin/activate"

# 5. 复制代码与安装依赖
echo -e "${YELLOW}🚚 正在部署代码并安装 Python 库...${PLAIN}"
cp "$CURRENT_DIR/src/main.py" "$BOT_DIR/main.py"
cp "$CURRENT_DIR/requirements.txt" "$BOT_DIR/requirements.txt"

# 使用国内源加速 (可选，若服务器在海外可去掉 -i 部分)
pip install -r "$BOT_DIR/requirements.txt" --upgrade
echo -e "${GREEN}✅ 代码部署与依赖安装完成${PLAIN}"

# 6. 交互式配置 (如果不存在配置)
CONFIG_PATH="$BOT_DIR/config.json"
if [ ! -f "$CONFIG_PATH" ]; then
    echo -e "${BLUE}⚙️  检测到首次运行，开始配置...${PLAIN}"
    read -p "请输入 Bot Token: " BOT_TOKEN
    read -p "请输入管理员 ID (多个ID用逗号分隔): " ADMIN_IDS
    read -p "请输入监控域名 (例如 mgny.112583.xyz): " DOMAIN

    cat > "$CONFIG_PATH" <<EOF
{
  "bot_token": "$BOT_TOKEN",
  "admin_ids": [${ADMIN_IDS}],
  "domain": "$DOMAIN",
  "api_id": 2040,
  "api_hash": "b18441a1ff607e10a989891a5462e627",
  "xray_config": "/usr/local/etc/xray/config.json",
  "log_files": ["/var/log/xray/error.log", "/var/log/xray/access.log"]
}
EOF
    echo -e "${GREEN}✅ 配置文件已生成${PLAIN}"
else
    echo -e "${GREEN}✅ 检测到已有配置文件，跳过配置步骤${PLAIN}"
fi

# 7. Systemd 服务配置
echo -e "${YELLOW}🛡️ 配置后台服务 (Systemd)...${PLAIN}"
cat > /etc/systemd/system/nlbw_bot.service <<EOF
[Unit]
Description=NLBW Telegram Bot Service
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_DIR/venv/bin/python main.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nlbw_bot >/dev/null 2>&1
systemctl restart nlbw_bot

# 8. 完成
echo -e "${BLUE}================================================${PLAIN}"
echo -e "${GREEN}🎉 部署成功！${PLAIN}"
echo -e "🤖 机器人状态: $(systemctl is-active nlbw_bot)"
echo -e "📂 部署位置: $BOT_DIR"
echo -e "📝 配置文件: $CONFIG_PATH"
echo -e "${BLUE}================================================${PLAIN}"
