#!/usr/bin/env bash
#
# SRV-LIN1-02.sh - Installation automatisée du serveur Nextcloud SRV-LIN1-02
#
# Ce script configure, sur une Debian 13 (trixie) fraîchement installée :
#   1. le réseau (interface LAN 10.10.10.22, interface WAN, DNS = SRV-LIN1-01)
#   2. Apache + PHP + MariaDB
#   3. Nextcloud (téléchargement, base de données, installation, HTTPS)
#   4. l'authentification des utilisateurs par l'annuaire LDAP de SRV-LIN1-01
#   5. le partage : montage des partages SMB du NAS dans Nextcloud
#      (Commun, Logiciels, Clients, Personnel) selon les groupes LDAP
#
# Prérequis : SRV-LIN1-01 (DNS + LDAP) et NAS-LIN1-01 (partages SMB) sont en service.
#
# Utilisation (en root, depuis la console de la VM de préférence) :
#   chmod +x SRV-LIN1-02.sh
#   ./SRV-LIN1-02.sh
#
# Les mots de passe peuvent être donnés par variables d'environnement :
#   NC_ADMIN_PASS='...' DB_PASS='...' LDAP_ADMIN_PASS='...' ./SRV-LIN1-02.sh
#
# Le script peut être relancé : chaque étape vérifie ce qui existe déjà.
# Journal complet : /var/log/SRV-LIN1-02_install.log

set -euo pipefail

# ---------------------------------------------------------------------------
# Paramètres (à adapter si l'environnement change)
# ---------------------------------------------------------------------------
HOSTNAME_SRV="SRV-LIN1-02"

LAN_IF="${LAN_IF:-ens33}"       # interface côté réseau interne LIN1
LAN_IP="10.10.10.22"
LAN_NETMASK="255.255.255.0"
WAN_IF="${WAN_IF:-ens37}"       # interface côté Internet (NAT VMware)
WAN_IP="192.168.32.130/24"
WAN_GW="192.168.32.2"

DOMAIN="LIN1.internal"
DNS_SERVER="10.10.10.11"        # SRV-LIN1-01
NAS_IP="10.10.10.33"            # NAS-LIN1-01

NC_DIR="/var/www/nextcloud"
NC_DATA="${NC_DIR}/data"
NC_URL="https://${LAN_IP}/nextcloud"
NC_DOWNLOAD="https://download.nextcloud.com/server/releases/latest.tar.bz2"
NC_ADMIN="admin"
NC_ADMIN_PASS="${NC_ADMIN_PASS:-Pa\$\$w0rd}"

DB_NAME="nextcloud"
DB_USER="nextcloud"
DB_PASS="${DB_PASS:-Pa\$\$w0rd}"

LDAP_HOST="10.10.10.11"
LDAP_BASE="dc=LIN1,dc=internal"
LDAP_ADMIN_DN="cn=admin,${LDAP_BASE}"
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:-Pa\$\$w0rd}"

# Partages SMB du NAS : "point de montage:partage:groupes autorisés"
# (groupes séparés par des virgules ; vide = tous les utilisateurs)
# $user est remplacé par Nextcloud par le nom de l'utilisateur connecté.
NAS_MOUNTS=(
    "/Commun:Commun:"
    "/Logiciels:Logiciels:Developpeur,Ingenieur"
    "/Clients:Clients:Manager"
    "/Personnel:\$user:"
)

SSL_CERT="/etc/ssl/certs/nextcloud-lin1.crt"
SSL_KEY="/etc/ssl/private/nextcloud-lin1.key"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/${HOSTNAME_SRV}_install.log"

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------
etape() { echo; echo "==== $* ===="; }
info()  { echo "  -> $*"; }
erreur() { echo "ERREUR : $*" >&2; exit 1; }

# XDG_CACHE_HOME : www-data n'a pas de dossier de cache inscriptible (évite les messages Fontconfig)
occ() { sudo -u www-data env XDG_CACHE_HOME=/tmp php "${NC_DIR}/occ" --no-interaction "$@"; }

# Lit une sortie JSON de occ sur l'entrée standard et affiche une liste :
#   json_cles      -> les clés de premier niveau (ex. identifiants de config LDAP)
#   json_champ X   -> le champ X de chaque élément (ex. mount_point)
json_cles()  { php -r '$d = json_decode(stream_get_contents(STDIN), true) ?: []; foreach (array_keys($d) as $k) echo $k, "\n";'; }
json_champ() { php -r '$d = json_decode(stream_get_contents(STDIN), true) ?: []; foreach ($d as $e) echo $e[$argv[1]], "\n";' "$1"; }

verifier_prerequis() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root"
    for iface in "$LAN_IF" "$WAN_IF"; do
        ip link show "$iface" >/dev/null 2>&1 \
            || erreur "interface $iface introuvable (interfaces présentes : $(ls /sys/class/net | tr '\n' ' '))"
    done
}

# ---------------------------------------------------------------------------
# 1. Réseau
# ---------------------------------------------------------------------------
configurer_reseau() {
    etape "1. Configuration du réseau"

    hostnamectl set-hostname "$HOSTNAME_SRV"
    info "nom d'hôte : $HOSTNAME_SRV"

    cat > /etc/hosts <<EOF
127.0.0.1	localhost
${LAN_IP}	${HOSTNAME_SRV}.${DOMAIN} ${HOSTNAME_SRV} nextcloud.${DOMAIN}
10.10.10.11	SRV-LIN1-01.${DOMAIN} SRV-LIN1-01
${NAS_IP}	NAS-LIN1-01.${DOMAIN} NAS-LIN1-01

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    # Arrête les interfaces avec leur ancienne configuration (ex. client DHCP)
    for iface in "$LAN_IF" "$WAN_IF"; do
        ifdown "$iface" 2>/dev/null || true
        dhcpcd -x "$iface" 2>/dev/null || true
    done

    cat > /etc/network/interfaces <<EOF
# Généré par SRV-LIN1-02.sh
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# LAN : réseau interne LIN1
auto ${LAN_IF}
iface ${LAN_IF} inet static
    address ${LAN_IP}
    netmask ${LAN_NETMASK}

# WAN : accès Internet via le NAT VMware
auto ${WAN_IF}
iface ${WAN_IF} inet static
    address ${WAN_IP}
    gateway ${WAN_GW}
EOF
    info "/etc/network/interfaces écrit (LAN ${LAN_IF} = ${LAN_IP}, WAN ${WAN_IF} = ${WAN_IP})"

    # Applique la nouvelle configuration
    for iface in "$LAN_IF" "$WAN_IF"; do
        ip addr flush dev "$iface"
        ifup "$iface"
    done
    ip -br addr

    # Le DNS interne (SRV-LIN1-01) résout LIN1.internal et transmet le reste
    # (écrit après ifup, pour qu'un ancien client DHCP ne l'écrase pas)
    printf 'search %s\nnameserver %s\n' "$DOMAIN" "$DNS_SERVER" > /etc/resolv.conf

    # Le réseau VMware n'a pas d'IPv6 : on fait préférer l'IPv4 à tous les
    # programmes (curl, PHP...), sinon ils restent bloqués sur les adresses IPv6
    grep -qs '^precedence ::ffff:0:0/96' /etc/gai.conf \
        || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

    getent hosts "srv-lin1-01.${DOMAIN}" >/dev/null \
        && info "DNS OK : srv-lin1-01.${DOMAIN} résolu" \
        || info "ATTENTION : le DNS ${DNS_SERVER} ne répond pas (SRV-LIN1-01 est-il démarré ?)"
}

# ---------------------------------------------------------------------------
# 2. Apache, PHP, MariaDB
# ---------------------------------------------------------------------------
installer_paquets() {
    etape "2. Installation d'Apache, PHP et MariaDB"

    if ! grep -rqs "deb.debian.org" /etc/apt/sources.list /etc/apt/sources.list.d/; then
        info "ajout des dépôts Debian officiels"
        cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
        sed -i 's/^deb cdrom/# deb cdrom/' /etc/apt/sources.list 2>/dev/null || true
    fi

    # Le réseau VMware n'a pas d'IPv6 : sans cette option, apt insiste sur les
    # adresses IPv6 des miroirs et finit par épuiser la mémoire
    echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        apache2 libapache2-mod-php mariadb-server \
        php php-cli php-mysql php-gd php-curl php-mbstring php-intl php-gmp \
        php-bcmath php-xml php-zip php-imagick php-ldap php-apcu \
        php-smbclient smbclient \
        bzip2 curl sudo openssl ldap-utils

    # Réglages PHP recommandés par Nextcloud
    local ini
    for ini in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini; do
        sed -i \
            -e 's/^memory_limit = .*/memory_limit = 512M/' \
            -e 's/^upload_max_filesize = .*/upload_max_filesize = 512M/' \
            -e 's/^post_max_size = .*/post_max_size = 512M/' \
            -e 's/^max_execution_time = .*/max_execution_time = 300/' \
            -e 's|^;\?date.timezone =.*|date.timezone = Europe/Zurich|' \
            "$ini"
    done
    echo "apc.enable_cli=1" > "$(ls -d /etc/php/*/cli/conf.d | head -1)/99-apcu-cli.ini"
    info "PHP $(php -r 'echo PHP_VERSION;') configuré"

    systemctl enable --now mariadb
    mysql <<EOF
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
    info "base MariaDB ${DB_NAME} prête (utilisateur ${DB_USER})"
}

# ---------------------------------------------------------------------------
# 3. Nextcloud
# ---------------------------------------------------------------------------
installer_nextcloud() {
    etape "3. Installation de Nextcloud"

    if [[ ! -f "${NC_DIR}/occ" ]]; then
        local archive="${SCRIPT_DIR}/latest.tar.bz2"
        if [[ -f "$archive" ]]; then
            # Archive déjà présente à côté du script : pas de téléchargement
            info "utilisation de l'archive locale ${archive}"
        else
            archive="/tmp/latest.tar.bz2"
            info "téléchargement de ${NC_DOWNLOAD}"
            # Reprise automatique si la connexion est coupée en cours de route
            local essai
            for essai in {1..10}; do
                curl -4 -fSL -C - "$NC_DOWNLOAD" -o "$archive" && break
                [[ $essai -lt 10 ]] || erreur "téléchargement de Nextcloud impossible"
                info "connexion coupée, reprise (essai $((essai + 1))/10)"
                sleep 5
            done
            curl -4 -fsSL --retry 5 "${NC_DOWNLOAD}.sha256" -o "${archive}.sha256"
            # Le fichier .sha256 liste aussi latest.metadata : on ne garde que l'archive
            (cd /tmp && grep ' latest.tar.bz2$' latest.tar.bz2.sha256 | sha256sum -c -) \
                || { rm -f "$archive"; erreur "somme de contrôle Nextcloud incorrecte"; }
            rm -f "${archive}.sha256"
        fi
        tar -xjf "$archive" -C /var/www/
        [[ "$archive" == /tmp/* ]] && rm -f "$archive"
        chown -R www-data:www-data "$NC_DIR"
        info "Nextcloud extrait dans ${NC_DIR}"
    fi

    if occ status --output=json 2>/dev/null | grep -q '"installed":true'; then
        info "Nextcloud est déjà installé"
    else
        occ maintenance:install \
            --database mysql \
            --database-name "$DB_NAME" \
            --database-user "$DB_USER" \
            --database-pass "$DB_PASS" \
            --admin-user "$NC_ADMIN" \
            --admin-pass "$NC_ADMIN_PASS" \
            --data-dir "$NC_DATA"
        info "Nextcloud installé (administrateur : ${NC_ADMIN})"
    fi

    occ config:system:set trusted_domains 0 --value="$LAN_IP"
    occ config:system:set trusted_domains 1 --value="$HOSTNAME_SRV"
    occ config:system:set trusted_domains 2 --value="nextcloud.${DOMAIN}"
    occ config:system:set overwrite.cli.url --value="$NC_URL"
    occ config:system:set memcache.local --value='\OC\Memcache\APCu'
    occ config:system:set default_phone_region --value="CH"
    occ config:system:set maintenance_window_start --type=integer --value=1

    # Tâches de fond par cron toutes les 5 minutes
    occ background:cron
    echo "*/5 * * * * php -f ${NC_DIR}/cron.php" | crontab -u www-data -
    info "cron Nextcloud configuré"

    # Application Calendrier (utilisée dans le POC)
    occ app:install calendar 2>/dev/null || occ app:enable calendar || info "ATTENTION : calendrier non installé"
}

# Certificat auto-signé + VirtualHosts Apache (HTTPS sur /nextcloud)
configurer_apache() {
    etape "3b. Apache en HTTPS"

    if [[ ! -f "$SSL_CERT" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
            -keyout "$SSL_KEY" -out "$SSL_CERT" \
            -subj "/C=CH/O=CPNV/CN=${LAN_IP}" \
            -addext "subjectAltName=IP:${LAN_IP},DNS:${HOSTNAME_SRV},DNS:nextcloud.${DOMAIN}"
        chmod 600 "$SSL_KEY"
        info "certificat auto-signé créé (${SSL_CERT})"
    fi

    # HTTP : redirige vers HTTPS
    cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
<VirtualHost *:80>
    ServerName nextcloud.${DOMAIN}
    ServerAlias ${LAN_IP} ${HOSTNAME_SRV}
    Redirect permanent / ${NC_URL}/
</VirtualHost>
EOF

    # HTTPS : Nextcloud accessible sur https://<serveur>/nextcloud
    cat > /etc/apache2/sites-available/nextcloud-ssl.conf <<EOF
<VirtualHost *:443>
    ServerName nextcloud.${DOMAIN}
    ServerAlias ${LAN_IP} ${HOSTNAME_SRV}
    DocumentRoot /var/www
    Alias /nextcloud ${NC_DIR}

    SSLEngine on
    SSLCertificateFile    ${SSL_CERT}
    SSLCertificateKeyFile ${SSL_KEY}

    <Directory ${NC_DIR}>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
    </Directory>

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=15552000"
    </IfModule>

    ErrorLog \${APACHE_LOG_DIR}/nextcloud_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/nextcloud_ssl_access.log combined
</VirtualHost>
EOF

    a2enmod ssl rewrite headers env dir mime >/dev/null
    a2dissite 000-default >/dev/null 2>&1 || true
    a2ensite nextcloud nextcloud-ssl >/dev/null
    apache2ctl configtest
    systemctl enable apache2
    systemctl restart apache2
    info "Nextcloud disponible sur ${NC_URL}"
}

# ---------------------------------------------------------------------------
# 4. Authentification LDAP (SRV-LIN1-01)
# ---------------------------------------------------------------------------
configurer_ldap() {
    etape "4. Utilisateurs LDAP dans Nextcloud"

    occ app:enable user_ldap

    local cfg
    cfg="$(occ ldap:show-config --output=json 2>/dev/null | json_cles | head -1)"
    if [[ -z "$cfg" ]]; then
        cfg="$(occ ldap:create-empty-config -p)"
        info "configuration LDAP ${cfg} créée"
    fi

    local -A ldap=(
        [ldapHost]="$LDAP_HOST"
        [ldapPort]="389"
        [ldapAgentName]="$LDAP_ADMIN_DN"
        [ldapAgentPassword]="$LDAP_ADMIN_PASS"
        [ldapBase]="$LDAP_BASE"
        [ldapBaseUsers]="ou=Users,${LDAP_BASE}"
        [ldapBaseGroups]="ou=Groups,${LDAP_BASE}"
        [ldapUserFilter]="(&(objectClass=posixAccount)(uid=*))"
        [ldapLoginFilter]="(&(objectClass=posixAccount)(uid=%uid))"
        [ldapLoginFilterUsername]="1"
        [ldapGroupFilter]="(&(objectClass=posixGroup)(cn=*))"
        [ldapGroupMemberAssocAttr]="memberUid"
        [ldapGroupDisplayName]="cn"
        [ldapUserDisplayName]="uid"
        [ldapExpertUsernameAttr]="uid"
        [ldapGidNumber]="gidNumber"
        [ldapTLS]="0"
        [ldapConfigurationActive]="1"
    )
    local key
    for key in "${!ldap[@]}"; do
        occ ldap:set-config "$cfg" "$key" "${ldap[$key]}" >/dev/null
    done

    occ ldap:test-config "$cfg"

    # Force la lecture des utilisateurs et groupes LDAP
    occ user:list --limit=50 >/dev/null
    occ group:list >/dev/null
    info "utilisateurs LDAP visibles : $(occ user:list | grep -c -E '(man|ing|dev)[0-9]+' || true)"
}

# ---------------------------------------------------------------------------
# 5. Partage : partages SMB du NAS montés dans Nextcloud
# ---------------------------------------------------------------------------
configurer_partages() {
    etape "5. Montage des partages du NAS (${NAS_IP})"

    occ app:enable files_external

    local m point share groups g
    local -a options
    for m in "${NAS_MOUNTS[@]}"; do
        IFS=: read -r point share groups <<< "$m"

        if occ files_external:list --output=json | json_champ mount_point | grep -qx "$point"; then
            info "${point} existe déjà"
            continue
        fi

        # Restriction aux groupes LDAP indiqués (aucun = tous les utilisateurs)
        options=()
        IFS=, read -ra glist <<< "$groups"
        for g in "${glist[@]}"; do
            options+=(--applicable-group="$g")
        done

        # Authentification : identifiants de connexion Nextcloud (= compte LDAP)
        occ files_external:create "$point" smb password::logincredentials \
            -c host="$NAS_IP" -c share="$share" -c root="" -c domain="" \
            "${options[@]}" >/dev/null
        info "${point} -> //${NAS_IP}/${share} (${groups:-tous les utilisateurs})"
    done

    echo
    occ files_external:list
}

# ---------------------------------------------------------------------------
# Vérification finale
# ---------------------------------------------------------------------------
resume() {
    etape "Résumé"
    for s in apache2 mariadb cron; do
        printf '  %-10s %s\n' "$s" "$(systemctl is-active "$s")"
    done
    echo
    occ status
    echo
    echo "  Nextcloud : ${NC_URL}  (admin : ${NC_ADMIN})"
    echo "  Connexion des utilisateurs avec leur compte LDAP (ex. dev01)"
    echo "  Journal   : ${LOG_FILE}"
}

main() {
    verifier_prerequis
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "### ${HOSTNAME_SRV}.sh - $(date '+%d.%m.%Y %H:%M:%S')"

    configurer_reseau
    installer_paquets
    installer_nextcloud
    configurer_apache
    configurer_ldap
    configurer_partages
    resume
}

main "$@"
