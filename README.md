# LIN1-LABO — Infrastructure réseau automatisée (module LIN1)

Scripts d'installation automatisée d'une petite infrastructure d'entreprise sous **Debian 12** :
DNS, DHCP, LDAP, passerelle Internet, serveur de fichiers Nextcloud et stockage NAS.

> Projet réalisé dans le cadre du module **LIN1** (CPNV) — auteur : **Ajin Sivasampoo**.

---

## Sommaire

1. [Architecture](#architecture)
2. [Contenu du dépôt](#contenu-du-dépôt)
3. [Prérequis](#prérequis)
4. [Utilisation](#utilisation)
5. [Ce que fait chaque script](#ce-que-fait-chaque-script)
6. [Récapitulatif affiché en fin d'exécution](#récapitulatif-affiché-en-fin-dexécution)
7. [Droits d'accès (Nextcloud)](#droits-daccès-nextcloud)
8. [Étapes réalisées après les scripts](#étapes-réalisées-après-les-scripts)
9. [Dépannage](#dépannage)
10. [Notes de sécurité](#notes-de-sécurité)

---

## Architecture

| Machine | Rôle | Adresse IP |
|---|---|---|
| `SRV-LIN1-01` | DNS (BIND9), DHCP, LDAP (OpenLDAP), passerelle et NAT | `10.10.10.11` |
| `SRV-LIN1-02` | Nextcloud (Apache, MariaDB, PHP) | `10.10.10.22` |
| `NAS-LIN1-01` | OpenMediaVault, RAID 1 logiciel, NFS, iSCSI | `10.10.10.33` |
| Client Linux | Poste de test (Debian 12, sans interface graphique) | DHCP `10.10.10.100–200` |
| Client Windows | Poste de test (client Nextcloud) | DHCP `10.10.10.100–200` |

```
                        Internet / réseau CPNV
                                  |
                                  | ens33 (NAT)
                         +------------------+
                         |   SRV-LIN1-01    |   DNS · DHCP · LDAP
                         |   10.10.10.11    |   passerelle + NAT
                         +--------+---------+
                                  | ens34 (Host-only, 10.10.10.0/24)
        +-----------+-------------+-------------+----------------+
        |           |                           |                |
+---------------+ +---------------+   +----------------+  +----------------+
| SRV-LIN1-02   | | NAS-LIN1-01   |   | Client Linux   |  | Client Windows |
| Nextcloud     | | RAID 1        |   | (DHCP)         |  | (DHCP)         |
| 10.10.10.22   | | NFS + iSCSI   |   +----------------+  +----------------+
+-------+-------+ | 10.10.10.33   |
        |         +-------+-------+
        +-----NFS / iSCSI-+
```

Domaine interne : `lin1-labo.local` — annuaire LDAP : `dc=lin1-labo,dc=local`.

---

## Contenu du dépôt

| Fichier | Description |
|---|---|
| `SRV-LIN1-01.sh` | Installation de SRV-LIN1-01 : réseau, routage/NAT, DNS, DHCP, LDAP peuplé |
| `SRV-LIN1-02.sh` | Installation de SRV-LIN1-02 : réseau, montage NFS du NAS, Nextcloud en HTTPS |
| `README.md` | Ce fichier |

---

## Prérequis

- Machines virtuelles (VMware Workstation) avec **Debian 12 « Bookworm » fraîchement installée**,
  sans interface graphique.
- Réseau interne **Host-only (VMnet2)** en `10.10.10.0/24`, **DHCP de VMware désactivé** sur ce réseau.
- `SRV-LIN1-01` : deux cartes réseau — NAT (`ens33`, accès Internet) et Host-only (`ens34`).
- `SRV-LIN1-02` : une carte Host-only ; son accès Internet passe par SRV-LIN1-01.
- **`NAS-LIN1-01` démarré en premier**, avec l'export NFS `/export/nextcloud-data` accessible au réseau
  `10.10.10.0/24` et l'option **`no_root_squash`** (sans elle, `www-data` ne peut pas écrire dans le partage).
- Exécution en **root** (`su -`) avec un accès Internet pour télécharger les paquets.

**Ordre de lancement : NAS → `SRV-LIN1-01.sh` → `SRV-LIN1-02.sh`.**

---

## Utilisation

Sur chaque serveur, en root :

```bash
su -
wget -O SRV-LIN1-01.sh https://raw.githubusercontent.com/14Ajin/LIN1-LABO/main/SRV-LIN1-01.sh
bash SRV-LIN1-01.sh          # sur SRV-LIN1-01
```

```bash
su -
wget -O SRV-LIN1-02.sh https://raw.githubusercontent.com/14Ajin/LIN1-LABO/main/SRV-LIN1-02.sh
bash SRV-LIN1-02.sh          # sur SRV-LIN1-02
```

Les scripts ne demandent **aucun paramètre** et s'arrêtent à la première erreur (`set -e`).
Le téléchargement de Nextcloud (≈ 315 Mo) peut prendre plusieurs minutes.

---

## Ce que fait chaque script

### `SRV-LIN1-01.sh`

1. **Réseau** : nom de machine, IP statique `10.10.10.11` sur `ens34`, `ens33` en DHCP (NAT).
2. **Routage** : activation de l'IP forwarding et du NAT (iptables, règles rendues persistantes).
3. **DNS (BIND9)** : zone directe `lin1-labo.local`, zone inverse `10.10.10.in-addr.arpa`,
   redirecteurs DNS du CPNV.
4. **DHCP (isc-dhcp-server)** : plage `10.10.10.100–200`, passerelle et DNS = `10.10.10.11`,
   écoute sur `ens34` uniquement.
5. **LDAP (OpenLDAP)** : structure de l'annuaire, **3 groupes** (`manager`, `ingenieur`,
   `developpeur`) et **5 utilisateurs** (`man01`, `man02`, `ing01`, `ing02`, `dev01`) avec leurs mots de passe.
6. **Résolveur local** : le serveur utilise son propre DNS.

### `SRV-LIN1-02.sh`

1. **Réseau** : nom de machine, IP statique `10.10.10.22`, passerelle et DNS = `10.10.10.11`.
2. **Partage** : montage NFS `10.10.10.33:/export/nextcloud-data` sur `/mnt/nfs-nas`
   (persistant dans `/etc/fstab`) et contrôle d'écriture.
3. **Nextcloud** : Apache, MariaDB, PHP 8.2, base de données, **Nextcloud 34.0.3**,
   certificat SSL auto-signé, virtual hosts HTTP/HTTPS (`Alias /nextcloud`), installation en ligne de
   commande avec le **répertoire de données sur le NAS** (`/mnt/nfs-nas/data`), domaines de confiance,
   application **Calendrier**.

Nextcloud est accessible sur **`https://10.10.10.22/nextcloud`** (et `https://10.10.10.22`).

---

## Récapitulatif affiché en fin d'exécution

À la fin, chaque script affiche automatiquement ce qu'il a configuré, sans commande de vérification à saisir :

- **SRV-LIN1-01** : nom de la machine, interfaces et IP, routage et NAT, accès Internet, état de
  `named`, `isc-dhcp-server` et `slapd`, enregistrements DNS directs et inverse, plage DHCP, groupes et
  utilisateurs LDAP.
- **SRV-LIN1-02** : réseau, passerelle, DNS, montage NFS, état d'`apache2` et de `mariadb`, version de PHP,
  version de Nextcloud, répertoire de données, domaines de confiance, application Calendrier, comptes
  présents et réponse HTTPS.

Le dernier message est : `SRV-LIN1-0X - Installation terminee avec succes`.

---

## Droits d'accès (Nextcloud)

| Dossier | Quota | `manager` | `ingenieur` | `developpeur` |
|---|---|---|---|---|
| Clients | 20 Mo | lecture / écriture | aucun accès | aucun accès |
| Logiciels | 20 Mo | aucun accès | lecture / écriture | lecture / écriture |
| Commun | 30 Mo | lecture seule | lecture / écriture | lecture / écriture |
| Répertoire personnel | 10 Mo | chaque utilisateur | chaque utilisateur | chaque utilisateur |

---

## Étapes réalisées après les scripts

Conformément au cahier des charges, `SRV-LIN1-02.sh` se limite au réseau, à l'installation de Nextcloud et au
partage. Les étapes suivantes sont faites ensuite avec `occ` et sont décrites dans la documentation technique :

- liaison LDAP de Nextcloud (section 7.6) ;
- dossiers de groupe Clients / Logiciels / Commun, quotas et droits (section 7.7) ;
- client iSCSI (section 7.9) et installation de LAM (section 5.6).

---

## Dépannage

| Symptôme | Cause et solution |
|---|---|
| `Job for networking.service failed` au début d'un script | Sans conséquence si le script poursuit et affiche l'adresse configurée. Contrôler avec `ip -br a`. |
| `ERREUR : www-data ne peut pas ecrire dans /mnt/nfs-nas/data` | L'export NFS du NAS n'a pas `no_root_squash`. Ajouter l'option sur le NAS puis relancer le script. |
| `Login is invalid because files already exist for this user` | Le répertoire de données du NAS contient déjà une installation précédente. Le renommer sur le NAS (`mv data data-ancien`) ou indiquer un autre dossier : `NC_DATA_DIR=/mnt/nfs-nas/data-test bash SRV-LIN1-02.sh`. |
| `Access through untrusted domain` | L'adresse n'est pas dans `trusted_domains` : `occ config:system:set trusted_domains <n> --value=<adresse>`. |
| Alerte SSH `REMOTE HOST IDENTIFICATION HAS CHANGED` | Nouvelle machine sur la même IP : `ssh-keygen -R <adresse_ip>`. |
| Pas d'accès Internet depuis SRV-LIN1-02 | Vérifier que SRV-LIN1-01 est démarré, que `ip_forward` vaut `1` et que la règle `MASQUERADE` est présente. |

---

## Notes de sécurité

- Les mots de passe des scripts (`Pa$$w0rd`, etc.) sont des **valeurs de laboratoire** définies en clair
  en tête de script pour permettre l'automatisation. **Ne pas les réutiliser en production.**
- Le certificat SSL est **auto-signé** : l'avertissement du navigateur est normal en laboratoire.
- L'annuaire LDAP est interrogé en clair (port 389, sans LDAPS) : acceptable uniquement sur un réseau isolé.
- `no_root_squash` donne les droits root du client sur le partage NFS : à limiter au réseau `10.10.10.0/24`.

---

## Auteur

**Ajin Sivasampoo** — module LIN1, CPNV.
