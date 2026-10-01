# LIN1-LABO Scripts

Scripts d'automatisation complète pour infrastructure réseau CPNV Module LIN1.

## 🎯 Objectif

Installation et configuration automatisée de l'infrastructure LIN1-LABO en tant que root.
Totalement non-interactive = lancer et oublier.

## 📋 Scripts

### SRV-LIN1-01.sh
**Infrastructure Réseau - Serveur Principal (10.10.10.11)**

Installe et configure :
- **Réseau** : Interface statique + routage NAT
- **DNS (BIND9)** : Zones directe/inverse pour lin1-labo.local
- **DHCP** : Serveur avec pool 10.10.10.100-200
- **LDAP (OpenLDAP)** : Annuaire avec 3 groupes (manager, ingenieur, developpeur) + 5 utilisateurs

**Exécution :**
```bash
su -
bash SRV-LIN1-01.sh
```

**Temps :** 10-15 minutes
**Résultat :** Infrastructure réseau complètement opérationnelle

### SRV-LIN1-02.sh
**Nextcloud - Serveur Cloud & Stockage (10.10.10.22)**

Installe et configure :
- **Réseau** : Interface statique 10.10.10.22
- **Apache 2** : Virtual hosts HTTP/HTTPS avec SSL auto-signé
- **MariaDB** : Base de données Nextcloud
- **PHP 8.2** : Extensions (LDAP, MySQL, GD, etc.)
- **Nextcloud 34.0.3** : Cloud personnel avec admin ncadmin
- **NFS** : Montage automatique du NAS (10.10.10.33:/export/nextcloud-data)

**Exécution :**
```bash
su -
bash SRV-LIN1-02.sh
```

**Temps :** 10-15 minutes (+ téléchargement Nextcloud ~300MB)
**Accès :** https://10.10.10.22

## 🔧 Prérequis

### Pour SRV-LIN1-01.sh
- **OS :** Debian 12 (Bookworm) fraîche
- **Interfaces réseau :** ens33 (NAT), ens34 (Host-only 10.10.10.0/24)
- **RAM :** 1 GB minimum
- **Disque :** 10 GB minimum
- **Exécution :** En tant que **root** (`su -`)
- **Internet :** Connexion active

### Pour SRV-LIN1-02.sh
- **OS :** Debian 12 (Bookworm) fraîche
- **Interface réseau :** ens33 (Host-only 10.10.10.0/24)
- **RAM :** 2 GB minimum
- **Disque :** 20 GB minimum
- **Exécution :** En tant que **root** (`su -`)
- **Dépendances :** SRV-LIN1-01 et NAS-LIN1-01 opérationnels
- **Internet :** Connexion active

## 🔐 Identifiants Par Défaut

### LDAP (SRV-LIN1-01)
- Admin DN : `cn=admin,dc=lin1-labo,dc=local`
- Password : `Pa$$w0rd`

Utilisateurs créés :
- **Managers :** man01, man02 (gid 5001)
- **Ingénieurs :** ing01, ing02 (gid 5002)
- **Développeurs :** dev01 (gid 5003)
- Password utilisateurs : `Pa$$w0rd`

### Nextcloud (SRV-LIN1-02)
- Admin user : `ncadmin`
- Password : `Pa$$w0rd`
- DB user : `nextclouduser`
- DB password : `Pa$$w0rd`

## ⚙️ Variables Configurables

### SRV-LIN1-01.sh (début du fichier)
```bash
IFACE_NAT="ens33"                    # Interface NAT
IFACE_LAN="ens34"                    # Interface interne
IP_SRV01="10.10.10.11"              # IP du serveur
DOMAIN="lin1-labo.local"            # Domaine LDAP
DHCP_RANGE_START="10.10.10.100"     # Pool DHCP début
DHCP_RANGE_END="10.10.10.200"       # Pool DHCP fin
LDAP_ADMIN_PASSWORD="Pa$$w0rd"      # Admin LDAP
USER_DEFAULT_PASSWORD="Pa$$w0rd"    # Password utilisateurs
```

### SRV-LIN1-02.sh (début du fichier)
```bash
IFACE_LAN="ens33"                   # Interface réseau
IP_SRV02="10.10.10.22"              # IP du serveur
GATEWAY="10.10.10.11"               # Passerelle
NAS_IP="10.10.10.33"                # IP du NAS
NC_ADMIN_USER="ncadmin"             # Admin Nextcloud
NC_ADMIN_PASSWORD="Pa$$w0rd"        # Password Nextcloud
NEXTCLOUD_VERSION="34.0.3"          # Version Nextcloud
```

## ✅ Tests & Validation

- ✅ SRV-LIN1-01.sh : Testé sur VM Test-Script-01
- ✅ SRV-LIN1-02.sh : Testé sur VM Test-Script-02
- ✅ Tous les services opérationnels
- ✅ Configuration persistante après reboot

## ⚠️ Important

1. **Mots de passe :** À modifier après installation en production
2. **Certificat SSL :** Auto-signé pour le lab. Utiliser Let's Encrypt en production
3. **LDAP dans Nextcloud :** Configuration manuelle après script (voir documentation)
4. **Group Folders :** Créer manuellement après config LDAP

## 📚 Documentation Complète

Voir `Documentation_LIN1_LABO.docx` pour :
- Description détaillée de chaque service
- Instructions installation & configuration
- Exemples d'utilisation et tests
- Guide dépannage complet
- Bonnes pratiques de sécurité

## 📄 Licence

MIT License

---

**État :** Production-Ready ✅ Testé
**Version :** 1.0
**Date :** 2026-10-01