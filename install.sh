#!/usr/bin/env bash
# OpenList Telegram Bot 一键管理脚本（菜单版）
# 默认安装目录：/root/openlistbot
# 说明：本脚本会安装/更新 Bot 运行环境，并把 aria2、qBittorrent 也作为依赖一起装上（你两套都用）。
set -euo pipefail

APP_DIR="/root/openlistbot"
SERVICE_NAME="openlist-tg-bot"
ENV_FILE="$APP_DIR/.env"
PY_BIN="$APP_DIR/venv/bin/python"
PIP_BIN="$APP_DIR/venv/bin/pip"
GIT_REPO_DEFAULT="https://github.com/Licen211/OpenList.git"

GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; CYAN="\033[36m"; NC="\033[0m"

need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || { echo -e "${RED}请用 root 执行：sudo -i${NC}"; exit 1; }; }
pause() { echo; read -r -p "按回车继续..." _; }

banner() {
  clear || true
  echo -e "${GREEN}欢迎使用 OpenList 管理脚本${NC}"
  echo
  echo -e "${CYAN}基础功能：${NC}"
  echo "  1. 安装 Bot（OpenList TG Bot）"
  echo "  2. 更新 Bot"
  echo "  3. 卸载 Bot"
  echo "------------------------------"
  echo -e "${CYAN}服务管理：${NC}"
  echo "  4. 查看状态"
  echo "  5. 启动 Bot"
  echo "  6. 停止 Bot"
  echo "  7. 重启 Bot"
  echo "------------------------------"
  echo -e "${CYAN}配置管理：${NC}"
  echo "  8. 配置向导（填 TG / OpenList / qB / aria2）"
  echo "  9. 备份配置"
  echo " 10. 恢复配置"
  echo "------------------------------"
  echo -e "${CYAN}高级选项：${NC}"
  echo " 11. 定期清理日志（每周一次）"
  echo " 12. 系统状态"
  echo " 13. 查看安装目录"
  echo " 14. 关于"
  echo "------------------------------"
  echo "  0. 退出脚本"
  echo
}

ensure_deps() {
  echo -e "${YELLOW}安装依赖（git/python3-venv/curl + aria2 + qbittorrent-nox）...${NC}"
  apt-get update -y
  apt-get install -y --no-install-recommends \
    git curl ca-certificates \
    python3 python3-venv python3-pip \
    aria2 qbittorrent-nox
}

ensure_app_dir() { mkdir -p "$APP_DIR"; }

clone_or_update_repo() {
  local repo="${1:-$GIT_REPO_DEFAULT}"
  ensure_app_dir
  if [ -d "$APP_DIR/.git" ]; then
    echo -e "${YELLOW}更新仓库...${NC}"
    git -C "$APP_DIR" fetch --all -p
    git -C "$APP_DIR" reset --hard origin/main || git -C "$APP_DIR" reset --hard origin/master
  else
    echo -e "${YELLOW}拉取仓库...${NC}"
    rm -rf "$APP_DIR"/*
    git clone --depth=1 "$repo" "$APP_DIR"
  fi
}

ensure_venv() {
  if [ ! -x "$PY_BIN" ]; then
    echo -e "${YELLOW}创建 venv...${NC}"
    python3 -m venv "$APP_DIR/venv"
  fi
  "$PIP_BIN" install -U pip wheel >/dev/null
  "$PIP_BIN" install -U python-telegram-bot==21.* requests python-dotenv >/dev/null
}

write_service() {
  local svc="/etc/systemd/system/${SERVICE_NAME}.service"
  cat >"$svc" <<EOF
[Unit]
Description=OpenList Telegram Bot (admin-only)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${PY_BIN} ${APP_DIR}/bot.py
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null
}

service_start()  { systemctl start  "${SERVICE_NAME}" || true; }
service_stop()   { systemctl stop   "${SERVICE_NAME}" || true; }
service_restart(){ systemctl restart "${SERVICE_NAME}" || true; }
service_status() { systemctl --no-pager -l status "${SERVICE_NAME}" || true; }

backup_config() {
  [ -f "$ENV_FILE" ] || { echo -e "${RED}找不到配置：$ENV_FILE${NC}"; return 0; }
  local bk="$APP_DIR/.env.bak.$(date +%F_%H%M%S)"
  cp -a "$ENV_FILE" "$bk"
  echo -e "${GREEN}✅ 已备份：$bk${NC}"
}

restore_config() {
  local latest
  latest="$(ls -1t "$APP_DIR"/.env.bak.* 2>/dev/null | head -n 1 || true)"
  [ -n "$latest" ] || { echo -e "${RED}没有找到备份文件（$APP_DIR/.env.bak.*）${NC}"; return 0; }
  cp -a "$latest" "$ENV_FILE"
  echo -e "${GREEN}✅ 已恢复：$latest -> $ENV_FILE${NC}"
}

prompt_env() {
  ensure_app_dir
  touch "$ENV_FILE"; chmod 600 "$ENV_FILE"

  echo -e "${CYAN}开始配置（回车保留原值）${NC}\n"

  local tg_token admin_ids openlist_base openlist_token qbt_url qbt_user qbt_pass aria2_rpc aria2_secret v
  tg_token="$(grep -E '^TG_BOT_TOKEN=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  admin_ids="$(grep -E '^TG_ADMIN_IDS=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  openlist_base="$(grep -E '^OPENLIST_BASE=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  openlist_token="$(grep -E '^OPENLIST_TOKEN=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  qbt_url="$(grep -E '^QBT_URL=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  qbt_user="$(grep -E '^QBT_USER=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  qbt_pass="$(grep -E '^QBT_PASS=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  aria2_rpc="$(grep -E '^ARIA2_RPC=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  aria2_secret="$(grep -E '^ARIA2_SECRET=' "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2- || true)"

  read -r -p "Telegram Bot Token [${tg_token:-空}] : " v; tg_token="${v:-$tg_token}"
  read -r -p "Telegram 管理员ID（多个用逗号）[${admin_ids:-空}] : " v; admin_ids="${v:-$admin_ids}"
  read -r -p "OpenList 地址（例：http://do.licen.live:525）[${openlist_base:-空}] : " v; openlist_base="${v:-$openlist_base}"
  read -r -p "OpenList Token [${openlist_token:-空}] : " v; openlist_token="${v:-$openlist_token}"

  echo -e "\n${YELLOW}qBittorrent 配置：用于 /progress 查询任务${NC}"
  read -r -p "qBittorrent URL（例：http://127.0.0.1:18080）[${qbt_url:-空}] : " v; qbt_url="${v:-$qbt_url}"
  read -r -p "qBittorrent 用户名 [${qbt_user:-空}] : " v; qbt_user="${v:-$qbt_user}"
  read -r -p "qBittorrent 密码（回车保留）[已设置] : " v; qbt_pass="${v:-$qbt_pass}"

  echo -e "\n${YELLOW}aria2 配置：用于 /progress 查询任务${NC}"
  read -r -p "aria2 RPC（例：http://127.0.0.1:6800/jsonrpc）[${aria2_rpc:-空}] : " v; aria2_rpc="${v:-$aria2_rpc}"
  read -r -p "aria2 secret（没有就留空）[${aria2_secret:-空}] : " v; aria2_secret="${v:-$aria2_secret}"

  cat >"$ENV_FILE" <<EOF
# Telegram
TG_BOT_TOKEN=${tg_token}
TG_ADMIN_IDS=${admin_ids}

# OpenList
OPENLIST_BASE=${openlist_base}
OPENLIST_TOKEN=${openlist_token}

# qBittorrent
QBT_URL=${qbt_url}
QBT_USER=${qbt_user}
QBT_PASS=${qbt_pass}

# aria2
ARIA2_RPC=${aria2_rpc}
ARIA2_SECRET=${aria2_secret}
EOF
  chmod 600 "$ENV_FILE"
  echo -e "${GREEN}✅ 已保存：$ENV_FILE${NC}"
}

install_bot() {
  need_root
  ensure_deps
  local repo
  read -r -p "Git 仓库地址（回车默认：$GIT_REPO_DEFAULT）: " repo
  repo="${repo:-$GIT_REPO_DEFAULT}"
  clone_or_update_repo "$repo"
  ensure_venv
  [ -f "$ENV_FILE" ] || { echo -e "${YELLOW}未检测到 .env，进入配置向导...${NC}"; prompt_env; }
  write_service
  service_restart
  echo -e "${GREEN}✅ 安装完成！${NC}\n目录：$APP_DIR\n服务：$SERVICE_NAME"
}

update_bot() {
  need_root
  [ -d "$APP_DIR" ] || { echo -e "${RED}未安装（找不到 $APP_DIR）${NC}"; return 0; }
  clone_or_update_repo "$GIT_REPO_DEFAULT"
  ensure_venv
  service_restart
  echo -e "${GREEN}✅ 已更新并重启${NC}"
}

uninstall_bot() {
  need_root
  echo -e "${YELLOW}卸载 Bot（仅卸载机器人）...${NC}"
  service_stop
  systemctl disable "${SERVICE_NAME}" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service" "/lib/systemd/system/${SERVICE_NAME}.service" || true
  systemctl daemon-reload || true
  systemctl reset-failed || true
  rm -rf "$APP_DIR" || true
  rm -f /etc/cron.d/openlistbot-clean >/dev/null 2>&1 || true
  echo -e "${GREEN}✅ 机器人已卸载${NC}"
}

setup_log_clean() {
  need_root
  cat >/etc/cron.d/openlistbot-clean <<'EOF'
# 每周一次清理 systemd 日志（不保留历史）
# 周日 03:30
30 3 * * 0 root journalctl --rotate >/dev/null 2>&1; journalctl --vacuum-time=1s >/dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/openlistbot-clean
  echo -e "${GREEN}✅ 已设置每周清理日志（/etc/cron.d/openlistbot-clean）${NC}"
}

system_info() {
  echo -e "${CYAN}系统状态：${NC}"
  uptime || true
  echo; df -h / || true
  echo; free -h || true
  echo; echo -e "${CYAN}相关服务：${NC}"
  systemctl list-units --type=service | grep -E "(${SERVICE_NAME}|openlist|qbittorrent|aria2)" || true
}

show_dir() { echo -e "${CYAN}安装目录：${NC} $APP_DIR"; ls -la "$APP_DIR" 2>/dev/null || true; }

about() {
  echo -e "${CYAN}说明：${NC}"
  echo " - 这是菜单版 install.sh（编号菜单），方便你后期自己改。"
  echo " - Bot 目录固定：$APP_DIR"
  echo " - 服务名固定：$SERVICE_NAME"
  echo " - 配置文件：$ENV_FILE"
  echo " - 本脚本会安装 aria2、qbittorrent-nox（你两套都用）"
}

main() {
  need_root
  while true; do
    banner
    read -r -p "请输入选项 [0-14]：" choice
    case "${choice}" in
      1) install_bot; pause ;;
      2) update_bot; pause ;;
      3) uninstall_bot; pause ;;
      4) service_status; pause ;;
      5) service_start; service_status; pause ;;
      6) service_stop; service_status; pause ;;
      7) service_restart; service_status; pause ;;
      8) prompt_env; service_restart; pause ;;
      9) backup_config; pause ;;
      10) restore_config; service_restart; pause ;;
      11) setup_log_clean; pause ;;
      12) system_info; pause ;;
      13) show_dir; pause ;;
      14) about; pause ;;
      0) echo "Bye."; exit 0 ;;
      *) echo -e "${RED}无效选项${NC}"; pause ;;
    esac
  done
}

main "$@"
