#!/bin/bash
# ==============================================================================
# NLBW Ultra: 全栈节点自动化部署系统 (Lite版)
# 功能: 系统初始化 + Swap/BBR + 防火墙 + 定时战报 + Python机器人
# 修复: AWS端口检测 / Crontab空表 / 路径错误 / 移除WARP
# 部署路径: /opt/nlbw
# ==============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# --- 全局配置 ---
WORK_DIR="/opt/nlbw"
BOT_DIR="$WORK_DIR/tgbot"
SCRIPT_DIR="$WORK_DIR/scripts"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_LOG_DIR="/var/log/xray"

# --- 颜色输出 ---
green(){ echo -e "\033[1;32m$1\033[0m"; }
yellow(){ echo -e "\033[1;33m$1\033[0m"; }
red(){ echo -e "\033[1;31m$1\033[0m"; }

# --- 权限检查 ---
if [[ $EUID -ne 0 ]]; then red "❌ 错误: 必须使用 root 运行"; exit 1; fi

clear
echo -e "\033[1;36m================================================\033[0m"
echo -e "\033[1;36m      🤖 NLBW 全栈节点部署系统 (Ultra Lite)     \033[0m"
echo -e "\033[1;36m================================================\033[0m"

# ==============================================================================
# 0. 系统初始化与安全基线
# ==============================================================================
green "🚀 [阶段 0] 系统初始化与安全加固"

# 0.1 更新与基础工具
green "📦 [1/4] 更新系统并安装必备工具..."
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget git htop vim jq tar gzip unzip socat cron lsb-release gnupg >/dev/null 2>&1

# 0.2 时区
green "🕒 [2/4] 同步时区至 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai

# 0.3 智能 Swap
green "💾 [3/4] 检查内存配置..."
PHY_MEM=$(free -m | grep Mem | awk '{print $2}')
SWAP_MEM=$(free -m | grep Swap | awk '{print $2}')
if [ "$PHY_MEM" -le 2048 ] && [ "$SWAP_MEM" -eq 0 ]; then
    yellow "⚠️ 物理内存不足 2GB，正在创建 Swap 防止崩溃..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    green "✅ 2GB Swap 已启用"
else
    green "✅ 内存状态良好"
fi

# 0.4 BBR 加速
green "🚀 [4/4] 检查 BBR 加速..."
if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1
    green "✅ BBR 已开启"
else
    green "✅ BBR 已处于开启状态"
fi

# 0.5 自动防火墙 (Auto Firewall)
green "🛡️ [5/5] 配置自动防火墙..."

# [修复] 增加默认值回退逻辑，防止 grep 为空导致脚本退出
SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | head -n 1 | awk '{print $2}' || echo "22")
SSH_PORT=${SSH_PORT:-22} 

if command -v ufw >/dev/null; then
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow ${SSH_PORT}/tcp
    # 允许 Socks5 端口范围
    ufw allow 20000:50000/tcp
    ufw --force enable
    green "✅ UFW 防火墙规则已更新"
elif command -v firewall-cmd >/dev/null; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    firewall-cmd --permanent --add-port=20000-50000/tcp
    firewall-cmd --reload
    green "✅ Firewalld 规则已更新"
else
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT
    iptables -I INPUT -p tcp --dport 20000:50000 -j ACCEPT
    green "✅ Iptables 规则已更新 (临时)"
fi

echo -e "\n\033[1;32m🎉 系统基线环境准备就绪！\033[0m\n"
sleep 2

# ==============================================================================
# 1. 业务配置采集
# ==============================================================================
green "📝 [阶段 1] 业务配置"

while true; do
    read -r -p "请输入域名 (例如 vpn.example.com): " DOMAIN
    if [[ -n "$DOMAIN" ]]; then break; fi
done

read -r -p "请输入邮箱 (默认: admin@$DOMAIN): " EMAIL
EMAIL=${EMAIL:-admin@$DOMAIN}

yellow "🤖 配置 Telegram 管理机器人"
while true; do
    read -r -p "Bot Token: " BOT_TOKEN
    if [[ -n "$BOT_TOKEN" ]]; then break; fi
done

while true; do
    read -r -p "管理员 ID (多个用英文逗号分隔): " ADMIN_IDS
    if [[ -n "$ADMIN_IDS" ]]; then break; fi
done

# 生成随机凭证
UUID="$(cat /proc/sys/kernel/random/uuid)"
WS_PATH="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 6)"
SOCKS_PORT=$(shuf -i 20000-50000 -n 1)
SOCKS_USER="u$(head /dev/urandom | tr -dc a-z0-9 | head -c 6)"
SOCKS_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 12)

# ==============================================================================
# 2. 基础设施部署
# ==============================================================================
green "📦 [阶段 2] 安装核心组件"

# 2.1 安装基础
apt-get install -y nginx certbot python3-certbot-nginx python3 python3-pip python3-venv vnstat ffmpeg >/dev/null 2>&1

# 2.2 安装 Xray
if ! command -v xray &> /dev/null; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null
fi

# 2.3 配置 Nginx
WEB_ROOT="/var/www/${DOMAIN}/html"
mkdir -p "$WEB_ROOT"
echo "<h1>NLBW Node Active</h1>" > "$WEB_ROOT/index.html"
chown -R www-data:www-data "/var/www/${DOMAIN}"

# 2.4 申请证书
systemctl stop nginx
certbot certonly --standalone -d "$DOMAIN" --email "$EMAIL" --agree-tos --non-interactive >/dev/null 2>&1 || { red "❌ 证书申请失败，请检查域名解析"; exit 1; }
systemctl start nginx

# 2.5 生成 Xray 配置 (已移除 WARP 逻辑)
green "⚙️ 生成 Xray 配置文件..."
mkdir -p "$XRAY_LOG_DIR"

# 构建纯净的 Outbounds 配置
OUTBOUNDS='[{"protocol": "freedom","tag": "direct"}]'
RULES='{"type": "field","outboundTag": "direct","domain": ["geosite:cn"]}'

cat > "$XRAY_CONF" <<EOF
{
  "log": { "loglevel": "warning", "access": "$XRAY_LOG_DIR/access.log", "error": "$XRAY_LOG_DIR/error.log" },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [ $RULES ]
  },
  "inbounds": [
    {
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": { "clients": [{ "id": "${UUID}", "email": "admin" }], "decryption": "none" },
      "streamSettings": { "network": "ws", "wsSettings": { "path": "${WS_PATH}" } }
    },
    {
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": { "auth": "password", "accounts": [{ "user": "${SOCKS_USER}", "pass": "${SOCKS_PASS}" }], "udp": true }
    }
  ],
  "outbounds": $OUTBOUNDS
}
EOF

# Nginx 配置文件
cat > "/etc/nginx/conf.d/${DOMAIN}.conf" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    root ${WEB_ROOT};
    location / { try_files \$uri \$uri/ =404; }
    location ${WS_PATH} {
        if (\$http_upgrade != "websocket") { return 404; }
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

chown -R nobody:nogroup "$XRAY_LOG_DIR"
systemctl restart xray nginx

# ==============================================================================
# 3. 部署 Python 机器人
# ==============================================================================
green "🐍 [阶段 3] 部署 Python 机器人"

mkdir -p "$BOT_DIR" "$SCRIPT_DIR"
CURRENT_DIR=$(cd "$(dirname "$0")";pwd)

# 源码处理 - [修复] 修正复制路径，从 src/ 目录复制
if [ -f "$CURRENT_DIR/src/main.py" ]; then
    cp "$CURRENT_DIR/src/main.py" "$BOT_DIR/main.py"
    # [修复] 确保 requirements.txt 也从 src/ 复制
    cp "$CURRENT_DIR/src/requirements.txt" "$BOT_DIR/requirements.txt"
else
    touch "$BOT_DIR/main.py" # 占位
    red "⚠️ 未找到本地源码，请后续手动上传 main.py"
fi

# 虚拟环境
if [ ! -d "$BOT_DIR/venv" ]; then python3 -m venv "$BOT_DIR/venv"; fi
source "$BOT_DIR/venv/bin/activate"
pip install --upgrade pip >/dev/null 2>&1
if [ -f "$BOT_DIR/requirements.txt" ]; then
    pip install -r "$BOT_DIR/requirements.txt" >/dev/null 2>&1
fi

# 生成 Config
cat > "$BOT_DIR/config.json" <<EOF
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

# Bot Systemd
cat > /etc/systemd/system/nlbw_bot.service <<EOF
[Unit]
Description=NLBW Python Controller
After=network.target xray.service

[Service]
Type=simple
User=root
WorkingDirectory=$BOT_DIR
ExecStart=$BOT_DIR/venv/bin/python main.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nlbw_bot >/dev/null 2>&1
systemctl restart nlbw_bot

# ==============================================================================
# 4. 每日战报与异常推送 (Cron)
# ==============================================================================
green "📉 [阶段 4] 配置每日战报"

# 创建战报脚本
cat > "$SCRIPT_DIR/daily_report.sh" <<'EOF'
#!/bin/bash
# 自动读取 Bot 配置
CONFIG_FILE="/opt/nlbw/tgbot/config.json"
BOT_TOKEN=$(jq -r '.bot_token' $CONFIG_FILE)
CHAT_ID=$(jq -r '.admin_ids[0]' $CONFIG_FILE) # 默认发给第一个管理员
DOMAIN=$(jq -r '.domain' $CONFIG_FILE)

# 采集数据
DATE=$(date "+%Y-%m-%d %H:%M:%S")
CPU=$(grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage}')
MEM=$(free -m | grep Mem | awk '{print $3"/"$2"MB"}')
TRAFFIC=$(vnstat --json m 1 | jq -r '.interfaces[0].traffic.month[0] | "⬇️" + (.rx | tostring) + "KB ⬆️" + (.tx | tostring) + "KB"')

# 发送消息
TEXT="📊 *NLBW Daily Report*
📅 Time: \`$DATE\`
💻 Domain: \`$DOMAIN\`
🧠 Mem: \`$MEM\`
⚡ CPU: \`$CPU%\`
🌐 Traffic (Month): \`$TRAFFIC\`"

curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" \
    -d parse_mode="Markdown" \
    -d text="$TEXT" >/dev/null
EOF

chmod +x "$SCRIPT_DIR/daily_report.sh"

# 添加 Crontab (每天早上 08:00 执行)

(crontab -l 2>/dev/null || true; echo "0 8 * * * /bin/bash $SCRIPT_DIR/daily_report.sh") | crontab -
green "✅ 定时任务已添加 (每天 08:00)"

# ==============================================================================
# 5. 结束汇总
# ==============================================================================
VLESS_LINK="vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${WS_PATH}#${DOMAIN}"

clear
echo -e "\033[1;36m================================================\033[0m"
echo -e "\033[1;32m🎉 NLBW Ultra System Deployment Complete!\033[0m"
echo -e "------------------------------------------------"
echo -e "📂 部署目录: \033[1;33m/opt/nlbw\033[0m"
echo -e "🤖 Bot 状态: $(systemctl is-active nlbw_bot)"
echo -e "🛡️ 防火墙  : 已开启 (Port 80, 443, $SSH_PORT, 20000-50000)"
echo -e "📉 战报    : 每日 08:00 推送"
echo -e "------------------------------------------------"
echo -e "🔗 VLESS 链接:"
echo -e "\033[1;35m$VLESS_LINK\033[0m"
echo -e "\033[1;36m================================================\033[0m"
