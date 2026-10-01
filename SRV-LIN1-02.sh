#!/bin/bash
#
# ============================================================================
# SRV-LIN1-02.sh
# ----------------------------------------------------------------------------
# Script d'installation et de configuration automatisee de SRV-LIN1-02
# Module LIN1 - Infrastructure LIN1-LABO
#
# Ce script configure, sur une Debian 12 fraichement installee :
#   1. Le reseau (interface interne statique)
#   2. Nextcloud (avec Apache, MariaDB, PHP) accessible en HTTPS
#   3. La configuration du partage (montage du stockage NAS en NFS)
#
# PREREQUIS :
#   - Debian 12 (Bookworm) fraichement installee, avec une interface
#     reseau ens33 (Host-only, reseau interne LIN1-LABO, adresse
#     10.10.10.22). L'acces Internet transite par le routage assure par
#     SRV-LIN1-01 (passerelle), deja pris en compte via la variable
#     GATEWAY ci-dessous.
#   - SRV-LIN1-01 (DNS/DHCP/LDAP) et NAS-LIN1-01 (stockage NFS) deja
#     operationnels et accessibles sur le reseau 10.10.10.0/24.
#   - Ce script s'execute entierement en tant que root. Se connecter en
#     root (su -) puis lancer :
#       bash SRV-LIN1-02.sh
#   Sudo est installe au passage pour l'administration courante du
#   serveur une fois le script termine, mais n'est pas necessaire a
#   l'execution du script lui-meme.
#
# UTILISATION :
#   su -
#   bash SRV-LIN1-02.sh
#
# NOTE : la liaison LDAP et la creation des dossiers de groupe (Group
# folders) dans Nextcloud necessitent que l'application web soit accessible
# et sont finalisees via l'utilitaire occ (voir documentation, section 7.5
# et 7.6) une fois ce script termine, le temps que Nextcloud soit
# entierement initialise.
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

DB_NAME="nextcloud"
DB_USER="nextclouduser"
DB_PASSWORD="Pa\$\$w0rd"
MARIADB_ROOT_PASSWORD="Pa\$\$w0rd"

NC_ADMIN_USER="ncadmin"
NC_ADMIN_PASSWORD="Pa\$\$w0rd"

LDAP_HOST="10.10.10.11"
LDAP_BASE_DN="dc=lin1-labo,dc=local"
LDAP_ADMIN_DN="cn=admin,dc=lin1-labo,dc=local"
LDAP_ADMIN_PASSWORD="Pa\$\$w0rd"

# ----------------------------------------------------------------------------
# 0bis. VERIFICATION DES DROITS
# ----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit etre execute en tant que root : su - puis bash SRV-LIN1-02.sh"
    exit 1
fi

# Installation de sudo pour l'administration courante du serveur apres
# l'execution de ce script (pas requis pour le script lui-meme, qui
# s'execute directement en root).
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

echo "Reseau configure : ${IFACE_LAN} = ${IP_SRV02}, passerelle ${GATEWAY}."

# ============================================================================
# 2. INSTALLATION DE NEXTCLOUD
# ============================================================================
echo ""
echo "---- [2/3] Installation de Nextcloud (Apache, MariaDB, PHP) ----"

apt update
apt install -y apache2 mariadb-server php php-gd php-mysql php-curl \
    php-mbstring php-intl php-gmp php-bcmath php-xml php-imagick \
    php-zip php-ldap libapache2-mod-php unzip nfs-common open-iscsi

# --- Base de donnees ---
mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME};
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF

# --- Telechargement et extraction de Nextcloud ---
# Version epinglee (33.0.7) plutot que "latest.zip" : Debian 12 fournit
# PHP 8.2, or les versions de Nextcloud posterieures a la 33 exigent
# PHP 8.3, non disponible dans les depots standards de Debian 12.
NEXTCLOUD_VERSION="34.0.3"
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

# Augmentation de la limite memoire PHP (evite les erreurs 500 sur certaines
# pages, comme la decouverte d'applications, rencontrees en usage normal)
PHP_INI=$(php -i | grep "Loaded Configuration File" | awk '{print $NF}')
if [ -f "${PHP_INI}" ]; then
    sed -i 's/^memory_limit = .*/memory_limit = 512M/' "${PHP_INI}"
fi

systemctl restart apache2

# --- Installation de Nextcloud en ligne de commande (mode non-interactif) ---
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
    --database "mysql" \
    --database-name "${DB_NAME}" \
    --database-user "${DB_USER}" \
    --database-pass "${DB_PASSWORD}" \
    --admin-user "${NC_ADMIN_USER}" \
    --admin-pass "${NC_ADMIN_PASSWORD}" || echo "Nextcloud deja installe, etape ignoree."

# occ maintenance:install ne configure que "localhost" comme domaine de
# confiance par defaut : sans cette etape, l'acces via l'IP reelle du
# serveur est refuse ("Access through untrusted domain").
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 1 --value=${IP_SRV02}
sudo -u www-data php /var/www/nextcloud/occ config:system:set trusted_domains 2 --value=srv-lin1-02.${DOMAIN}

# Installation de l'application Calendrier (necessaire pour le POC, point 20)
sudo -u www-data php /var/www/nextcloud/occ app:install calendar || echo "App calendar deja installee ou indisponible, etape ignoree."

echo "Nextcloud installe. Acces : https://${IP_SRV02}"

# ============================================================================
# 3. CONFIGURATION DU PARTAGE (montage NAS en NFS)
# ============================================================================
echo ""
echo "---- [3/3] Configuration du partage (montage NFS depuis le NAS) ----"

mkdir -p ${NFS_MOUNT_POINT}

if ! mountpoint -q ${NFS_MOUNT_POINT}; then
    mount -t nfs ${NAS_IP}:${NAS_NFS_EXPORT} ${NFS_MOUNT_POINT}
fi

# Rendre le montage persistant au redemarrage
if ! grep -q "${NFS_MOUNT_POINT}" /etc/fstab; then
    echo "${NAS_IP}:${NAS_NFS_EXPORT} ${NFS_MOUNT_POINT} nfs defaults 0 0" >> /etc/fstab
fi

echo "Partage NFS monte : ${NAS_IP}:${NAS_NFS_EXPORT} -> ${NFS_MOUNT_POINT}"

# Stockage externe Nextcloud pointant vers le partage NAS (point 16 du POC :
# les fichiers Nextcloud doivent etre physiquement stockes sur le partage).
# PREREQUIS cote NAS : l'export NFS doit avoir l'option no_root_squash,
# sinon www-data ne peut pas ecrire dans le repertoire monte (voir doc 7.6bis).
if [ -f /var/www/nextcloud/occ ]; then
    sudo -u www-data php /var/www/nextcloud/occ app:enable files_external || true
    sudo -u www-data php /var/www/nextcloud/occ files_external:create "NAS-Storage" local null::null -c datadir=${NFS_MOUNT_POINT} || echo "Stockage externe NAS-Storage deja cree, etape ignoree."
fi

# ============================================================================
# NOTE : quotas personnels (repertoire "perso", 10 Mo par utilisateur,
# document d'arborescence des donnees) : les utilisateurs LDAP ne possedent
# pas d'UUID stable avant leur premiere synchronisation (declenchee par une
# premiere connexion ou par occ user:list une fois LDAP configure). Cette
# etape s'effectue donc manuellement apres la configuration LDAP, avec :
#   sudo -u www-data php /var/www/nextcloud/occ user:list
#   sudo -u www-data php /var/www/nextcloud/occ user:setting <uuid> files quota "10 MB"
# (voir documentation, section 7.6)
# ============================================================================

# ============================================================================
# FIN
# ============================================================================
echo ""
echo "============================================================"
echo " SRV-LIN1-02 - Installation terminee avec succes"
echo "============================================================"
echo " Nextcloud : https://${IP_SRV02}"
echo " Compte admin Nextcloud : ${NC_ADMIN_USER}"
echo " Partage NFS monte sur : ${NFS_MOUNT_POINT}"
echo ""
echo " ETAPES MANUELLES RESTANTES (voir documentation section 7.5 et 7.6) :"
echo "   - Activation et configuration de l'application LDAP dans Nextcloud"
echo "   - Installation de l'application Group folders et creation des"
echo "     dossiers Clients / Logiciels / Commun avec quotas et droits"
echo "   - Quota personnel (10 MB) pour chaque utilisateur LDAP, via"
echo "     occ user:setting <uuid> files quota \"10 MB\""
echo "============================================================"
