import os
import json
import asyncio
import io
import logging
from datetime import datetime
from pyrogram import Client, filters
from pyrogram.types import InlineKeyboardMarkup, InlineKeyboardButton
import qrcode

# ================= 配置加载 =================
# 自动定位当前目录下的 config.json
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(BASE_DIR, "config.json")

def load_config():
    if not os.path.exists(CONFIG_FILE):
        print(f"❌ 错误: 找不到配置文件 {CONFIG_FILE}")
        exit(1)
    with open(CONFIG_FILE, 'r', encoding='utf-8') as f:
        return json.load(f)

CFG = load_config()
ADMIN_IDS = [int(x) for x in CFG['admin_ids']] # 确保是整数列表
LOG_FILES = CFG.get('log_files', ["/var/log/xray/error.log", "/var/log/xray/access.log"])

# 日志配置
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(name)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# 初始化 Bot
app = Client(
    "nlbw_session",
    api_id=CFG['api_id'],
    api_hash=CFG['api_hash'],
    bot_token=CFG['bot_token'],
    workdir=BASE_DIR
)

# ================= 核心工具函数 =================

def make_progress_bar(percent, length=8):
    """生成进度条"""
    percent = max(0, min(100, percent))
    filled = int(length * percent / 100)
    return "█" * filled + "░" * (length - filled)

def human_size(bytes_val):
    """字节转换"""
    for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
        if bytes_val < 1024: return f"{bytes_val:.1f}{unit}"
        bytes_val /= 1024
    return f"{bytes_val:.1f}PB"

async def get_shell_output(cmd):
    """异步执行 Shell 命令"""
    try:
        proc = await asyncio.create_subprocess_shell(
            cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
        )
        stdout, _ = await proc.communicate()
        return stdout.decode().strip()
    except Exception as e:
        logger.error(f"Shell Error: {e}")
        return ""

async def get_system_stats():
    """获取系统状态"""
    try:
        cpu_cmd = "grep 'cpu ' /proc/stat | awk '{usage=($2+$4)*100/($2+$4+$5)} END {print usage}'"
        cpu = float(await get_shell_output(cpu_cmd))
    except: cpu = 0.0
    
    mem_out = await get_shell_output("free -m | grep Mem | awk '{print $2,$3}'")
    try:
        total, used = map(int, mem_out.split())
        mem_percent = (used / total) * 100
        mem_str = f"{int(used)}/{int(total)}MB"
    except: mem_percent, mem_str = 0, "N/A"

    load = await get_shell_output("cat /proc/loadavg | awk '{print $1}'")
    uptime = await get_shell_output("uptime -p")
    uptime = uptime.replace("up ", "").replace("weeks", "周").replace("days", "天").replace("hours", "小时").replace("minutes", "分")
    
    return {
        "cpu_bar": make_progress_bar(cpu), "cpu_val": round(cpu, 1),
        "mem_bar": make_progress_bar(mem_percent), "mem_str": mem_str,
        "load": load, "uptime": uptime
    }

async def get_vnstat_traffic():
    """获取流量统计"""
    try:
        output = await get_shell_output("vnstat --json m 1")
        if not output: return "⏳ 数据同步中..."
        data = json.loads(output)
        month_data = data['interfaces'][0]['traffic']['month'][0]
        rx, tx = month_data['rx'], month_data['tx']
        return f"{human_size(rx + tx)} (⬇️{human_size(rx)} ⬆️{human_size(tx)})"
    except:
        return "⏳ 等待流量接口..."

# ================= 业务逻辑 (Xray/Logs) =================

def manage_xray_config(action, data=None):
    """统一管理 Xray 配置文件读写"""
    path = CFG['xray_config']
    if not os.path.exists(path): return None
    
    try:
        with open(path, 'r', encoding='utf-8') as f:
            config = json.load(f)
        
        socks_inbound = next((i for i in config.get('inbounds', []) if i.get('protocol') == 'socks'), None)
        vless_inbound = next((i for i in config.get('inbounds', []) if i.get('protocol') == 'vless'), None)

        if action == "get_socks":
            return socks_inbound['settings']['accounts'] if socks_inbound else []
        elif action == "add_socks":
            if not socks_inbound: return False
            if any(u['user'] == data['user'] for u in socks_inbound['settings']['accounts']): return False
            socks_inbound['settings']['accounts'].append(data)
        elif action == "del_socks":
            if not socks_inbound: return False
            socks_inbound['settings']['accounts'] = [u for u in socks_inbound['settings']['accounts'] if u['user'] != data['user']]
        elif action == "get_vless":
            return vless_inbound['settings']['clients'] if vless_inbound else []

        if action in ["add_socks", "del_socks"]:
            with open(path, 'w', encoding='utf-8') as f:
                json.dump(config, f, indent=2)
            return True
    except Exception as e:
        logger.error(f"Config Error: {e}")
        return False

def get_vless_link(uid, name):
    domain = CFG['domain']
    return f"vless://{uid}@{domain}:443?encryption=none&security=none&type=ws&host={domain}&path=/dvJcCk#{name}"

# ================= 交互菜单 =================

def main_menu():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("📊 系统状态", callback_data="status")],
        [InlineKeyboardButton("👥 VLESS 节点", callback_data="users_vless"), InlineKeyboardButton("👻 Socks5 管理", callback_data="users_socks")],
        [InlineKeyboardButton("📜 日志诊断", callback_data="logs_menu"), InlineKeyboardButton("🛠️ 维护工具", callback_data="sys")]
    ])

def back_btn(data="back"):
    return [InlineKeyboardButton("🔙 返回主菜单", callback_data=data)]

# ================= 事件处理 =================

@app.on_message(filters.command("start") & filters.user(ADMIN_IDS))
async def start_handler(c, m):
    await m.reply_text(f"👋 **你好，管理员！**\n这是你的服务器控制中心。", reply_markup=main_menu())

@app.on_callback_query()
async def callback_handler(c, q):
    if q.from_user.id not in ADMIN_IDS: return await q.answer("🚫 权限不足", show_alert=True)
    d = q.data

    try:
        if d == "back":
            await q.edit_message_text("🖥️ **控制面板**", reply_markup=main_menu())

        # --- 状态模块 ---
        elif d == "status":
            sys = await get_system_stats()
            traf = await get_vnstat_traffic()
            text = (
                f"📊 **服务器状态监控**\n"
                f"➖➖➖➖➖➖➖➖\n"
                f"💻 CPU : {sys['cpu_bar']} `{sys['cpu_val']}%`\n"
                f"🧠 内存: {sys['mem_bar']} `{sys['mem_str']}`\n"
                f"⚖️ 负载: `{sys['load']}`\n"
                f"⏱️ 运行: `{sys['uptime']}`\n"
                f"🌐 流量: `{traf}`\n"
                f"➖➖➖➖➖➖➖➖\n"
                f"🕒 {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
            )
            await q.edit_message_text(text, reply_markup=main_menu())

        # --- Socks5 模块 ---
        elif d == "users_socks":
            accs = manage_xray_config("get_socks")
            btns = []
            if accs:
                for a in accs:
                    btns.append([InlineKeyboardButton(f"👤 {a['user']} | 🔑 {a['pass']}", callback_data="nop"), 
                                 InlineKeyboardButton("🗑️ 删除", callback_data=f"del_s|{a['user']}")])
            btns.append([InlineKeyboardButton("➕ 添加账号 (/addsocks 用户 密码)", callback_data="nop")])
            btns.append(back_btn())
            await q.edit_message_text("👻 **Socks5 账号列表 (Port 16111)**", reply_markup=InlineKeyboardMarkup(btns))

        elif d.startswith("del_s|"):
            user = d.split("|")[1]
            if manage_xray_config("del_socks", {"user": user}):
                await asyncio.create_subprocess_shell("systemctl restart xray")
                await q.answer(f"✅ 用户 {user} 已删除", show_alert=True)
                # 重新加载列表
                await callback_handler(c, type('obj', (object,), {'data': 'users_socks', 'message': q.message, 'from_user': q.from_user, 'answer': q.answer, 'edit_message_text': q.edit_message_text})) 
            else:
                await q.answer("❌ 删除失败", show_alert=True)

        # --- VLESS 模块 ---
        elif d == "users_vless":
            clients = manage_xray_config("get_vless")
            btns = [[InlineKeyboardButton(f"👤 {u.get('email','未知')}", callback_data="nop"), 
                     InlineKeyboardButton("📱 二维码", callback_data=f"qr|{u['id']}|{u.get('email','未知')}")] for u in clients]
            btns.append(back_btn())
            await q.edit_message_text("👥 **VLESS 用户列表**", reply_markup=InlineKeyboardMarkup(btns))

        elif d.startswith("qr|"):
            _, uid, name = d.split("|")
            link = get_vless_link(uid, name)
            qr = qrcode.QRCode(box_size=10, border=2)
            qr.add_data(link); qr.make(fit=True)
            bio = io.BytesIO()
            qr.make_image(fill_color="black", back_color="white").save(bio, 'PNG')
            bio.seek(0)
            await q.message.reply_photo(bio, caption=f"👤 **用户**: `{name}`\n🔗 **链接**: `{link}`")
            await q.answer()

        # --- 日志模块 (已补全) ---
        elif d == "logs_menu":
            btns = [
                [InlineKeyboardButton("❌ 错误日志 (Error)", callback_data="v_err")],
                [InlineKeyboardButton("🌐 访问日志 (Access)", callback_data="v_acc")],
                [InlineKeyboardButton("🧹 清空所有日志", callback_data="c_log")],
                back_btn()
            ]
            await q.edit_message_text("📜 **日志与诊断中心**", reply_markup=InlineKeyboardMarkup(btns))
        
        elif d == "v_err":
            log = await get_shell_output(f"tail -n 20 {LOG_FILES[0]}") # 错误日志
            await q.message.reply_text(f"📜 **Xray 错误日志 (最后20行)**\n```\n{log[-4000:]}\n```")
            await q.answer()

        elif d == "v_acc":
            log = await get_shell_output(f"tail -n 20 {LOG_FILES[1]}") # 访问日志
            await q.message.reply_text(f"🌐 **Xray 访问日志 (最后20行)**\n```\n{log[-4000:]}\n```")
            await q.answer()
        
        elif d == "c_log":
            for f in LOG_FILES:
                await get_shell_output(f"truncate -s 0 {f}")
            await q.answer("✅ 所有日志已清空", show_alert=True)

        # --- 系统维护 ---
        elif d == "sys":
            btns = [
                [InlineKeyboardButton("♻️ 重启 Xray 服务", callback_data="rx")],
                [InlineKeyboardButton("♻️ 重启 机器人", callback_data="rb")],
                back_btn()
            ]
            await q.edit_message_text("🛠️ **系统维护**", reply_markup=InlineKeyboardMarkup(btns))
        
        elif d == "rx":
            await asyncio.create_subprocess_shell("systemctl restart xray")
            await q.answer("✅ Xray 重启指令已发送", show_alert=True)
        
        elif d == "rb":
            await q.answer("♻️ 机器人正在重启...", show_alert=True)
            os._exit(0)

    except Exception as e:
        logger.error(f"Callback Error: {e}")
        await q.answer(f"❌ 发生错误: {str(e)}", show_alert=True)

@app.on_message(filters.command("addsocks") & filters.user(ADMIN_IDS))
async def add_socks_handler(c, m):
    if len(m.command) < 3:
        return await m.reply_text("💡 **格式错误**\n请使用: `/addsocks 用户名 密码`")
    user, pwd = m.command[1], m.command[2]
    if manage_xray_config("add_socks", {"user": user, "pass": pwd}):
        await asyncio.create_subprocess_shell("systemctl restart xray")
        await m.reply_text(f"✅ **Socks5 账号已添加**\n用户: `{user}`\n密码: `{pwd}`")
    else:
        await m.reply_text("❌ **添加失败**\n可能是用户名重复或配置文件损坏。")

if __name__ == "__main__":
    print("🤖 NLBW Bot Started...")
    app.run()
