#!/usr/bin/env bash
set -e

# --- Couleurs & Formats (Style Community Scripts) ---
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
  ******** ******** ****     ** ********** ** ****     ** ******** **             *******  **       **     **  ********       ********   *******   *******             **       ********  **      **
 **////// /**///// /**/**   /**/////**/// /**/**/**   /**/**///// /**            /**////**/**      /**    /** **//////       /**/////   **/////** /**////**           ****     **//////**/**     /**
/**       /**      /**//**  /**    /**    /**/**//**  /**/**      /**            /**   /**/**      /**    /**/**             /**       **     //**/**   /**          **//**   **      // /**     /**
/*********/******* /** //** /**    /**    /**/** //** /**/******* /**            /******* /**      /**    /**/*********      /******* /**      /**/*******          **  //** /**         /**********
////////**/**////  /**  //**/**    /**    /**/**  //**/**/**////  /**            /**////  /**      /**    /**////////**      /**////  /**      /**/**///**         **********/**    *****/**//////**
       /**/**      /**   //****    /**    /**/**   //****/**      /**            /**      /**      /**    /**       /**      /**      //**     ** /**  //**       /**//////**//**  ////**/**     /**
 ******** /********/**    //***    /**    /**/**    //***/********/********      /**      /********//*******  ********       /**       //*******  /**   //**      /**     /** //******** /**     /**
////////  //////// //      ///     //     // //      /// //////// ////////       //       ////////  ///////  ////////        //         ///////   //     //       //      //   ////////  //      // 
EOF
echo -e "${CL}"
echo -e "${BOLD}--- Sentinel Plus for AdGuard Home Installer ---${CL}\n"

# --- Configuration basique ---
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

# 1. Obtenir l'ID conteneur
msg_info "Recherche du premier ID conteneur disponible..."
CT_ID=$(pvesh get /cluster/nextid)
msg_ok "ID attribué : ${BOLD}$CT_ID${CL}"

# 2. Template Debian 12
msg_info "Mise à jour et recherche du template Debian 12..."
pveam update > /dev/null
OSTEMPLATE=$(pveam available -section system | grep -i "debian-12-standard" | awk '{print $2}' | tail -n1)

if [ -z "$OSTEMPLATE" ]; then
    msg_error "Impossible de trouver un template Debian 12 dans le dépôt Proxmox."
    exit 1
fi

if ! pveam list $TEMPLATE_STORAGE | grep -q "$OSTEMPLATE"; then
    msg_info "Téléchargement du template $OSTEMPLATE..."
    pveam download $TEMPLATE_STORAGE $OSTEMPLATE > /dev/null
fi
msg_ok "Template prêt : $OSTEMPLATE"

# 3. Création du conteneur
msg_info "Création du conteneur LXC (ID: $CT_ID)..."
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
msg_ok "Conteneur $CT_ID créé avec succès."

# 4. Démarrage
msg_info "Démarrage du conteneur..."
pct start $CT_ID
sleep 5
msg_ok "Conteneur démarré."

# 5. Dépendances système
msg_info "Installation des dépendances système..."
pct exec $CT_ID -- bash -c "apt-get update >/dev/null && apt-get install -y git python3 python3-pip python3-venv python3-dotenv >/dev/null"
msg_ok "Dépendances système installées."

# 6. Clonage
msg_info "Clonage du dépôt Sentinel..."
pct exec $CT_ID -- bash -c "git clone $REPO_URL $INSTALL_DIR" > /dev/null
msg_ok "Dépôt cloné dans $INSTALL_DIR."

# 7. Environnement Python
msg_info "Configuration du Virtualenv Python..."
pct exec $CT_ID -- bash -c "python3 -m venv $INSTALL_DIR/venv"
pct exec $CT_ID -- bash -c "$INSTALL_DIR/venv/bin/pip install --upgrade pip requests python-dotenv" > /dev/null
msg_ok "Environnement Python configuré."

# 8. Fichier .env
msg_info "Préparation du fichier de configuration .env..."
pct exec $CT_ID -- bash -c "if [ -f $INSTALL_DIR/.env.example ] && [ ! -f $INSTALL_DIR/.env ]; then cp $INSTALL_DIR/.env.example $INSTALL_DIR/.env; fi"
msg_ok "Fichier .env initialisé."

# 9. Création du service Systemd
msg_info "Création du service Systemd..."
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
msg_ok "Service Sentinel activé et démarré."

# 10. Redirection de la console sur les logs du service
msg_info "Configuration de la console interactive sur les logs..."
pct exec $CT_ID -- bash -c "cat << 'EOF' >> /root/.bashrc

# Affichage automatique des logs Sentinel à la connexion console
if [ -t 0 ]; then
    echo -e '\033[36m=== Logs en direct de Sentinel (Appuyez sur Ctrl+C pour quitter la vue des logs) ===\033[0m'
    journalctl -u sentinel.service -f -n 50
fi
EOF"
msg_ok "Console configurée."

# --- Résumé Final ---
echo -e "\n${GN}======================================================${CL}"
echo -e "${BOLD}${GN}   Installation de Sentinel terminée avec succès !${CL}"
echo -e "${GN}======================================================${CL}\n"
echo -e "  ${BOLD}Conteneur ID :${CL} $CT_ID"
echo -e "  ${BOLD}Nom d'hôte   :${CL} $HOSTNAME"
echo -e "\n${YW}⚠️ Prochaine étape obligatoire :${CL}"
echo -e " Éditez vos accès AdGuard Home dans le fichier .env :"
echo -e " ${BL}pct exec $CT_ID -- nano /opt/sentinel/.env${CL}"
echo -e " ${BL}pct exec $CT_ID -- systemctl restart sentinel.service${CL}\n"
