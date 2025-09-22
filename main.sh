#!/usr/bin/env bash
# ================================================================
# VXLAN Tunnel Manager v1.3Pro (Multi IR <-> EU, IPv4 + IPv6)
# Author: PooyaServerSup
#
# Features:
#   - Multi VXLAN IR (up to 10 tunnels) for IPv4 and IPv6 (6to4)
#   - Multi GRE EU (up to 10 tunnels) for IPv4 (Mikrotik)
#   - Single VXLAN EU (IPv4 or IPv6)
#   - Auto-detect local device & public IP
#   - Config saved in /etc/vxlan-manager.conf
#   - systemd persistence + health-check
#   - HAProxy installer option
# ================================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
NC='\033[0m'

set -euo pipefail

CONF_FILE="/etc/vxlan-manager.conf"
UP_SCRIPT="/usr/local/sbin/vxlan-up.sh"
DOWN_SCRIPT="/usr/local/sbin/vxlan-down.sh"
HC_SCRIPT="/usr/local/sbin/vxlan-health.sh"
SVC_FILE="/etc/systemd/system/vxlan-manager.service"
SVC_HEALTH="/etc/systemd/system/vxlan-health.service"
TIMER_FILE="/etc/systemd/system/vxlan-health.timer"

require_root() { [ "$(id -u)" -eq 0 ] || { echo "[!] Run as root (sudo)"; exit 1; }; }

ask() {
  local prompt="$1" default="$2" value
  read -rp "$prompt [$default]: " value
  echo "${value:-$default}"
}

auto_detect_dev() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

auto_detect_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

apt install jq -y

banner() {
  clear
  SERVER_IP=$(hostname -I | awk '{print $1}')
  SERVER_COUNTRY=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.country')
  SERVER_ISP=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.isp')
  echo "======================================================"
  echo "             VXLAN Tunnel Manager v1.3Pro"
  echo "             PooyaServerSup"
  echo "======================================================"
  echo -e "|${GREEN}Server Country |${NC} $SERVER_COUNTRY"
  echo " Hostname     : $(hostname)"
  echo " Kernel       : $(uname -r)"
  echo " Local Pub IP : $(auto_detect_ip)"
  echo " Device       : $(auto_detect_dev)"
  echo -e "|${GREEN}Server ISP |${NC} $SERVER_ISP"
  echo "======================================================"
}

save_config() {
  cat > "$CONF_FILE" <<EOF
TUNNELS=(${TUNNELS[@]-})
TUNNELS_V6=(${TUNNELS_V6[@]-})
GRE_TUNNELS=(${GRE_TUNNELS[@]-})
EOF
  chmod 600 "$CONF_FILE"
}

load_config() { [ -f "$CONF_FILE" ] && source "$CONF_FILE" || true; }

# ------------------ UP / DOWN scripts ------------------

create_up_script() {
  cat > "$UP_SCRIPT" <<'EOS'
#!/usr/bin/env bash
set -e
. /etc/vxlan-manager.conf

# VXLAN IPv4 tunnels
for t in "${TUNNELS[@]-}"; do
  IFS=":" read IF_NAME VNI PORT LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP <<< "$t"
  [ -z "$REMOTE_IP" ] && continue
  if ! ip link show "$IF_NAME" >/dev/null 2>&1; then
    modprobe vxlan || true
    ip link add "$IF_NAME" type vxlan id "$VNI" \
      dev "$(ip route get $REMOTE_IP | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')" \
      local "$LOCAL_IP" remote "$REMOTE_IP" dstport "$PORT" nolearning
    ip addr add "$LOCAL_TUN_IP" dev "$IF_NAME"
    bridge fdb append 00:00:00:00:00:00 dev "$IF_NAME" dst "$REMOTE_IP"
  fi
  ip link set "$IF_NAME" up
done

# VXLAN IPv6 tunnels
for t in "${TUNNELS_V6[@]-}"; do
  IFS=":" read IF_NAME VNI PORT LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP <<< "$t"
  [ -z "$REMOTE_IP" ] && continue
  if ! ip link show "$IF_NAME" >/dev/null 2>&1; then
    modprobe vxlan || true
    ip link add "$IF_NAME" type vxlan id "$VNI" \
      dev "$(ip route get $REMOTE_IP | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')" \
      local "$LOCAL_IP" remote "$REMOTE_IP" dstport "$PORT" nolearning
    ip -6 addr add "$LOCAL_TUN_IP" dev "$IF_NAME"
    bridge fdb append 00:00:00:00:00:00 dev "$IF_NAME" dst "$REMOTE_IP"
  fi
  ip link set "$IF_NAME" up
done

# GRE tunnels
for g in "${GRE_TUNNELS[@]-}"; do
  IFS=":" read IF_NAME LOCAL_IP MT_PUBLIC UB_TUN_IP MT_TUN_IP <<< "$g"
  [ -z "$MT_PUBLIC" ] && continue
  if ! ip link show "$IF_NAME" >/dev/null 2>&1; then
    ip tunnel add "$IF_NAME" mode gre local "$LOCAL_IP" remote "$MT_PUBLIC" ttl 255
    ip addr add "$UB_TUN_IP" dev "$IF_NAME"
  fi
  ip link set "$IF_NAME" up
done
EOS
  chmod +x "$UP_SCRIPT"
}

create_down_script() {
  cat > "$DOWN_SCRIPT" <<'EOS'
#!/usr/bin/env bash
. /etc/vxlan-manager.conf

# Delete VXLAN IPv4
for t in "${TUNNELS[@]-}"; do
  IF_NAME=$(echo "$t" | cut -d: -f1)
  [ -n "$IF_NAME" ] && ip link del "$IF_NAME" 2>/dev/null || true
done

# Delete VXLAN IPv6
for t in "${TUNNELS_V6[@]-}"; do
  IF_NAME=$(echo "$t" | cut -d: -f1)
  [ -n "$IF_NAME" ] && ip link del "$IF_NAME" 2>/dev/null || true
done

# Delete GRE
for g in "${GRE_TUNNELS[@]-}"; do
  IF_NAME=$(echo "$g" | cut -d: -f1)
  [ -n "$IF_NAME" ] && ip tunnel del "$IF_NAME" 2>/dev/null || true
done
EOS
  chmod +x "$DOWN_SCRIPT"
}

create_service() {
  cat > "$SVC_FILE" <<EOF
[Unit]
Description=VXLAN + GRE Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UP_SCRIPT
ExecStop=$DOWN_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now vxlan-manager.service
}

create_healthcheck() {
  cat > "$HC_SCRIPT" <<'EOS'
#!/usr/bin/env bash
. /etc/vxlan-manager.conf
for t in "${TUNNELS[@]}" "${TUNNELS_V6[@]}"; do
  REMOTE_TUN_IP=$(echo "$t" | cut -d: -f7)
  if ! ping -c1 -W2 "$REMOTE_TUN_IP" >/dev/null 2>&1; then
    systemctl restart vxlan-manager.service
    exit 0
  fi
done
EOS
  chmod +x "$HC_SCRIPT"

  cat > "$SVC_HEALTH" <<EOF
[Unit]
Description=VXLAN tunnel health check
[Service]
Type=oneshot
ExecStart=$HC_SCRIPT
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run VXLAN health check every 30s
[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=vxlan-health.service
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now vxlan-health.timer
}

# ------------------ Install Functions ------------------

install_multi_ir_v4() {
  banner
  echo "[*] Configure Multi VXLAN IR (IPv4)"
  local LOCAL_IP=$(auto_detect_ip)

  local count
  count=$(ask "How many EU peers (1-10)" "2")
  TUNNELS=()
  for i in $(seq 1 "$count"); do
    echo "--- Peer $i ---"
    IF_NAME=$(ask "VXLAN interface name" "vxlan1$i")
    VNI=$(ask "VXLAN ID" "100$i")
    PORT=$(ask "UDP port" "443")
    REMOTE_IP=$(ask "Remote PUBLIC IPv4 (EU $i)" "")
    LOCAL_TUN_IP=$(ask "Local tunnel IP (e.g., 192.168.$i.1/30)" "")
    REMOTE_TUN_IP=$(ask "Remote tunnel IP (e.g., 192.168.$i.2)" "")
    TUNNELS+=("$IF_NAME:$VNI:$PORT:$LOCAL_IP:$REMOTE_IP:$LOCAL_TUN_IP:$REMOTE_TUN_IP")
  done

  save_config
  create_up_script
  create_down_script
  create_service
  create_healthcheck
  echo "[+] Multi IPv4 VXLAN IR configured."
}

install_multi_ir_v6() {
  banner
  echo "[*] Configure Multi VXLAN IR (IPv6 6to4)"
  local LOCAL_IP=$(auto_detect_ip)

  local count
  count=$(ask "How many EU peers (1-10)" "2")
  TUNNELS_V6=()
  for i in $(seq 1 "$count"); do
    echo "--- Peer $i ---"
    IF_NAME=$(ask "VXLAN interface name" "vxlan6$i")
    VNI=$(ask "VXLAN ID" "200$i")
    PORT=$(ask "UDP port" "443")
    REMOTE_IP=$(ask "Remote PUBLIC IPv4 (EU $i)" "")
    LOCAL_TUN_IP=$(ask "Local tunnel IPv6 (e.g., fd00:$i::1/64)" "")
    REMOTE_TUN_IP=$(ask "Remote tunnel IPv6 (e.g., fd00:$i::2)" "")
    TUNNELS_V6+=("$IF_NAME:$VNI:$PORT:$LOCAL_IP:$REMOTE_IP:$LOCAL_TUN_IP:$REMOTE_TUN_IP")
  done

  save_config
  create_up_script
  create_down_script
  create_service
  create_healthcheck
  echo "[+] Multi IPv6 VXLAN IR configured."
}

install_eu_v4() {
  banner
  echo "[*] Configure VXLAN EU (IPv4)"
  local LOCAL_IP=$(auto_detect_ip)

  IF_NAME=$(ask "VXLAN interface name" "vxlan10")
  VNI=$(ask "VXLAN ID" "10")
  PORT=$(ask "UDP port" "443")
  REMOTE_IP=$(ask "Remote PUBLIC IPv4 (IR server)" "")
  LOCAL_TUN_IP=$(ask "Local tunnel IP (e.g., 192.168.50.2/30)" "")
  REMOTE_TUN_IP=$(ask "Remote tunnel IP (e.g., 192.168.50.1)" "")

  TUNNELS=("$IF_NAME:$VNI:$PORT:$LOCAL_IP:$REMOTE_IP:$LOCAL_TUN_IP:$REMOTE_TUN_IP")

  save_config
  create_up_script
  create_down_script
  create_service
  create_healthcheck
  echo "[+] VXLAN EU IPv4 configured."
}

install_eu_v6() {
  banner
  echo "[*] Configure VXLAN EU (IPv6 6to4)"
  local LOCAL_IP=$(auto_detect_ip)

  IF_NAME=$(ask "VXLAN interface name" "vxlan20")
  VNI=$(ask "VXLAN ID" "20")
  PORT=$(ask "UDP port" "443")
  REMOTE_IP=$(ask "Remote PUBLIC IPv4 (IR server)" "")
  LOCAL_TUN_IP=$(ask "Local tunnel IPv6 (e.g., fd00:50::2/64)" "")
  REMOTE_TUN_IP=$(ask "Remote tunnel IPv6 (e.g., fd00:50::1)" "")

  TUNNELS_V6=("$IF_NAME:$VNI:$PORT:$LOCAL_IP:$REMOTE_IP:$LOCAL_TUN_IP:$REMOTE_TUN_IP")

  save_config
  create_up_script
  create_down_script
  create_service
  create_healthcheck
  echo "[+] VXLAN EU IPv6 configured."
}

# ------------------ Other Functions ------------------

status() {
  load_config
  echo "---------------- STATUS ----------------"

  # VXLAN IPv4 tunnels
  for t in "${TUNNELS[@]-}"; do
    IFS=":" read IF_NAME VNI PORT LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP <<< "$t"
    echo "Interface : $IF_NAME (VXLAN IPv4) -> $REMOTE_IP"
    ip link show "$IF_NAME" >/dev/null 2>&1 && echo "Status    : UP" || echo "Status    : DOWN"
    echo "Local Tun : $LOCAL_TUN_IP"
    echo "Remote Tun: $REMOTE_TUN_IP"
    echo "--------------------------------------"
  done

  # VXLAN IPv6 tunnels
  for t in "${TUNNELS_V6[@]-}"; do
    IFS=":" read IF_NAME VNI PORT LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP <<< "$t"
    echo "Interface : $IF_NAME (VXLAN IPv6) -> $REMOTE_IP"
    ip link show "$IF_NAME" >/dev/null 2>&1 && echo "Status    : UP" || echo "Status    : DOWN"
    echo "Local Tun : $LOCAL_TUN_IP"
    echo "Remote Tun: $REMOTE_TUN_IP"
    echo "--------------------------------------"
  done

  # GRE tunnels
  for g in "${GRE_TUNNELS[@]-}"; do
    IFS=":" read IF_NAME LOCAL_IP MT_PUBLIC UB_TUN_IP MT_TUN_IP <<< "$g"
    echo "Interface : $IF_NAME (GRE) -> $MT_PUBLIC"
    ip link show "$IF_NAME" >/dev/null 2>&1 && echo "Status    : UP" || echo "Status    : DOWN"
    echo "Local Tun : $UB_TUN_IP"
    echo "Remote Tun: $MT_TUN_IP"
    echo "--------------------------------------"
  done
}

delete_all() {
  echo "[i] Stopping services and removing files..."
  systemctl disable --now vxlan-manager.service >/dev/null 2>&1 || true
  systemctl disable --now vxlan-health.timer >/dev/null 2>&1 || true

  # Delete VXLAN IPv4 interfaces
  for t in "${TUNNELS[@]-}"; do
    IF_NAME=$(echo "$t" | cut -d: -f1)
    ip link del "$IF_NAME" 2>/dev/null || true
  done

  # Delete VXLAN IPv6 interfaces
  for t in "${TUNNELS_V6[@]-}"; do
    IF_NAME=$(echo "$t" | cut -d: -f1)
    ip link del "$IF_NAME" 2>/dev/null || true
  done

  # Delete GRE interfaces

  rm -f "$CONF_FILE" "$UP_SCRIPT" "$DOWN_SCRIPT" "$HC_SCRIPT" \
        "$SVC_FILE" "$SVC_HEALTH" "$TIMER_FILE"
  systemctl daemon-reload
  echo "[+] VXLAN/GRE completely removed."
}

health_check() {
  load_config
  echo "----- Health Check -----"

  # VXLAN IPv4 & IPv6
  for t in "${TUNNELS[@]-}" "${TUNNELS_V6[@]-}"; do
    [ -z "$t" ] && continue
    REMOTE_TUN_IP=$(echo "$t" | cut -d: -f7)
    if ping -c1 -W2 "$REMOTE_TUN_IP" >/dev/null 2>&1; then
      echo "[OK] $REMOTE_TUN_IP reachable"
    else
      echo "[FAIL] $REMOTE_TUN_IP unreachable"
    fi
  done

  # GRE tunnels
  for g in "${GRE_TUNNELS[@]-}"; do
    [ -z "$g" ] && continue
    REMOTE_TUN_IP=$(echo "$g" | cut -d: -f5)
    if ping -c1 -W2 "$REMOTE_TUN_IP" >/dev/null 2>&1; then
      echo "[OK] $REMOTE_TUN_IP reachable"
    else
      echo "[FAIL] $REMOTE_TUN_IP unreachable"
    fi
  done
}

install_haproxy() {
  banner
  echo "[*] Installing HAProxy..."
  bash <(curl -Ls https://raw.githubusercontent.com/dev-ir/HAProxy/master/main.sh)
  echo "[+] HAProxy installed."
}

install_gost() {
  banner
  echo "[*] Installing HAProxy..."
  bash <(curl -Ls https://raw.githubusercontent.com/masoudgb/Gost-ip6/main/install.sh)
  echo "[+] HAProxy installed."
}

enable_bbr() {
  banner
  echo "[*] Enabling BBR congestion control..."
  modprobe tcp_bbr || true
  {
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
  } >> /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
  sysctl net.ipv4.tcp_congestion_control
  echo "[+] BBR enabled successfully."
  read -rp "Press Enter..." _
}

update_script() {
  banner
  echo "[*] Updating VXLAN Manager..."
  URL="https://raw.githubusercontent.com/pooyaserver/vxlan/master/main.sh"
  curl -sSL "$URL" -o /usr/local/bin/vxlan-manager.sh
  chmod +x /usr/local/bin/vxlan-manager.sh
  echo "[+] Script updated to latest version."
  read -rp "Press Enter..." _
}

gre_menu() {
  while true; do
    clear
    echo "================ GRE TUNNEL MANAGER ================"
    echo "1) Add GRE tunnel (Ubuntu ↔ MikroTik)"
    echo "2) Delete GRE tunnel"
    echo "3) List GRE tunnels"
    echo "0) Back"
    echo "---------------------------------------------------"
    read -rp "Select: " gop
    case "$gop" in
      1) add_gre ;;
      2) del_gre ;;
      3) list_gre ;;
      0) break ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

add_gre() {
  banner
  echo "[*] Add GRE Tunnel (Ubuntu ↔ MikroTik)"

  LOCAL_IP=$(auto_detect_ip)
  DEV=$(auto_detect_dev)

  # اسم تونل
  IF_NAME=$(ask "GRE interface name" "gre1")

  if [ -z "$IF_NAME" ]; then
    echo "[!] GRE interface name cannot be empty."
    read -rp "Press Enter..." _
    return
  fi

  # چک کن وجود نداشته باشه
  if ip link show "$IF_NAME" >/dev/null 2>&1; then
    echo "[!] GRE interface $IF_NAME already exists. Choose another name."
    read -rp "Press Enter..." _
    return
  fi

  # ورودی‌های کاربر
  MT_PUBLIC=$(ask "MikroTik PUBLIC IPv4" "")
  UB_TUN_IP=$(ask "Ubuntu tunnel IP (e.g., 192.168.10.2/30)" "")
  MT_TUN_IP=$(ask "MikroTik tunnel IP (e.g., 192.168.10.1)" "")
  MT_TUN_IP2=$(ask "Ubuntu tunnel IP (e.g., 192.168.10.2)" "")

  # ساخت تونل
  if ! ip tunnel add "$IF_NAME" mode gre local "$LOCAL_IP" remote "$MT_PUBLIC" dev "$DEV" ttl 255; then
    echo "[!] Failed to create GRE tunnel $IF_NAME"
    read -rp "Press Enter..." _
    return
  fi

  ip addr add "$UB_TUN_IP" dev "$IF_NAME"
  ip link set "$IF_NAME" up

  # ذخیره در آرایه
  GRE_TUNNELS+=("$IF_NAME:$LOCAL_IP:$MT_PUBLIC:$UB_TUN_IP:$MT_TUN_IP:$MT_TUN_IP2")
  save_config

  # نمایش دستورات برای میکروتیک
  echo "[+] GRE tunnel $IF_NAME created successfully."
  echo "======================================================"
  echo " MikroTik RouterOS commands for $IF_NAME"
  echo "======================================================"
  echo "/interface gre add name=$IF_NAME remote-address=$LOCAL_IP local-address=$MT_PUBLIC mtu=1476"
  echo "/ip address add address=$MT_TUN_IP/30 interface=$IF_NAME"
  echo "/ip firewall nat add chain=srcnat out-interface=$IF_NAME action=masquerade comment=\"NAT for $IF_NAME\""
  echo "/ip firewall nat add chain=srcnat action=masquerade"

  PORTS=$(ask "Enter ports for DST-NAT (comma separated, e.g. 80,443,1194)" "")
  if [ -n "$PORTS" ]; then
    IFS=',' read -ra PORT_LIST <<< "$PORTS"
    for PORT in "${PORT_LIST[@]}"; do
      PORT=$(echo "$PORT" | xargs)
      echo "/ip firewall nat add chain=dstnat protocol=tcp dst-port=$PORT action=dst-nat to-addresses=$MT_TUN_IP2"
      echo "/ip firewall nat add chain=dstnat protocol=udp dst-port=$PORT action=dst-nat to-addresses=$MT_TUN_IP2"
    done
  fi
  echo "======================================================"
  read -rp "Press Enter..." _
}

del_gre() {
  banner
  echo "[*] Delete GRE Tunnel"
  read -rp "Enter GRE interface name to delete: " IF_NAME

  # اگر وجود نداشت، خطا نده
  if ! ip link show "$IF_NAME" >/dev/null 2>&1; then
    echo "[!] GRE interface $IF_NAME not found."
    read -rp "Press Enter..." _
    return
  fi

  # حذف تونل از کرنل
  ip tunnel del "$IF_NAME" 2>/dev/null || true

  # حذف رکورد از GRE_TUNNELS در کانفیگ
  safe_load
  NEW_GRE_TUNNELS=()
  for g in "${GRE_TUNNELS[@]-}"; do
    NAME=$(echo "$g" | cut -d: -f1)
    if [ "$NAME" != "$IF_NAME" ]; then
      NEW_GRE_TUNNELS+=("$g")
    fi
  done
  GRE_TUNNELS=("${NEW_GRE_TUNNELS[@]}")
  save_config

  echo "[+] GRE tunnel $IF_NAME deleted successfully."
  read -rp "Press Enter..." _
}


list_gre() {
  banner
  echo "---------------- GRE STATUS ----------------"
  for g in "${GRE_TUNNELS[@]-}"; do
    IFS=":" read IF_NAME LOCAL_IP MT_PUBLIC UB_TUN_IP MT_TUN_IP <<< "$g"
    echo "Interface : $IF_NAME (GRE) -> $MT_PUBLIC"
    ip link show "$IF_NAME" >/dev/null 2>&1 && echo "Status    : UP" || echo "Status    : DOWN"
    echo "Local Tun : $UB_TUN_IP"
    echo "Remote Tun: $MT_TUN_IP"
    echo "-------------------------------------------"
  done
  read -rp "Press Enter..." _
}

# ------------------ Menu (ORIGINAL + one new option 9) ------------------

menu() {
  require_root
  while true; do
    banner
    echo "1) Install Multi VXLAN IR (IPv4)"
    echo "2) Install Multi VXLAN IR (IPv6 / 6to4)"
    echo "3) Install VXLAN EU (IPv4)"
    echo "4) Install VXLAN EU (IPv6 / 6to4)"
    echo "5) GRE Tunnel Manager (Add/Delete/List)"
    echo "6) Install HAProxy"
    echo "7) Install GostTunnel"
    echo "8) Status"
    echo "9) Delete"
    echo "10) Health Check"
    echo "11) Advanced Tools"
    echo "12) Enable BBR"
    echo "13) Update Script"
    echo "0) Exit"
    echo "------------------------------------------"
    read -rp "Enter option: " op
    case "$op" in
      1) install_multi_ir_v4 ; read -rp "Press Enter..." _ ;;
      2) install_multi_ir_v6 ; read -rp "Press Enter..." _ ;;
      3) install_eu_v4 ; read -rp "Press Enter..." _ ;;
      4) install_eu_v6 ; read -rp "Press Enter..." _ ;;
      5) gre_menu ; read -rp "Press Enter..." _ ;;
      6) install_haproxy ; read -rp "Press Enter..." _ ;;
      7) install_gost ; read -rp "Press Enter..." _ ;;
      8) status ; read -rp "Press Enter..." _ ;;
      9) delete_all ; read -rp "Press Enter..." _ ;;
      10) health_check ; read -rp "Press Enter..." _ ;;
      11) advanced_menu ;;
      12) enable_bbr ;;
      13) update_script ;;
      0) exit 0 ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

# =======================================================================
# =======================  ADD-ON FEATURES  =============================
# =======================================================================
# هیچ‌کدوم از فانکشن‌های بالا تغییر نکردن؛ از اینجا به بعد فقط «اضافه» است.

LOG_FILE="/var/log/vxlan-manager.log"
CONF_JSON="/etc/vxlan-manager.json"
CONF_BAK="/etc/vxlan-manager.conf.bak"
SMART_HC="/usr/local/sbin/vxlan-health-smart.sh"
SMART_SVC="/etc/systemd/system/vxlan-health-smart.service"
SMART_TIMER="/etc/systemd/system/vxlan-health-smart.timer"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
safe_load() { [ -f "$CONF_FILE" ] && source "$CONF_FILE" || true; }

# --- Add single IR tunnel (IPv4) ---
add_ir_v4() {
  banner
  echo "[*] Add new VXLAN IR tunnel (IPv4)"
  safe_load
  local LOCAL_IP=$(auto_detect_ip)

  IF_NAME=$(ask "VXLAN interface name" "vxlan-ir$(( ${#TUNNELS[@]-0} + 1 ))")
  VNI=$(ask "VXLAN ID" "$((100 + ${#TUNNELS[@]-0} + 1))")
  PORT=$(ask "UDP port" "443")
  REMOTE_IP=$(ask "Remote PUBLIC IPv4 (EU)" "")
  LOCAL_TUN_IP=$(ask "Local tunnel IP (e.g., 192.168.50.1/30)" "")
  REMOTE_TUN_IP=$(ask "Remote tunnel IP (e.g., 192.168.50.2)" "")

  TUNNELS+=("$IF_NAME:$VNI:$PORT:$LOCAL_IP:$REMOTE_IP:$LOCAL_TUN_IP:$REMOTE_TUN_IP")
  save_config
  systemctl restart vxlan-manager.service
  log "Added IPv4 tunnel $IF_NAME → $REMOTE_IP"
  echo "[+] New IPv4 tunnel added."
  read -rp "Press Enter..." _
}

# --- Add single IR tunnel (IPv6) ---
add_ir_v6() {
  banner
  echo "[*] Add new VXLAN IR tunnel (IPv6 / 6to4)"
  safe_load
  local LOCAL_IP=$(auto_detect_ip)

  IF_NAME=$(ask "VXLAN interface name" "vxlan6-ir$(( ${#TUNNELS_V6[@]-0} + 1 ))")
  VNI=$(ask "VXLAN ID" "$((200 + ${#TUNNELS_V6[@]-0} + 1))")
  PORT=$(ask "UDP port" "443")
  REMOTE_IP=$(ask "Remote PUBLIC IPv4 (EU)" "")
  LOCAL_TUN_IP=$(ask "Local tunnel IPv6 (e.g., fd00:50::1/64)" "")
  REMOTE_TUN_IP=$(ask "Remote tunnel IPv6 (e.g., fd00:50::2)" "")

  TUNNELS_V6+=("$IF_NAME:$VNI:$PORT:$LOCAL_IP:$REMOTE_IP:$LOCAL_TUN_IP:$REMOTE_TUN_IP")
  save_config
  systemctl restart vxlan-manager.service
  log "Added IPv6 tunnel $IF_NAME → $REMOTE_IP"
  echo "[+] New IPv6 tunnel added."
  read -rp "Press Enter..." _
}

# --- JSON Export ---
export_json() {
  safe_load
  {
    echo "{"
    echo '  "tunnels": ['
    sep=""
    for t in "${TUNNELS[@]-}"; do
      IFS=":" read IF_NAME VNI PORT LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP <<< "$t"
      echo "    ${sep}{\"if\":\"$IF_NAME\",\"vni\":\"$VNI\",\"port\":\"$PORT\",\"local_ip\":\"$LOCAL_IP\",\"remote_ip\":\"$REMOTE_IP\",\"local_tun\":\"$LOCAL_TUN_IP\",\"remote_tun\":\"$REMOTE_TUN_IP\"}"
      sep=","
    done
    for t in "${TUNNELS_V6[@]-}"; do
      IFS=":" read IF_NAME VNI PORT LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP <<< "$t"
      echo "    ${sep}{\"if\":\"$IF_NAME\",\"vni\":\"$VNI\",\"port\":\"$PORT\",\"local_ip\":\"$LOCAL_IP\",\"remote_ip\":\"$REMOTE_IP\",\"local_tun\":\"$LOCAL_TUN_IP\",\"remote_tun\":\"$REMOTE_TUN_IP\"}"
      sep=","
    done
    echo "  ]"
    echo "}"
  } > "$CONF_JSON"
  log "Exported JSON to $CONF_JSON"
  echo "[+] Exported to $CONF_JSON"
  read -rp "Press Enter..." _
}

# --- Backup / Restore ---
backup_config() {
  cp -f "$CONF_FILE" "$CONF_BAK"
  log "Backup saved to $CONF_BAK"
  echo "[+] Backup saved: $CONF_BAK"
  read -rp "Press Enter..." _
}

restore_config() {
  if [ -f "$CONF_BAK" ]; then
    cp -f "$CONF_BAK" "$CONF_FILE"
    log "Config restored from backup"
    systemctl restart vxlan-manager.service
    echo "[+] Restored & service restarted."
  else
    echo "[!] No backup found at $CONF_BAK"
  fi
  read -rp "Press Enter..." _
}

# --- Smart Healthcheck (IPv4/IPv6 aware) ---
enable_smart_healthcheck() {
  cat > "$SMART_HC" <<'EOS'
#!/usr/bin/env bash
. /etc/vxlan-manager.conf
restart_needed=0
for t in "${TUNNELS[@]-}" "${TUNNELS_V6[@]-}"; do
  [ -z "$t" ] && continue
  REMOTE_TUN_IP=$(echo "$t" | cut -d: -f7)
  if [[ "$REMOTE_TUN_IP" == *:* ]]; then
    ping6 -c1 -W2 "$REMOTE_TUN_IP" >/dev/null 2>&1 || restart_needed=1
  else
    ping -c1 -W2 "$REMOTE_TUN_IP" >/dev/null 2>&1 || restart_needed=1
  fi
done
[ $restart_needed -eq 1 ] && systemctl restart vxlan-manager.service || exit 0
EOS
  chmod +x "$SMART_HC"

  cat > "$SMART_SVC" <<EOF
[Unit]
Description=VXLAN smart healthcheck (IPv4/IPv6)
[Service]
Type=oneshot
ExecStart=$SMART_HC
EOF

  cat > "$SMART_TIMER" <<EOF
[Unit]
Description=Run smart healthcheck every 30s
[Timer]
OnBootSec=15s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=$(basename "$SMART_SVC")
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$(basename "$SMART_TIMER")"
  log "Enabled smart healthcheck timer"
  echo "[+] Smart healthcheck enabled."
  read -rp "Press Enter..." _
}

# --- MTU Tuner (non-destructive) ---
tune_mtu() {
  safe_load
  best_mtu() {
    local ip=$1 size=1472
    while ping -c1 -M do -s $size "$ip" >/dev/null 2>&1; do size=$((size+1)); done
    echo $((size-1))
  }
  for t in "${TUNNELS[@]-}" "${TUNNELS_V6[@]-}"; do
    [ -z "$t" ] && continue
    IFS=":" read IF_NAME VNI PORT LOCAL_IP REMOTE_IP LOCAL_TUN_IP REMOTE_TUN_IP <<< "$t"
    mtu=$(best_mtu "$REMOTE_IP")
    ip link set "$IF_NAME" mtu "$mtu" 2>/dev/null || true
    log "MTU tuned on $IF_NAME → $mtu"
    echo "[i] $IF_NAME → MTU=$mtu"
  done
  read -rp "Press Enter..." _
}

# --- Advanced submenu (to avoid touching original menu logic) ---
advanced_menu() {
  while true; do
    clear
    echo "================ ADVANCED TOOLS ================"
    echo "1) Add VXLAN IR (IPv4)         (append single tunnel)"
    echo "2) Add VXLAN IR (IPv6)         (append single tunnel)"
    echo "3) Export JSON                 (/etc/vxlan-manager.json)"
    echo "4) Backup Config               (/etc/vxlan-manager.conf.bak)"
    echo "5) Restore Config              (from .bak)"
    echo "6) Enable Smart Healthcheck    (IPv4/IPv6 aware)"
    echo "7) Tune MTU for all tunnels"
    echo "0) Back"
    echo "-----------------------------------------------"
    read -rp "Select: " a
    case "$a" in
      1) add_ir_v4 ;;
      2) add_ir_v6 ;;
      3) export_json ;;
      4) backup_config ;;
      5) restore_config ;;
      6) enable_smart_healthcheck ;;
      7) tune_mtu ;;
      0) break ;;
      *) echo "Invalid"; sleep 1 ;;
    esac
  done
}

menu
