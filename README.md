# LIN1 - Scripts d'installation de l'infrastructure

Scripts Bash qui installent et configurent automatiquement les serveurs de l'infrastructure LIN1, sur des VMs Debian 13 (trixie) fraîchement installées.

| Script | Serveur | Rôle |
|---|---|---|
| `SRV-LIN1-01.sh` | SRV-LIN1-01 (10.10.10.11) | Réseau, partage de connexion (NAT), DNS bind9, DHCP, LDAP + peuplement, LAM |
| `SRV-LIN1-02.sh` | SRV-LIN1-02 (10.10.10.22) | Réseau, Nextcloud (Apache, PHP, MariaDB, HTTPS), utilisateurs LDAP, partages du NAS |
| `samba.ldif` | - | Schéma samba chargé dans LDAP par `SRV-LIN1-01.sh` (utilisé par le NAS) |

## Infrastructure

```
            Internet (NAT VMware 192.168.32.0/24)
                 |                         |
            ens33 (DHCP)              ens37 192.168.32.130
         +---------------+         +---------------+
         |  SRV-LIN1-01  |         |  SRV-LIN1-02  |
         | DNS DHCP LDAP |         |   Nextcloud   |
         |  LAM  NAT     |         |               |
         +---------------+         +---------------+
            ens34 .11                 ens33 .22
                 |                         |
   ------------- réseau interne 10.10.10.0/24 ----------------
                 |                         |
          NAS-LIN1-01 .33           clients DHCP .100 - .200
          (partages SMB)
```

- Domaine DNS : `LIN1.internal`
- Base LDAP : `dc=LIN1,dc=internal` (utilisateurs dans `ou=Users`, groupes dans `ou=Groups`)
- Nextcloud : `https://10.10.10.22/nextcloud`
- LAM : `http://10.10.10.11/lam`

## Utilisation

Sur chaque serveur, en `root` (de préférence depuis la console de la VM, car le script reconfigure le réseau) :

```bash
apt-get install -y git
git clone https://github.com/Zachary-SMITH-CPNV/LIN1-Scripts.git
cd LIN1-Scripts
chmod +x SRV-LIN1-0*.sh

./SRV-LIN1-01.sh     # sur SRV-LIN1-01, en premier
./SRV-LIN1-02.sh     # sur SRV-LIN1-02, une fois SRV-LIN1-01 et le NAS en service
```

L'ordre compte : `SRV-LIN1-02.sh` a besoin du DNS et du LDAP de SRV-LIN1-01, et des partages SMB du NAS.

Les mots de passe par défaut sont ceux du laboratoire (`Pa$$w0rd`). On peut les changer sans modifier le script :

```bash
LDAP_ADMIN_PASS='...' USER_PASS='...' ./SRV-LIN1-01.sh
NC_ADMIN_PASS='...' DB_PASS='...' LDAP_ADMIN_PASS='...' ./SRV-LIN1-02.sh
```

Si les noms des cartes réseau sont différents sur la machine, on peut aussi les donner ainsi : `WAN_IF=ens33 LAN_IF=ens34 ./SRV-LIN1-01.sh`.

**Connexion lente ou coupée** : `SRV-LIN1-02.sh` télécharge Nextcloud (environ 250 Mo) et reprend automatiquement le téléchargement si la connexion est coupée. Si une archive `latest.tar.bz2` de Nextcloud est placée à côté du script, elle est utilisée directement, sans téléchargement.

Les autres paramètres (noms d'interfaces, adresses IP, utilisateurs, groupes, partages) sont regroupés en haut de chaque script, dans la section **Paramètres**.

Les scripts peuvent être relancés sans risque : chaque étape vérifie ce qui existe déjà (entrées LDAP, installation Nextcloud, points de montage…) avant d'agir. Tout ce qui s'affiche est aussi enregistré dans `/var/log/SRV-LIN1-0X_install.log`.

## Ce que fait `SRV-LIN1-01.sh`

1. **Réseau** : nom d'hôte, `/etc/hosts`, `ens33` en DHCP (WAN), `ens34` en `10.10.10.11/24` (LAN).
2. **Paquets** : ajoute les dépôts Debian si seul le CD est configuré, puis installe bind9, isc-dhcp-server, slapd, nftables, apache2 et LAM. Les questions de slapd sont pré-remplies (debconf).
3. **Partage de connexion** : active le routage IPv4 et un NAT `masquerade` (nftables, persistant au redémarrage) pour que le réseau 10.10.10.0/24 accède à Internet.
4. **DNS** : zone directe `LIN1.internal` (srv-lin1-01, srv-lin1-02, nas-lin1-01, alias ldap/lam/nextcloud), zone inverse `10.10.10.in-addr.arpa`, forwarder vers la passerelle VMware. Les fichiers sont vérifiés avec `named-checkconf` et `named-checkzone`.
5. **DHCP** : plage `10.10.10.100 - 10.10.10.200` sur `ens34`, DNS et domaine distribués aux clients.
6. **LDAP** : base `dc=LIN1,dc=internal`, chargement du schéma samba.
7. **Peuplement de l'annuaire** :

   | Groupe (gid) | Utilisateurs (uid) |
   |---|---|
   | Manager (10001) | man01 (10001), man02 (10002) |
   | Ingenieur (10002) | ing01 (10003), ing02 (10004) |
   | Developpeur (10003) | dev01 (10005) |

   Pour ajouter un utilisateur, il suffit d'ajouter une ligne `"uid:uidNumber:groupe"` dans `LDAP_USERS`.
8. **LAM** : configuration pour la base `dc=LIN1,dc=internal`, accessible sur `http://10.10.10.11/lam`.

## Ce que fait `SRV-LIN1-02.sh`

1. **Réseau** : nom d'hôte, `ens33` en `10.10.10.22/24` (LAN), `ens37` en `192.168.32.130/24` (WAN), DNS = SRV-LIN1-01.
2. **Apache, PHP 8.4, MariaDB** : installation, réglages PHP recommandés (mémoire, taille d'upload, APCu), création de la base `nextcloud`.
3. **Nextcloud** : téléchargement de la dernière version (somme SHA-256 vérifiée), installation avec `occ maintenance:install`, domaines de confiance, cron toutes les 5 minutes, application Calendrier.
4. **HTTPS** : certificat auto-signé (IP 10.10.10.22, SRV-LIN1-02, nextcloud.LIN1.internal), Nextcloud sur `https://10.10.10.22/nextcloud`, HTTP redirigé vers HTTPS.
5. **LDAP** : les utilisateurs et groupes de SRV-LIN1-01 se connectent à Nextcloud avec leur compte LDAP. La configuration est testée avec `occ ldap:test-config`.
6. **Partages du NAS** (SMB, identifiants de connexion de l'utilisateur) :

   | Dossier Nextcloud | Partage SMB | Accès |
   |---|---|---|
   | `/Commun` | `//10.10.10.33/Commun` | tous les utilisateurs |
   | `/Logiciels` | `//10.10.10.33/Logiciels` | Developpeur, Ingenieur |
   | `/Clients` | `//10.10.10.33/Clients` | Manager |
   | `/Personnel` | `//10.10.10.33/$user` | chaque utilisateur, son propre dossier |

   Les droits fins (ACL, quotas) sont appliqués par le NAS : Nextcloud se connecte au partage avec le compte de l'utilisateur.

## Vérifications rapides

```bash
# Sur SRV-LIN1-01
dig @127.0.0.1 srv-lin1-02.LIN1.internal
dig @127.0.0.1 -x 10.10.10.22
systemctl status isc-dhcp-server
ldapsearch -x -LLL -b ou=Users,dc=LIN1,dc=internal uid

# Sur SRV-LIN1-02
sudo -u www-data php /var/www/nextcloud/occ status
sudo -u www-data php /var/www/nextcloud/occ user:list
sudo -u www-data php /var/www/nextcloud/occ files_external:list
```
