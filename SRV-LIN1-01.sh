#!/bin/bash
#
# ============================================================================
# SRV-LIN1-01.sh
# ----------------------------------------------------------------------------
# Script d'installation et de configuration automatisee de SRV-LIN1-01
# Module LIN1 - Infrastructure LIN1-LABO
#
# Ce script configure, sur une Debian 12 fraichement installee :
#   1. Le reseau (interface interne statique + routage/NAT pour le reseau
#      interne)
#   2. Le serveur DNS (BIND9) avec zones directe et inverse
#   3. Le serveur DHCP (isc-dhcp-server)
#   4. Le serveur LDAP (OpenLDAP), avec creation de la structure et
#      peuplement des groupes et utilisateurs
#
# PREREQUIS :
#   - Debian 12 (Bookworm) fraichement installee, avec 2 interfaces reseau :
#     ens33 = NAT (sortie Internet, temps de l'installation des paquets)
#     ens34 = Host-only (reseau interne LIN1-LABO, adresse 10.10.10.11)
#   - Ce script s'execute entierement en tant que root. Se connecter en
#     root (su -) puis lancer :
#       bash SRV-LIN1-01.sh
#   Sudo est installe au passage pour l'administration courante du
#   serveur une fois le script termine, mais n'est pas necessaire a
#   l'execution du script lui-meme.
#
# UTILISATION :
#   su -
#   bash SRV-LIN1-01.sh
#
# ============================================================================

# ----------------------------------------------------------------------------
# 0. VERIFICATION DES DROITS
# ----------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit etre execute en tant que root : su - puis bash SRV-LIN1-01.sh"
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

# ----------------------------------------------------------------------------
# 0. VARIABLES DE CONFIGURATION (a adapter si besoin)
# ----------------------------------------------------------------------------

IFACE_NAT="ens33"                  # Interface reseau NAT (sortie internet)
IFACE_LAN="ens34"                  # Interface reseau interne (Host-only)
IP_SRV01="10.10.10.11"             # IP statique de ce serveur
NETMASK="255.255.255.0"
DOMAIN="lin1-labo.local"
BASE_DN="dc=lin1-labo,dc=local"

DHCP_RANGE_START="10.10.10.100"
DHCP_RANGE_END="10.10.10.200"

LDAP_ADMIN_PASSWORD="Pa\$\$w0rd"    # Mot de passe administrateur LDAP
USER_DEFAULT_PASSWORD="Pa\$\$w0rd"  # Mot de passe par defaut des utilisateurs LDAP

CPNV_DNS_1="10.229.60.22"          # Forwarders DNS du reseau CPNV
CPNV_DNS_2="10.229.28.22"

echo "============================================================"
echo " SRV-LIN1-01 - Debut de l'installation automatisee"
echo "============================================================"

echo "Interface NAT (sortie internet)  : ${IFACE_NAT}"
echo "Interface interne (Host-only)    : ${IFACE_LAN}"

# Force le nom de la machine, quel que soit celui choisi a l'installation
# de Debian, pour garantir un resultat coherent avec l'infrastructure.
hostnamectl set-hostname srv-lin1-01
sed -i '/127.0.1.1/d' /etc/hosts
echo "127.0.1.1 srv-lin1-01.${DOMAIN} srv-lin1-01" >> /etc/hosts
echo "Nom de machine configure : srv-lin1-01"

# ============================================================================
# 1. CONFIGURATION RESEAU
# ============================================================================
echo ""
echo "---- [1/4] Configuration reseau ----"

cat > /etc/network/interfaces <<EOF
# Interface loopback
auto lo
iface lo inet loopback

# Interface NAT - sortie Internet
auto ${IFACE_NAT}
iface ${IFACE_NAT} inet dhcp

# Interface Host-only - reseau interne LIN1-LABO
auto ${IFACE_LAN}
iface ${IFACE_LAN} inet static
    address ${IP_SRV01}
    netmask ${NETMASK}
EOF

systemctl restart networking || true

# Activation du routage IP (le serveur agit comme passerelle pour le reseau interne)
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -p

apt update
apt install -y iptables

# Preconfiguration non-interactive d'iptables-persistent (evite l'ecran de
# confirmation de sauvegarde des regles IPv4/IPv6 lors de l'installation)
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
apt install -y iptables-persistent

iptables -t nat -A POSTROUTING -o ${IFACE_NAT} -j MASQUERADE
iptables -A FORWARD -i ${IFACE_LAN} -o ${IFACE_NAT} -j ACCEPT
iptables -A FORWARD -i ${IFACE_NAT} -o ${IFACE_LAN} -m state --state RELATED,ESTABLISHED -j ACCEPT
netfilter-persistent save

echo "Reseau configure : ${IFACE_LAN} = ${IP_SRV01}, routage NAT actif."

# ============================================================================
# 2. SERVEUR DNS (BIND9)
# ============================================================================
echo ""
echo "---- [2/4] Installation et configuration du DNS (BIND9) ----"

apt install -y bind9 bind9utils bind9-doc

cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";

    recursion yes;
    allow-recursion { 10.10.10.0/24; 127.0.0.1; };
    listen-on { ${IP_SRV01}; 127.0.0.1; };
    allow-transfer { none; };

    forwarders {
        ${CPNV_DNS_1};
        ${CPNV_DNS_2};
    };

    dnssec-validation no;

    listen-on-v6 { none; };
};
EOF

cat >> /etc/bind/named.conf.local <<EOF

zone "${DOMAIN}" {
    type master;
    file "/etc/bind/db.${DOMAIN}";
};

zone "10.10.10.in-addr.arpa" {
    type master;
    file "/etc/bind/db.10.10.10";
};
EOF

cp /etc/bind/db.local /etc/bind/db.${DOMAIN}
cat > /etc/bind/db.${DOMAIN} <<EOF
\$TTL    604800
@       IN      SOA     srv-lin1-01.${DOMAIN}. admin.${DOMAIN}. (
                              3         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@               IN      NS      srv-lin1-01.${DOMAIN}.
srv-lin1-01     IN      A       10.10.10.11
srv-lin1-02     IN      A       10.10.10.22
nas-lin1-01     IN      A       10.10.10.33
EOF

cp /etc/bind/db.127 /etc/bind/db.10.10.10
cat > /etc/bind/db.10.10.10 <<EOF
\$TTL    604800
@       IN      SOA     srv-lin1-01.${DOMAIN}. admin.${DOMAIN}. (
                              3         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      srv-lin1-01.${DOMAIN}.
11      IN      PTR     srv-lin1-01.${DOMAIN}.
22      IN      PTR     srv-lin1-02.${DOMAIN}.
33      IN      PTR     nas-lin1-01.${DOMAIN}.
EOF

named-checkconf
named-checkzone ${DOMAIN} /etc/bind/db.${DOMAIN}
named-checkzone 10.10.10.in-addr.arpa /etc/bind/db.10.10.10

systemctl restart named
systemctl enable named

echo "DNS configure : zones ${DOMAIN} (directe) et 10.10.10.in-addr.arpa (inverse)."

# ============================================================================
# 3. SERVEUR DHCP (isc-dhcp-server)
# ============================================================================
echo ""
echo "---- [3/4] Installation et configuration du DHCP ----"

apt install -y isc-dhcp-server

# Le paquet tente de demarrer le service des l'installation, avant que la
# configuration ne soit ecrite : on l'arrete pour eviter l'echec au boot.
systemctl stop isc-dhcp-server || true

cat > /etc/dhcp/dhcpd.conf <<EOF
# Configuration DHCP pour LIN1-LABO
option domain-name "${DOMAIN}";
option domain-name-servers ${IP_SRV01};

default-lease-time 600;
max-lease-time 7200;

ddns-update-style none;

authoritative;

subnet 10.10.10.0 netmask ${NETMASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${IP_SRV01};
    option domain-name-servers ${IP_SRV01};
    option domain-name "${DOMAIN}";
    option broadcast-address 10.10.10.255;
}
EOF

sed -i "s/INTERFACESv4=\"\"/INTERFACESv4=\"${IFACE_LAN}\"/" /etc/default/isc-dhcp-server

systemctl restart isc-dhcp-server
systemctl enable isc-dhcp-server

echo "DHCP configure : plage ${DHCP_RANGE_START} - ${DHCP_RANGE_END} sur ${IFACE_LAN}."

# ============================================================================
# 4. SERVEUR LDAP (OpenLDAP) + PEUPLEMENT
# ============================================================================
echo ""
echo "---- [4/4] Installation, configuration et peuplement de LDAP ----"

# Preconfiguration debconf pour une installation non-interactive de slapd
debconf-set-selections <<EOF
slapd slapd/internal/generated_adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/internal/adminpw password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password2 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/password1 password ${LDAP_ADMIN_PASSWORD}
slapd slapd/domain string ${DOMAIN}
slapd shared/organization string LIN1-LABO
slapd slapd/backend string MDB
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
slapd slapd/no_configuration boolean false
EOF

apt install -y slapd ldap-utils

dpkg-reconfigure -f noninteractive slapd

# Verification / correction du mot de passe administrateur LDAP : le
# preseed debconf n'est pas toujours repris par dpkg-reconfigure selon le
# contexte d'execution ; on force le mot de passe directement via LDIF pour
# garantir sa coherence avec LDAP_ADMIN_PASSWORD utilise plus loin.
LDAP_ADMIN_HASH=$(slappasswd -s "${LDAP_ADMIN_PASSWORD}")
cat > /tmp/admin_pw.ldif <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: ${LDAP_ADMIN_HASH}
EOF
ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/admin_pw.ldif
rm -f /tmp/admin_pw.ldif

# --- Structure de l'annuaire : OU + groupes ---
cat > /tmp/base.ldif <<EOF
dn: ou=people,${BASE_DN}
objectClass: organizationalUnit
ou: people

dn: ou=groups,${BASE_DN}
objectClass: organizationalUnit
ou: groups

dn: cn=manager,ou=groups,${BASE_DN}
objectClass: posixGroup
cn: manager
gidNumber: 5001

dn: cn=ingenieur,ou=groups,${BASE_DN}
objectClass: posixGroup
cn: ingenieur
gidNumber: 5002

dn: cn=developpeur,ou=groups,${BASE_DN}
objectClass: posixGroup
cn: developpeur
gidNumber: 5003
EOF

ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/base.ldif

# --- Peuplement des utilisateurs ---
cat > /tmp/users.ldif <<EOF
dn: uid=man01,ou=people,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: man01
sn: Manager01
givenName: Man
cn: Man Manager01
displayName: Man Manager01
uidNumber: 6001
gidNumber: 5001
userPassword: {CRYPT}x
loginShell: /bin/bash
homeDirectory: /home/man01

dn: uid=man02,ou=people,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: man02
sn: Manager02
givenName: Man
cn: Man Manager02
displayName: Man Manager02
uidNumber: 6002
gidNumber: 5001
userPassword: {CRYPT}x
loginShell: /bin/bash
homeDirectory: /home/man02

dn: uid=ing01,ou=people,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ing01
sn: Ingenieur01
givenName: Ing
cn: Ing Ingenieur01
displayName: Ing Ingenieur01
uidNumber: 6003
gidNumber: 5002
userPassword: {CRYPT}x
loginShell: /bin/bash
homeDirectory: /home/ing01

dn: uid=ing02,ou=people,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: ing02
sn: Ingenieur02
givenName: Ing
cn: Ing Ingenieur02
displayName: Ing Ingenieur02
uidNumber: 6004
gidNumber: 5002
userPassword: {CRYPT}x
loginShell: /bin/bash
homeDirectory: /home/ing02

dn: uid=dev01,ou=people,${BASE_DN}
objectClass: inetOrgPerson
objectClass: posixAccount
objectClass: shadowAccount
uid: dev01
sn: Developpeur01
givenName: Dev
cn: Dev Developpeur01
displayName: Dev Developpeur01
uidNumber: 6005
gidNumber: 5003
userPassword: {CRYPT}x
loginShell: /bin/bash
homeDirectory: /home/dev01
EOF

ldapadd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" -f /tmp/users.ldif

# Definition des mots de passe utilisateurs (mot de passe par defaut identique
# pour tous ; a personnaliser individuellement si besoin apres coup)
for USERID in man01 man02 ing01 ing02 dev01; do
    ldappasswd -x -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD}" \
        -s "${USER_DEFAULT_PASSWORD}" \
        "uid=${USERID},ou=people,${BASE_DN}"
done

# Nettoyage des fichiers temporaires (contiennent des donnees sensibles)
rm -f /tmp/base.ldif /tmp/users.ldif

echo "LDAP configure et peuple : 3 groupes, 5 utilisateurs."

# ============================================================================
# CONFIGURATION FINALE DU RESOLVEUR DNS LOCAL
# ============================================================================
# Effectue en dernier, une fois BIND9 installe et fonctionnel, pour que ce
# serveur utilise desormais son propre DNS plutot que celui du reseau NAT.
echo ""
echo "---- Configuration finale du resolveur DNS local ----"

# Empecher le client DHCP de l'interface NAT d'ecraser resolv.conf
cat >> /etc/dhcp/dhclient.conf <<EOF

# Forcer l'utilisation du DNS local (evite l'ecrasement par le DHCP du NAT)
supersede domain-name-servers ${IP_SRV01};
supersede domain-name "${DOMAIN}";
EOF

cat > /etc/resolv.conf <<EOF
domain ${DOMAIN}
search ${DOMAIN}
nameserver ${IP_SRV01}
EOF

echo "Resolveur local configure : nameserver ${IP_SRV01}"

# ============================================================================
# FIN
# ============================================================================
echo ""
echo "============================================================"
echo " SRV-LIN1-01 - Installation terminee avec succes"
echo "============================================================"
echo " DNS    : ${IP_SRV01} (zone ${DOMAIN})"
echo " DHCP   : plage ${DHCP_RANGE_START} - ${DHCP_RANGE_END}"
echo " LDAP   : ${BASE_DN}"
echo "============================================================"
