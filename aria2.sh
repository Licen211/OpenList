#!/usr/bin/env bash
set -euo pipefail

# ========= 基本配置（你可按需改） =========
ARIA2_BASE="/root/aria2"
ARIA2_CONF_DIR="$ARIA2_BASE/conf"
ARIA2_CONF="$ARIA2_CONF_DIR/aria2.conf"
ARIA2_SESSION_DIR="$ARIA2_BASE/session"
ARIA2_LOG_DIR="$ARIA2_BASE/logs"
ARIA2_SERVICE="/etc/systemd/system/aria2.service"
ARIA2_PORT="6800"

# ========= 工具函数 =========
die() { echo -e "\n[错误] $*\n" >&2; exit 1; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "请用 sudo 运行：sudo bash $0"; }
have_cmd() { command -v "$1" >/dev/null 2>&1; }

pause() { read -r -p "按回车继续..." _; }

rand_secret() {
  if have_cmd openssl; then
    openssl rand -hex 16
  else
    head -c 32 /dev/urandom | xxd -p -c 32
  fi
}

# 尝试从 systemd openlist 服务里提取 data-dir；提取不到就用 /opt/openlist/data
detect_openlist_data_dir() {
  local data_dir=""
  if systemctl cat openlist >/dev/null 2>&1; then
    local exe
    exe="$(systemctl cat openlist | sed -n 's/^ExecStart=//p' | head -n 1 || true)"
    data_dir="$(echo "$exe" | sed -n 's/.*--data-dir[= ]\\([^ ]*\\).*/\\1/p' | head -n 1 || true)"
  fi
  [[ -n "$data_dir" ]] || data_dir="/opt/openlist/data"
  echo "$data_dir"
}

get_temp_aria2_dir() {
  local data_dir
  data_dir="$(detect_openlist_data_dir)"
  echo "$data_dir/temp/aria2"
}

get_current_secret() {
  [[ -f "$ARIA2_CONF" ]] || { echo ""; return; }
  grep -E '^rpc-secret=' "$ARIA2_CONF" | head -n 1 | cut -d= -f2- || true
}

write_aria2_conf() {
  local temp_aria2_dir="$1"
  local secret="$2"

  mkdir -p "$ARIA2_CONF_DIR" "$ARIA2_SESSION_DIR" "$ARIA2_LOG_DIR"
  touch "$ARIA2_SESSION_DIR/aria2.session"
  mkdir -p "$temp_aria2_dir"

  cat > "$ARIA2_CONF" <<EOF
enable-rpc=true
rpc-listen-all=false
rpc-listen-port=$ARIA2_PORT
rpc-secret=$secret
rpc-allow-origin-all=true

# 给 OpenList 离线下载用：必须与 OpenList 共享目录（自动上传依赖）
dir=$temp_aria2_dir

input-file=$ARIA2_SESSION_DIR/aria2.session
save-session=$ARIA2_SESSION_DIR/aria2.session
save-session-interval=60
continue=true
file-allocation=none

# 磁力/BT
enable-dht=true
enable-dht6=true
bt-save-metadata=true
follow-torrent=true

# 不做种（下载完就停）
bt-seed-time=0
seed-ratio=0.0

log=$ARIA2_LOG_DIR/aria2.log
log-level=notice
EOF

  chmod 600 "$ARIA2_CONF"
}

write_systemd_service() {
  cat > "$ARIA2_SERVICE" <<EOF
[Unit]
Description=aria2 RPC for OpenList
After=network.target

[Service]
User=root
ExecStart=/usr/bin/aria2c --conf-path=$ARIA2_CONF
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
}

show_summary() {
  local data_dir temp_dir secret
  data_dir="$(detect_openlist_data_dir)"
  temp_dir="$(get_temp_aria2_dir)"
  secret="$(get_current_secret)"

  echo
  echo "================= 配置信息 ================="
  echo "OpenList data dir : $data_dir"
  echo "aria2 临时目录    : $temp_dir"
  echo "aria2 RPC URL     : http://127.0.0.1:${ARIA2_PORT}/jsonrpc"
  echo "aria2 RPC secret  : ${secret:-<未设置>}"
  echo "aria2 配置文件    : $ARIA2_CONF"
  echo "============================================"
  echo
  echo "OpenList 后台【其他设置/下载器设置 -> Aria2】填写："
  echo "  地址：http://127.0.0.1:${ARIA2_PORT}/jsonrpc"
  echo "  密钥：上面的 secret"
  echo
}

# ========= 功能实现 =========
install_aria2() {
  need_root
  echo "[1/4] 安装 aria2（apt）..."
  apt update -y >/dev/null
  apt install -y aria2 >/dev/null

  local temp_dir secret
  temp_dir="$(get_temp_aria2_dir)"
  secret="$(rand_secret)"

  echo "[2/4] 写入配置到 $ARIA2_CONF ..."
  write_aria2_conf "$temp_dir" "$secret"

  echo "[3/4] 写入 systemd 服务..."
  write_systemd_service
  systemctl daemon-reload
  systemctl enable --now aria2 >/dev/null

  echo "[4/4] 启动检查..."
  systemctl status aria2 --no-pager -l || true
  show_summary
  pause
}

update_aria2() {
  need_root
  echo "更新 aria2（apt）..."
  apt update -y >/dev/null
  apt install -y --only-upgrade aria2 >/dev/null
  systemctl restart aria2 >/dev/null 2>&1 || true
  echo "完成。"
  pause
}

uninstall_aria2() {
  need_root
  echo "停止并禁用 aria2 服务..."
  systemctl disable --now aria2 >/dev/null 2>&1 || true
  rm -f "$ARIA2_SERVICE" || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  echo "卸载 aria2（apt purge）..."
  apt purge -y aria2 >/dev/null 2>&1 || true

  echo "删除 aria2 自建目录：$ARIA2_BASE"
  rm -rf "$ARIA2_BASE" || true

  local temp_dir
  temp_dir="$(get_temp_aria2_dir)"
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
  echo "---- aria2 服务状态 ----"
  systemctl status aria2 --no-pager -l || true
  echo
  echo "---- 端口监听 ----"
  ss -lntp | grep -E "(:${ARIA2_PORT}|aria2)" || true
  echo
  pause
}

start_service() { need_root; systemctl start aria2;  echo "已启动。"; pause; }
stop_service()  { need_root; systemctl stop aria2;   echo "已停止。"; pause; }
restart_service(){ need_root; systemctl restart aria2;echo "已重启。"; pause; }

change_secret() {
  need_root
  [[ -f "$ARIA2_CONF" ]] || die "找不到 $ARIA2_CONF（请先安装）"

  local old new choice
  old="$(get_current_secret)"
  echo "当前 secret：${old:-<未设置>}"
  echo
  echo "1. 手动输入新的 secret"
  echo "2. 自动生成随机 secret"
  read -r -p "请选择 [1-2]: " choice

  if [[ "$choice" == "1" ]]; then
    read -r -p "输入新的 secret（建议 16 位以上随机）: " new
    [[ -n "$new" ]] || die "secret 不能为空"
  else
    new="$(rand_secret)"
    echo "生成的 secret：$new"
  fi

  if grep -qE '^rpc-secret=' "$ARIA2_CONF"; then
    sed -i "s/^rpc-secret=.*/rpc-secret=$new/" "$ARIA2_CONF"
  else
    sed -i "/^rpc-listen-port=/a rpc-secret=$new" "$ARIA2_CONF"
  fi

  systemctl restart aria2 >/dev/null 2>&1 || true
  echo
  echo "已修改并重启 aria2。"
  echo "新的 secret：$new"
  echo "记得同步到 OpenList 后台 Aria2 密钥。"
  pause
}

show_info() { show_summary; pause; }

# ========= 菜单 =========
menu() {
  clear
  echo "欢迎使用 aria2(OpenList 离线下载) 管理脚本"
  echo
  echo "基础功能："
  echo "  1、安装 aria2（配 OpenList 离线下载自动上传）"
  echo "  2、更新 aria2"
  echo "  3、卸载 aria2"
  echo "------------------------------------"
  echo "服务管理："
  echo "  4、查看状态"
  echo "  5、修改 Aria2 密钥"
  echo "  6、启动 aria2"
  echo "  7、停止 aria2"
  echo "  8、重启 aria2"
  echo "------------------------------------"
  echo "配置查看："
  echo "  9、显示配置信息（URL/secret/目录）"
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
      1) install_aria2 ;;
      2) update_aria2 ;;
      3) uninstall_aria2 ;;
      4) service_status ;;
      5) change_secret ;;
      6) start_service ;;
      7) stop_service ;;
      8) restart_service ;;
      9) show_info ;;
      0) echo "退出。"; exit 0 ;;
      *) echo "无效选项：$opt"; pause ;;
    esac
  done
}

main "$@"
