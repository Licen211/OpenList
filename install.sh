#!/usr/bin/env bash
# OpenList TG Bot one-click installer -> /root/openlistbot
# Features:
# - Admin-only (supports multiple admin user IDs)
# - Browse dirs (/ls) with inline buttons + remember last chosen dir
# - Add offline download (/add <magnet|url>) -> /api/fs/add_offline_download
# - Show progress (/progress) -> /api/admin/task/upload/undone
# - Create folder (/mkdir /full/path/new_folder) -> /api/fs/mkdir
# - Weekly journal cleanup (keep last 7 days of this service logs)
#
# Usage:
#   chmod +x install.sh && sudo ./install.sh
# Or after pushing to GitHub:
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install.sh | sudo bash
set -euo pipefail

APP_DIR="/root/openlistbot"
VENV_DIR="${APP_DIR}/venv"
CFG_FILE="${APP_DIR}/config.yaml"
DB_FILE="${APP_DIR}/state.db"
SERVICE_NAME="openlist-tg-bot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; NC="\033[0m"
ok(){ echo -e "${GREEN}$*${NC}"; }
warn(){ echo -e "${YELLOW}$*${NC}"; }
err(){ echo -e "${RED}$*${NC}"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "请用 root 执行：sudo -i 或 sudo bash install.sh"
    exit 1
  fi
}

prompt() {
  local __var="$1"
  local __tip="$2"
  local __def="${3:-}"
  local __val=""
  if [[ -n "${__def}" ]]; then
    read -r -p "${__tip} [默认: ${__def}]: " __val || true
    __val="${__val:-$__def}"
  else
    read -r -p "${__tip}: " __val || true
  fi
  printf -v "${__var}" "%s" "${__val}"
}

install_deps() {
  ok "1) 安装依赖..."
  apt-get update -y
  apt-get install -y python3 python3-venv python3-pip curl ca-certificates
}

# 可选：清理编译/构建相关工具（避免占用空间）
# 说明：如果你的服务器还需要编译别的程序，请在安装时选择不清理。
cleanup_build_tools() {
  [[ "${CLEAN_BUILD_TOOLS}" != "y" ]] && return 0
  ok "(可选) 清理编译工具与无用依赖..."

  # 这些包通常只在编译 Python 扩展或源码构建时需要
  apt-get purge -y \
    build-essential \
    gcc g++ make cpp \
    dpkg-dev \
    python3-dev libpython3-dev \
    pkg-config \
    || true

  apt-get autoremove -y || true
  apt-get clean || true
  rm -rf /var/lib/apt/lists/* || true

  # 清理 pip 缓存（不影响 venv 内已安装的包）
  rm -rf /root/.cache/pip || true
}

write_files() {
  ok "2) 写入机器人程序到 ${APP_DIR} ..."
  mkdir -p "${APP_DIR}"

  cat > "${APP_DIR}/requirements.txt" <<'REQ'
python-telegram-bot==21.6
PyYAML==6.0.2
requests==2.32.3
REQ

  cat > "${CFG_FILE}" <<'YAML'
telegram:
  bot_token: ""
  # 允许使用机器人的管理员ID（数字），支持多个
  admin_user_ids: []

openlist:
  base_url: "http://127.0.0.1:525"
  token: ""
  tool: "qBittorrent"
  delete_policy: "no"

ui:
  page_size: 30
YAML

  cat > "${APP_DIR}/bot.py" <<'PY'
import os
import re
import sqlite3
from typing import List

import yaml
import requests
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, CallbackQueryHandler, ContextTypes, filters

APP_DIR = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.environ.get("BOT_CONFIG", os.path.join(APP_DIR, "config.yaml"))
DB_PATH = os.environ.get("BOT_DB", os.path.join(APP_DIR, "state.db"))

MAGNET_RE = re.compile(r"^(magnet:\?xt=urn:btih:|https?://|ftp://)", re.I)

def load_cfg() -> dict:
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)

def norm_base(base: str) -> str:
    base = (base or "").strip()
    if not base.startswith(("http://", "https://")):
        base = "http://" + base
    return base.rstrip("/")

class StateDB:
    def __init__(self, path: str):
        self.path = path
        self._init()
    def _init(self):
        conn = sqlite3.connect(self.path)
        try:
            conn.execute("""CREATE TABLE IF NOT EXISTS user_state(
              user_id INTEGER PRIMARY KEY,
              last_path TEXT NOT NULL DEFAULT '/'
            )""")
            conn.commit()
        finally:
            conn.close()
    def get_last_path(self, user_id: int) -> str:
        conn = sqlite3.connect(self.path)
        try:
            cur = conn.execute("SELECT last_path FROM user_state WHERE user_id=?", (user_id,))
            row = cur.fetchone()
            return row[0] if row else "/"
        finally:
            conn.close()
    def set_last_path(self, user_id: int, path: str):
        conn = sqlite3.connect(self.path)
        try:
            conn.execute(
                "INSERT INTO user_state(user_id,last_path) VALUES(?,?) "
                "ON CONFLICT(user_id) DO UPDATE SET last_path=excluded.last_path",
                (user_id, path),
            )
            conn.commit()
        finally:
            conn.close()

def is_admin(cfg: dict, user_id: int) -> bool:
    admins = cfg.get("telegram", {}).get("admin_user_ids", []) or []
    try:
        uid = int(user_id)
    except Exception:
        return False
    for a in admins:
        try:
            if int(a) == uid:
                return True
        except Exception:
            continue
    return False

def ol_headers(token: str) -> dict:
    return {"Authorization": token}

def fs_list(base: str, token: str, path: str, page: int, per_page: int) -> dict:
    url = f"{base}/api/fs/list"
    payload = {"path": path, "password": "", "page": page, "per_page": per_page, "refresh": False}
    r = requests.post(url, headers=ol_headers(token), json=payload, timeout=20)
    r.raise_for_status()
    return r.json()

def fs_mkdir(base: str, token: str, path: str) -> dict:
    url = f"{base}/api/fs/mkdir"
    payload = {"path": path}
    r = requests.post(url, headers=ol_headers(token), json=payload, timeout=20)
    r.raise_for_status()
    return r.json()

def add_offline(base: str, token: str, path: str, urls: List[str], tool: str, delete_policy: str) -> dict:
    url = f"{base}/api/fs/add_offline_download"
    payload = {"path": path, "urls": urls, "tool": tool, "delete_policy": delete_policy}
    r = requests.post(url, headers=ol_headers(token), json=payload, timeout=30)
    r.raise_for_status()
    return r.json()

def task_undone(base: str, token: str) -> dict:
    """获取未完成任务。

    OpenList 的任务类型在不同版本/页面可能不同（download/offline/upload）。
    这里按常见顺序依次尝试，取第一个成功且 data 有内容的结果。
    """
    endpoints = [
        "/api/admin/task/download/undone",
        "/api/admin/task/offline/undone",
        "/api/admin/task/upload/undone",
    ]
    last = None
    for ep in endpoints:
        url = f"{base}{ep}"
        try:
            r = requests.get(url, headers=ol_headers(token), timeout=20)
            r.raise_for_status()
            j = r.json()
            last = j
            data = j.get("data")
            if isinstance(data, list) and data:
                return j
        except Exception:
            continue
    return last or {"code": 500, "message": "task endpoint not found", "data": []}

def build_dir_keyboard(path: str, items: List[dict], page: int, per_page: int, total: int) -> InlineKeyboardMarkup:
    btns: List[List[InlineKeyboardButton]] = []
    if path != "/":
        parent = "/".join([p for p in path.rstrip("/").split("/")[:-1] if p])
        parent = "/" + parent if parent else "/"
        btns.append([InlineKeyboardButton("⬅️ 上级", callback_data=f"cd|{parent}|1")])

    for it in items:
        if it.get("is_dir"):
            name = it.get("name", "")
            cur = path.rstrip("/") or "/"
            tgt = ("/" + name) if cur == "/" else (cur + "/" + name)
            btns.append([InlineKeyboardButton(f"📁 {name}", callback_data=f"cd|{tgt}|1")])

    max_page = max(1, (total + per_page - 1) // per_page)
    nav: List[InlineKeyboardButton] = []
    if page > 1:
        nav.append(InlineKeyboardButton("⬅️ 上一页", callback_data=f"ls|{path}|{page-1}"))
    nav.append(InlineKeyboardButton(f"{page}/{max_page}", callback_data="noop"))
    if page < max_page:
        nav.append(InlineKeyboardButton("➡️ 下一页", callback_data=f"ls|{path}|{page+1}"))
    btns.append(nav)

    btns.append([InlineKeyboardButton("✅ 选这个目录", callback_data=f"pick|{path}|{page}")])
    return InlineKeyboardMarkup(btns)

async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = context.bot_data["cfg"]
    if not is_admin(cfg, update.effective_user.id):
        return
    db: StateDB = context.bot_data["db"]
    last = db.get_last_path(update.effective_user.id)
    await update.message.reply_text(
        "✅ OpenList 离线下载机器人已启动（仅管理员可用）。\n\n"
        "命令：\n"
        "/ls  浏览目录（从根目录开始）\n"
        "/add <磁力/链接>  选择目录后创建离线下载\n"
        "/progress  查看当前任务进度\n"
        "/mkdir /完整路径/新文件夹  创建文件夹\n\n"
        f"上次目录：{last}"
    )

async def cmd_ls(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = context.bot_data["cfg"]
    if not is_admin(cfg, update.effective_user.id):
        return
    per_page = cfg["ui"].get("page_size", 30)
    base = norm_base(cfg["openlist"]["base_url"])
    token = cfg["openlist"]["token"]
    path, page = "/", 1
    j = fs_list(base, token, path, page, per_page)
    content = j.get("data", {}).get("content", [])
    total = j.get("data", {}).get("total", len(content))
    kb = build_dir_keyboard(path, content, page, per_page, total)
    await update.message.reply_text(f"📂 当前：{path}\n（点文件夹进入，或直接选目录）", reply_markup=kb)

async def cmd_mkdir(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = context.bot_data["cfg"]
    if not is_admin(cfg, update.effective_user.id):
        return
    if not context.args:
        await update.message.reply_text("用法：/mkdir /完整路径/新文件夹名")
        return
    path = " ".join(context.args).strip()
    base = norm_base(cfg["openlist"]["base_url"])
    token = cfg["openlist"]["token"]
    try:
        j = fs_mkdir(base, token, path)
    except requests.HTTPError as e:
        await update.message.reply_text(f"❌ 创建失败：HTTP错误 {e}")
        return
    except Exception as e:
        await update.message.reply_text(f"❌ 创建失败：{e}")
        return

    if j.get("code") == 200:
        await update.message.reply_text(f"✅ 已创建：{path}")
    else:
        await update.message.reply_text(f"❌ 创建失败：{j}")

async def cmd_add(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = context.bot_data["cfg"]
    if not is_admin(cfg, update.effective_user.id):
        return
    if not context.args:
        await update.message.reply_text("用法：/add <磁力链接 或 http(s) 链接>")
        return
    url = " ".join(context.args).strip()
    if not MAGNET_RE.match(url):
        await update.message.reply_text("这看起来不像磁力/链接。请重新发 /add <link>")
        return
    context.user_data["pending_url"] = url

    db: StateDB = context.bot_data["db"]
    last = db.get_last_path(update.effective_user.id)

    per_page = cfg["ui"].get("page_size", 30)
    base = norm_base(cfg["openlist"]["base_url"])
    token = cfg["openlist"]["token"]
    page = 1
    j = fs_list(base, token, last, page, per_page)
    content = j.get("data", {}).get("content", [])
    total = j.get("data", {}).get("total", len(content))
    kb = build_dir_keyboard(last, content, page, per_page, total)
    await update.message.reply_text(f"🧲 收到链接。\n现在选保存目录（默认上次：{last}）：", reply_markup=kb)

async def cmd_progress(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = context.bot_data["cfg"]
    if not is_admin(cfg, update.effective_user.id):
        return
    base = norm_base(cfg["openlist"]["base_url"])
    token = cfg["openlist"]["token"]
    j = task_undone(base, token)
    tasks = j.get("data", [])
    if not tasks:
        await update.message.reply_text("暂无未完成任务。")
        return
    lines = []
    for t in tasks[:20]:
        tid = t.get("id", "")
        prog = t.get("progress", 0)
        state = t.get("state", "")
        name = t.get("name", "")
        lines.append(f"#{tid}  {prog}%  {state}  {name}")
    await update.message.reply_text("📈 未完成任务（最多显示 20 条）：\n" + "\n".join(lines))

async def on_cb(update: Update, context: ContextTypes.DEFAULT_TYPE):
    q = update.callback_query
    await q.answer()
    if q.data in ("noop", None):
        return

    cfg = context.bot_data["cfg"]
    if not is_admin(cfg, q.from_user.id):
        return

    base = norm_base(cfg["openlist"]["base_url"])
    token = cfg["openlist"]["token"]
    per_page = cfg["ui"].get("page_size", 30)
    db: StateDB = context.bot_data["db"]

    kind, path, page_s = q.data.split("|", 2)
    page = int(page_s)

    if kind in ("ls", "cd"):
        j = fs_list(base, token, path, page, per_page)
        content = j.get("data", {}).get("content", [])
        total = j.get("data", {}).get("total", len(content))
        kb = build_dir_keyboard(path, content, page, per_page, total)
        await q.edit_message_text(f"📂 当前：{path}\n（点文件夹进入，或直接选目录）", reply_markup=kb)
        return

    if kind == "pick":
        db.set_last_path(q.from_user.id, path)
        pending = context.user_data.get("pending_url")
        if not pending:
            await q.edit_message_text(f"✅ 已记住目录：{path}\n（你现在可以用 /add <链接> 创建离线下载）")
            return

        tool = cfg["openlist"].get("tool", "qBittorrent")
        delete_policy = cfg["openlist"].get("delete_policy", "no")

        j = add_offline(base, token, path, [pending], tool, delete_policy)
        if j.get("code") == 200:
            await q.edit_message_text(f"✅ 已创建离线下载\n目录：{path}\n工具：{tool}\n用 /progress 查看进度")
        else:
            await q.edit_message_text(f"❌ 创建失败：{j}")
        context.user_data.pop("pending_url", None)

async def on_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    cfg = context.bot_data["cfg"]
    if not is_admin(cfg, update.effective_user.id):
        return
    txt = (update.message.text or "").strip()
    if MAGNET_RE.match(txt):
        context.args = [txt]
        await cmd_add(update, context)

def main():
    cfg = load_cfg()
    token = (cfg.get("telegram", {}).get("bot_token") or "").strip()
    if not token:
        raise SystemExit("config.yaml 里 telegram.bot_token 不能为空")

    app = Application.builder().token(token).build()
    app.bot_data["cfg"] = cfg
    app.bot_data["db"] = StateDB(DB_PATH)

    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("ls", cmd_ls))
    app.add_handler(CommandHandler("mkdir", cmd_mkdir))
    app.add_handler(CommandHandler("add", cmd_add))
    app.add_handler(CommandHandler("progress", cmd_progress))
    app.add_handler(CallbackQueryHandler(on_cb))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, on_text))

    app.run_polling(close_loop=False)

if __name__ == "__main__":
    main()
PY

  chmod 700 "${APP_DIR}"
  chmod 600 "${CFG_FILE}" || true
}

setup_venv() {
  ok "3) 创建虚拟环境并安装依赖..."
  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/pip" install --upgrade pip
  "${VENV_DIR}/bin/pip" install -r "${APP_DIR}/requirements.txt"
}

configure() {
  ok "4) 填写配置（支持多个管理员ID）..."
  local TG_TOKEN TG_ADMIN_IDS OL_BASE OL_TOKEN OL_TOOL OL_DEL
  prompt TG_TOKEN "Telegram Bot Token（@BotFather 获取）" ""
  prompt TG_ADMIN_IDS "管理员 Telegram ID（数字，多个用逗号，例如 123,456）" ""
  prompt OL_BASE "OpenList Base URL（例如 http://do.licen.live:525 ）" "http://do.licen.live:525"
  prompt OL_TOKEN "OpenList Token" ""
  prompt OL_TOOL "默认离线工具（qBittorrent / aria2 / SimpleHttp）" "qBittorrent"
  prompt OL_DEL "delete_policy（不确定就 no）" "no"

  # 仅影响本次安装流程，不写入配置文件
  local CLEAN_BUILD_TOOLS_LOCAL
  prompt CLEAN_BUILD_TOOLS_LOCAL "安装完成后清理编译工具/无用依赖？(y/n)" "y"
  CLEAN_BUILD_TOOLS="${CLEAN_BUILD_TOOLS_LOCAL,,}"

  python3 - <<PY
import yaml, re
cfg_path="${CFG_FILE}"
cfg=yaml.safe_load(open(cfg_path,'r',encoding='utf-8'))
cfg['telegram']['bot_token']="${TG_TOKEN}"

admins=[]
s="${TG_ADMIN_IDS}".strip()
if s:
    for x in s.split(','):
        x=x.strip()
        if not x:
            continue
        if re.fullmatch(r"\d+", x):
            admins.append(int(x))
cfg['telegram']['admin_user_ids']=admins

cfg['openlist']['base_url']="${OL_BASE}"
cfg['openlist']['token']="${OL_TOKEN}"
cfg['openlist']['tool']="${OL_TOOL}"
cfg['openlist']['delete_policy']="${OL_DEL}"

yaml.safe_dump(cfg, open(cfg_path,'w',encoding='utf-8'), allow_unicode=True, sort_keys=False)
print("OK")
PY

  chmod 600 "${CFG_FILE}"
}

install_service() {
  ok "5) 安装 systemd 服务并启动..."
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=OpenList Telegram Bot (admin-only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
Environment=BOT_CONFIG=${CFG_FILE}
Environment=BOT_DB=${DB_FILE}
ExecStart=${VENV_DIR}/bin/python ${APP_DIR}/bot.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
}

install_logclean() {
  ok "6) 添加每周清理日志（保留最近 7 天）..."
  cat > /etc/systemd/system/openlist-tg-bot-logclean.service <<'EOF'
[Unit]
Description=Vacuum journal logs for openlist-tg-bot

[Service]
Type=oneshot
ExecStart=/usr/bin/journalctl -u openlist-tg-bot --vacuum-time=7d
EOF

  cat > /etc/systemd/system/openlist-tg-bot-logclean.timer <<'EOF'
[Unit]
Description=Weekly journal vacuum for openlist-tg-bot

[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now openlist-tg-bot-logclean.timer
}

finish() {
  ok "✅ 安装完成：${SERVICE_NAME}"
  echo
  echo "目录：${APP_DIR}"
  echo "管理命令："
  echo "  systemctl status ${SERVICE_NAME} -l"
  echo "  systemctl restart ${SERVICE_NAME}"
  echo "  journalctl -u ${SERVICE_NAME} -f --no-pager"
  echo
  echo "日志清理："
  echo "  systemctl status openlist-tg-bot-logclean.timer -l"
  echo "  journalctl -u openlist-tg-bot-logclean.service --no-pager"
  echo
  echo "Telegram（只有管理员ID可用）："
  echo "  /start"
  echo "  /ls"
  echo "  /mkdir /完整路径/新文件夹"
  echo "  /add magnet:..."
  echo "  /progress"
}

main() {
  need_root
  install_deps
  write_files
  setup_venv
  configure
  install_service
  install_logclean
  cleanup_build_tools
  finish
}

main "$@"
