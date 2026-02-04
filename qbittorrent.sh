#!/usr/bin/env bash
set -euo pipefail

# ========= 基本配置（可按需改） =========
QB_BASE="/root/qb"                           # qB 配置/缓存独立目录（方便卸载直接删）
QB_PROFILE="$QB_BASE/profile"                # qB profile 目录
QB_SERVICE="/etc/systemd/system/qbittorrent.service"
QB_PORT="8080"

# OpenList data dir 默认路径（若能从 systemd openlist 服务中解析会自动覆盖）
OPENLIST_DATA_DEFAULT="/opt/openlist/data"

# ========= 工具函数 =========
die() { echo -e "\n[错误] $*\n" >&2; exit 1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "请用 sudo 运行：sudo bash $0"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }
pause() { read -r -p "按回车继续..." _; }

detect_openlist_data_dir() {
  local data_dir=""
  if systemctl cat openlist >/dev/null 2>&1; then
    local exe
    exe="$(systemctl cat openlist | sed -n 's/^ExecStart=//p' | head -n 1 || true)"
    data_dir="$(echo "$exe" | sed -n 's/.*--data-dir[= ]\([^ ]*\).*/\1/p' | head -n 1 || true)"
  fi
  [[ -n "$data_dir" ]] || data_dir="$OPENLIST_DATA_DEFAULT"
  echo "$data_dir"
}

qb_temp_dir() {
  local data_dir
  data_dir="$(detect_openlist_data_dir)"
  echo "$data_dir/temp/qb"
}

qb_conf_file() {
  # qB 会在 profile 下创建 qBittorrent/qBittorrent.conf
  echo "$QB_PROFILE/qBittorrent/qBittorrent.conf"
}

ensure_dirs() {
  mkdir -p "$QB_BASE" "$QB_PROFILE"
  mkdir -p "$(qb_temp_dir)"
}

write_systemd_service() {
  cat > "$QB_SERVICE" <<EOF
[Unit]
Description=qBittorrent-nox (for OpenList)
After=network.target

[Service]
User=root
ExecStart=/usr/bin/qbittorrent-nox --webui-port=${QB_PORT} --profile=${QB_PROFILE}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

apply_no_seed_and_paths() {
  local conf
  conf="$(qb_conf_file)"
  if [[ ! -f "$conf" ]]; then
    die "找不到配置文件：$conf（请先执行“安装/初始化”或先启动一次 qB）"
  fi

  local temp_dir
  temp_dir="$(qb_temp_dir)"

  # 确保有 [Preferences] 段
  if ! grep -q '^\[Preferences\]' "$conf"; then
    echo -e "\n[Preferences]" >> "$conf"
  fi

  # 用 sed 更新/插入配置键（避免重复）
  set_kv() {
    local key="$1"
    local value="$2"
    if grep -qE "^${key}=" "$conf"; then
      sed -i "s#^${key}=.*#${key}=${value}#g" "$conf"
    else
      # 插入到 [Preferences] 后面
      awk -v k="$key" -v v="$value" '
        BEGIN{added=0}
        {print}
        $0=="[Preferences]" && added==0 {print k"="v; added=1}
      ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi
  }

  # 下载目录：指向 OpenList 共享临时目录
  set_kv 'Downloads\\SavePath' "$temp_dir"

  # 不做种：完成后停止/暂停（尽量通用）
  set_kv 'Bittorrent\\MaxRatio' "0"
  set_kv 'Bittorrent\\MaxSeedingTime' "0"
  set_kv 'Bittorrent\\MaxRatioAction' "0"

  echo
  echo "已写入：下载目录=$temp_dir，且设置不做种(比率0/时间0)。"
  echo "建议你也进入 qB WebUI 再确认一次：设置 -> BitTorrent/下载。"
  echo
}

show_summary() {
  local data_dir temp_dir conf
  data_dir="$(detect_openlist_data_dir)"
  temp_dir="$(qb_temp_dir)"
  conf="$(qb_conf_file)"

  echo
  echo "================= 配置信息 ================="
  echo "OpenList data dir : $data_dir"
  echo "qB 临时目录       : $temp_dir"
  echo "qB WebUI          : http://127.0.0.1:${QB_PORT}"
  echo "qB Profile        : $QB_PROFILE"
  echo "qB 配置文件       : $conf"
  echo "============================================"
  echo
  echo "OpenList 后台 qBittorrent URL 示例："
  echo "  http://用户名:密码@127.0.0.1:${QB_PORT}/"
  echo
}

# ========= 功能实现 =========
install_qb() {
  need_root
  echo "[1/3] 安装 qbittorrent-nox（不执行 apt update）..."
  apt-get install -y qbittorrent-nox >/dev/null

  echo "[2/3] 创建目录（独立目录 + OpenList 临时目录）..."
  ensure_dirs

  echo "[3/3] 写入 systemd 服务并启动..."
  write_systemd_service
  systemctl daemon-reload
  systemctl enable --now qbittorrent >/dev/null

  echo
  echo "qB 已启动。建议首次打开 WebUI 设置用户名/密码："
  echo "  http://你的服务器IP:${QB_PORT}"
  echo "如果你只在服务器本机访问： http://127.0.0.1:${QB_PORT}"
  echo
  echo "然后回到本脚本，选择“2：写入(不做种 + 下载目录)”来自动配置。"
  echo
  systemctl status qbittorrent --no-pager -l || true
  show_summary
  pause
}

write_settings() {
  need_root
  ensure_dirs
  # 如果服务未运行，先启动一次生成配置（不同版本生成时机不同）
  if ! systemctl is-active --quiet qbittorrent; then
    systemctl start qbittorrent >/dev/null 2>&1 || true
    sleep 2
  fi

  # 等待配置文件出现（最多 10 秒）
  local conf
  conf="$(qb_conf_file)"
  for _ in {1..10}; do
    [[ -f "$conf" ]] && break
    sleep 1
  done
  [[ -f "$conf" ]] || die "qB 配置文件仍未生成：$conf。请先运行一次：systemctl start qbittorrent，然后再试。"

  apply_no_seed_and_paths

  systemctl restart qbittorrent >/dev/null 2>&1 || true
  echo "已重启 qBittorrent 使配置生效。"
  show_summary
  pause
}

uninstall_qb() {
  need_root
  echo "停止并禁用 qbittorrent 服务..."
  systemctl disable --now qbittorrent >/dev/null 2>&1 || true
  rm -f "$QB_SERVICE" || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  echo "卸载 qbittorrent-nox（apt purge）..."
  apt-get purge -y qbittorrent-nox >/dev/null 2>&1 || true

  echo "删除 qB 独立目录：$QB_BASE"
  rm -rf "$QB_BASE" || true

  local temp_dir
  temp_dir="$(qb_temp_dir)"
  echo
  read -r -p "是否同时删除 OpenList 临时目录 $temp_dir ？(y/N): " yn
  if [[ "${yn,,}" == "y" ]]; then
    rm -rf "$temp_dir" || true
    echo "已删除：$temp_dir"
  else
    echo "保留：$temp_dir"
  fi

  echo "卸载完成。"
  pause
}

service_status() {
  need_root
  echo "---- qbittorrent 服务状态 ----"
  systemctl status qbittorrent --no-pager -l || true
  echo
  echo "---- 端口监听 ----"
  ss -lntp | grep -E "(:${QB_PORT}|qbittorrent)" || true
  echo
  pause
}

start_service() { need_root; systemctl start qbittorrent;  echo "已启动。"; pause; }
stop_service()  { need_root; systemctl stop qbittorrent;   echo "已停止。"; pause; }
restart_service(){ need_root; systemctl restart qbittorrent;echo "已重启。"; pause; }

reset_profile() {
  need_root
  read -r -p "这会删除 $QB_BASE（包括登录信息/设置）。确认继续？(y/N): " yn
  [[ "${yn,,}" == "y" ]] || { echo "取消。"; pause; return; }

  systemctl stop qbittorrent >/dev/null 2>&1 || true
  rm -rf "$QB_BASE"
  ensure_dirs
  systemctl start qbittorrent >/dev/null 2>&1 || true

  echo
  echo "已重置 qB profile。请重新打开 WebUI 设置账号密码。"
  show_summary
  pause
}

show_info() { show_summary; pause; }

# ========= 菜单 =========
menu() {
  clear
  echo "欢迎使用 qBittorrent(OpenList 离线下载) 管理脚本"
  echo
  echo "基础功能："
  echo "  1、安装 qBittorrent-nox（不更新系统）"
  echo "  2、写入配置：不做种 + 下载目录指向 OpenList 临时目录"
  echo "  3、卸载 qBittorrent-nox"
  echo "------------------------------------"
  echo "服务管理："
  echo "  4、查看状态"
  echo "  5、启动 qBittorrent"
  echo "  6、停止 qBittorrent"
  echo "  7、重启 qBittorrent"
  echo "------------------------------------"
  echo "维护工具："
  echo "  8、重置 qB 配置目录（删除 /root/qb）"
  echo "  9、显示配置信息（WebUI/目录/路径）"
  echo "------------------------------------"
  echo "  0、退出脚本"
  echo
}

main() {
  need_root
  while true; do
    menu
    read -r -p "请输入选项 [0-9]: " opt
    case "$opt" in
      1) install_qb ;;
      2) write_settings ;;
      3) uninstall_qb ;;
      4) service_status ;;
      5) start_service ;;
      6) stop_service ;;
      7) restart_service ;;
      8) reset_profile ;;
      9) show_info ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项：$opt"; pause ;;
    esac
  done
}

main "$@"
