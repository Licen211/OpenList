#!/usr/bin/env bash
# OpenList Telegram Bot (admin-only) 管理菜单脚本
# - 安装到 /root/openlistbot
# - systemd 服务: openlist-tg-bot.service
# - 支持 qBittorrent / aria2 的 OpenList 离线下载任务创建与进度查询
# - 每周清理一次机器人日志（不保留历史）

set -Eeuo pipefail

APP_DIR="/root/openlistbot"
SERVICE_NAME="openlist-tg-bot"
CRON_FILE="/etc/cron.d/openlistbot-clean"
PY_BIN="python3"

# ====== 工具函数 ======
red(){ echo -e "\033[31m$*\033[0m"; }
green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }

need_root(){
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    red "请用 root 运行：sudo -i 或 sudo bash $0"
    exit 1
  fi
}

pause(){ read -r -p "回车继续..." _; }

svc_stop_disable(){
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed 2>/dev/null || true
}

install_apt_base(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends \
    ca-certificates curl git jq \
    "${PY_BIN}" "${PY_BIN}-venv" "${PY_BIN}-pip"
}

ensure_build_tools_if_needed(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y --no-install-recommends build-essential python3-dev pkg-config
}

cleanup_build_tools(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y build-essential gcc g++ make python3-dev pkg-config 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  apt-get clean -y 2>/dev/null || true
}

write_bot_files(){
  mkdir -p "$APP_DIR"
  chmod 755 "$APP_DIR"

  cat > "$APP_DIR/requirements.txt" <<'REQ'
python-telegram-bot==21.6
requests>=2.31
REQ

  cat > "$APP_DIR/.env.example" <<'ENV'
# Telegram
TG_BOT_TOKEN=123:abc
# 只允许这些 TG 用户使用（逗号分隔，纯数字）
TG_ADMIN_IDS=123456789,987654321

# OpenList
OPENLIST_BASE_URL=http://127.0.0.1:525
# OpenList 管理/用户 Token（你说“官方给的 token 能用”就填这个）
OPENLIST_TOKEN=xxxxxxxxxxxxxxxx

# 目录选择初始路径（可不填，默认 / ）
OPENLIST_START_PATH=/
ENV

  cat > "$APP_DIR/bot.py" <<'PY'
import os, re, json
from typing import List
import requests
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes

def env(name: str, default: str = "") -> str:
    v = os.getenv(name)
    return v if v is not None and v != "" else default

TG_BOT_TOKEN = env("TG_BOT_TOKEN")
TG_ADMIN_IDS = {int(x.strip()) for x in env("TG_ADMIN_IDS","").split(",") if x.strip().isdigit()}

OPENLIST_BASE_URL = env("OPENLIST_BASE_URL", "http://127.0.0.1:525").rstrip("/")
OPENLIST_TOKEN = env("OPENLIST_TOKEN")
OPENLIST_START_PATH = env("OPENLIST_START_PATH", "/") or "/"

STATE_DIR = env("STATE_DIR", "/root/openlistbot/state")
os.makedirs(STATE_DIR, exist_ok=True)

PER_PAGE_DEFAULT = 30

def ol_headers(token: str) -> dict:
    return {"Authorization": token, "Content-Type": "application/json", "User-Agent": "openlist-tg-bot/1.0"}

def ol_post(path: str, token: str, payload: dict, timeout: int = 25) -> dict:
    url = f"{OPENLIST_BASE_URL}{path}"
    r = requests.post(url, headers=ol_headers(token), data=json.dumps(payload), timeout=timeout)
    r.raise_for_status()
    return r.json()

def ol_get(path: str, token: str, timeout: int = 25) -> dict:
    url = f"{OPENLIST_BASE_URL}{path}"
    r = requests.get(url, headers=ol_headers(token), timeout=timeout)
    r.raise_for_status()
    return r.json()

def fs_list(path: str, token: str, page: int = 1, per_page: int = PER_PAGE_DEFAULT, refresh: bool = False) -> dict:
    return ol_post("/api/fs/list", token, {"path": path, "password": "", "page": page, "per_page": per_page, "refresh": refresh})

def fs_mkdir(full_path: str, token: str) -> dict:
    return ol_post("/api/fs/mkdir", token, {"path": full_path})

def add_offline(magnet_or_url: str, save_path: str, tool: str, token: str) -> dict:
    return ol_post("/api/fs/add_offline_download", token, {"path": save_path, "url": magnet_or_url, "tool": tool})

def offline_tools(token: str) -> List[str]:
    j = ol_get("/api/public/offline_download/tools", token)
    tools: List[str] = []
    if isinstance(j, dict) and j.get("code") == 200:
        data = j.get("data") or []
        for x in data:
            if isinstance(x, str): tools.append(x)
            elif isinstance(x, dict):
                n = x.get("name") or x.get("tool") or x.get("id")
                if n: tools.append(str(n))
    return tools

def task_download_undone(token: str) -> dict:
    # 注意：网页端“离线下载”是下载任务，不是上传任务
    candidates = ["/api/admin/task/offline/undone", "/api/admin/task/download/undone", "/api/admin/task/offline/list"]
    last_err = None
    for path in candidates:
        try:
            j = ol_get(path, token, timeout=20)
            if isinstance(j, dict) and j.get("code") == 200:
                return j
        except Exception as e:
            last_err = e
            continue
    raise RuntimeError(f"无法获取下载任务列表：已尝试 {candidates}，最后错误：{last_err}")

def is_admin(update: Update) -> bool:
    uid = update.effective_user.id if update.effective_user else 0
    return uid in TG_ADMIN_IDS

def deny() -> str:
    return "⛔️ 仅管理员可用（TG_ADMIN_IDS）"

def state_path(user_id: int) -> str:
    return os.path.join(STATE_DIR, f"user_{user_id}.json")

def load_state(user_id: int) -> dict:
    p = state_path(user_id)
    if os.path.exists(p):
        try:
            with open(p, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {}
    return {}

def save_state(user_id: int, data: dict) -> None:
    with open(state_path(user_id), "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)

def norm_path(p: str) -> str:
    if not p: return "/"
    if not p.startswith("/"): p = "/" + p
    p = re.sub(r"/+", "/", p)
    if len(p) > 1 and p.endswith("/"): p = p[:-1]
    return p

def build_dir_keyboard(path: str, items: List[dict], page: int, per_page: int, total: int) -> InlineKeyboardMarkup:
    btns: List[List[InlineKeyboardButton]] = []
    if path != "/":
        parent = "/".join([p for p in path.rstrip("/").split("/")[:-1] if p])
        parent = "/" + parent
        btns.append([InlineKeyboardButton("⬅️ 上级", callback_data=f"cd|{parent}|1")])

    for it in items:
        if it.get("is_dir"):
            name = it.get("name","")
            nxt = norm_path(path.rstrip("/") + "/" + name)
            btns.append([InlineKeyboardButton(f"📁 {name}", callback_data=f"cd|{nxt}|1")])

    pages = max(1, (total + per_page - 1) // per_page)
    nav: List[InlineKeyboardButton] = []
    if page > 1: nav.append(InlineKeyboardButton("⬅️ 上一页", callback_data=f"cd|{path}|{page-1}"))
    nav.append(InlineKeyboardButton(f"{page}/{pages}", callback_data="noop"))
    if page < pages: nav.append(InlineKeyboardButton("下一页 ➡️", callback_data=f"cd|{path}|{page+1}"))
    if nav: btns.append(nav)

    btns.append([InlineKeyboardButton("✅ 选这个目录", callback_data=f"pick|{path}")])
    return InlineKeyboardMarkup(btns)

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        await update.message.reply_text(deny()); return
    await update.message.reply_text(
        "✅ OpenList Bot 已启动\n"
        "命令：\n"
        "/ls - 浏览目录并选择保存目录\n"
        "/mkdir /完整路径/新文件夹 - 创建文件夹\n"
        "/tool - 查看/设置离线下载工具（qBittorrent/aria2...）\n"
        "/add <磁力/直链> - 用已选择的目录创建离线下载\n"
        "/progress - 查询当前下载进度（网页端/机器人创建的都尽量显示）\n"
    )

async def cmd_ls(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        await update.message.reply_text(deny()); return
    uid = update.effective_user.id
    st = load_state(uid)
    path = norm_path(st.get("cwd") or OPENLIST_START_PATH or "/")
    try:
        j = fs_list(path, OPENLIST_TOKEN, page=1, per_page=PER_PAGE_DEFAULT, refresh=False)
        data = j.get("data") or {}
        items = (data.get("content") or []) or []
        total = int(data.get("total") or len(items))
        kb = build_dir_keyboard(path, items, 1, PER_PAGE_DEFAULT, total)
        await update.message.reply_text(f"📂 当前：{path}\n(点文件夹进入，或直接选目录)", reply_markup=kb)
    except Exception as e:
        await update.message.reply_text(f"❌ 列目录失败：{e}")

async def on_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()  # 关键：否则 iOS/Telegram 常出现“点了没反应”
    if not is_admin(update):
        await query.edit_message_text(deny()); return
    data = query.data or ""
    if data in ("noop",""): return
    uid = update.effective_user.id
    st = load_state(uid)
    try:
        if data.startswith("cd|"):
            _, path, page_s = data.split("|", 2)
            path = norm_path(path); page = int(page_s)
            j = fs_list(path, OPENLIST_TOKEN, page=page, per_page=PER_PAGE_DEFAULT, refresh=False)
            d = j.get("data") or {}
            items = (d.get("content") or []) or []
            total = int(d.get("total") or len(items))
            kb = build_dir_keyboard(path, items, page, PER_PAGE_DEFAULT, total)
            st["cwd"] = path
            save_state(uid, st)
            await query.edit_message_text(f"📂 当前：{path}\n(点文件夹进入，或直接选目录)", reply_markup=kb)
            return
        if data.startswith("pick|"):
            _, path = data.split("|", 1)
            path = norm_path(path)
            st["save_path"] = path
            st["cwd"] = path
            save_state(uid, st)
            await query.edit_message_text(f"✅ 已选择保存目录：{path}\n接下来可用 /add 粘贴磁力或链接")
            return
    except Exception as e:
        await query.edit_message_text(f"❌ 操作失败：{e}")

async def cmd_mkdir(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        await update.message.reply_text(deny()); return
    if not context.args:
        await update.message.reply_text("用法：/mkdir /完整路径/新文件夹名"); return
    p = norm_path(" ".join(context.args).strip())
    try:
        j = fs_mkdir(p, OPENLIST_TOKEN)
        if j.get("code") == 200:
            await update.message.reply_text(f"✅ 已创建：{p}")
        else:
            await update.message.reply_text(f"❌ 创建失败：{j}")
    except Exception as e:
        await update.message.reply_text(f"❌ 创建失败：{e}")

async def cmd_tool(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        await update.message.reply_text(deny()); return
    uid = update.effective_user.id
    st = load_state(uid)
    if context.args:
        st["tool"] = " ".join(context.args).strip()
        save_state(uid, st)
        await update.message.reply_text(f"✅ 已设置工具：{st['tool']}")
        return
    tools = offline_tools(OPENLIST_TOKEN)
    if not tools:
        await update.message.reply_text("❌ 未获取到工具列表（检查 OPENLIST_TOKEN / OpenList 离线下载是否启用）"); return
    prefer = ["qBittorrent","aria2"]
    tools_sorted = prefer + [t for t in tools if t not in prefer]
    cur = st.get("tool") or (tools_sorted[0] if tools_sorted else "qBittorrent")
    st["tool"] = cur; save_state(uid, st)
    await update.message.reply_text(f"当前工具：{cur}\n可选：{', '.join(tools_sorted[:20])}\n\n用法：/tool <工具名>")

async def cmd_add(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        await update.message.reply_text(deny()); return
    uid = update.effective_user.id
    st = load_state(uid)
    if not context.args:
        await update.message.reply_text("用法：/add <磁力链接/直链URL>"); return
    url = " ".join(context.args).strip()
    save_path = st.get("save_path") or OPENLIST_START_PATH or "/"
    tool = st.get("tool") or "qBittorrent"
    try:
        j = add_offline(url, save_path, tool, OPENLIST_TOKEN)
        if j.get("code") == 200:
            await update.message.reply_text(f"✅ 已创建离线下载\n目录：{save_path}\n工具：{tool}\n用 /progress 查看进度")
        else:
            await update.message.reply_text(f"❌ 创建失败：{j}")
    except Exception as e:
        await update.message.reply_text(f"❌ 创建失败：{e}")

async def cmd_progress(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        await update.message.reply_text(deny()); return
    try:
        j = task_download_undone(OPENLIST_TOKEN)
        data = j.get("data") or {}
        content = (data.get("content") or []) or []
        if not content:
            await update.message.reply_text("暂无未完成任务。"); return
        lines = []
        for t in content[:10]:
            name = t.get("name") or t.get("title") or t.get("url") or "-"
            status = t.get("status") or t.get("state") or "-"
            tool = t.get("tool") or t.get("driver") or t.get("type") or "-"
            prog = t.get("progress")
            prog_s = f"{prog:.1f}%" if isinstance(prog,(int,float)) else (str(prog) if prog not in (None,"") else "-")
            save_path = t.get("path") or t.get("save_path") or "-"
            lines.append(f"• {name}\n  目录：{save_path}\n  状态：[{tool}] {status}  进度：{prog_s}")
        await update.message.reply_text("📥 当前未完成任务：\n\n" + "\n\n".join(lines))
    except Exception as e:
        await update.message.reply_text(f"❌ 查询失败：{e}\n把这段报错整段发我，我再把接口兜底补全。")

def main():
    if not TG_BOT_TOKEN: raise SystemExit("TG_BOT_TOKEN 为空，请在 /root/openlistbot/.env 填好后重启服务")
    if not OPENLIST_TOKEN: raise SystemExit("OPENLIST_TOKEN 为空，请在 /root/openlistbot/.env 填好后重启服务")
    if not TG_ADMIN_IDS: raise SystemExit("TG_ADMIN_IDS 为空，请在 /root/openlistbot/.env 填好后重启服务")

    app = Application.builder().token(TG_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("ls", cmd_ls))
    app.add_handler(CallbackQueryHandler(on_cb))
    app.add_handler(CommandHandler("mkdir", cmd_mkdir))
    app.add_handler(CommandHandler("tool", cmd_tool))
    app.add_handler(CommandHandler("add", cmd_add))
    app.add_handler(CommandHandler("progress", cmd_progress))
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == "__main__":
    main()
PY
}

write_env_if_missing(){
  if [ ! -f "$APP_DIR/.env" ]; then
    cp -a "$APP_DIR/.env.example" "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"
  fi
}

print_config_hint(){
  cat <<EOF

需要填写配置文件：
  $APP_DIR/.env

至少要填：
  TG_BOT_TOKEN=xxxx
  TG_ADMIN_IDS=123,456
  OPENLIST_BASE_URL=http://do.licen.live:525
  OPENLIST_TOKEN=你的token

改完后：
  systemctl restart ${SERVICE_NAME}

EOF
}

create_systemd_service(){
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=OpenList Telegram Bot (admin-only)
After=network.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/bot.py
Restart=always
RestartSec=3
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
}

setup_log_clean_weekly(){
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
# 每周日 03:30 清理 openlist-tg-bot 的 journald 日志（不保留历史）
30 3 * * 0 root journalctl -u ${SERVICE_NAME}.service --rotate >/dev/null 2>&1; journalctl -u ${SERVICE_NAME}.service --vacuum-time=1s >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"
}

install_bot(){
  need_root
  green "== 安装 OpenList TG Bot（admin-only） =="
  install_apt_base
  write_bot_files
  write_env_if_missing

  if [ ! -d "$APP_DIR/venv" ]; then
    "$PY_BIN" -m venv "$APP_DIR/venv"
  fi
  "$APP_DIR/venv/bin/pip" install -U pip wheel setuptools >/dev/null

  set +e
  "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    yellow "pip 依赖安装失败，装编译工具重试（之后自动清理）..."
    ensure_build_tools_if_needed
    "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
    cleanup_build_tools
  fi

  create_systemd_service
  setup_log_clean_weekly
  systemctl restart "${SERVICE_NAME}.service" || true

  green "✅ 安装完成"
  print_config_hint
  systemctl --no-pager -l status "${SERVICE_NAME}.service" | sed -n '1,18p' || true
}

update_bot(){
  need_root
  green "== 更新（重写 bot.py 与 requirements，不动你的 .env） =="
  [ -d "$APP_DIR" ] || { red "未找到 $APP_DIR，请先安装"; return; }
  write_bot_files
  write_env_if_missing

  if [ ! -d "$APP_DIR/venv" ]; then
    "$PY_BIN" -m venv "$APP_DIR/venv"
  fi
  "$APP_DIR/venv/bin/pip" install -U pip wheel setuptools >/dev/null

  set +e
  "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    yellow "pip 依赖安装失败，装编译工具重试..."
    ensure_build_tools_if_needed
    "$APP_DIR/venv/bin/pip" install -r "$APP_DIR/requirements.txt"
    cleanup_build_tools
  fi

  create_systemd_service
  setup_log_clean_weekly
  systemctl restart "${SERVICE_NAME}.service" || true
  green "✅ 已更新并重启"
  systemctl --no-pager -l status "${SERVICE_NAME}.service" | sed -n '1,18p' || true
}

uninstall_bot(){
  need_root
  yellow "== 卸载机器人（只卸 openlist-tg-bot，不动 OpenList/qB/aria2） =="
  svc_stop_disable
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service" "/lib/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl daemon-reload || true
  systemctl reset-failed || true
  rm -rf "$APP_DIR"
  rm -f "$CRON_FILE" 2>/dev/null || true
  green "✅ 已卸载：${SERVICE_NAME}"
}

service_status(){ systemctl --no-pager -l status "${SERVICE_NAME}.service" | sed -n '1,30p' || true; }
service_start(){ systemctl start "${SERVICE_NAME}.service"; }
service_stop(){ systemctl stop "${SERVICE_NAME}.service"; }
service_restart(){ systemctl restart "${SERVICE_NAME}.service"; }

config_edit(){
  need_root
  [ -f "$APP_DIR/.env" ] || { red "找不到 $APP_DIR/.env，请先安装"; return; }
  ${EDITOR:-nano} "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env" || true
  green "✅ 已保存配置。执行：systemctl restart ${SERVICE_NAME}"
}

backup_config(){
  need_root
  [ -f "$APP_DIR/.env" ] || { red "未找到 .env"; return; }
  bk="$APP_DIR/.env.bak.$(date +%F_%H%M%S)"
  cp -a "$APP_DIR/.env" "$bk"
  green "✅ 已备份：$bk"
}

restore_config(){
  need_root
  ls -1 "$APP_DIR"/.env.bak.* 2>/dev/null || { red "没有备份文件"; return; }
  read -r -p "输入要恢复的备份文件名（完整路径）: " bk
  [ -f "$bk" ] || { red "文件不存在"; return; }
  cp -a "$bk" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env" || true
  green "✅ 已恢复：$bk"
}

system_info(){
  echo
  echo "System load: $(awk '{print $1}' /proc/loadavg 2>/dev/null || echo '-')"
  echo "Usage of / : $(df -h / | awk 'NR==2{print $5" of "$2}')"
  echo "Memory usage: $(free -m | awk 'NR==2{printf "%.1f%%", $3*100/$2}')"
  echo "Swap usage: $(free -m | awk 'NR==3{if($2==0) print "0%"; else printf "%.1f%%", $3*100/$2}')"
  echo
  ip -4 a | sed -n 's/.*inet \([0-9.]\+\)\/.*/IPv4: \1/p' | head -n 5 || true
  echo
}

about(){
  cat <<'EOF'
OpenList Telegram Bot (admin-only)
- /ls 目录浏览（带按钮进入/选择）
- /mkdir 创建文件夹
- /tool 选择离线下载工具（qBittorrent/aria2）
- /add 创建离线下载
- /progress 查询下载进度（尽量显示网页端任务）

安装目录：/root/openlistbot
服务名：openlist-tg-bot.service
EOF
}

menu(){
  clear
  cat <<'EOF'
欢迎使用 OpenList Bot 管理脚本

基础功能：
1、安装 机器人
2、更新 机器人
3、卸载 机器人
----------------
服务管理：
4、查看状态
5、配置管理（编辑 .env）
6、启动 机器人
7、停止 机器人
8、重启 机器人
----------------
配置备份：
9、备份配置
10、恢复配置
----------------
高级选项：
12、设置/重写 定期清理日志（每周一次，不保留历史）
13、系统状态
14、关于

0、退出脚本
EOF
  read -r -p "请输入选项 [0-14]：" opt
  case "$opt" in
    1) install_bot; pause;;
    2) update_bot; pause;;
    3) uninstall_bot; pause;;
    4) service_status; pause;;
    5) config_edit; pause;;
    6) service_start; green "✅ 已启动"; pause;;
    7) service_stop; green "✅ 已停止"; pause;;
    8) service_restart; green "✅ 已重启"; pause;;
    9) backup_config; pause;;
    10) restore_config; pause;;
    12) setup_log_clean_weekly; green "✅ 已设置"; pause;;
    13) system_info; pause;;
    14) about; pause;;
    0) exit 0;;
    *) yellow "无效选项"; pause;;
  esac
}

main(){
  need_root
  while true; do menu; done
}
main
