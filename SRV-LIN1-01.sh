#!/usr/bin/env bash
#
# SRV-LIN1-01.sh - Installation automatisée du serveur d'infrastructure SRV-LIN1-01
#
# Ce script configure, sur une Debian 13 (trixie) fraîchement installée :
#   1. le réseau (interface WAN en DHCP, interface LAN en IP fixe, nom d'hôte)
#   2. le partage de la connexion réseau (routage IPv4 + NAT vers le WAN)
#   3. le serveur DNS bind9 (zone LIN1.internal + zone inverse 10.10.10.x)
#   4. le serveur DHCP isc-dhcp-server (plage 10.10.10.100 - 10.10.10.200)
#   5. l'annuaire LDAP OpenLDAP (slapd) + schéma samba pour le NAS
#   6. le peuplement de l'annuaire (OU, groupes, utilisateurs, mots de passe)
#   7. LDAP Account Manager (LAM) pour gérer l'annuaire par le web
#
# Utilisation (en root, depuis la console de la VM de préférence) :
#   chmod +x SRV-LIN1-01.sh
#   ./SRV-LIN1-01.sh
#
# Les mots de passe peuvent être donnés par variables d'environnement :
#   LDAP_ADMIN_PASS='...' USER_PASS='...' ./SRV-LIN1-01.sh
#
# Le script peut être relancé : chaque étape vérifie ce qui existe déjà.
# Journal complet : /var/log/SRV-LIN1-01_install.log

set -euo pipefail

# ---------------------------------------------------------------------------
# Paramètres (à adapter si l'environnement change)
# ---------------------------------------------------------------------------
HOSTNAME_SRV="SRV-LIN1-01"

WAN_IF="${WAN_IF:-ens33}"       # interface côté Internet (DHCP, NAT VMware)
LAN_IF="${LAN_IF:-ens34}"       # interface côté réseau interne LIN1
LAN_IP="10.10.10.11"
LAN_NETMASK="255.255.255.0"
LAN_NET="10.10.10.0/24"
UPSTREAM_DNS="192.168.32.2"     # DNS de la passerelle VMware (forwarder)

DOMAIN="LIN1.internal"
REVERSE_ZONE="10.10.10.in-addr.arpa"

# Machines de l'infrastructure : "nom:dernier octet"
HOSTS_DNS=(
    "srv-lin1-01:11"
    "srv-lin1-02:22"
    "nas-lin1-01:33"
)

DHCP_RANGE_START="10.10.10.100"
DHCP_RANGE_END="10.10.10.200"

LDAP_BASE="dc=LIN1,dc=internal"
LDAP_ORG="LIN1"
LDAP_ADMIN_DN="cn=admin,${LDAP_BASE}"
LDAP_ADMIN_PASS="${LDAP_ADMIN_PASS:-Pa\$\$w0rd}"
USER_PASS="${USER_PASS:-Pa\$\$w0rd}"           # mot de passe initial des utilisateurs

# Groupes : "nom:gidNumber"
LDAP_GROUPS=(
    "Manager:10001"
    "Ingenieur:10002"
    "Developpeur:10003"
)

# Utilisateurs : "uid:uidNumber:groupe principal"
LDAP_USERS=(
    "man01:10001:Manager"
    "man02:10002:Manager"
    "ing01:10003:Ingenieur"
    "ing02:10004:Ingenieur"
    "dev01:10005:Developpeur"
)

SAMBA_SCHEMA_URL="https://raw.githubusercontent.com/samba-team/samba/master/examples/LDAP/samba.ldif"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/${HOSTNAME_SRV}_install.log"

# ---------------------------------------------------------------------------
# Fonctions utilitaires
# ---------------------------------------------------------------------------
etape() { echo; echo "==== $* ===="; }
info()  { echo "  -> $*"; }
erreur() { echo "ERREUR : $*" >&2; exit 1; }

verifier_prerequis() {
    [[ $EUID -eq 0 ]] || erreur "ce script doit être lancé en root"
    for iface in "$WAN_IF" "$LAN_IF"; do
        ip link show "$iface" >/dev/null 2>&1 \
            || erreur "interface $iface introuvable (interfaces présentes : $(ls /sys/class/net | tr '\n' ' '))"
    done
}

# Ajoute une entrée LDAP seulement si elle n'existe pas encore
ldap_existe() {
    ldapsearch -x -LLL -H ldap://127.0.0.1 -b "$1" -s base dn >/dev/null 2>&1
}

ldap_ajouter() {
    ldapadd -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASS"
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
${LAN_IP}	${HOSTNAME_SRV}.${DOMAIN} ${HOSTNAME_SRV}
10.10.10.22	SRV-LIN1-02.${DOMAIN} SRV-LIN1-02
10.10.10.33	NAS-LIN1-01.${DOMAIN} NAS-LIN1-01

::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

    cat > /etc/network/interfaces <<EOF
# Généré par SRV-LIN1-01.sh
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

# WAN : accès Internet via le NAT VMware
allow-hotplug ${WAN_IF}
iface ${WAN_IF} inet dhcp

# LAN : réseau interne LIN1
auto ${LAN_IF}
iface ${LAN_IF} inet static
    address ${LAN_IP}
    netmask ${LAN_NETMASK}
EOF
    info "/etc/network/interfaces écrit (WAN ${WAN_IF} en DHCP, LAN ${LAN_IF} = ${LAN_IP})"

    # Applique l'IP du LAN sans couper le WAN
    if ! ip -4 addr show "$LAN_IF" | grep -q "inet ${LAN_IP}/"; then
        ip addr flush dev "$LAN_IF"
        ifup "$LAN_IF" || ip addr add "${LAN_IP}/24" dev "$LAN_IF"
    fi
    ip link set "$LAN_IF" up
    ip -br addr show "$LAN_IF"

    # Le réseau VMware n'a pas d'IPv6 : on fait préférer l'IPv4 à tous les
    # programmes (curl...), sinon ils restent bloqués sur les adresses IPv6
    grep -qs '^precedence ::ffff:0:0/96' /etc/gai.conf \
        || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
}

# Vérifie que les dépôts Debian en ligne sont configurés, puis installe les paquets
installer_paquets() {
    etape "Installation des paquets"

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

    # Réponses pré-remplies pour slapd : l'installation ne pose aucune question
    debconf-set-selections <<EOF
slapd slapd/no_configuration boolean false
slapd slapd/domain string ${DOMAIN}
slapd shared/organization string ${LDAP_ORG}
slapd slapd/password1 password ${LDAP_ADMIN_PASS}
slapd slapd/password2 password ${LDAP_ADMIN_PASS}
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
EOF

    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        bind9 bind9-utils bind9-dnsutils \
        isc-dhcp-server \
        slapd ldap-utils \
        nftables \
        apache2 ldap-account-manager \
        curl
}

# ---------------------------------------------------------------------------
# 2. Partage de la connexion réseau (routeur NAT pour le LAN)
# ---------------------------------------------------------------------------
configurer_partage_reseau() {
    etape "2. Partage de la connexion réseau (routage + NAT)"

    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-router.conf
    sysctl -p /etc/sysctl.d/99-router.conf
    info "routage IPv4 activé"

    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# Généré par SRV-LIN1-01.sh : NAT du réseau ${LAN_NET} vers ${WAN_IF}
flush ruleset

table inet filter {
    chain input   { type filter hook input priority filter; }
    chain forward { type filter hook forward priority filter; }
    chain output  { type filter hook output priority filter; }
}

table ip nat {
    chain postrouting {
        type nat hook postrouting priority srcnat;
        ip saddr ${LAN_NET} oifname "${WAN_IF}" masquerade
    }
}
EOF
    systemctl enable nftables
    systemctl restart nftables
    info "NAT ${LAN_NET} -> ${WAN_IF} actif et persistant (nftables)"
}

# ---------------------------------------------------------------------------
# 3. DNS (bind9)
# ---------------------------------------------------------------------------
configurer_dns() {
    etape "3. Serveur DNS bind9"

    local serial
    serial="$(date +%Y%m%d)01"
    mkdir -p /etc/bind/zones

    cat > /etc/bind/named.conf.options <<EOF
options {
    directory "/var/cache/bind";

    listen-on { any; };
    listen-on-v6 { none; };

    // Seuls le serveur et le réseau interne peuvent interroger le DNS
    allow-query     { 127.0.0.1; ${LAN_NET}; };
    recursion yes;
    allow-recursion { 127.0.0.1; ${LAN_NET}; };

    // Les noms externes sont résolus par la passerelle VMware
    forwarders { ${UPSTREAM_DNS}; };

    version "not available";
    dnssec-validation no;
};
EOF

    cat > /etc/bind/named.conf.local <<EOF
// Zone directe ${DOMAIN}
zone "${DOMAIN}" {
    type master;
    file "/etc/bind/zones/db.${DOMAIN}";
    allow-transfer { none; };
    allow-update { none; };
};

// Zone inverse ${LAN_NET}
zone "${REVERSE_ZONE}" {
    type master;
    file "/etc/bind/zones/db.10.10.10";
    allow-transfer { none; };
    allow-update { none; };
};
EOF

    # Zone directe
    {
        cat <<EOF
\$TTL 86400
@   IN  SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
            ${serial}  ; Serial
            3600        ; Refresh
            1800        ; Retry
            604800      ; Expire
            86400 )     ; Negative TTL

@       IN  NS      ns1.${DOMAIN}.
@       IN  A       ${LAN_IP}
ns1     IN  A       ${LAN_IP}

; Serveurs de l'infrastructure
EOF
        for h in "${HOSTS_DNS[@]}"; do
            printf '%-14s IN  A       10.10.10.%s\n' "${h%%:*}" "${h##*:}"
        done
        echo
        echo "; Alias des services web"
        echo "ldap           IN  CNAME   srv-lin1-01.${DOMAIN}."
        echo "lam            IN  CNAME   srv-lin1-01.${DOMAIN}."
        echo "nextcloud      IN  CNAME   srv-lin1-02.${DOMAIN}."
    } > "/etc/bind/zones/db.${DOMAIN}"

    # Zone inverse
    {
        cat <<EOF
\$TTL 86400
@   IN  SOA ns1.${DOMAIN}. admin.${DOMAIN}. (
            ${serial}
            3600
            1800
            604800
            86400 )

@       IN  NS      ns1.${DOMAIN}.

; Enregistrements PTR (IP -> nom)
EOF
        for h in "${HOSTS_DNS[@]}"; do
            printf '%-4s    IN  PTR     %s.%s.\n' "${h##*:}" "${h%%:*}" "$DOMAIN"
        done
    } > /etc/bind/zones/db.10.10.10

    # IPv4 uniquement : sans IPv6 sur le réseau, bind9 perd du temps sur les
    # serveurs racine IPv6 et certaines résolutions externes échouent
    if grep -q '^OPTIONS=' /etc/default/named; then
        sed -i 's/^OPTIONS=.*/OPTIONS="-u bind -4"/' /etc/default/named
    else
        echo 'OPTIONS="-u bind -4"' >> /etc/default/named
    fi

    named-checkconf
    named-checkzone "$DOMAIN" "/etc/bind/zones/db.${DOMAIN}"
    named-checkzone "$REVERSE_ZONE" /etc/bind/zones/db.10.10.10

    systemctl enable named
    systemctl restart named

    # Le serveur utilise son propre DNS (dhcpcd ne doit plus écraser resolv.conf)
    if [[ -f /etc/dhcpcd.conf ]] && ! grep -q '^nohook resolv.conf' /etc/dhcpcd.conf; then
        echo "nohook resolv.conf" >> /etc/dhcpcd.conf
    fi
    printf 'search %s\nnameserver 127.0.0.1\n' "$DOMAIN" > /etc/resolv.conf

    info "test : srv-lin1-02.${DOMAIN} -> $(dig +short @127.0.0.1 "srv-lin1-02.${DOMAIN}")"
}

# ---------------------------------------------------------------------------
# 4. DHCP (isc-dhcp-server)
# ---------------------------------------------------------------------------
configurer_dhcp() {
    etape "4. Serveur DHCP"

    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${LAN_IF}\"/" /etc/default/isc-dhcp-server
    sed -i 's/^INTERFACESv6=.*/INTERFACESv6=""/' /etc/default/isc-dhcp-server

    cat > /etc/dhcp/dhcpd.conf <<EOF
# Généré par SRV-LIN1-01.sh
default-lease-time 600;
max-lease-time 7200;
authoritative;

option domain-name "${DOMAIN}";
option domain-name-servers ${LAN_IP};

subnet 10.10.10.0 netmask ${LAN_NETMASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option broadcast-address 10.10.10.255;
    # SRV-LIN1-01 est la passerelle (NAT) des clients vers Internet
    option routers ${LAN_IP};
}
EOF

    dhcpd -t -cf /etc/dhcp/dhcpd.conf
    systemctl enable isc-dhcp-server
    systemctl restart isc-dhcp-server
    info "plage ${DHCP_RANGE_START} - ${DHCP_RANGE_END} distribuée sur ${LAN_IF}"
}

# ---------------------------------------------------------------------------
# 5. Annuaire LDAP (slapd) + schéma samba
# ---------------------------------------------------------------------------
configurer_ldap() {
    etape "5. Annuaire LDAP"

    # Si slapd était déjà installé avec un autre domaine, on le reconfigure
    if ! ldapsearch -x -LLL -H ldap://127.0.0.1 -s base -b "" namingContexts 2>/dev/null | grep -qi "$LDAP_BASE"; then
        info "reconfiguration de slapd pour ${LDAP_BASE}"
        dpkg-reconfigure -f noninteractive slapd
    fi
    systemctl enable slapd
    systemctl restart slapd
    ldapwhoami -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASS" >/dev/null \
        || erreur "connexion impossible avec ${LDAP_ADMIN_DN}"
    info "base ${LDAP_BASE} opérationnelle"

    # Schéma samba : nécessaire au NAS (passdb backend = ldapsam)
    if ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b cn=schema,cn=config '(cn=*samba)' dn 2>/dev/null | grep -q samba; then
        info "schéma samba déjà chargé"
    else
        local schema="${SCRIPT_DIR}/samba.ldif"
        if [[ ! -f "$schema" ]]; then
            schema="/tmp/samba.ldif"
            curl -4 -fsSL "$SAMBA_SCHEMA_URL" -o "$schema" || erreur "téléchargement du schéma samba impossible"
        fi
        ldapadd -Q -Y EXTERNAL -H ldapi:/// -f "$schema"
        info "schéma samba chargé"
    fi
}

# ---------------------------------------------------------------------------
# 6. Peuplement de l'annuaire
# ---------------------------------------------------------------------------
peupler_ldap() {
    etape "6. Peuplement de l'annuaire LDAP"

    # Unités d'organisation
    for ou in Users Groups; do
        if ldap_existe "ou=${ou},${LDAP_BASE}"; then
            info "ou=${ou} existe déjà"
        else
            ldap_ajouter <<EOF
dn: ou=${ou},${LDAP_BASE}
objectClass: organizationalUnit
ou: ${ou}
EOF
            info "ou=${ou} créée"
        fi
    done

    # Groupes POSIX
    local g name gid
    for g in "${LDAP_GROUPS[@]}"; do
        name="${g%%:*}"; gid="${g##*:}"
        if ldap_existe "cn=${name},ou=Groups,${LDAP_BASE}"; then
            info "groupe ${name} existe déjà"
        else
            ldap_ajouter <<EOF
dn: cn=${name},ou=Groups,${LDAP_BASE}
objectClass: top
objectClass: posixGroup
cn: ${name}
gidNumber: ${gid}
EOF
            info "groupe ${name} (gid ${gid}) créé"
        fi
    done

    # Utilisateurs POSIX + appartenance au groupe + mot de passe
    local u uid uidnum group gidnum hash
    for u in "${LDAP_USERS[@]}"; do
        IFS=: read -r uid uidnum group <<< "$u"
        gidnum="$(printf '%s\n' "${LDAP_GROUPS[@]}" | awk -F: -v g="$group" '$1==g {print $2}')"
        [[ -n "$gidnum" ]] || erreur "groupe ${group} inconnu pour ${uid}"

        if ldap_existe "uid=${uid},ou=Users,${LDAP_BASE}"; then
            info "utilisateur ${uid} existe déjà"
        else
            hash="$(slappasswd -s "$USER_PASS")"
            ldap_ajouter <<EOF
dn: uid=${uid},ou=Users,${LDAP_BASE}
objectClass: top
objectClass: account
objectClass: posixAccount
cn: ${uid}
uid: ${uid}
uidNumber: ${uidnum}
gidNumber: ${gidnum}
homeDirectory: /home/${uid}
loginShell: /bin/bash
userPassword: ${hash}
EOF
            info "utilisateur ${uid} (uid ${uidnum}, groupe ${group}) créé"
        fi

        # memberUid : ajouté seulement s'il manque
        if ! ldapsearch -x -LLL -H ldap://127.0.0.1 -b "cn=${group},ou=Groups,${LDAP_BASE}" memberUid | grep -qx "memberUid: ${uid}"; then
            ldapmodify -x -H ldap://127.0.0.1 -D "$LDAP_ADMIN_DN" -w "$LDAP_ADMIN_PASS" >/dev/null <<EOF
dn: cn=${group},ou=Groups,${LDAP_BASE}
changetype: modify
add: memberUid
memberUid: ${uid}
EOF
            info "${uid} ajouté au groupe ${group}"
        fi
    done

    echo
    info "contenu de l'annuaire :"
    ldapsearch -x -LLL -H ldap://127.0.0.1 -b "$LDAP_BASE" '(|(objectClass=posixGroup)(objectClass=posixAccount))' dn memberUid
}

# ---------------------------------------------------------------------------
# 7. LDAP Account Manager
# ---------------------------------------------------------------------------
configurer_lam() {
    etape "7. LDAP Account Manager (http://${LAN_IP}/lam)"

    local conf=/var/lib/ldap-account-manager/config/lam.conf
    [[ -f "${conf}.bak" ]] || cp "$conf" "${conf}.bak"
    sed -i \
        -e "s/cn=Manager,dc=my-domain,dc=com/${LDAP_ADMIN_DN}/" \
        -e "s/dc=yourdomain,dc=org/${LDAP_BASE}/g" \
        -e "s/ou=People,dc=my-domain,dc=com/ou=Users,${LDAP_BASE}/" \
        -e "s/ou=group,dc=my-domain,dc=com/ou=Groups,${LDAP_BASE}/" \
        -e "s/dc=my-domain,dc=com/${LDAP_BASE}/g" \
        "$conf"
    systemctl enable apache2
    systemctl restart apache2
    info "connexion LAM : ${LDAP_ADMIN_DN}"
}

# ---------------------------------------------------------------------------
# Vérification finale
# ---------------------------------------------------------------------------
resume() {
    etape "Résumé"
    for s in named isc-dhcp-server slapd nftables apache2; do
        printf '  %-16s %s\n' "$s" "$(systemctl is-active "$s")"
    done
    echo
    echo "  DNS   : dig @${LAN_IP} srv-lin1-02.${DOMAIN}"
    echo "  DHCP  : ${DHCP_RANGE_START} - ${DHCP_RANGE_END} sur ${LAN_IF}"
    echo "  LDAP  : ldapsearch -x -b ${LDAP_BASE}"
    echo "  LAM   : http://${LAN_IP}/lam"
    echo "  Journal : ${LOG_FILE}"
}

main() {
    verifier_prerequis
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "### ${HOSTNAME_SRV}.sh - $(date '+%d.%m.%Y %H:%M:%S')"

    configurer_reseau
    installer_paquets
    configurer_partage_reseau
    configurer_dns
    configurer_dhcp
    configurer_ldap
    peupler_ldap
    configurer_lam
    resume
}

main "$@"
