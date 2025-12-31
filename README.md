# 🤖 NLBW Telegram Bot 自动化部署项目

这是一个基于 Python Pyrogram 的服务器管理机器人，支持一键自动化部署。

## ✨ 功能特点
- **系统监控**: CPU、内存、负载、Vnstat 流量实时监控
- **Xray 管理**: VLESS / Socks5 账号增删查、二维码生成
- **日志诊断**: 实时查看 Xray 报错与访问日志
- **自动维护**: Systemd 守护进程，开机自启

## 🚀 快速部署 (一键安装)

**系统要求**: Debian 10+ / Ubuntu 20.04+ / CentOS 7+

在 VPS 上以 Root 身份执行以下命令：

```bash
# 1. 拉取代码
git clone [https://github.com/hupan0210/nlbw-bot-project.git](https://github.com/hupan0210/nlbw-bot-project.git)
cd nlbw-bot-project

# 2. 授权并安装
chmod +x install.sh
./install.sh

📂 目录结构
安装完成后，程序将位于 /root/nlbw/：

tgbot/main.py: 核心代码

tgbot/config.json: 配置文件 (包含 Token)

tgbot/venv/: 虚拟环境

🛠️ 常用管理命令
重启机器人: systemctl restart nlbw_bot

查看运行日志: journalctl -u nlbw_bot -f

停止机器人: systemctl stop nlbw_bot
