#!/bin/bash
set -e

# --- Configuration du conteneur LXC ---
CT_ID=110                            # ID du conteneur (à adapter)
HOSTNAME="sentinel-agh"              # Nom d'hôte
STORAGE="local-lvm"                  # Stockage pour le disque LXC
TEMPLATE_STORAGE="local"             # Stockage pour les templates
RAM=512                              # RAM en Mo (amplement suffisant)
SWAP=512                             # SWAP en Mo
CORES=1                              # Cœurs CPU
DISK_SIZE="4G"                       # Taille du disque
BRIDGE="vmbr0"                       # Bridge réseau
OSTEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"

# Dépôt GitHub
REPO_URL="https://github.com/Sentinel-Secure/sentinel.git"
INSTALL_DIR="/opt/sentinel"

echo "=== 1. Téléchargement du template Debian 12 si nécessaire ==="
pveam update
if ! pveam list $TEMPLATE_STORAGE | grep -q "$OSTEMPLATE"; then
    echo "Téléchargement du template $OSTEMPLATE..."
    pveam download $TEMPLATE_STORAGE $OSTEMPLATE
fi

echo "=== 2. Création du conteneur LXC (ID: $CT_ID) ==="
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
    --unprivileged 1

echo "=== 3. Démarrage du conteneur ==="
pct start $CT_ID
sleep 5 # Pause pour laisser le réseau s'initialiser

echo "=== 4. Installation des dépendances dans le LXC ==="
pct exec $CT_ID -- bash -c "apt-get update && apt-get install -y git python3 python3-pip python3-venv python3-dotenv"

echo "=== 5. Clonage du projet Sentinel ==="
pct exec $CT_ID -- bash -c "git clone $REPO_URL $INSTALL_DIR"

echo "=== 6. Configuration de l'environnement Python ==="
pct exec $CT_ID -- bash -c "python3 -m venv $INSTALL_DIR/venv"
pct exec $CT_ID -- bash -c "$INSTALL_DIR/venv/bin/pip install --upgrade pip"
pct exec $CT_ID -- bash -c "$INSTALL_DIR/venv/bin/pip install python-dotenv requests" # Modules courants requis pour AGH

echo "=== 7. Configuration du fichier d'environnement (.env) ==="
pct exec $CT_ID -- bash -c "if [ -f $INSTALL_DIR/.env.example ] && [ ! -f $INSTALL_DIR/.env ]; then cp $INSTALL_DIR/.env.example $INSTALL_DIR/.env; fi"

echo "=== 8. Création et activation du service Systemd ==="
pct exec $CT_ID -- bash -c "cat <<EOF > /etc/systemd/system/sentinel.service
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
EOF"

pct exec $CT_ID -- bash -c "systemctl daemon-reload && systemctl enable --now sentinel.service"

echo "=== Installation terminée ! ==="
echo "⚠️ N'oubliez pas d'éditer le fichier .env avec vos identifiants AdGuard Home :"
echo "   pct exec $CT_ID -- nano $INSTALL_DIR/.env"
echo "   pct exec $CT_ID -- systemctl restart sentinel.service"
echo ""
echo "Statut du service Sentinel :"
pct exec $CT_ID -- systemctl status sentinel.service --no-pager
