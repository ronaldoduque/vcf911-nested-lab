#!/bin/sh
# =============================================================================
# esxi-host-setup.sh - prepara o ESXi 8.0 U3 físico do SRV-LAB para o lab VCF 9.1.1
#
# Rode no próprio ESXi, por SSH como root (Host Client > Gerenciar > Serviços > TSM-SSH > Iniciar):
#   scp esxi-host-setup.sh root@<ip-do-esxi>:/tmp/
#   ssh root@<ip-do-esxi>
#   sh /tmp/esxi-host-setup.sh listar
#
# Ações (na ordem):
#   listar      mostra os discos com o papel sugerido e os IDs para preencher abaixo (não altera nada)
#   basico      hostname, NTP, política de energia, autostart, avisos de shell
#   rede        3 vSwitches internos (sem placa física, MTU 9000, promíscuo) + port groups do lab
#   datastores  VMFS6 nos 3 NVMe de 1 TB e renomeia o datastore do SSD para ds-ssd   (APAGA os NVMe)
#   tiering     liga o Memory Tiering no NVMe de 500 GB do antigo Windows        (APAGA o Windows)
#   rdm         cria o ponteiro RDM do HD de dados para a VM svc01 ler as ISOs (não formata o HD)
#   svc01       cria a VM svc01 (Ubuntu 24.04): disco, 3 placas com MAC fixo, ISO no CD, autostart; liga a VM
#               para você instalar o Ubuntu pela console do Host Client (SEM o HD de dados: o instalador
#               só enxerga o disco de 60 GB e não tem como apagar o HD por engano)
#   svc01rdm    com a svc01 DESLIGADA depois da instalação: liga o HD de dados (RDM) e tira a ISO do CD
#   status      resumo de tudo (rede, datastores, tiering, memória, licença)
#
# Cada ação é idempotente. As destrutivas pedem para você digitar o nome do disco/datastore.
# =============================================================================

# ------------------------------------------------------------------ PREENCHA
HOST_NAME="srv-lab"
DOMAIN_NAME=""                       # opcional (o domínio do lab é servido pela svc01)
NTP_SERVERS="a.st1.ntp.br b.st1.ntp.br"
MTU=9000

# vSwitches internos (sem uplink físico) = as VMnets do Workstation
VSW_MGMT="vSwitch-VCF-MGMT";  PG_MGMT="VCF911-MGMT"        # 10.52.10.0/24 + vMotion sem tag (= VMnet10)
VSW_VSAN="vSwitch-VCF-VSAN";  PG_VSAN="VCF911-VSAN"        # 10.52.12.0/24 sem tag              (= VMnet12)
VSW_NSX="vSwitch-VCF-NSX";    PG_NSX="VCF911-NSX-TRUNK"    # VLANs 13-16 com tag (VLAN 4095)  (= LAN Segment)
# A rede da sua casa continua no vSwitch0 / port group "VM Network" (WAN do VyOS, LAN da svc01)

# Depois do 'listar', cole os IDs (coluna ID) aqui:
DS_LIST=""            # ex.: "ds-nvme1=t10.NVMe____Samsung_SSD_970_EVO_1TB___xxxx ds-nvme2=t10... ds-nvme3=t10..."
DS_SSD_NAME="ds-ssd"  # o instalador cria "datastore1" no SSD; renomeamos
TIER_DEVICE=""        # ID do NVMe de 500 GB (o antigo disco do Windows)
TIER_PCT=25           # % da RAM em NVMe: 25 = +64 GB. Era 120: com memória ativa no NVMe de linha consumidor um ESX nested congelou
HDD_DADOS=""          # ID do HD de 1 TB com a pasta _migracao (o antigo E: "HDD-BKP") - RDM da svc01
SVC_VM_DIR="svc01"    # pasta da VM svc01 no ds-ssd

# VM svc01 (Ubuntu 24.04). Os MACs têm de bater com o lab-config.psd1 (Svc01.*Mac) e com o setup-svc01.sh
SVC_ISO=""            # nome da ISO do Ubuntu Server em [ds-ssd] ISO/ (ex.: ubuntu-24.04.3-live-server-amd64.iso)
SVC_CPU=4
SVC_MEM_MB=8192
SVC_DISK_GB=60
SVC_MAC_CASA="00:50:56:3B:01:00"   # VM Network (rede de casa)
SVC_MAC_MGMT="00:50:56:3B:01:01"   # VCF911-MGMT (10.52.10.2)
SVC_MAC_VSAN="00:50:56:3B:01:02"   # VCF911-VSAN (10.52.12.1)
PG_CASA="VM Network"
# -----------------------------------------------------------------------------

set -u
RED='\033[31m'; GRN='\033[32m'; YEL='\033[33m'; CYA='\033[36m'; RST='\033[0m'
ok()   { printf "${GRN}[OK]${RST}   %s\n" "$*"; }
info() { printf "${CYA}[..]${RST}   %s\n" "$*"; }
warn() { printf "${YEL}[AVISO]${RST} %s\n" "$*"; }
die()  { printf "${RED}[ERRO]${RST} %s\n" "$*"; exit 1; }

field() { echo "$1" | awk -F': ' -v k="$2" '$1 ~ "^ *"k"$" {print $2; exit}'; }

disk_info() {   # $1 = id
    esxcli storage core device list -d "$1" 2>/dev/null
}

is_boot() { [ "$(field "$(disk_info "$1")" 'Is Boot Device')" = "true" ]; }

ptbl() { partedUtil getptbl "/vmfs/devices/disks/$1" 2>/dev/null | tail -n +3; }

confirm() {     # $1 = texto que precisa ser digitado
    printf "${YEL}Para confirmar, digite exatamente:${RST} %s\n> " "$1"
    read -r ans
    [ "$ans" = "$1" ] || die "Confirmação diferente - nada foi alterado."
}

# ------------------------------------------------------------------ listar
do_listar() {
    info "Discos vistos pelo ESXi (Size em GB decimais aproximados)"
    printf "%-6s %-8s %-5s %-5s %-34s %s\n" "GB" "TIPO" "SSD" "BOOT" "CONTEÚDO" "ID / modelo"
    for d in $(ls /vmfs/devices/disks/ | grep -v ':' | grep -v '^vml\.'); do
        inf=$(disk_info "$d") || continue
        [ -n "$inf" ] || continue
        name=$(field "$inf" 'Display Name')
        mb=$(field "$inf" 'Size'); gb=$(( ${mb:-0} * 1049 / 1000000 ))
        ssd=$(field "$inf" 'Is SSD'); boot=$(field "$inf" 'Is Boot Device')
        bus="SATA/SAS"; echo "$name $d" | grep -qi nvme && bus="NVMe"
        [ "$ssd" = "false" ] && bus="HDD"
        pt=$(ptbl "$d")
        cont="vazio"
        echo "$pt" | grep -qiE 'vmfs|AA31E02A' && cont="VMFS ($(esxcli storage vmfs extent list | awk -v d="$d" '$0 ~ d {print $1}' | head -1))"
        echo "$pt" | grep -qiE 'basicdata|msftres|EBD0A0A2|E3C9E316' && cont="NTFS/Windows"
        [ "$boot" = "true" ] && cont="ESXi (boot)"
        echo "$pt" | grep -q . || cont="sem partições"
        role="?"
        if [ "$boot" = "true" ]; then role="BOOT ESXi + $DS_SSD_NAME"
        elif [ "$bus" = "HDD" ]; then role="HDD backup (preservar)"
        elif [ "$bus" = "NVMe" ] && [ "$gb" -ge 800 ] && [ "$gb" -le 1200 ]; then role="-> DS_LIST (ds-nvmeN)"
        elif [ "$bus" = "NVMe" ] && [ "$gb" -ge 400 ] && [ "$gb" -le 600 ]; then role="-> TIER_DEVICE (antigo Windows)"
        fi
        printf "%-6s %-8s %-5s %-5s %-34s %s\n" "$gb" "$bus" "$ssd" "$boot" "$cont" "$d"
        printf "       %s   [%s]\n" "$name" "$role"
    done
    echo
    info "Datastores atuais:"; esxcli storage filesystem list | awk 'NR<=2 || /VMFS/'
    echo
    info "Preencha DS_LIST, TIER_DEVICE e HDD_DADOS no topo do script com os IDs acima."
}

# ------------------------------------------------------------------ basico
do_basico() {
    info "Hostname, NTP, energia e autostart"
    if [ -n "$DOMAIN_NAME" ]; then esxcli system hostname set --host="$HOST_NAME" --domain="$DOMAIN_NAME"
    else esxcli system hostname set --host="$HOST_NAME"; fi
    args=""; for s in $NTP_SERVERS; do args="$args --server=$s"; done
    # shellcheck disable=SC2086
    esxcli system ntp set $args --enabled=true && ok "NTP: $NTP_SERVERS" || warn "NTP não configurado (configure no Host Client > Gerenciar > Sistema > Data e hora)"
    esxcli network firewall ruleset set --ruleset-id=ntpClient --enabled=true 2>/dev/null
    esxcli system settings advanced set -o /Power/CpuPolicy -s "High Performance" 2>/dev/null && ok "Energia: High Performance"
    esxcli system settings advanced set -o /UserVars/SuppressShellWarning -i 1
    esxcli system settings advanced set -o /UserVars/HostClientCEIPOptIn -i 2
    vim-cmd hostsvc/autostartmanager/enable_autostart true >/dev/null 2>&1 && ok "Autostart de VMs ligado"
    ok "Básico aplicado ($(esxcli system hostname get | awk -F': ' '/Fully Qualified/ {print $2}'))"
}

# ------------------------------------------------------------------ rede
mk_vswitch() {   # $1 vswitch  $2 portgroup  $3 vlan
    if ! esxcli network vswitch standard list -v "$1" >/dev/null 2>&1; then
        esxcli network vswitch standard add -v "$1" -P 128 || die "não criei $1"
    fi
    esxcli network vswitch standard set -v "$1" -m "$MTU"
    esxcli network vswitch standard policy security set -v "$1" --allow-promiscuous=true --allow-forged-transmits=true --allow-mac-change=true
    esxcli network vswitch standard policy shaping set -v "$1" -e false
    if ! esxcli network vswitch standard portgroup list | awk '{print $1}' | grep -qx "$2"; then
        esxcli network vswitch standard portgroup add -p "$2" -v "$1"
    fi
    esxcli network vswitch standard portgroup set -p "$2" --vlan-id "$3"
    ok "$1 (MTU $MTU, promíscuo/forged/MAC, sem shaping) -> port group $2 VLAN $3"
}
do_rede() {
    info "Criando os switches internos do lab (sem placa física: só as VMs conversam entre si)"
    mk_vswitch "$VSW_MGMT" "$PG_MGMT" 0
    mk_vswitch "$VSW_VSAN" "$PG_VSAN" 0
    mk_vswitch "$VSW_NSX"  "$PG_NSX"  4095
    esxcli network vswitch standard portgroup list | awk 'NR<=2 || /VCF911|VM Network/'
}

# ------------------------------------------------------------------ datastores
do_datastores() {
    # SSD de boot: datastore1 -> ds-ssd
    if [ -d /vmfs/volumes/datastore1 ] && [ ! -d "/vmfs/volumes/$DS_SSD_NAME" ]; then
        vim-cmd hostsvc/datastore/rename datastore1 "$DS_SSD_NAME" && ok "datastore1 renomeado para $DS_SSD_NAME"
    fi
    [ -d "/vmfs/volumes/$DS_SSD_NAME" ] && mkdir -p "/vmfs/volumes/$DS_SSD_NAME/ISO" && ok "$DS_SSD_NAME/ISO pronto"
    # o /tmp do ESXi some no reboot: guarda uma cópia deste script (com os IDs já preenchidos) no datastore
    if [ -d "/vmfs/volumes/$DS_SSD_NAME" ]; then
        mkdir -p "/vmfs/volumes/$DS_SSD_NAME/scripts" && cp "$0" "/vmfs/volumes/$DS_SSD_NAME/scripts/esxi-host-setup.sh" \
            && ok "cópia do script em /vmfs/volumes/$DS_SSD_NAME/scripts/esxi-host-setup.sh (use esta depois do reboot)"
    fi
    [ -n "$DS_LIST" ] || die "DS_LIST vazio - rode 'listar' e preencha no topo do script."
    for pair in $DS_LIST; do
        name=${pair%%=*}; id=${pair#*=}
        dev="/vmfs/devices/disks/$id"
        [ -e "$dev" ] || die "$id não existe (confira o 'listar')."
        if [ -d "/vmfs/volumes/$name" ]; then ok "$name já existe"; continue; fi
        is_boot "$id" && die "$id é o disco de boot do ESXi!"
        [ "$id" = "$TIER_DEVICE" ] && die "$id é o TIER_DEVICE - não pode ser datastore."
        [ "$id" = "$HDD_DADOS" ] && die "$id é o HD de dados - não pode ser datastore."
        echo; info "$name em $(field "$(disk_info "$id")" 'Display Name')"
        pt=$(ptbl "$id"); [ -n "$pt" ] && { warn "partições atuais (serão APAGADAS):"; echo "$pt"; }
        confirm "$name"
        partedUtil mklabel "$dev" gpt || die "mklabel falhou em $id"
        end=$(partedUtil getUsableSectors "$dev" | awk '{print $2}')
        partedUtil setptbl "$dev" gpt "1 2048 $end AA31E02A400F11DB9590000C2911D1B8 0" >/dev/null || die "setptbl falhou em $id"
        vmkfstools -C vmfs6 -S "$name" "${dev}:1" >/dev/null || die "vmkfstools falhou em $id"
        ok "$name criado (VMFS6)"
    done
    # core dump no ds-ssd (com systemMediaSize=min o ESX-OSData é pequeno para o dump de 256 GB de RAM)
    if [ -d "/vmfs/volumes/$DS_SSD_NAME" ] && ! esxcli system coredump file list 2>/dev/null | grep -q "$DS_SSD_NAME"; then
        if esxcli system coredump file add -d "$DS_SSD_NAME" -f coredump >/dev/null 2>&1 && esxcli system coredump file set --smart --enable true >/dev/null 2>&1; then
            ok "core dump em $DS_SSD_NAME"
        else
            warn "não configurei o core dump no $DS_SSD_NAME (esxcli system coredump file add -d $DS_SSD_NAME)"
        fi
    fi
    esxcli storage filesystem list | awk 'NR<=2 || /VMFS/'
}

# ------------------------------------------------------------------ tiering
do_tiering() {
    [ -n "$TIER_DEVICE" ] || die "TIER_DEVICE vazio - rode 'listar' e preencha no topo do script."
    dev="/vmfs/devices/disks/$TIER_DEVICE"
    [ -e "$dev" ] || die "$TIER_DEVICE não existe."
    is_boot "$TIER_DEVICE" && die "$TIER_DEVICE é o disco de boot do ESXi!"
    if esxcli system tierdevice list 2>/dev/null | grep -q "$TIER_DEVICE"; then
        ok "$TIER_DEVICE já é dispositivo de tiering"
    else
        pt=$(ptbl "$TIER_DEVICE")
        if echo "$pt" | grep -qiE 'basicdata|msftres|EBD0A0A2|E3C9E316'; then
            warn "Este NVMe ainda tem o WINDOWS. Só continue se o 05-Verificar-Backup.ps1 deu PRONTO-PARA-MIGRAR."
            echo "$pt"
            confirm "APAGAR-WINDOWS"
        elif [ -n "$pt" ]; then
            warn "partições atuais (serão APAGADAS):"; echo "$pt"
            confirm "TIER"
        fi
        partedUtil mklabel "$dev" gpt || die "mklabel falhou"
        esxcli system settings kernel set -s MemoryTiering -v TRUE || die "não liguei o MemoryTiering"
        esxcli system tierdevice create -d "$dev" || die "tierdevice create falhou"
        ok "NVMe $TIER_DEVICE agora é memória em camadas"
    fi
    esxcli system settings advanced set -o /Mem/TierNvmePct -i "$TIER_PCT" && ok "TierNvmePct = $TIER_PCT% da RAM"
    warn "REINICIE o ESXi para valer (reboot). Depois: sh $0 status"
}

# ------------------------------------------------------------------ rdm
make_rdm() {    # cria [ds-ssd] svc01/hdd-dados-rdm.vmdk (RDM físico) apontando para o HD de dados
    [ -n "$HDD_DADOS" ] || die "HDD_DADOS vazio - rode 'listar' e preencha no topo do script."
    dev="/vmfs/devices/disks/$HDD_DADOS"
    [ -e "$dev" ] || die "$HDD_DADOS não existe."
    is_boot "$HDD_DADOS" && die "é o disco de boot!"
    [ "$HDD_DADOS" = "$TIER_DEVICE" ] && die "HDD_DADOS é o TIER_DEVICE!"
    echo "$DS_LIST" | grep -q "=$HDD_DADOS" && die "HDD_DADOS está no DS_LIST!"
    dir="/vmfs/volumes/$DS_SSD_NAME/$SVC_VM_DIR"
    mkdir -p "$dir"
    out="$dir/hdd-dados-rdm.vmdk"
    if [ -f "$out" ]; then ok "$out já existe"; else
        vmkfstools -z "$dev" "$out" || die "vmkfstools -z falhou (o ESXi não permite RDM deste controlador?)"
        ok "RDM físico criado: $out (o HD NÃO é formatado)"
    fi
}
do_rdm() {
    make_rdm
    info "O 'svc01' já liga este RDM na VM. Para uma VM criada à mão: Editar > Adicionar disco rígido > Disco existente"
    info "> $SVC_VM_DIR/hdd-dados-rdm.vmdk, numa controladora SCSI (PVSCSI). O Ubuntu monta o NTFS em /srv/dados."
}

# ------------------------------------------------------------------ svc01 (Ubuntu)
do_svc01() {
    ds="/vmfs/volumes/$DS_SSD_NAME"; dir="$ds/$SVC_VM_DIR"; vmx="$dir/$SVC_VM_DIR.vmx"
    [ -d "$ds" ] || die "$DS_SSD_NAME não existe - rode 'datastores' antes."
    if vim-cmd vmsvc/getallvms 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "$SVC_VM_DIR"; then
        ok "VM $SVC_VM_DIR já registrada"; return
    fi
    [ -n "$SVC_ISO" ] || die "SVC_ISO vazio: envie a ISO do Ubuntu Server para [$DS_SSD_NAME] ISO/ e preencha SVC_ISO no topo."
    [ -f "$ds/ISO/$SVC_ISO" ] || die "$ds/ISO/$SVC_ISO não existe (Host Client > Armazenamento > $DS_SSD_NAME > Navegador > ISO > Carregar)."
    for pg in "$PG_CASA" "$PG_MGMT" "$PG_VSAN"; do
        esxcli network vswitch standard portgroup list | grep -q "^$pg " || die "port group '$pg' não existe (rode 'rede')."
    done
    mkdir -p "$dir"
    if [ ! -f "$dir/$SVC_VM_DIR.vmdk" ]; then
        vmkfstools -c "${SVC_DISK_GB}G" -d thin "$dir/$SVC_VM_DIR.vmdk" >/dev/null || die "não criei o disco"
    fi
    cat > "$vmx" <<VMX
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "21"
displayName = "$SVC_VM_DIR"
guestOS = "ubuntu-64"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
numvcpus = "$SVC_CPU"
cpuid.coresPerSocket = "$SVC_CPU"
memSize = "$SVC_MEM_MB"
pciBridge0.present = "TRUE"
pciBridge4.present = "TRUE"
pciBridge4.virtualDev = "pcieRootPort"
pciBridge4.functions = "8"
pciBridge5.present = "TRUE"
pciBridge5.virtualDev = "pcieRootPort"
pciBridge5.functions = "8"
pciBridge6.present = "TRUE"
pciBridge6.virtualDev = "pcieRootPort"
pciBridge6.functions = "8"
pciBridge7.present = "TRUE"
pciBridge7.virtualDev = "pcieRootPort"
pciBridge7.functions = "8"
nvme0.present = "TRUE"
nvme0:0.present = "TRUE"
nvme0:0.fileName = "$SVC_VM_DIR.vmdk"
sata0.present = "TRUE"
sata0:0.present = "TRUE"
sata0:0.deviceType = "cdrom-image"
sata0:0.fileName = "$ds/ISO/$SVC_ISO"
sata0:0.startConnected = "TRUE"
ethernet0.present = "TRUE"
ethernet0.virtualDev = "vmxnet3"
ethernet0.networkName = "$PG_CASA"
ethernet0.addressType = "static"
ethernet0.address = "$SVC_MAC_CASA"
ethernet0.startConnected = "TRUE"
ethernet1.present = "TRUE"
ethernet1.virtualDev = "vmxnet3"
ethernet1.networkName = "$PG_MGMT"
ethernet1.addressType = "static"
ethernet1.address = "$SVC_MAC_MGMT"
ethernet1.startConnected = "TRUE"
ethernet2.present = "TRUE"
ethernet2.virtualDev = "vmxnet3"
ethernet2.networkName = "$PG_VSAN"
ethernet2.addressType = "static"
ethernet2.address = "$SVC_MAC_VSAN"
ethernet2.startConnected = "TRUE"
tools.syncTime = "FALSE"
VMX
    id=$(vim-cmd solo/registervm "$vmx" "$SVC_VM_DIR" 2>/dev/null) || die "não registrei a VM ($vmx)"
    ok "VM $SVC_VM_DIR registrada (id $id): $SVC_CPU vCPU, $((SVC_MEM_MB / 1024)) GB, disco ${SVC_DISK_GB} GB thin, 3 placas vmxnet3"
    if vim-cmd hostsvc/autostartmanager/update_autostartentry "$id" PowerOn 120 1 guestShutdown 120 systemDefault >/dev/null 2>&1; then
        ok "autostart: $SVC_VM_DIR liga primeiro"
    else
        warn "autostart não configurado (a etapa 1 da automação faz)"
    fi
    vim-cmd vmsvc/power.on "$id" >/dev/null && ok "VM ligada: Host Client > Máquinas virtuais > $SVC_VM_DIR > Console, e instale o Ubuntu"
    info "Placa da rede de casa no instalador do Ubuntu = MAC $SVC_MAC_CASA. As outras duas ficam desabilitadas."
    info "Depois de instalar: desligue a svc01 (sudo poweroff) e rode: sh $0 svc01rdm"
}

do_svc01rdm() {
    warn "No ESXi 8 o HD SATA local sai com Is RDM Capable: false e a VM fica inválida. Use o disco de dados + host/hdd-nbd.py (docs/svc01-ubuntu.md, passo 4)."
    die "svc01rdm desativado"
    dir="/vmfs/volumes/$DS_SSD_NAME/$SVC_VM_DIR"; vmx="$dir/$SVC_VM_DIR.vmx"
    id=$(vim-cmd vmsvc/getallvms 2>/dev/null | awk -v n="$SVC_VM_DIR" 'NR>1 && $2==n {print $1}')
    [ -n "$id" ] || die "VM $SVC_VM_DIR não registrada (rode 'svc01')."
    vim-cmd vmsvc/power.getstate "$id" | grep -q 'Powered off' || die "desligue a svc01 antes (no Ubuntu: sudo poweroff)."
    make_rdm
    if grep -q 'hdd-dados-rdm.vmdk' "$vmx"; then ok "RDM já está no .vmx"; else
        cp "$vmx" "$vmx.bak"
        cat >> "$vmx" <<VMX
scsi0.present = "TRUE"
scsi0.virtualDev = "pvscsi"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "hdd-dados-rdm.vmdk"
scsi0:0.mode = "independent-persistent"
VMX
        ok "HD de dados (RDM físico) ligado na svc01 em PVSCSI"
    fi
    sed -i 's/^sata0:0.startConnected = .*/sata0:0.startConnected = "FALSE"/' "$vmx"
    vim-cmd vmsvc/reload "$id" >/dev/null 2>&1 || die "não recarreguei a VM (restaure $vmx.bak)"
    ok "ISO do Ubuntu desconectada do CD"
    vim-cmd vmsvc/power.on "$id" >/dev/null && ok "svc01 ligada: entre por SSH e rode sudo bash setup-svc01.sh"
}

# ------------------------------------------------------------------ status
do_status() {
    info "Host";        esxcli system version get | sed 's/^/   /'; esxcli system hostname get | awk -F': ' '/Fully/ {print "   "$0}'
    info "Licença";     vim-cmd vimsvc/license --show 2>/dev/null | grep -E 'serial|name|expir|editionKey' | sed 's/^/   /'
    info "Memória";     esxcli hardware memory get | sed 's/^/   /'
    info "Tiering";     esxcli system settings kernel list -o MemoryTiering 2>/dev/null | tail -n +3 | sed 's/^/   /'
                        esxcli system tierdevice list 2>/dev/null | sed 's/^/   /'
                        echo "   TierNvmePct: $(esxcli system settings advanced list -o /Mem/TierNvmePct 2>/dev/null | awk -F': ' '/Int Value/ {print $2; exit}')"
    info "Rede";        esxcli network vswitch standard list | awk -F': ' '/^[^ ]/ {n=$0} /MTU|Uplinks/ {print "   " n " -> " $0}'
                        esxcli network vswitch standard portgroup list | sed 's/^/   /'
                        esxcli network nic list | sed 's/^/   /'
    info "Datastores";  esxcli storage filesystem list | awk 'NR<=2 || /VMFS/' | sed 's/^/   /'
    info "NTP";         esxcli system ntp get 2>/dev/null | sed 's/^/   /'
}

case "${1:-}" in
    listar)     do_listar ;;
    basico)     do_basico ;;
    rede)       do_rede ;;
    datastores) do_datastores ;;
    tiering)    do_tiering ;;
    rdm)        do_rdm ;;
    svc01)      do_svc01 ;;
    svc01rdm)   do_svc01rdm ;;
    status)     do_status ;;
    *) echo "uso: sh $0 listar|basico|rede|datastores|tiering|rdm|svc01|svc01rdm|status"; exit 1 ;;
esac
