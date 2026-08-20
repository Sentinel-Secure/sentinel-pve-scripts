#!/bin/bash
set -e

# --- Configuration basique ---
HOSTNAME="sentinel-agh"              # Nom d'hôte du conteneur
STORAGE="local-lvm"                  # Stockage pour le disque LXC
TEMPLATE_STORAGE="local"             # Stockage pour les templates
RAM=512                              # RAM en Mo
SWAP=512                             # SWAP en Mo
CORES=1                              # Cœurs CPU
DISK_SIZE="4"                       # Taille du disque (Taille en go)
BRIDGE="vmbr0"                       # Bridge réseau

# Dépôt GitHub source
REPO_URL="https://github.com/Sentinel-Secure/sentinel-pve-script-backend.git"
INSTALL_DIR="/opt/sentinel"

echo "=== 1. Recherche du premier ID de conteneur disponible ==="
CT_ID=$(pvesh get /cluster/nextid)
echo "ID attribué automatiquement : $CT_ID"

echo "=== 2. Recherche du dernier template Debian 12 disponible ==="
pveam update > /dev/null

OSTEMPLATE=$(pveam available -section system | grep -i "debian-12-standard" | awk '{print $2}' | tail -n1)

if [ -z "$OSTEMPLATE" ]; then
    echo "❌ Erreur : Impossible de trouver un template Debian 12 dans le dépôt Proxmox."
    exit 1
fi

echo "Template trouvé : $OSTEMPLATE"

if ! pveam list $TEMPLATE_STORAGE | grep -q "$OSTEMPLATE"; then
    echo "Téléchargement du template $OSTEMPLATE..."
    pveam download $TEMPLATE_STORAGE $OSTEMPLATE
fi

echo "=== 3. Création du conteneur LXC (ID: $CT_ID) ==="
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

echo "=== 4. Démarrage du conteneur ==="
pct start $CT_ID
sleep 5 # Pause pour l'initialisation du réseau

echo "=== 5. Installation des dépendances dans le LXC ==="
pct exec $CT_ID -- bash -c "apt-get update && apt-get install -y git python3 python3-pip python3-venv python3-dotenv"

echo "=== 6. Clonage du projet Sentinel ==="
pct exec $CT_ID -- bash -c "git clone $REPO_URL $INSTALL_DIR"

echo "=== 7. Configuration de l'environnement Python ==="
pct exec $CT_ID -- bash -c "python3 -m venv $INSTALL_DIR/venv"
pct exec $CT_ID -- bash -c "$INSTALL_DIR/venv/bin/pip install --upgrade pip"
pct exec $CT_ID -- bash -c "$INSTALL_DIR/venv/bin/pip install python-dotenv requests"

echo "=== 8. Configuration du fichier d'environnement (.env) ==="
pct exec $CT_ID -- bash -c "if [ -f $INSTALL_DIR/.env.example ] && [ ! -f $INSTALL_DIR/.env ]; then cp $INSTALL_DIR/.env.example $INSTALL_DIR/.env; fi"

echo "=== 9. Création et activation du service Systemd ==="
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

pct exec $CT_ID -- bash -c "systemctl daemon-reload && systemctl enable --now sentinel.service"

echo ""
echo "=== Installation terminée avec succès sur le conteneur CT $CT_ID ! ==="
echo "⚠️ N'oubliez pas d'éditer le fichier .env avec vos accès AdGuard Home :"
echo "   pct exec $CT_ID -- nano $INSTALL_DIR/.env"
echo "   pct exec $CT_ID -- systemctl restart sentinel.service"
echo ""
pct exec $CT_ID -- systemctl status sentinel.service --no-pager
