#!/bin/bash
set -e

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
ok()   { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[*]${N} $*"; }
fail() { echo -e "${R}[-]${N} $*"; }
die()  { fail "$*"; exit 1; }

trap 'echo -e "${R}[-]${N} Script berhenti di baris $LINENO (exit $?)" >&2' ERR

[[ $EUID -eq 0 ]] || die "Harus root"

FAILED=()
bad() { fail "$*"; FAILED+=("$*"); }

STDIN_TTY=0
[[ -t 0 ]] && STDIN_TTY=1

ask() {
    local prompt="$1" default="$2" var=""
    if [[ "$STDIN_TTY" -eq 1 ]]; then
        read -rp "$prompt" var
    elif [[ -r /dev/tty ]]; then
        read -rp "$prompt" var < /dev/tty
    else
        echo "" >&2
    fi
    echo "${var:-$default}"
}

ip_to_int() {
    local IFS=.
    read -r a b c d <<< "$1"
    echo $(( (a<<24) | (b<<16) | (c<<8) | d ))
}
int_to_ip() {
    local n=$1
    echo "$(( (n>>24)&255 )).$(( (n>>16)&255 )).$(( (n>>8)&255 )).$(( n&255 ))"
}
is_ip() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

IP_ARG=""; PREFIX_ARG=""; GW_ARG=""; DOMAIN_ARG=""; SSH_ARG=""; INDEX_ARG=""
AUTO=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)     IP_ARG="$2"; shift 2 ;;
        --prefix) PREFIX_ARG="$2"; shift 2 ;;
        --gw)     GW_ARG="$2"; shift 2 ;;
        --domain) DOMAIN_ARG="$2"; shift 2 ;;
        --ssh)    SSH_ARG="$2"; shift 2 ;;
        --index)  INDEX_ARG="$2"; shift 2 ;;
        -y|--yes|--auto) AUTO=1; shift ;;
        -h|--help)
            echo "Pakai: $0 [opsi]"
            echo ""
            echo "Opsi:"
            echo "  --ip IP        IP static Debian"
            echo "  --prefix N     Prefix CIDR (24 = 255.255.255.0)"
            echo "  --gw IP        Gateway"
            echo "  --domain NAMA  Domain (WAJIB di mode non-interaktif)"
            echo "  --ssh PORT     Port SSH (default 22)"
            echo "  --index PATH   File index.html (default HTML bawaan)"
            echo ""
            echo "Mode:"
            echo "  (tanpa flag)   Interaktif, tanya semua"
            echo "  -y, --yes      Non-interaktif, argumen wajib lengkap"
            echo "  --auto         Non-interaktif, isi otomatis kalau kosong"
            echo ""
            echo "Contoh:"
            echo "  $0"
            echo "  $0 --auto --domain namaweb"
            echo "  $0 --auto --ip 192.168.56.25 --prefix 24 --gw 192.168.56.1 --domain namaweb --ssh 142 --index /root/index.html"
            exit 0 ;;
        *) die "Argumen tidak dikenal: $1 (pakai -h)" ;;
    esac
done

ok "FASE 0: cek awal & pembersihan config lama"

# Buka kunci resolv.conf jika sebelumnya pernah dikunci
chattr -i /etc/resolv.conf 2>/dev/null || true

# Bersihkan BIND9 lama
if systemctl is-active --quiet bind9; then
    warn "BIND9 berjalan, menghentikan sementara untuk reset..."
    systemctl stop bind9 2>/dev/null || true
fi

if [[ -f /etc/bind/named.conf.local ]]; then
    if grep -q "zone " /etc/bind/named.conf.local 2>/dev/null; then
        warn "Menghapus zone lama di named.conf.local"
        cp /etc/bind/named.conf.local /etc/bind/named.conf.local.bak.$(date +%s) 2>/dev/null || true
        cat > /etc/bind/named.conf.local <<EOL
// Config lama dibersihkan otomatis oleh setup.sh
EOL
    fi
fi

# Hapus file db lama yang dibuat script sebelumnya
for f in /etc/bind/db.*; do
    if [[ -f "$f" && "$f" != "/etc/bind/db.0" && "$f" != "/etc/bind/db.127" && "$f" != "/etc/bind/db.255" && "$f" != "/etc/bind/db.empty" && "$f" != "/etc/bind/db.local" && "$f" != "/etc/bind/db.root" ]]; then
        rm -f "$f"
    fi
done
ok "Config DNS lama dibersihkan"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    [[ "$ID" == "debian" || "$ID_LIKE" == *debian* ]] && ok "OS: $PRETTY_NAME" || warn "OS bukan Debian ($ID)"
fi

touch /etc/.wtest 2>/dev/null && rm -f /etc/.wtest && ok "/etc writable" || die "/etc tidak writable"

for c in ip awk sed grep systemctl; do
    command -v "$c" >/dev/null || die "cmd '$c' tidak ada"
done
ok "cmd dasar ada"

if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    warn "dpkg lock aktif, tunggu 10s"
    sleep 10
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && die "dpkg lock masih aktif"
fi

dpkg --audit 2>/dev/null | grep -q . && { warn "dpkg rusak, fix"; dpkg --configure -a >/dev/null 2>&1 || true; }

for s in bind9 apache2; do
    systemctl is-failed "$s" >/dev/null 2>&1 && systemctl reset-failed "$s" 2>/dev/null || true
done

ok "FASE 1: deteksi network"

IFACE=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
[[ -z "$IFACE" ]] && IFACE=$(ip -4 addr show | awk '/^[0-9]+:/{i=$2} /inet /{print i; exit}' | tr -d ':')
[[ -z "$IFACE" ]] && die "Tidak ada interface"
ok "interface: $IFACE"

ip link show "$IFACE" | grep -q "state UP" || ip link set "$IFACE" up 2>/dev/null || true

IP_CIDR=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
if [[ -z "$IP_CIDR" ]]; then
    warn "tidak ada IP, coba dhclient"
    command -v dhclient >/dev/null && timeout 15 dhclient -1 "$IFACE" 2>/dev/null || true
    sleep 2
    IP_CIDR=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}')
fi
[[ -z "$IP_CIDR" ]] && die "Tidak dapat IP"

DEF_IP=${IP_CIDR%/*}
DEF_PREFIX=${IP_CIDR#*/}
DEF_GW=$(ip -4 route show default 2>/dev/null | awk '/via/{print $3; exit}')

ok "terdeteksi: $DEF_IP/$DEF_PREFIX, gw ${DEF_GW:-kosong}"

ok "FASE 2: input data"

if [[ -n "$IP_ARG" ]]; then
    IP_ADDR="$IP_ARG"; is_ip "$IP_ADDR" || die "IP invalid: $IP_ADDR"
elif [[ "$AUTO" -eq 1 ]]; then
    IP_ADDR="$DEF_IP"
    ok "IP auto: $IP_ADDR"
else
    while :; do
        IP_ADDR=$(ask "IP Debian [${DEF_IP}]: " "$DEF_IP")
        is_ip "$IP_ADDR" && break
        fail "IP invalid"
    done
fi

if [[ -n "$PREFIX_ARG" ]]; then
    PREFIX="$PREFIX_ARG"
elif [[ "$AUTO" -eq 1 ]]; then
    PREFIX="$DEF_PREFIX"
    ok "prefix auto: /$PREFIX"
else
    while :; do
        PREFIX=$(ask "Prefix CIDR (24=255.255.255.0) [${DEF_PREFIX}]: " "$DEF_PREFIX")
        [[ "$PREFIX" =~ ^[0-9]+$ ]] && (( PREFIX >= 8 && PREFIX <= 30 )) && break
        fail "prefix 8-30"
    done
fi
[[ "$PREFIX" =~ ^[0-9]+$ ]] && (( PREFIX >= 8 && PREFIX <= 30 )) || die "Prefix invalid"

if [[ -n "$GW_ARG" ]]; then
    GATEWAY="$GW_ARG"; is_ip "$GATEWAY" || die "Gateway invalid: $GATEWAY"
elif [[ "$AUTO" -eq 1 ]]; then
    GATEWAY="$DEF_GW"
    [[ -n "$GATEWAY" ]] && ok "gateway auto: $GATEWAY" || warn "gateway kosong (tanpa default route)"
else
    while :; do
        GATEWAY=$(ask "Gateway [${DEF_GW:-kosong}]: " "$DEF_GW")
        [[ -z "$GATEWAY" ]] && { warn "gateway kosong"; break; }
        is_ip "$GATEWAY" && break
        fail "Gateway invalid"
    done
fi

IP_INT=$(ip_to_int "$IP_ADDR")
HOST_BITS=$(( 32 - PREFIX ))
MASK_INT=$(( HOST_BITS == 0 ? 0xFFFFFFFF : (0xFFFFFFFF << HOST_BITS) & 0xFFFFFFFF ))
NETMASK=$(int_to_ip "$MASK_INT")
NET_INT=$(( IP_INT & MASK_INT ))
BCAST_INT=$(( NET_INT | (~MASK_INT & 0xFFFFFFFF) ))
BROADCAST=$(int_to_ip "$BCAST_INT")
NETWORK=$(int_to_ip "$NET_INT")

IFS=. read -r O1 O2 O3 O4 <<< "$IP_ADDR"

case "$PREFIX" in
    24) REV_ZONE="${O3}.${O2}.${O1}.in-addr.arpa"; PTR="$O4" ;;
    16) REV_ZONE="${O2}.${O1}.in-addr.arpa";       PTR="$O4.$O3" ;;
    8)  REV_ZONE="${O1}.in-addr.arpa";             PTR="$O4.$O3.$O2" ;;
    *)  warn "prefix /$PREFIX, reverse pakai /24"
        REV_ZONE="${O3}.${O2}.${O1}.in-addr.arpa"; PTR="$O4" ;;
esac

if [[ -n "$DOMAIN_ARG" ]]; then
    DOMAIN="$DOMAIN_ARG"
    [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] || die "Domain invalid"
elif [[ "$AUTO" -eq 1 ]]; then
    die "Mode non-interaktif butuh --domain (domain tidak bisa ditebak)"
else
    while :; do
        DOMAIN=$(ask "Domain (mis. namaweb): " "")
        [[ -z "$DOMAIN" ]] && { fail "wajib"; continue; }
        [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]] && break
        fail "format invalid"
    done
fi

if [[ -n "$SSH_ARG" ]]; then
    SSH_PORT="$SSH_ARG"
elif [[ "$AUTO" -eq 1 ]]; then
    SSH_PORT=22
    ok "SSH port auto: 22"
else
    SSH_PORT=$(ask "Port SSH [22]: " "22")
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die "Port SSH invalid"

if [[ -n "$INDEX_ARG" ]]; then
    INDEX_SRC="$INDEX_ARG"
    [[ -f "$INDEX_SRC" ]] || die "File index tidak ada: $INDEX_SRC"
elif [[ "$AUTO" -eq 1 ]]; then
    INDEX_SRC=""
    warn "index auto: pakai HTML bawaan"
else
    warn "file index.html dari VS Code (kosong = HTML default)"
    while :; do
        INDEX_SRC=$(ask "Path index.html: " "")
        [[ -z "$INDEX_SRC" ]] && { warn "pakai HTML default"; break; }
        [[ -f "$INDEX_SRC" ]] && break
        fail "file tidak ada: $INDEX_SRC"
    done
fi

echo
echo "Ringkasan:"
echo "  Interface : $IFACE"
echo "  IP/CIDR   : $IP_ADDR/$PREFIX"
echo "  Netmask   : $NETMASK"
echo "  Network   : $NETWORK"
echo "  Broadcast : $BROADCAST"
echo "  Gateway   : ${GATEWAY:-kosong}"
echo "  Domain    : $DOMAIN"
echo "  Reverse   : $REV_ZONE"
echo "  SSH port  : $SSH_PORT"
echo "  Index     : ${INDEX_SRC:-default}"
if [[ "$AUTO" -eq 0 ]]; then
    K=$(ask "Lanjut? (y/N): " "n")
    [[ "$K" =~ ^[yY]$ ]] || die "dibatalkan"
fi

ok "FASE 3: tulis config network + ssh"

backup() { [[ -f "$1" ]] && cp "$1" "$1.bak.$(date +%s)" 2>/dev/null || true; }

backup /etc/network/interfaces
{
    echo "auto lo"
    echo "iface lo inet loopback"
    echo
    echo "auto $IFACE"
    echo "iface $IFACE inet static"
    echo "    address $IP_ADDR"
    echo "    netmask $NETMASK"
    echo "    broadcast $BROADCAST"
    [[ -n "$GATEWAY" ]] && echo "    gateway $GATEWAY"
    echo "    dns-nameservers $IP_ADDR"
} > /etc/network/interfaces
ok "interfaces ditulis"

SSHD=/etc/ssh/sshd_config
backup "$SSHD"
sed -i -E "s/^#?Port .*/Port $SSH_PORT/" "$SSHD"
sed -i -E "s/^#?PermitRootLogin .*/PermitRootLogin yes/" "$SSHD"
grep -q "^Port " "$SSHD" || echo "Port $SSH_PORT" >> "$SSHD"
grep -q "^PermitRootLogin " "$SSHD" || echo "PermitRootLogin yes" >> "$SSHD"
ok "sshd_config ditulis"

ok "FASE 4: install paket"

export DEBIAN_FRONTEND=noninteractive

PKGS_NEED="bind9 bind9-utils bind9-dnsutils dnsutils apache2 apache2-bin apache2-utils net-tools curl ifupdown isc-dhcp-client iproute2"
PKGS_MISSING=""

for p in $PKGS_NEED; do
    if dpkg -s "$p" >/dev/null 2>&1; then
        ok "paket $p sudah ada"
    else
        warn "paket $p belum ada"
        PKGS_MISSING="$PKGS_MISSING $p"
    fi
done

if [[ -z "$PKGS_MISSING" ]]; then
    ok "semua paket sudah terinstall"
else
    ok "install:$PKGS_MISSING"

    apt_fix_lock() {
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
           fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
           fuser /var/cache/apt/archives/lock >/dev/null 2>&1; then
            warn "apt lock aktif, tunggu 15s"
            sleep 15
            if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
                warn "lock masih aktif, kill"
                fuser -k /var/lib/dpkg/lock-frontend 2>/dev/null || true
                sleep 3
            fi
        fi
    }

    apt_fix_dpkg() {
        if dpkg --audit 2>/dev/null | grep -q .; then
            warn "dpkg rusak, fix"
            dpkg --configure -a >/dev/null 2>&1 || true
            apt-get -f install -y >/dev/null 2>&1 || true
        fi
    }

    apt_update() {
        apt-get update -y 2>&1 | tail -3
    }

    apt_install() {
        apt-get install -y $PKGS_MISSING 2>&1 | tail -5
    }

    apt_fix_lock
    apt_fix_dpkg

    if ! apt_update; then
        warn "apt update gagal, coba ganti mirror"
        if [[ -f /etc/apt/sources.list ]]; then
            cp /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%s) 2>/dev/null || true
            sed -i 's|deb.debian.org|kartolo.sby.datautama.net.id|g' /etc/apt/sources.list 2>/dev/null || true
            sed -i 's|security.debian.org|kartolo.sby.datautama.net.id|g' /etc/apt/sources.list 2>/dev/null || true
            apt_update || warn "apt update tetap gagal"
        fi
    fi

    if ! apt_install; then
        warn "install gagal, coba fix bertingkat"
        apt_fix_lock
        apt_fix_dpkg
        apt-get -f install -y >/dev/null 2>&1 || true
        dpkg --configure -a >/dev/null 2>&1 || true
        if ! apt_install; then
            warn "install masih gagal, coba satu per satu"
            for p in $PKGS_MISSING; do
                apt-get install -y "$p" >/dev/null 2>&1 && ok "$p OK" || bad "$p gagal"
            done
        fi
    fi

    ok "install selesai"
fi

for b in named-checkconf named-checkzone dig curl; do
    command -v "$b" >/dev/null 2>&1 && ok "$b ada" || bad "$b tidak ada"
done

if command -v apache2ctl >/dev/null 2>&1 || [[ -x /usr/sbin/apache2ctl ]]; then
    ok "apache2ctl ada"
else
    warn "apache2ctl tidak ada (apache2 tetap jalan, bukan fatal)"
fi

command -v ifup >/dev/null 2>&1 && ok "ifup ada" || warn "ifup tidak ada"
command -v ifdown >/dev/null 2>&1 && ok "ifdown ada" || warn "ifdown tidak ada"

systemctl list-unit-files | grep -q '^bind9\.service' && ok "service bind9 terdaftar" || bad "service bind9 tidak terdaftar"
systemctl list-unit-files | grep -q '^apache2\.service' && ok "service apache2 terdaftar" || bad "service apache2 tidak terdaftar"

ok "FASE 5: BIND9"

FWD_FILE="/etc/bind/db.$DOMAIN"
REV_FILE="/etc/bind/db.$IP_ADDR"

backup /etc/bind/named.conf.local
cat > /etc/bind/named.conf.local <<EOL
zone "$DOMAIN" {
    type master;
    file "$FWD_FILE";
};

zone "$REV_ZONE" {
    type master;
    file "$REV_FILE";
};
EOL

cat > "$FWD_FILE" <<EOL
\$TTL    604800
@       IN      SOA     $DOMAIN. root.$DOMAIN. (
                              2
                         604800
                          86400
                        2419200
                         604800 )
;
@       IN      NS      $DOMAIN.
@       IN      A       $IP_ADDR
www     IN      A       $IP_ADDR
EOL

cat > "$REV_FILE" <<EOL
\$TTL    604800
@       IN      SOA     $DOMAIN. root.$DOMAIN. (
                              1
                         604800
                          86400
                        2419200
                         604800 )
;
@       IN      NS      $DOMAIN.
@       IN      A       $IP_ADDR
$PTR      IN      PTR     $DOMAIN.
EOL

backup /etc/bind/named.conf.options
cat > /etc/bind/named.conf.options <<EOL
options {
    directory "/var/cache/bind";
    recursion yes;
    allow-query { any; };
    allow-recursion { 127.0.0.1; $NETWORK/$PREFIX; };
    listen-on { 127.0.0.1; $IP_ADDR; };
    listen-on-v6 { none; };
    forwarders { 8.8.8.8; 8.8.4.4; };
    dnssec-validation no;
    auth-nxdomain no;
};
EOL
ok "zone + options ditulis"

named-checkconf 2>/dev/null && ok "named-checkconf OK" || bad "named-checkconf gagal"
named-checkzone "$DOMAIN" "$FWD_FILE" >/dev/null 2>&1 && ok "fwd zone valid" || bad "fwd zone invalid"
named-checkzone "$REV_ZONE" "$REV_FILE" >/dev/null 2>&1 && ok "rev zone valid" || bad "rev zone invalid"

ok "FASE 6: resolv.conf + web"

backup /etc/resolv.conf
cat > /etc/resolv.conf <<EOL
search $DOMAIN
nameserver $IP_ADDR
EOL
chattr +i /etc/resolv.conf 2>/dev/null || true
ok "resolv.conf ditulis dan dikunci (tidak bisa ditimpa)"

systemctl is-active systemd-resolved >/dev/null 2>&1 && warn "systemd-resolved aktif"

rm -f /var/www/html/index.html
if [[ -n "$INDEX_SRC" && -f "$INDEX_SRC" ]]; then
    cp "$INDEX_SRC" /var/www/html/index.html
    ok "index.html dari $INDEX_SRC"
else
    cat > /var/www/html/index.html <<EOL
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>$DOMAIN</title></head>
<body><h1>$DOMAIN</h1><p>$IP_ADDR</p></body></html>
EOL
    ok "index.html default"
fi

ok "FASE 7: restart service"

restart_svc() {
    local s=$1
    systemctl restart "$s" 2>/dev/null && systemctl is-active "$s" >/dev/null 2>&1 && { ok "$s aktif"; return 0; }
    warn "$s gagal"
    journalctl -u "$s" -n 10 --no-pager 2>/dev/null | tail -8
    return 1
}

systemctl daemon-reload

if systemctl list-unit-files | grep -q '^networking\.service'; then
    CUR_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1)
    if [[ "$CUR_IP" == "$IP_ADDR" ]]; then
        ok "IP $IFACE sudah $IP_ADDR, skip restart networking"
    else
        if command -v ifup >/dev/null 2>&1; then
            if ifup --no-act "$IFACE" >/dev/null 2>&1; then
                restart_svc networking || bad "networking gagal"
            else
                bad "config interfaces invalid, networking tidak direstart"
            fi
        else
            warn "ifup tidak ada, restart networking langsung"
            restart_svc networking || bad "networking gagal"
        fi
    fi
elif systemctl is-active NetworkManager >/dev/null 2>&1; then
    restart_svc NetworkManager || bad "NetworkManager gagal"
fi

restart_svc ssh || bad "ssh gagal"

if ! restart_svc bind9; then
    if ss -lunp 2>/dev/null | grep -q ':53 ' && ! ss -lunp 2>/dev/null | grep -q named; then
        warn "port 53 dipakai proses lain, stop systemd-resolved"
        systemctl stop systemd-resolved 2>/dev/null || true
        systemctl disable systemd-resolved 2>/dev/null || true
        restart_svc bind9 || bad "bind9 tetap gagal"
    else
        bad "bind9 gagal"
    fi
fi

if ! restart_svc apache2; then
    ss -ltnp 2>/dev/null | grep -q ':80 ' && ! ss -ltnp 2>/dev/null | grep -q apache2 && bad "port 80 dipakai proses lain" || bad "apache2 gagal"
fi

ok "FASE 8: diagnostic"

sleep 2

ss -lunp 2>/dev/null | grep -q "$IP_ADDR:53" && ok "bind9 listen $IP_ADDR:53" || bad "bind9 tidak listen $IP_ADDR:53"
ss -ltnp 2>/dev/null | grep -q ':80 .*apache2' && ok "apache2 :80" || bad "apache2 tidak :80"

FWD_TEST=$(dig +short "$DOMAIN" @"$IP_ADDR" 2>/dev/null | head -1)
[[ "$FWD_TEST" == "$IP_ADDR" ]] && ok "forward $DOMAIN -> $IP_ADDR" || bad "forward gagal"

REV_TEST=$(dig +short -x "$IP_ADDR" @"$IP_ADDR" 2>/dev/null | sed 's/\.$//' | head -1)
[[ "$REV_TEST" == "$DOMAIN" ]] && ok "reverse $IP_ADDR -> $DOMAIN" || bad "reverse gagal"

if command -v curl >/dev/null; then
    CODE=$(curl --noproxy '*' -s -o /dev/null -w "%{http_code}" "http://$IP_ADDR")
    [[ "$CODE" == "200" ]] && ok "HTTP 200" || bad "HTTP $CODE"
fi

ss -ltn 2>/dev/null | grep -q ":$SSH_PORT " && ok "SSH :$SSH_PORT" || bad "SSH tidak :$SSH_PORT"

if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    warn "ufw aktif, buka port"
    ufw allow "$SSH_PORT"/tcp >/dev/null 2>&1 || true
    ufw allow 53/tcp >/dev/null 2>&1 || true
    ufw allow 53/udp >/dev/null 2>&1 || true
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ok "ufw rule ditambah"
fi

echo
if (( ${#FAILED[@]} == 0 )); then
    echo -e "${G}[+] ALL PASS${N}"
else
    echo -e "${R}[-] ${#FAILED[@]} FAIL${N}"
    for f in "${FAILED[@]}"; do echo "  [-] $f"; done
fi

echo
echo "Domain    : $DOMAIN"
echo "IP        : $IP_ADDR/$PREFIX"
echo "Gateway   : ${GATEWAY:-kosong}"
echo "Reverse   : $REV_ZONE"
echo "SSH port  : $SSH_PORT"
echo "Web       : http://$IP_ADDR"
echo
echo "Cek manual:"
echo "  ip a show $IFACE | grep $IP_ADDR"
echo "  nslookup $DOMAIN"
echo "  nslookup $IP_ADDR"
echo "  curl http://$IP_ADDR"
echo
echo "Client:"
echo "  IP      : ${NETWORK%.*}.xxx"
echo "  Netmask : $NETMASK"
echo "  Gateway : ${GATEWAY:-kosong}"
echo "  DNS     : $IP_ADDR"
echo "  Test    : ping $DOMAIN"

exit 0
