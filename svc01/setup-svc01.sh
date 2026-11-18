#!/usr/bin/env bash
# =============================================================================
# setup-svc01.sh - prepara a VM svc01 (Ubuntu Server 24.04) para o lab VCF 9.1.1 no ESXi físico
#
# A svc01 substitui o Windows físico: DNS (BIND9), NTP (chrony), depot e kickstart (nginx), roteador/NAT
# do notebook para o lab, e é de onde a automação roda (PowerShell 7 + VCF.PowerCLI + Posh-SSH + ovftool).
#
# Rode dentro da svc01, depois de instalar o Ubuntu (docs/svc01-ubuntu.md):
#   sudo bash setup-svc01.sh            # tudo, na ordem (idempotente: pode rodar de novo)
#   sudo bash setup-svc01.sh rede       # só uma parte: base rede disco dns ntp nginx nat pwsh ovftool status
#
# Os MACs e IPs abaixo têm de bater com host/esxi-host-setup.sh (SVC_MAC_*) e com o lab-config.psd1.
# =============================================================================

# ------------------------------------------------------------------ CONFIRA
LAB_DOMAIN="vcf.lab"
MAC_CASA="00:50:56:3b:01:00"        # VM Network: rede de casa (configurada no instalador do Ubuntu)
MAC_MGMT="00:50:56:3b:01:01"        # VCF911-MGMT
MAC_VSAN="00:50:56:3b:01:02"        # VCF911-VSAN
IP_MGMT="10.52.10.2/24"             # DNS, NTP, depot, kickstart do lab
IP_VSAN="10.52.12.1/24"             # gateway "de mentira" do vSAN isolado (como a VMnet12)
LAB_GW="10.52.10.1"                 # VyOS
LAB_NETS="10.52.0.0/16 10.60.0.0/16"
MTU_LAB=9000
DNS_FORWARDERS="1.1.1.1; 8.8.8.8;"
NTP_UPSTREAM="a.st1.ntp.br b.st1.ntp.br"
DATA_MOUNT="/srv/dados"             # disco de dados (ext4 no ds-ssd; ver docs/svc01-ubuntu.md, passo 4)
LAB_HOME="/opt/vcf911"              # pacote + WorkDir (_work)
TIMEZONE="America/Sao_Paulo"
# -----------------------------------------------------------------------------

set -uo pipefail
RED='\033[31m'; GRN='\033[32m'; YEL='\033[33m'; CYA='\033[36m'; RST='\033[0m'
ok()   { printf "${GRN}[OK]${RST}    %s\n" "$*"; }
info() { printf "${CYA}[..]${RST}    %s\n" "$*"; }
warn() { printf "${YEL}[AVISO]${RST} %s\n" "$*"; }
die()  { printf "${RED}[ERRO]${RST}  %s\n" "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "rode com sudo: sudo bash $0"
. /etc/os-release
[ "${ID:-}" = "ubuntu" ] || die "feito para Ubuntu 24.04 (achei ${PRETTY_NAME:-?})"
[ "${VERSION_ID:-}" = "24.04" ] || warn "testado no 24.04; você está no ${VERSION_ID:-?} (deve funcionar no 26.04)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

nic_by_mac() { for d in /sys/class/net/*; do [ "$(cat "$d/address" 2>/dev/null)" = "$1" ] && basename "$d" && return; done; }
ip_only() { echo "${1%/*}"; }

# ------------------------------------------------------------------ base
do_base() {
    info "Pacotes, fuso, hostname"
    timedatectl set-timezone "$TIMEZONE"
    hostnamectl set-hostname svc01
    grep -q "svc01.$LAB_DOMAIN" /etc/hosts || sed -i "s/^127\.0\.1\.1.*/127.0.1.1 svc01.$LAB_DOMAIN svc01/" /etc/hosts
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q bind9 bind9-utils bind9-dnsutils chrony nginx tmux jq unzip curl wget nftables \
        ntfs-3g open-vm-tools sshpass rsync htop ca-certificates apt-transport-https >/dev/null \
        || die "apt-get install falhou (a placa da rede de casa tem internet?)"
    ok "pacotes instalados"
    mkdir -p "$LAB_HOME/_work"
    chmod 755 "$LAB_HOME" "$LAB_HOME/_work"
    ok "pasta do lab: $LAB_HOME (WorkDir $LAB_HOME/_work)"
}

# ------------------------------------------------------------------ rede
do_rede() {
    info "Placas do lab pelas MACs"
    casa=$(nic_by_mac "$MAC_CASA"); mgmt=$(nic_by_mac "$MAC_MGMT"); vsan=$(nic_by_mac "$MAC_VSAN")
    [ -n "$mgmt" ] && [ -n "$vsan" ] || { ip -br link; die "não achei as placas $MAC_MGMT / $MAC_VSAN (confira os MACs da VM no Host Client)"; }
    [ -n "$casa" ] || warn "placa da rede de casa ($MAC_CASA) não encontrada"
    routes=""
    for net in $LAB_NETS; do routes="$routes
        - to: $net
          via: $LAB_GW"; done
    cat > /etc/netplan/60-vcf-lab.yaml <<EOF
# gerado por setup-svc01.sh - placas do lab (a da rede de casa fica no arquivo do instalador)
network:
  version: 2
  ethernets:
    lab-mgmt:
      match: { macaddress: "$MAC_MGMT" }
      set-name: lab-mgmt
      dhcp4: false
      dhcp6: false
      mtu: $MTU_LAB
      addresses: [ "$IP_MGMT" ]
      routes:$routes
    lab-vsan:
      match: { macaddress: "$MAC_VSAN" }
      set-name: lab-vsan
      dhcp4: false
      dhcp6: false
      mtu: $MTU_LAB
      addresses: [ "$IP_VSAN" ]
EOF
    chmod 600 /etc/netplan/60-vcf-lab.yaml
    netplan generate || die "netplan inválido (/etc/netplan/60-vcf-lab.yaml)"
    netplan apply
    sleep 3
    ip -br addr show lab-mgmt | grep -q "$(ip_only "$IP_MGMT")" && ok "lab-mgmt = $IP_MGMT (MTU $MTU_LAB)" || die "lab-mgmt sem $IP_MGMT"
    ip -br addr show lab-vsan | grep -q "$(ip_only "$IP_VSAN")" && ok "lab-vsan = $IP_VSAN (MTU $MTU_LAB)" || die "lab-vsan sem $IP_VSAN"
    ok "rotas $LAB_NETS via $LAB_GW (o VyOS sobe na etapa 4)"
    # o resolvedor local passa a ser o BIND da própria svc01 (que encaminha para fora)
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/vcf-lab.conf <<EOF
[Resolve]
DNS=127.0.0.1
Domains=~$LAB_DOMAIN ~.
EOF
    systemctl restart systemd-resolved
    ok "resolvedor: BIND local (127.0.0.1)"
}

# ------------------------------------------------------------------ disco de dados
do_disco() {
    info "Disco de dados em $DATA_MOUNT"
    mkdir -p "$DATA_MOUNT"
    if findmnt -n "$DATA_MOUNT" >/dev/null; then ok "já montado: $(findmnt -n -o SOURCE,FSTYPE "$DATA_MOUNT")"; return; fi
    root_disk=$(lsblk -no PKNAME "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1)
    part=$(lsblk -prno NAME,FSTYPE,SIZE,PKNAME | awk -v r="$root_disk" '$2=="ntfs" && $4!=r {print $3, $1}' | sort -h | tail -1 | awk '{print $2}')
    [ -n "$part" ] || { lsblk -f; warn "nenhuma partição NTFS fora do disco do sistema: o RDM do HD está na VM? (host: esxi-host-setup.sh rdm)"; return; }
    uuid=$(blkid -s UUID -o value "$part")
    opts="uid=0,gid=0,fmask=0022,dmask=0022,nofail,x-systemd.device-timeout=30"
    grep -q "$uuid" /etc/fstab || echo "UUID=$uuid $DATA_MOUNT ntfs3 $opts 0 0" >> /etc/fstab
    systemctl daemon-reload
    if mount "$DATA_MOUNT" 2>/dev/null; then
        ok "montado $part ($uuid) em $DATA_MOUNT (ntfs3, leitura e escrita)"
    else
        warn "o ntfs3 recusou montar (volume marcado como 'sujo' pelo Windows?). Montando só leitura com ntfs-3g."
        warn "Para gravar: ntfsfix -d $part  (ou chkdsk num Windows) e rode 'sudo bash $0 disco' de novo."
        mount -t ntfs-3g -o ro,uid=0,gid=0,fmask=0022,dmask=0022 "$part" "$DATA_MOUNT" || die "não montei $part"
    fi
    [ -d "$DATA_MOUNT/_migracao/D/VCF-Depot-911/PROD" ] && ok "depot encontrado em $DATA_MOUNT/_migracao/D/VCF-Depot-911" \
        || warn "não achei $DATA_MOUNT/_migracao/D/VCF-Depot-911/PROD - confira o caminho e ajuste Depot.Root no lab-config.psd1"
}

# ------------------------------------------------------------------ DNS (BIND9)
do_dns() {
    info "BIND9: recursivo para a casa e o lab, autoritativo para $LAB_DOMAIN (as zonas vêm da etapa 2)"
    casa_net=$(ip -4 -o route show dev "$(nic_by_mac "$MAC_CASA")" scope link 2>/dev/null | awk '{print $1}' | head -1)
    cat > /etc/bind/named.conf.options <<EOF
// gerado por setup-svc01.sh
acl lab-clients { 127.0.0.0/8; $(for n in $LAB_NETS; do printf '%s; ' "$n"; done)${casa_net:+$casa_net; }100.64.0.0/10; };
options {
    directory "/var/cache/bind";
    listen-on { any; };
    listen-on-v6 { none; };
    allow-query { lab-clients; };
    allow-recursion { lab-clients; };
    forwarders { $DNS_FORWARDERS };
    forward only;
    dnssec-validation no;   // .lab não existe na raiz: sem validação, o encaminhamento para fora não quebra
    auth-nxdomain no;
};
EOF
    mkdir -p /etc/bind/lab
    [ -f /etc/bind/lab/named.conf.lab ] || echo "// preenchido pela etapa 2 da automação" > /etc/bind/lab/named.conf.lab
    chgrp -R bind /etc/bind/lab; chmod 2775 /etc/bind/lab
    grep -q 'named.conf.lab' /etc/bind/named.conf.local || echo 'include "/etc/bind/lab/named.conf.lab";' >> /etc/bind/named.conf.local
    named-checkconf || die "named.conf inválido"
    systemctl enable --now named >/dev/null 2>&1; systemctl restart named
    systemctl is-active --quiet named && ok "BIND9 ativo (clientes: lab, ${casa_net:-casa?}, Tailscale)" || die "named não subiu (journalctl -u named)"
}

# ------------------------------------------------------------------ NTP (chrony)
do_ntp() {
    info "chrony: servidor de hora do lab"
    casa_net=$(ip -4 -o route show dev "$(nic_by_mac "$MAC_CASA")" scope link 2>/dev/null | awk '{print $1}' | head -1)
    {
        echo "# gerado por setup-svc01.sh"
        for s in $NTP_UPSTREAM; do echo "server $s iburst"; done
        echo "pool ntp.ubuntu.com iburst maxsources 2"
        for n in $LAB_NETS; do echo "allow $n"; done
        [ -n "$casa_net" ] && echo "allow $casa_net"
        echo "# sem internet, continua servindo hora para o lab"
        echo "local stratum 10"
        echo "makestep 1.0 3"
        echo "rtcsync"
        echo "driftfile /var/lib/chrony/chrony.drift"
        echo "logdir /var/log/chrony"
    } > /etc/chrony/chrony.conf
    systemctl enable --now chrony >/dev/null 2>&1; systemctl restart chrony
    sleep 2
    systemctl is-active --quiet chrony || journalctl -u chrony -n 10 --no-pager
    systemctl is-active --quiet chrony && ok "chrony ativo ($(chronyc -n tracking 2>/dev/null | awk -F': ' '/Reference ID/ {print $2}'))" || die "chrony não subiu"
}

# ------------------------------------------------------------------ nginx
do_nginx() {
    info "nginx (os sites do depot e do kickstart são criados pelas etapas 3 e 5)"
    rm -f /etc/nginx/sites-enabled/default
    nginx -t >/dev/null 2>&1 || die "nginx -t falhou"
    systemctl enable --now nginx >/dev/null 2>&1; systemctl reload nginx
    ok "nginx ativo"
}

# ------------------------------------------------------------------ NAT notebook -> lab
do_nat() {
    info "Roteamento: o notebook (rede de casa) alcança o lab passando pela svc01"
    echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/90-vcf-lab.conf
    sysctl -q -p /etc/sysctl.d/90-vcf-lab.conf
    cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
# gerado por setup-svc01.sh: o que entra pela rede de casa (ou Tailscale) e vai para o lab sai com o IP da
# svc01 no lab (10.52.10.2). Assim o lab responde para a svc01, sem rota de volta para a sua casa.
flush ruleset
table ip vcf-lab {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        oifname "lab-mgmt" ip daddr { $(echo "$LAB_NETS" | sed 's/ /, /g') } ip saddr != { $(echo "$LAB_NETS" | sed 's/ /, /g') } masquerade
    }
}
EOF
    nft -f /etc/nftables.conf || die "nftables inválido"
    systemctl enable --now nftables >/dev/null 2>&1
    casa_ip=$(ip -4 -o addr show dev "$(nic_by_mac "$MAC_CASA")" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    ok "NAT ligado. No notebook: rota $LAB_NETS via ${casa_ip:-<IP da svc01 na rede de casa>} (docs/svc01-ubuntu.md)"
}

# ------------------------------------------------------------------ proxy para os aparelhos da casa (sem mexer no roteador)
do_proxy() {
    info "Proxy HTTP (tinyproxy :3128) + PAC (http://<IP da casa>/lab.pac): o lab em qualquer aparelho da casa"
    apt-get install -y -q tinyproxy >/dev/null || die "não instalei o tinyproxy"
    casa_ip=$(ip -4 -o addr show dev "$(nic_by_mac "$MAC_CASA")" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    casa_net=$(ip -4 -o route show dev "$(nic_by_mac "$MAC_CASA")" scope link 2>/dev/null | awk '{print $1}' | head -1)
    c=/etc/tinyproxy/tinyproxy.conf
    sed -i 's/^Port .*/Port 3128/; s/^Timeout .*/Timeout 600/' "$c"
    grep -q "^Allow $casa_net" "$c" || echo "Allow $casa_net" >> "$c"
    for pt in 443 5480 8443 9443; do grep -q "^ConnectPort $pt" "$c" || echo "ConnectPort $pt" >> "$c"; done
    systemctl enable tinyproxy >/dev/null 2>&1; systemctl restart tinyproxy
    mkdir -p /var/www/lab
    cat > /var/www/lab/lab.pac <<EOF
function FindProxyForURL(url, host) {
  if (dnsDomainIs(host, ".$LAB_DOMAIN") || host == "$LAB_DOMAIN" || shExpMatch(host, "10.52.*") || shExpMatch(host, "10.60.*"))
    return "PROXY $casa_ip:3128";
  return "DIRECT";
}
EOF
    cat > /etc/nginx/sites-available/lab-pac <<EOF
server {
    listen 80;
    server_name _;
    location = /lab.pac { root /var/www/lab; default_type application/x-ns-proxy-autoconfig; }
}
EOF
    ln -sf /etc/nginx/sites-available/lab-pac /etc/nginx/sites-enabled/lab-pac
    nginx -t >/dev/null 2>&1 || die "nginx -t falhou"
    systemctl reload nginx
    systemctl is-active --quiet tinyproxy && ok "proxy ativo. Nos aparelhos: proxy automático (PAC) = http://$casa_ip/lab.pac" || die "tinyproxy não subiu"
}

# ------------------------------------------------------------------ PowerShell 7 + módulos
do_pwsh() {
    info "PowerShell 7, Posh-SSH e VCF.PowerCLI"
    if ! command -v pwsh >/dev/null; then
        # repositório da Microsoft para a versão do Ubuntu; se ainda não existir (ex.: 26.04), usa o snap oficial
        if wget -q "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -O /tmp/ms-prod.deb \
           && dpkg -i /tmp/ms-prod.deb >/dev/null && apt-get update -q && apt-get install -y -q powershell >/dev/null; then
            ok "PowerShell pelo repositório da Microsoft"
        else
            warn "sem pacote da Microsoft para o Ubuntu ${VERSION_ID}: instalando pelo snap"
            rm -f /etc/apt/sources.list.d/microsoft-prod.list /etc/apt/sources.list.d/microsoft-prod.sources
            snap install powershell --classic >/dev/null || die "não instalei o PowerShell (nem pelo snap)"
            ln -sf /snap/bin/pwsh /usr/local/bin/pwsh
        fi
    fi
    ok "PowerShell $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
    pwsh -NoProfile -Command '
        $ErrorActionPreference = "Stop"
        Set-PSRepository PSGallery -InstallationPolicy Trusted
        foreach ($m in "Posh-SSH", "VCF.PowerCLI") {
            if (-not (Get-Module -ListAvailable $m)) { Install-Module $m -Scope AllUsers -Force -AllowClobber; "  $m instalado" } else { "  $m já instalado" }
        }
        Import-Module VMware.VimAutomation.Core -WarningAction SilentlyContinue
        Set-PowerCLIConfiguration -Scope AllUsers -InvalidCertificateAction Ignore -ParticipateInCEIP $false -Confirm:$false | Out-Null
        "  PowerCLI configurado (certificados autoassinados aceitos)"
    ' || die "falhou a instalação dos módulos"
    ok "módulos prontos"
}

# ------------------------------------------------------------------ ovftool (opcional)
do_ovftool() {
    info "ovftool para Linux (opcional: sem ele a etapa 6 usa Import-VApp)"
    if command -v ovftool >/dev/null; then ok "ovftool já instalado: $(ovftool --version 2>/dev/null | head -1)"; return; fi
    zip=$(find "$DATA_MOUNT" "$SCRIPT_DIR" "$HOME" -maxdepth 6 -iname 'VMware-ovftool-*-lin.x86_64.zip' 2>/dev/null | sort | tail -1)
    if [ -z "$zip" ]; then
        warn "não achei VMware-ovftool-*-lin.x86_64.zip (portal Broadcom > OVF Tool > Linux 64-bit zip). Copie para $DATA_MOUNT e rode: sudo bash $0 ovftool"
        return
    fi
    rm -rf /opt/ovftool && unzip -q "$zip" -d /opt && ln -sf /opt/ovftool/ovftool /usr/local/bin/ovftool
    ovftool --version >/dev/null 2>&1 && ok "ovftool instalado de $(basename "$zip")" || warn "ovftool extraído mas não executa (ldd /opt/ovftool/ovftool.bin)"
}

# ------------------------------------------------------------------ status
do_status() {
    info "Rede";     ip -br addr | grep -v '^lo' | sed 's/^/   /'; ip route | grep -E "10\.52|10\.60|default" | sed 's/^/   /'
    info "Serviços"; for s in named chrony nginx nftables; do printf '   %-9s %s\n' "$s" "$(systemctl is-active $s)"; done
    info "DNS";      printf '   svc01.%s -> %s\n' "$LAB_DOMAIN" "$(dig +short "svc01.$LAB_DOMAIN" @127.0.0.1)"; printf '   google.com -> %s\n' "$(dig +short google.com @127.0.0.1 | head -1)"
    info "NTP";      chronyc -n tracking 2>/dev/null | grep -E 'Reference|Stratum|System time' | sed 's/^/   /'
    info "Disco";    findmnt "$DATA_MOUNT" | sed 's/^/   /' || echo "   $DATA_MOUNT não montado"
    info "Ferramentas"; printf '   pwsh %s | ovftool %s\n' "$(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>/dev/null || echo ausente)" "$(command -v ovftool >/dev/null && echo ok || echo ausente)"
}

case "${1:-tudo}" in
    tudo)    do_base; do_rede; do_disco; do_dns; do_ntp; do_nginx; do_nat; do_pwsh; do_ovftool; do_status
             echo; ok "svc01 pronta. Próximo: copiar o pacote para $LAB_HOME e rodar a automação (docs/PLANO-MIGRACAO.md, Fase 6)" ;;
    base)    do_base ;;
    rede)    do_rede ;;
    disco)   do_disco ;;
    dns)     do_dns ;;
    ntp)     do_ntp ;;
    nginx)   do_nginx ;;
    nat)     do_nat ;;
    proxy)   do_proxy ;;
    pwsh)    do_pwsh ;;
    ovftool) do_ovftool ;;
    status)  do_status ;;
    *) echo "uso: sudo bash $0 [tudo|base|rede|disco|dns|ntp|nginx|nat|proxy|pwsh|ovftool|status]"; exit 1 ;;
esac
