#!/usr/bin/env bash
set -e

# --- Colors & Output Formatting (Community Scripts Style) ---
YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[31m")
GN=$(echo "\033[32m")
CL=$(echo "\033[0m")
BOLD=$(echo "\033[1m")

msg_info() { echo -e "${BL}[INFO]${CL} $1"; }
msg_ok() { echo -e "${GN}[OK]${CL} $1"; }
msg_error() { echo -e "${RD}[ERROR]${CL} $1"; }

clear
echo -e "${BL}"
cat << "EOF"
   _____ ______ _   _ _______ _____ _   _ ______ _        _____  _     _    _  _____ 
  / ____|  ____| \ | |__   __|_   _| \ | |  ____| |      |  __ \| |   | |  | |/ ____|
 | (___ | |__  |  \| |  | |    | | |  \| | |__  | |      | |__) | |   | |  | | (___  
  \___ \|  __| | . ` |  | |    | | | . ` |  __| | |      |  ___/| |   | |  | |\___ \ 
  ____) | |____| |\  |  | |   _| |_| |\  | |____| |____  | |    | |___| |__| |____) |
 |_____/|______|_| \_|  |_|  |_____|_| \_|______|______| |_|    |______\____/|_____/ 
EOF
echo -e "${CL}"
echo -e "${BOLD}--- Sentinel Plus for AdGuard Home Installer ---${CL}\n"

# --- Basic Configuration ---
HOSTNAME="sentinel"
STORAGE="local-lvm"
TEMPLATE_STORAGE="local"
RAM=512
SWAP=512
CORES=1
DISK_SIZE="4"
BRIDGE="vmbr0"

REPO_URL="https://github.com/Sentinel-Secure/sentinel-pve-script-backend.git"
INSTALL_DIR="/opt/sentinel"

# 1. Fetch available Container ID
msg_info "Searching for next available Container ID..."
CT_ID=$(pvesh get /cluster/nextid)
msg_ok "Assigned Container ID: ${BOLD}$CT_ID${CL}"

# 2. Fetch Debian 12 Template
msg_info "Updating template list and finding latest Debian 12..."
pveam update > /dev/null
OSTEMPLATE=$(pveam available -section system | grep -i "debian-12-standard" | awk '{print $2}' | tail -n1)

if [ -z "$OSTEMPLATE" ]; then
    msg_error "Could not find a valid Debian 12 template in the Proxmox repository."
    exit 1
fi

if ! pveam list $TEMPLATE_STORAGE | grep -q "$OSTEMPLATE"; then
    msg_info "Downloading template $OSTEMPLATE..."
    pveam download $TEMPLATE_STORAGE $OSTEMPLATE > /dev/null
fi
msg_ok "Template ready: $OSTEMPLATE"

# 3. Create Container
msg_info "Creating LXC Container (ID: $CT_ID)..."
pct create $CT_ID "$TEMPLATE_STORAGE:vztmpl/$OSTEMPLATE" \
    --ostype debian \
    --hostname $HOSTNAME \
    --cores $CORES \
    --memory $RAM \
    --swap $SWAP \
    --storage $STORAGE \
    --rootfs "$STORAGE:$DISK_SIZE" \
    --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
    --onboot 1 \
    --unprivileged 1 > /dev/null
msg_ok "Container $CT_ID created successfully."

# 4. Start Container
msg_info "Starting container..."
pct start $CT_ID
sleep 5
msg_ok "Container started."

# 5. System Dependencies & Locale Fix
msg_info "Installing system dependencies..."
pct exec $CT_ID -- bash -c "export DEBIAN_FRONTEND=noninteractive LC_ALL=C.UTF-8 && apt-get update >/dev/null && apt-get install -y git python3 python3-pip python3-venv python3-dotenv locales >/dev/null && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen >/dev/null"
msg_ok "System dependencies installed."

# 6. Clone Repository
msg_info "Cloning Sentinel repository..."
pct exec $CT_ID -- bash -c "git clone $REPO_URL $INSTALL_DIR" > /dev/null
msg_ok "Repository cloned into $INSTALL_DIR."

# 7. Python Environment
msg_info "Setting up Python Virtual Environment..."
pct exec $CT_ID -- bash -c "python3 -m venv $INSTALL_DIR/venv"
pct exec $CT_ID -- bash -c "$INSTALL_DIR/venv/bin/pip install --upgrade pip requests python-dotenv" > /dev/null
msg_ok "Python environment configured."

# 8. Environment File Setup
msg_info "Preparing configuration file (.env)..."
pct exec $CT_ID -- bash -c "if [ -f $INSTALL_DIR/.env.example ] && [ ! -f $INSTALL_DIR/.env ]; then cp $INSTALL_DIR/.env.example $INSTALL_DIR/.env; fi"
msg_ok ".env file initialized."

# 9. Create Systemd Service
msg_info "Creating Systemd service..."
pct exec $CT_ID -- bash -c "cat <<SERVICE > /etc/systemd/system/sentinel.service
[Unit]
Description=Sentinel Plus for AdGuard Home Daemon
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/venv/bin/python $INSTALL_DIR/Sentinel-Plus-for-AGH.py
Restart=always
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
SERVICE"

pct exec $CT_ID -- bash -c "systemctl daemon-reload && systemctl enable --now sentinel.service" > /dev/null
msg_ok "Sentinel service enabled and started."

# 10. Configure Auto-Logon on Console (Official Community Scripts Method)
msg_info "Configuring Automatic Login..."
pct exec $CT_ID -- bash -c "mkdir -p /etc/systemd/system/getty@tty1.service.d /etc/systemd/system/console-getty.service.d"

# tty1 Override
pct exec $CT_ID -- bash -c "cat <<EOF > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I \$TERM
EOF"

# console-getty Override (Proxmox Web Console / Serial)
pct exec $CT_ID -- bash -c "cat <<EOF > /etc/systemd/system/console-getty.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud console 115200,38400,9600 \$TERM
EOF"

pct exec $CT_ID -- systemctl daemon-reload
msg_ok "Auto-logon configured."

# 11. Redirect Console to Live Service Logs
msg_info "Configuring console to auto-display live service logs..."
pct exec $CT_ID -- bash -c "cat << 'EOF' >> /root/.bashrc

# Automatic live log display upon console login
if [ -t 0 ]; then
    echo -e '\033[36m=== Sentinel Live Logs (Press Ctrl+C to exit log view) ===\033[0m'
    journalctl -u sentinel.service -f -n 50
fi
EOF"
msg_ok "Console and logs configured."

# --- Final Summary ---
echo -e "\n${GN}======================================================${CL}"
echo -e "${BOLD}${GN}   Sentinel Installation Completed Successfully!${CL}"
echo -e "${GN}======================================================${CL}\n"
echo -e "  ${BOLD}Container ID :${CL} $CT_ID"
echo -e "  ${BOLD}Hostname     :${CL} $HOSTNAME"
echo -e "\n${YW}⚠️ Action Required:${CL}"
echo -e " Configure your AdGuard Home credentials in the .env file:"
echo -e " ${BL}pct exec $CT_ID -- nano /opt/sentinel/.env${CL}"
echo -e " ${BL}pct exec $CT_ID -- systemctl restart sentinel.service${CL}\n"
