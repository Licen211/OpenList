#!/usr/bin/env bash
# OpenList Telegram Bot (admin-only) 管理菜单脚本（安装时配置向导 + 可配置项齐全）
# - 安装到 /root/openlistbot
# - systemd 服务: openlist-tg-bot.service
# - 安装/更新/配置向导：写入 /root/openlistbot/.env（后期直接改 .env）
# - 支持 qBittorrent / aria2：把 URL/账号/密钥都写进 .env
# - /ls 目录浏览按钮；/mkdir；/tool(qB/aria2)；/add；/progress（可配置 API 路径候选）
# - 如安装过程中临时装了编译工具，会在成功后自动清理
# - 可选清理额外依赖（git/curl/jq/python3-pip）
# - 每周清理一次该服务日志（journald），清理时间可在 .env 里改

set -Eeuo pipefail

APP_DIR="/root/openlistbot"
SERVICE_NAME="openlist-tg-bot"
CRON_FILE="/etc/cron.d/openlistbot-clean"
PY_BIN="python3"

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
  apt-get install -y --no-installrecommends build-essential python3-dev pkg-config || \
  apt-get install -y --no-install-recommends build-essential python3-dev pkg-config
}

cleanup_build_tools(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y build-essential gcc g++ make python3-dev pkg-config 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  apt-get clean -y 2>/dev/null || true
}


cleanup_extra_deps(){
  # 清理“安装阶段用、运行不必须”的依赖
  # 注意：会移除 git/curl/jq/python3-pip 等，后续若想用菜单更新，可能需要重新安装这些包
  export DEBIAN_FRONTEND=noninteractive
  apt-get purge -y git jq curl python3-pip 2>/dev/null || true
  apt-get autoremove -y 2>/dev/null || true
  apt-get clean -y 2>/dev/null || true
  rm -rf /var/lib/apt/lists/* 2>/dev/null || true
}

maybe_cleanup_extra_deps(){
  # 默认不清理；你若想更“干净”，安装完可选清理
  local ans="n"
  read -r -p "是否清理安装时用到的额外依赖（git/curl/jq/python3-pip 等）？[y/N] " ans || true
  ans="${ans:-n}"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    yellow "开始清理额外依赖（后续要更新脚本可能需要再装回来）..."
    cleanup_extra_deps
    green "✅ 已清理额外依赖"
  fi
}

write_bot_files(){
  mkdir -p "$APP_DIR"
  chmod 755 "$APP_DIR"

  cat > "$APP_DIR/requirements.txt" <<'REQ'
python-telegram-bot==21.6
requests>=2.31
REQ

  cat > "$APP_DIR/bot.py" <<'PY'
import os, re, json
from typing import List
import requests
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, ContextTypes

def env(name: str, default: str = "") -> str:
    v = os.getenv(name)
    return v if v is not None and v != "" else default

# ===== Telegram =====
TG_BOT_TOKEN = env("TG_BOT_TOKEN")
TG_ADMIN_IDS = {int(x.strip()) for x in env("TG_ADMIN_IDS","").split(",") if x.strip().isdigit()}

# ===== OpenList =====
OPENLIST_BASE_URL = env("OPENLIST_BASE_URL", "http://127.0.0.1:525").rstrip("/")
OPENLIST_TOKEN = env("OPENLIST_TOKEN")
OPENLIST_START_PATH = env("OPENLIST_START_PATH", "/") or "/"
PER_PAGE = int(env("PER_PAGE", "30") or "30")

DEFAULT_TOOL = env("DEFAULT_TOOL", "qBittorrent") or "qBittorrent"
STATE_DIR = env("STATE_DIR", "/root/openlistbot/state")
TASK_API_PATHS = [p.strip() for p in env(
    "TASK_API_PATHS",
    "/api/admin/task/offline/undone,/api/admin/task/download/undone,/api/admin/task/upload/undone,/api/admin/task/offline/list"
).split(",") if p.strip()]

# ===== 下载器（给后续扩展用：你想把 /progress 也合并成 qb+aria2 时用得上）=====
QBT_URL = env("QBT_URL", "")
QBT_USER = env("QBT_USER", "")
QBT_PASS = env("QBT_PASS", "")

ARIA2_RPC = env("ARIA2_RPC", "")
ARIA2_SECRET = env("ARIA2_SECRET", "")

os.makedirs(STATE_DIR, exist_ok=True)

# ========= OpenList API =========
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

def fs_list(path: str, token: str, page: int = 1, per_page: int = PER_PAGE, refresh: bool = False) -> dict:
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
    last_err = None
    for path in TASK_API_PATHS:
        try:
            j = ol_get(path, token, timeout=20)
            if isinstance(j, dict) and j.get("code") == 200:
                return j
        except Exception as e:
            last_err = e
            continue
    raise RuntimeError(f"无法获取任务列表：已尝试 {TASK_API_PATHS}，最后错误：{last_err}")

# ========= 状态存储 =========
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

# ========= 目录选择键盘 =========
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

    pages = max(1, (total + per_page - 1) // per_page) if total else 1
    nav: List[InlineKeyboardButton] = []
    if page > 1: nav.append(InlineKeyboardButton("⬅️ 上一页", callback_data=f"cd|{path}|{page-1}"))
    nav.append(InlineKeyboardButton(f"{page}/{pages}", callback_data="noop"))
    if page < pages: nav.append(InlineKeyboardButton("下一页 ➡️", callback_data=f"cd|{path}|{page+1}"))
    if nav: btns.append(nav)

    btns.append([InlineKeyboardButton("✅ 选这个目录", callback_data=f"pick|{path}")])
    return InlineKeyboardMarkup(btns)

# ========= 命令 =========
async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        await update.message.reply_text(deny()); return
    await update.message.reply_text(
        "✅ OpenList Bot 已启动\n"
        "命令：\n"
        "/ls - 浏览目录并选择保存目录\n"
        "/mkdir /完整路径/新文件夹名\n"
        "/tool - 查看/设置离线下载工具（qBittorrent/aria2...）\n"
        "/add <磁力/直链>\n"
        "/progress - 查询当前未完成任务\n"
    )

async def cmd_ls(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update):
        await update.message.reply_text(deny()); return
    uid = update.effective_user.id
    st = load_state(uid)
    path = norm_path(st.get("cwd") or OPENLIST_START_PATH or "/")
    try:
        j = fs_list(path, OPENLIST_TOKEN, page=1, per_page=PER_PAGE, refresh=False)
        data = j.get("data") or {}
        items = (data.get("content") or []) or []
        total = int(data.get("total") or len(items))
        kb = build_dir_keyboard(path, items, 1, PER_PAGE, total)
        await update.message.reply_text(f"📂 当前：{path}\n(点文件夹进入，或直接选目录)", reply_markup=kb)
    except Exception as e:
        await update.message.reply_text(f"❌ 列目录失败：{e}")

async def on_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
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
            j = fs_list(path, OPENLIST_TOKEN, page=page, per_page=PER_PAGE, refresh=False)
            d = j.get("data") or {}
            items = (d.get("content") or []) or []
            total = int(d.get("total") or len(items))
            kb = build_dir_keyboard(path, items, page, PER_PAGE, total)
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
        await update.message.reply_text(f"✅ 已创建：{p}" if j.get("code")==200 else f"❌ 创建失败：{j}")
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
        await update.message.reply_text("❌ 未获取到工具列表（检查 OPENLIST_TOKEN / 离线下载是否启用）"); return
    prefer = ["qBittorrent","aria2"]
    tools_sorted = prefer + [t for t in tools if t not in prefer]
    cur = st.get("tool") or DEFAULT_TOOL
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
    tool = st.get("tool") or DEFAULT_TOOL
    try:
        j = add_offline(url, save_path, tool, OPENLIST_TOKEN)
        await update.message.reply_text(
            f"✅ 已创建离线下载\n目录：{save_path}\n工具：{tool}\n用 /progress 查看进度"
            if j.get("code")==200 else f"❌ 创建失败：{j}"
        )
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
        for t in content[:12]:
            name = t.get("name") or t.get("title") or t.get("url") or "-"
            status = t.get("status") or t.get("state") or "-"
            tool = t.get("tool") or t.get("driver") or t.get("type") or "-"
            prog = t.get("progress")
            prog_s = f"{prog:.1f}%" if isinstance(prog,(int,float)) else (str(prog) if prog not in (None,"") else "-")
            save_path = t.get("path") or t.get("save_path") or "-"
            lines.append(f"• {name}\n  目录：{save_path}\n  状态：[{tool}] {status}  进度：{prog_s}")
        await update.message.reply_text("📥 当前未完成任务：\n\n" + "\n\n".join(lines))
    except Exception as e:
        await update.message.reply_text(f"❌ 查询失败：{e}")

def main():
    if not TG_BOT_TOKEN: raise SystemExit("TG_BOT_TOKEN 为空，请在 .env 填好后重启服务")
    if not OPENLIST_TOKEN: raise SystemExit("OPENLIST_TOKEN 为空，请在 .env 填好后重启服务")
    if not TG_ADMIN_IDS: raise SystemExit("TG_ADMIN_IDS 为空，请在 .env 填好后重启服务")

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

# 读取旧值
env_get(){
  local k="$1" f="$APP_DIR/.env"
  [ -f "$f" ] || return 0
  grep -E "^${k}=" "$f" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

config_wizard(){
  need_root
  mkdir -p "$APP_DIR"
  chmod 755 "$APP_DIR"

  local envf="$APP_DIR/.env"
  local v

  local old_TG_BOT_TOKEN="$(env_get TG_BOT_TOKEN)"
  local old_TG_ADMIN_IDS="$(env_get TG_ADMIN_IDS)"
  local old_OPENLIST_BASE_URL="$(env_get OPENLIST_BASE_URL)"
  local old_OPENLIST_TOKEN="$(env_get OPENLIST_TOKEN)"
  local old_OPENLIST_START_PATH="$(env_get OPENLIST_START_PATH)"; old_OPENLIST_START_PATH="${old_OPENLIST_START_PATH:-/}"
  local old_PER_PAGE="$(env_get PER_PAGE)"; old_PER_PAGE="${old_PER_PAGE:-30}"
  local old_DEFAULT_TOOL="$(env_get DEFAULT_TOOL)"; old_DEFAULT_TOOL="${old_DEFAULT_TOOL:-qBittorrent}"
  local old_STATE_DIR="$(env_get STATE_DIR)"; old_STATE_DIR="${old_STATE_DIR:-/root/openlistbot/state}"
  local old_TASK_API_PATHS="$(env_get TASK_API_PATHS)"
  old_TASK_API_PATHS="${old_TASK_API_PATHS:-/api/admin/task/offline/undone,/api/admin/task/download/undone,/api/admin/task/upload/undone,/api/admin/task/offline/list}"

  local old_QBT_URL="$(env_get QBT_URL)"
  local old_QBT_USER="$(env_get QBT_USER)"
  local old_QBT_PASS="$(env_get QBT_PASS)"
  local old_ARIA2_RPC="$(env_get ARIA2_RPC)"
  local old_ARIA2_SECRET="$(env_get ARIA2_SECRET)"

  echo
  green "== 配置向导（写入 $envf，后期直接改这个文件）=="
  echo

  read -r -p "Telegram Bot Token [${old_TG_BOT_TOKEN:+已设置}] : " v; TG_BOT_TOKEN="${v:-$old_TG_BOT_TOKEN}"
  read -r -p "Telegram 管理员ID（多个用逗号）[${old_TG_ADMIN_IDS:-空}] : " v; TG_ADMIN_IDS="${v:-$old_TG_ADMIN_IDS}"

  read -r -p "OpenList 地址（例：http://do.licen.live:525）[${old_OPENLIST_BASE_URL:-空}] : " v; OPENLIST_BASE_URL="${v:-$old_OPENLIST_BASE_URL}"
  read -r -p "OpenList Token [${old_OPENLIST_TOKEN:+已设置}] : " v; OPENLIST_TOKEN="${v:-$old_OPENLIST_TOKEN}"
  read -r -p "初始浏览路径 [${old_OPENLIST_START_PATH}] : " v; OPENLIST_START_PATH="${v:-$old_OPENLIST_START_PATH}"
  read -r -p "目录每页显示数量 PER_PAGE [${old_PER_PAGE}] : " v; PER_PAGE="${v:-$old_PER_PAGE}"
  read -r -p "默认离线下载工具 DEFAULT_TOOL(qBittorrent/aria2) [${old_DEFAULT_TOOL}] : " v; DEFAULT_TOOL="${v:-$old_DEFAULT_TOOL}"
  read -r -p "状态目录 STATE_DIR [${old_STATE_DIR}] : " v; STATE_DIR="${v:-$old_STATE_DIR}"
  read -r -p "progress 接口候选 TASK_API_PATHS(逗号分隔) [已设置] : " v; TASK_API_PATHS="${v:-$old_TASK_API_PATHS}"

  echo
  yellow "== qBittorrent（用于你后期合并进度查询/或扩展）=="
  read -r -p "QBT_URL（例：http://127.0.0.1:18080）[${old_QBT_URL:-空}] : " v; QBT_URL="${v:-$old_QBT_URL}"
  read -r -p "QBT_USER [${old_QBT_USER:-空}] : " v; QBT_USER="${v:-$old_QBT_USER}"
  read -r -p "QBT_PASS（回车保留）[${old_QBT_PASS:+已设置}] : " v; QBT_PASS="${v:-$old_QBT_PASS}"

  echo
  yellow "== aria2（用于你后期合并进度查询/或扩展）=="
  read -r -p "ARIA2_RPC（例：http://127.0.0.1:6800/jsonrpc）[${old_ARIA2_RPC:-空}] : " v; ARIA2_RPC="${v:-$old_ARIA2_RPC}"
  read -r -p "ARIA2_SECRET（没有就空）[${old_ARIA2_SECRET:+已设置}] : " v; ARIA2_SECRET="${v:-$old_ARIA2_SECRET}"

  echo
  yellow "== 日志清理时间（每周）=="
  local old_DOW="$(env_get LOG_CLEAN_DOW)"; old_DOW="${old_DOW:-0}"
  local old_HH="$(env_get LOG_CLEAN_HH)"; old_HH="${old_HH:-3}"
  local old_MM="$(env_get LOG_CLEAN_MM)"; old_MM="${old_MM:-30}"
  read -r -p "LOG_CLEAN_DOW（0=周日..6=周六）[${old_DOW}] : " v; LOG_CLEAN_DOW="${v:-$old_DOW}"
  read -r -p "LOG_CLEAN_HH（0-23）[${old_HH}] : " v; LOG_CLEAN_HH="${v:-$old_HH}"
  read -r -p "LOG_CLEAN_MM（0-59）[${old_MM}] : " v; LOG_CLEAN_MM="${v:-$old_MM}"

  cat > "$envf" <<EOF
# Telegram
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_ADMIN_IDS=${TG_ADMIN_IDS}

# OpenList
OPENLIST_BASE_URL=${OPENLIST_BASE_URL}
OPENLIST_TOKEN=${OPENLIST_TOKEN}
OPENLIST_START_PATH=${OPENLIST_START_PATH}
PER_PAGE=${PER_PAGE}
DEFAULT_TOOL=${DEFAULT_TOOL}
STATE_DIR=${STATE_DIR}

# /progress 接口候选（逗号分隔）
TASK_API_PATHS=${TASK_API_PATHS}

# qBittorrent（后续扩展/合并进度用）
QBT_URL=${QBT_URL}
QBT_USER=${QBT_USER}
QBT_PASS=${QBT_PASS}

# aria2（后续扩展/合并进度用）
ARIA2_RPC=${ARIA2_RPC}
ARIA2_SECRET=${ARIA2_SECRET}

# 每周清理日志（journald）
LOG_CLEAN_DOW=${LOG_CLEAN_DOW}
LOG_CLEAN_HH=${LOG_CLEAN_HH}
LOG_CLEAN_MM=${LOG_CLEAN_MM}
EOF
  chmod 600 "$envf"
  green "✅ 已写入配置：$envf"
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
  # 从 .env 读取清理时间；没有就默认 周日 03:30
  local envf="$APP_DIR/.env"
  local dow="0" hh="3" mm="30"
  if [ -f "$envf" ]; then
    dow="$(grep -E '^LOG_CLEAN_DOW=' "$envf" 2>/dev/null | head -n1 | cut -d= -f2- || echo 0)"
    hh="$(grep -E '^LOG_CLEAN_HH=' "$envf" 2>/dev/null | head -n1 | cut -d= -f2- || echo 3)"
    mm="$(grep -E '^LOG_CLEAN_MM=' "$envf" 2>/dev/null | head -n1 | cut -d= -f2- || echo 30)"
  fi
  cat > "$CRON_FILE" <<EOF
SHELL=/bin/bash
PATH=/usr/sbin:/usr/bin:/sbin:/bin
# 每周清理 openlist-tg-bot 的 journald 日志（不保留历史）
${mm} ${hh} * * ${dow} root journalctl -u ${SERVICE_NAME}.service --rotate >/dev/null 2>&1; journalctl -u ${SERVICE_NAME}.service --vacuum-time=1s >/dev/null 2>&1
EOF
  chmod 644 "$CRON_FILE"
}

install_bot(){
  need_root
  green "== 安装 OpenList TG Bot（admin-only） =="
  install_apt_base
  write_bot_files

  # ✅ 安装时写入完整配置（含 qB/aria2 密钥）
  config_wizard

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

  maybe_cleanup_extra_deps

  green "✅ 安装完成"
  systemctl --no-pager -l status "${SERVICE_NAME}.service" | sed -n '1,18p' || true
}

update_bot(){
  need_root
  green "== 更新（保留 venv/state；重写 bot.py）=="
  [ -d "$APP_DIR" ] || { red "未找到 $APP_DIR，请先安装"; return; }
  write_bot_files
  config_wizard

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

about(){
  cat <<'EOF'
OpenList Telegram Bot (admin-only)
- 绝大多数可调项都在 /root/openlistbot/.env（包括 qB/aria2 账号密钥）
- 安装/更新会运行配置向导写入 .env
- /ls 目录浏览（按钮进入/选择）
- /mkdir 创建文件夹
- /tool 选择离线下载工具（qBittorrent/aria2）
- /add 创建离线下载
- /progress 查询未完成任务（接口候选可在 .env 里改）

安装目录：/root/openlistbot
服务名：openlist-tg-bot.service
EOF
}

system_info(){
  echo
  echo "System load: $(awk '{print $1}' /proc/loadavg 2>/dev/null || echo '-')"
  echo "Usage of / : $(df -h / | awk 'NR==2{print $5\" of \"$2}')"
  echo "Memory usage: $(free -m | awk 'NR==2{printf \"%.1f%%\", $3*100/$2}')"
  echo
}

menu(){
  clear
  cat <<'EOF'
欢迎使用 OpenList Bot 管理脚本

基础功能：
1、安装 机器人（安装时填写配置：含 qB/aria2）
2、更新 机器人（更新时可重新填写配置）
3、卸载 机器人
----------------
服务管理：
4、查看状态
5、重新运行 配置向导（只改 .env，并重写日志清理计划）
6、启动 机器人
7、停止 机器人
8、重启 机器人
----------------
高级选项：
12、重写 定期清理日志（按 .env 时间）
13、系统状态
14、关于
15、清理额外依赖（git/curl/jq/python3-pip）

0、退出脚本
EOF
  read -r -p "请输入选项 [0-14]：" opt
  case "$opt" in
    1) install_bot; pause;;
    2) update_bot; pause;;
    3) uninstall_bot; pause;;
    4) service_status; pause;;
    5) config_wizard; setup_log_clean_weekly; green "✅ 已写入 .env 并应用日志计划。建议重启：systemctl restart openlist-tg-bot"; pause;;
    6) service_start; green "✅ 已启动"; pause;;
    7) service_stop; green "✅ 已停止"; pause;;
    8) service_restart; green "✅ 已重启"; pause;;
    12) setup_log_clean_weekly; green "✅ 已按 .env 重写日志清理计划"; pause;;
    13) system_info; pause;;
    14) about; pause;;
    15) cleanup_extra_deps; green "✅ 已清理额外依赖"; pause;;
    0) exit 0;;
    *) yellow "无效选项"; pause;;
  esac
}

main(){ need_root; while true; do menu; done; }
main
