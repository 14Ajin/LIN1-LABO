#!/bin/bash
#
# ============================================================================
# SRV-LIN1-02.sh
# ----------------------------------------------------------------------------
# Script d'installation et de configuration automatisee de SRV-LIN1-02
# Module LIN1 - Infrastructure LIN1-LABO
#
# Ce script configure, sur une Debian 12 fraichement installee :
#   1. Le reseau (interface interne statique, DNS)
#   2. Le partage : montage du stockage NAS en NFS (persistant)
#   3. Nextcloud (avec Apache, MariaDB, PHP) accessible en HTTPS, avec son
#      repertoire de donnees place sur le partage du NAS
#
# PREREQUIS :
#   - Debian 12 (Bookworm) fraichement installee, avec une interface
#     reseau ens33 (Host-only, reseau interne LIN1-LABO, adresse
#     10.10.10.22). L'acces Internet transite par le routage assure par
#     SRV-LIN1-01 (passerelle), deja pris en compte via la variable
#     GATEWAY ci-dessous.
#   - NAS-LIN1-01 demarre en premier, avec un export NFS
#     /export/nextcloud-data ayant l'option no_root_squash (sans elle,
#     www-data ne peut pas ecrire dans le partage).
#   - SRV-LIN1-01 (DNS/DHCP/LDAP) operationnel sur 10.10.10.0/24.
#   - Ce script s'execute entierement en tant que root. Se connecter en
#     root (su -) puis lancer :
#       bash SRV-LIN1-02.sh
#   Sudo est installe au passage pour l'administration courante du
#   serveur une fois le script termine.
#
# UTILISATION :
#   su -
#   bash SRV-LIN1-02.sh
#
# NOTE : la liaison LDAP et la creation des dossiers de groupe (Group
# folders) dans Nextcloud sont finalisees avec l'utilitaire occ une fois ce
# script termine (voir documentation, sections 7.6 et 7.7).
#
# ============================================================================

# ----------------------------------------------------------------------------
# 0. VARIABLES DE CONFIGURATION (a adapter si besoin)
# ----------------------------------------------------------------------------

IFACE_LAN="ens33"                  # Interface reseau interne (Host-only) - reajustee automatiquement ci-dessous si besoin
IP_SRV02="10.10.10.22"
NETMASK="255.255.255.0"
GATEWAY="10.10.10.11"
DNS_SERVER="10.10.10.11"
DOMAIN="lin1-labo.local"

NAS_IP="10.10.10.33"
NAS_NFS_EXPORT="/export/nextcloud-data"
NFS_MOUNT_POINT="/mnt/nfs-nas"
NC_DATA_DIR="${NFS_MOUNT_POINT}/data"   # Repertoire de donnees Nextcloud (sur le NAS)

DB_NAME="nextcloud"
DB_USER="nextclouduser"
DB_PASSWORD="Pa\$\$w0rd"

NC_ADMIN_USER="ncadmin"
NC_ADMIN_PASSWORD="Pa\$\$w0rd"

# Version epinglee plutot que "latest.zip" : Debian 12 fournit PHP 8.2, or
# les versions recentes de Nextcloud peuvent exiger PHP 8.3, non disponible
# dans les depots standards de Debian 12. La version choisie doit etre
# compatible avec PHP 8.2.
NEXTCLOUD_VERSION="34.0.3"

# ----------------------------------------------------------------------------
# 0bis. VERIFICATION DES DROITS
# ----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit etre execute en tant que root : su - puis bash SRV-LIN1-02.sh"
    exit 1
fi

# Installation de sudo (utilise ensuite pour lancer occ sous l'utilisateur
# www-data, et pour l'administration courante du serveur).
if ! command -v sudo >/dev/null 2>&1; then
    apt update
    apt install -y sudo
fi

set -e  # Arrete le script a la moindre erreur

echo "============================================================"
echo " SRV-LIN1-02 - Debut de l'installation automatisee"
echo "============================================================"

# Force le nom de la machine, quel que soit celui choisi a l'installation
# de Debian, pour garantir un resultat coherent avec l'infrastructure.
hostnamectl set-hostname srv-lin1-02
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1 srv-lin1-02.${DOMAIN} srv-lin1-02" >> /etc/hosts
echo "Nom de machine configure : srv-lin1-02"

# Sur la configuration finale (une seule interface ens33, Host-only), la
# valeur par defaut ci-dessus convient directement. Si une seconde
# interface est presente (ex. VM de test avec une carte NAT ajoutee pour
# telecharger les paquets), celle-ci est reconnue par son adresse en
# 192.168.x.x (plage NAT VMware) et ecartee : l'interface interne est
# alors l'autre.
if ip -4 addr show "${IFACE_LAN}" | grep -q "inet 192\.168\."; then
    for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$'); do
        if [ "${IFACE}" != "${IFACE_LAN}" ]; then
            IFACE_LAN="${IFACE}"
            break
        fi
    done
fi
echo "Interface interne (Host-only) : ${IFACE_LAN}"

# ============================================================================
# 1. CONFIGURATION RESEAU
# ============================================================================
echo ""
echo "---- [1/3] Configuration reseau ----"

cat > /etc/network/interfaces <<EOF
# Interface loopback
auto lo
iface lo inet loopback

# Interface Host-only - reseau interne LIN1-LABO
auto ${IFACE_LAN}
iface ${IFACE_LAN} inet static
    address ${IP_SRV02}
    netmask ${NETMASK}
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVER}
EOF

systemctl restart networking || true

# dns-nameservers n'est pris en compte que si resolvconf est installe :
# le resolveur est ecrit directement pour utiliser SRV-LIN1-01 comme DNS.
cat > /etc/resolv.conf <<EOF
domain ${DOMAIN}
search ${DOMAIN}
nameserver ${DNS_SERVER}
EOF

echo "Reseau configure : ${IFACE_LAN} = ${IP_SRV02}, passerelle ${GATEWAY}, DNS ${DNS_SERVER}."

# ============================================================================
# 2. CONFIGURATION DU PARTAGE (montage NAS en NFS)
# ============================================================================
echo ""
echo "---- [2/3] Configuration du partage (montage NFS depuis le NAS) ----"

apt update
apt install -y nfs-common apache2

mkdir -p ${NFS_MOUNT_POINT}

if ! mountpoint -q ${NFS_MOUNT_POINT}; then
    mount -t nfs ${NAS_IP}:${NAS_NFS_EXPORT} ${NFS_MOUNT_POINT}
fi

# Rendre le montage persistant au redemarrage (nofail : ne bloque pas le
# demarrage si le NAS est indisponible)
if ! grep -q "${NFS_MOUNT_POINT}" /etc/fstab; then
    echo "${NAS_IP}:${NAS_NFS_EXPORT} ${NFS_MOUNT_POINT} nfs defaults,_netdev,nofail 0 0" >> /etc/fstab
fi

# Repertoire de donnees de Nextcloud, sur le partage du NAS. Il doit etre
# inscriptible par www-data (necessite no_root_squash cote NAS).
mkdir -p ${NC_DATA_DIR}
chown www-data:www-data ${NC_DATA_DIR}
chmod 0770 ${NC_DATA_DIR}
if ! sudo -u www-data touch ${NC_DATA_DIR}/.test_ecriture 2>/dev/null; then
    echo "ERREUR : www-data ne peut pas ecrire dans ${NC_DATA_DIR}."
    echo "Ajouter l'option no_root_squash a l'export NFS du NAS, puis relancer le script."
    exit 1
fi
rm -f ${NC_DATA_DIR}/.test_ecriture

echo "Partage NFS monte : ${NAS_IP}:${NAS_NFS_EXPORT} -> ${NFS_MOUNT_POINT}"
echo "Repertoire de donnees Nextcloud : ${NC_DATA_DIR} (sur le NAS)"

# ============================================================================
# 3. INSTALLATION DE NEXTCLOUD
# ============================================================================
echo ""
echo "---- [3/3] Installation de Nextcloud (Apache, MariaDB, PHP) ----"

apt install -y mariadb-server php php-gd php-mysql php-curl \
    php-mbstring php-intl php-gmp php-bcmath php-xml php-imagick \
    php-zip php-ldap libapache2-mod-php unzip

# --- Base de donnees ---
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# --- Telechargement et extraction de Nextcloud ---
if [ ! -d /var/www/nextcloud ]; then
    cd /tmp
    echo "Telechargement de Nextcloud ${NEXTCLOUD_VERSION} (environ 300 Mo, peut prendre plusieurs minutes)..."
    wget "https://download.nextcloud.com/server/releases/nextcloud-${NEXTCLOUD_VERSION}.zip" -O nextcloud.zip
    unzip -q nextcloud.zip -d /var/www/
    chown -R www-data:www-data /var/www/nextcloud
    rm -f /tmp/nextcloud.zip
fi

# --- Certificat SSL auto-signe ---
mkdir -p /etc/apache2/ssl
if [ ! -f /etc/apache2/ssl/nextcloud.crt ]; then
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/apache2/ssl/nextcloud.key \
        -out /etc/apache2/ssl/nextcloud.crt \
        -subj "/C=CH/ST=Vaud/L=Yverdon/O=LIN1-LABO/CN=srv-lin1-02.${DOMAIN}"
fi

# --- Virtual host HTTP (port 80) ---
cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    DocumentRoot /var/www/nextcloud
    ServerName srv-lin1-02.${DOMAIN}
    # Alias : Nextcloud repond aussi sur /nextcloud (adresse demandee par la grille du POC)
    Alias /nextcloud /var/www/nextcloud

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_access.log combined
</VirtualHost>
EOF

# --- Virtual host HTTPS (port 443) ---
cat > /etc/apache2/sites-available/nextcloud-ssl.conf <<EOF
<VirtualHost *:443>
    DocumentRoot /var/www/nextcloud
    ServerName srv-lin1-02.${DOMAIN}
    # Alias : Nextcloud repond aussi sur /nextcloud (adresse demandee par la grille du POC)
    Alias /nextcloud /var/www/nextcloud

    SSLEngine on
    SSLCertificateFile /etc/apache2/ssl/nextcloud.crt
    SSLCertificateKeyFile /etc/apache2/ssl/nextcloud.key

    <Directory /var/www/nextcloud/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_ssl_access.log combined
</VirtualHost>
EOF

a2enmod rewrite headers env dir mime ssl php8.2 >/dev/null 2>&1 || a2enmod rewrite headers env dir mime ssl
a2ensite nextcloud.conf nextcloud-ssl.conf

# Augmentation de la limite memoire PHP d'Apache (evite les erreurs 500 sur
# certaines pages, comme la decouverte d'applications)
sed -i 's/^memory_limit = .*/memory_limit = 512M/' /etc/php/*/apache2/php.ini

systemctl restart apache2

# --- Installation de Nextcloud en ligne de commande (mode non-interactif) ---
# Le repertoire de donnees est place sur le partage du NAS (--data-dir).
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
    --database "mysql" \
    --database-name "${DB_NAME}" \
    --database-user "${DB_USER}" \
    --database-pass "${DB_PASSWORD}" \
    --admin-user "${NC_ADMIN_USER}" \
    --admin-pass "${NC_ADMIN_PASSWORD}" \
    --data-dir "${NC_DATA_DIR}" || echo "Nextcloud deja installe, etape ignoree."

# occ maintenance:install ne configure que "localhost" comme domaine de
# confiance par defaut : sans cette etape, l'acces via l'IP reelle du
# serveur est refuse ("Access through untrusted domain").
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 1 --value=${IP_SRV02}
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 2 --value=srv-lin1-02.${DOMAIN}

# Installation de l'application Calendrier (necessaire pour le POC, point 20)
sudo -u www-data php /var/www/nextcloud/occ app:install calendar || echo "App calendar deja installee ou indisponible, etape ignoree."

echo "Nextcloud installe. Acces : https://${IP_SRV02}"

# ============================================================================
# FIN
# ============================================================================
echo ""
echo "============================================================"
echo " SRV-LIN1-02 - Installation terminee avec succes"
echo "============================================================"
echo " Nextcloud : https://${IP_SRV02}"
echo " Compte admin Nextcloud : ${NC_ADMIN_USER}"
echo " Donnees Nextcloud : ${NC_DATA_DIR} (partage NFS du NAS)"
echo ""
echo " ETAPES MANUELLES RESTANTES (voir documentation, sections 7.6 et 7.7) :"
echo "   - Liaison LDAP de Nextcloud"
echo "   - Dossiers de groupe Clients / Logiciels / Commun (quotas et droits)"
echo "   - Quota personnel (10 Mo) des utilisateurs"
echo "============================================================"
