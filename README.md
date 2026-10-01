\# LIN1-LABO Scripts



Scripts d'automatisation infrastructure CPNV Module LIN1.



\## Scripts



\### SRV-LIN1-01.sh

Infrastructure réseau : Réseau, DNS (BIND9), DHCP, LDAP

\- Configure 10.10.10.11

\- 5 utilisateurs LDAP, 3 groupes

\- Temps : \~15 min



\*\*Usage:\*\*

```bash

su -

bash SRV-LIN1-01.sh

```



\### SRV-LIN1-02.sh

Nextcloud : Apache, MariaDB, PHP, Nextcloud 34.0.3

\- Configure 10.10.10.22

\- Montage NAS en NFS

\- Temps : \~15 min



\*\*Usage:\*\*

```bash

su -

bash SRV-LIN1-02.sh

```



\## Prérequis



\### SRV-LIN1-01

\- Debian 12 fraîche

\- 2 interfaces réseau (ens33 NAT, ens34 Host-only)

\- Root access



\### SRV-LIN1-02

\- Debian 12 fraîche

\- 1 interface (ens33 Host-only)

\- SRV-LIN1-01 + NAS opérationnels

\- Root access



\## Status



✅ Testé et validé

