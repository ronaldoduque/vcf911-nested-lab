#
# lab-config.psd1 - Configuração ÚNICA do lab VCF 9.1.1 nested no ESXi 8 FÍSICO (SRV-LAB)
#
# Mesmo desenho do lab do Workstation (10.52.x, VyOS, VCF Installer, fleet sem Automation), com:
#   - o ESXi 8.0 U3 instalado direto na máquina (SSD de boot, Memory Tiering no NVMe de 500 GB)
#   - os ESX nested um por NVMe de 1 TB (ds-nvme1..3)
#   - a VM svc01 (Ubuntu 24.04) no lugar do Windows físico: DNS (BIND9), NTP (chrony), depot e kickstart
#     (nginx), e de onde estes scripts rodam (PowerShell 7 + VCF.PowerCLI). Preparada por svc01/setup-svc01.sh
#   - VMnet10 / VMnet12 / LAN Segment viram port groups de vSwitches internos (host/esxi-host-setup.sh)
#
# Regras de senha que este arquivo já respeita (o 00-Preflight.ps1 confere):
#   - VCF Installer / SDDC Manager / VCFMS / VCF Operations: mínimo 15 caracteres, complexa
#   - NSX (root/admin/audit): mínimo 12 caracteres, complexa
#   - vCenter root e SSO: 8 a 20 caracteres
#
@{
    LabName  = 'vcf911'

    # Domínio do lab (zona do BIND9 na svc01). O mesmo do lab do Workstation.
    Domain   = 'vcf.lab'
    TimeZone = 'America/Sao_Paulo'

    # ------------------------------------------------------------------ ESXi 8 físico
    EsxiHost = @{
        Address      = '192.168.0.100'          # IP do ESXi físico na rede de casa (vmk0): o antigo IP do Windows
        User         = 'root'
        Password     = '<SENHA_ROOT_DO_ESXI_FISICO>'
        IsoDatastore = 'ds-ssd'                # onde as ISOs (ESX, VyOS) ficam para as VMs darem boot
        IsoFolder    = 'ISO'
        MinVersion   = '8.0.3'                 # Memory Tiering precisa do 8.0 U3
    }

    # ------------------------------------------------------------------ VM de serviços (svc01, Ubuntu 24.04)
    # Criada por host/esxi-host-setup.sh svc01 e preparada por svc01/setup-svc01.sh (os MACs e IPs de lá
    # precisam bater com estes).
    Svc01 = @{
        VmName       = 'svc01'
        MemoryGB     = 8
        LanMac       = '00:50:56:3B:01:00'   # VM Network (casa): SSH, internet, acesso do notebook ao lab
        MgmtMac      = '00:50:56:3B:01:01'   # VCF911-MGMT: 10.52.10.2 (DNS, NTP, depot, kickstart)
        VsanMac      = '00:50:56:3B:01:02'   # VCF911-VSAN: 10.52.12.1 (gateway do vSAN isolado)
        DataMount    = '/srv/dados'          # HD de dados (RDM, NTFS, driver ntfs3) montado aqui
        NginxSites   = '/etc/nginx/sites-available'
        BindDir      = '/etc/bind/lab'       # zonas geradas pela etapa 2
    }

    # ------------------------------------------------------------------ Mídias / pastas (dentro da svc01)
    # O HD de dados (o antigo E: "HDD-BKP", com a cópia em _migracao) chega na svc01 por RDM e é montado em
    # /srv/dados. A ISO do ESX e o OVA do Installer vêm de dentro do depot oficial (VCF Download Tool).
    Paths = @{
        # Nome exato ou curinga (*). Com curinga e mais de um arquivo, usa o mais novo e avisa.
        IsoEsxi         = '/srv/dados/_migracao/D/VCF-Depot-911/PROD/COMP/ESX_HOST/VMware-VMvisor-Installer-9.1.1*.iso'
        IsoVyos         = '/srv/dados/_migracao/D/ISOs/vyos-2026.03-generic-amd64.iso'
        OvaVcfInstaller = '/srv/dados/_migracao/D/VCF-Depot-911/PROD/COMP/SDDC_MANAGER_VCF/VCF-SDDC-Manager-Appliance-9.1.1*.ova'
        WorkDir         = '/opt/vcf911/_work'
        # ovftool para Linux (o setup-svc01.sh instala a partir do zip VMware-ovftool-*-lin.x86_64.zip no HD de
        # dados). Com ele o Installer é importado com --X:injectOvfEnv; sem ele, usa Import-VApp + guestinfo.ovfEnv.
        Ovftool         = '/usr/local/bin/ovftool'
    }

    # ------------------------------------------------------------------ Depot offline (nginx)
    # O depot é o baixado pelo VCF Download Tool (estrutura PROD/ pronta). A etapa 3 confere se tem tudo
    # o que a release precisa e publica no nginx da svc01, lendo direto do HD de dados.
    # VCF 9.1.1 recusa URL de depot terminando em .lab (KB 456037): o Installer usa o IP.
    Depot = @{
        Root      = '/srv/dados/_migracao/D/VCF-Depot-911'
        SiteName  = 'vcf-depot-911'
        BindIp    = '10.52.10.2'       # IP da svc01 no port group de gerência
        Port      = 8091               # HTTP sem autenticação (suportado a partir do 9.1)
    }

    # ------------------------------------------------------------------ Rede (mesmo plano IP; port groups no lugar das VMnets)
    Network = @{
        MgmtPortgroup  = 'VCF911-MGMT'          # = VMnet10 (sem tag)
        VsanPortgroup  = 'VCF911-VSAN'          # = VMnet12 (vSAN isolado, sem tag)
        TrunkPortgroup = 'VCF911-NSX-TRUNK'     # = LAN Segment (VLAN 4095, tags 13-16)
        WanPortgroup   = 'VM Network'           # rede de casa (WAN do VyOS, LAN da svc01)
        HostAdapterIp  = '10.52.10.2'           # IP da svc01 na gerência (DNS/NTP/depot/kickstart)
        MgmtCidr       = '10.52.10.0/24'
        MgmtGateway    = '10.52.10.1'
        DnsServer      = '10.52.10.2'
        NtpServer      = '10.52.10.2'
        LabSupernet    = '10.52.0.0/16'
        OverlaySupernet = '10.60.0.0/16'
        JumboMtu       = 9000

        Vlans = @{
            VMotion = @{ Id = 0;  Cidr = '10.52.11.0/24'; Gateway = '10.52.11.1'; PoolStart = '10.52.11.101'; PoolEnd = '10.52.11.118' }
            VSAN    = @{ Id = 0;  Cidr = '10.52.12.0/24'; Gateway = '10.52.12.1'; PoolStart = '10.52.12.101'; PoolEnd = '10.52.12.118' }
            HostTep = @{ Id = 13; Cidr = '10.52.13.0/24'; Gateway = '10.52.13.1'; PoolStart = '10.52.13.101'; PoolEnd = '10.52.13.118' }
            EdgeTep = @{ Id = 14; Cidr = '10.52.14.0/24'; Gateway = '10.52.14.1' }
            Uplink1 = @{ Id = 15; Cidr = '10.52.15.0/24'; Gateway = '10.52.15.1' }
            Uplink2 = @{ Id = 16; Cidr = '10.52.16.0/24'; Gateway = '10.52.16.1' }
        }
    }

    # ------------------------------------------------------------------ VyOS
    VyOS = @{
        VmName        = 'vcf911-gw01'
        Datastore     = 'ds-ssd'
        MacPrefix     = '00:50:56:3B:02'        # eth0..eth2 = :00 :01 :02
        Hostname      = 'gw01'
        CpuCount      = 2
        MemoryMB      = 2048
        DiskMB        = 10240
        Password      = '<SENHA_DO_LAB>'
        BootWaitSec   = 60                     # tempo do live boot da ISO antes do login
    }

    # ------------------------------------------------------------------ ESX 9.1.1 nested (4 hosts)
    Esxi = @{
        Password       = '<SENHA_DO_LAB>'
        # 4 (padrão, decisão de 15/11: cluster mais realista; esx04 divide um NVMe, sem problema de desempenho
        # no ESXi físico, e com vSAN FTT=0 cabe com folga) ou 3 (um por NVMe, 120 GB cada).
        # Pode trocar aqui ou na hora: ./Deploy-Lab.ps1 -HostCount 3
        HostCount      = 4
        CpuCount       = 14                  # com 4 hosts: 4 x 14 = 56 vCPU (= threads do host)
        CpuCount3      = 18                  # com 3 hosts: 3 x 18 = 54 vCPU (passa a checagem de capacidade do Installer, 52)
        CoresPerSocket = 0                   # 0 = 2 sockets virtuais (metade das vCPU em cada), como o host
        # Memória: 256 GB de RAM + Memory Tiering (TierNvmePct 25 = +64 GB, ~320 GB). Lição do deploy real:
        # com 110 GB por host (~466 GB contratados) um ESX nested congelou; com 58 GB tudo cabe na DRAM. O que está ativo
        # fica na RAM, o resto vai para o NVMe.
        MemoryGB       = 58                  # 4 hosts: 4 x 58 + svc01 8 + VyOS 2 = 242 GB (+ Installer 16 só no deploy)
        MemoryGB3      = 76                  # 3 hosts: 3 x 76 + svc01 8 + VyOS 2 = 238 GB (+ Installer 16 só no deploy)
        BootDiskGB     = 40                  # ESX 9 pede no mínimo 32 GB de boot
        CacheDiskGB    = 40                  # só OSA: disco de cache (no ESA não existe)
        CacheEagerZero = $true               # cache thick eager-zeroed (40 GB por host já alocados): escrita sem custo de 1a alocação
        NicTxThreads   = $true               # ethernetN.ctxPerDev = 3 nas vmxnet3 dos ESX nested: mais vazão de pacotes
        CapacityDiskGB = 600                 # capacidade do vSAN por host (thin). OSA: PVSCSI marcado SSD; ESA: NVMe virtual
        NicType        = 'vmxnet3'
        NicCount       = 6
        MacPrefix      = '00:50:56:3B'       # diferente do 5.2 (3A) para não confundir ARP/DHCP antigos
        HttpPortBase   = 8080                # site 'vcf911-ks' no nginx da svc01 serve os kickstarts nesta porta
        # Minutos até o vSAN reconstruir uma cópia ausente (padrão 60). Só para lab (no Workstation, uma cópia
        # perdida num vMotion reprovou a checagem de conformidade do deploy antes dos 60 min).
        VsanRepairDelayMin = 5
        # Linha de boot (o mesmo truque do Packer, agora pela API do ESXi): Shift+O uma vez por segundo
        # durante ShiftOWindowSec (pega a contagem 'Automatic boot in 5 seconds' onde ela cair), apaga a
        # linha e digita BootKernelOpt (a 'kernelopt=' do BOOT.CFG do ISO) + as opções de kickstart.
        ShiftOWindowSec = 45
        BootKernelOpt   = 'runweasel cdromBoot'

        # E5-2680 v4 (Broadwell-EP) é "Discontinued" no ESX 9.x (KB 318697). No 9.1.1 o aviso
        # CPU_SUPPORT_OVERRIDEWARNING ABORTA o kickstart ("The system was not installed correctly")
        # e o instalador cai no modo manual (EULA). Enter não resolve.
        # Solução (testada no Workstation deste host, no 9.0 e no 9.1.1): mascarar o CPUID como Cascade Lake
        # (família 6, modelo 0x55, stepping 7). Só muda o modelo reportado; as features reais
        # (VT-x/EPT etc.) continuam as do Broadwell. Instala sem nenhum Enter.
        CpuidMask      = '0000:0000:0000:0101:0000:0110:0101:0111'
        LegacyCpu      = $true               # allowLegacyCPU=true no boot e --ignoreprereq* no kickstart (inofensivo com a máscara)

        # Com HostCount = 3 usa os 3 primeiros desta lista.
        Hosts = @(
            @{ Name = 'esx01'; Ip = '10.52.10.11'; Datastore = 'ds-nvme1' }
            @{ Name = 'esx02'; Ip = '10.52.10.12'; Datastore = 'ds-nvme2' }
            @{ Name = 'esx03'; Ip = '10.52.10.13'; Datastore = 'ds-nvme3' }
            @{ Name = 'esx04'; Ip = '10.52.10.14'; Datastore = 'ds-nvme1' }   # troque para o NVMe com mais espaço livre
        )
    }

    # ------------------------------------------------------------------ VCF Installer (substitui o Cloud Builder)
    Installer = @{
        VmName        = 'vcf911-inst01'
        Datastore     = 'ds-nvme3'              # longe do /srv/dados (ds-ssd): download e validação dos bundles bem mais rápidos (15/11: ~1 h com os dois no ds-ssd)
        Mac           = '00:50:56:3B:03:00'
        Hostname      = 'inst01'
        Ip            = '10.52.10.4'          # o mesmo IP do cb01 do 5.2
        AdminUser     = 'admin@local'         # não mude
        AdminPassword = '<SENHA_DO_LAB>'
        RootPassword  = '<SENHA_DO_LAB>'
        MemoryGB      = 16

        # Ajustes de lab gravados em /etc/vmware/vcf/domainmanager/application.properties
        # (lista do William Lam para 9.1). Os timeouts maiores evitam falha por lentidão do nested.
        DomainManagerProperties = @{
            'nsxt.manager.wait.minutes'                 = '180'
            'edge.node.vm.creation.max.wait.minutes'    = '90'
            'vsp.bootstrap.task.timeout.minutes'        = '240'
            'vsp.bootstrap.command.timeout.minutes'     = '200'
            'orchestrator.task.retry.max'               = '5'
            # Descomente se a validação reclamar e o 08-Test-LabReadiness estiver todo verde:
            # 'validation.disable.network.connectivity.check' = 'true'
            # 'nsxt.mtu.validation.skip'                       = 'true'
            # 'validation.disable.vmotion.connectivity.check'  = 'true'
            # 'validation.disable.vsan.connectivity.check'     = 'true'
        }
    }

    # ------------------------------------------------------------------ VCF 9.1.1
    Vcf = @{
        Version         = '9.1.1.0'
        Sku             = 'VCF'
        InstanceName    = 'VCF911-Lab'
        SddcId          = 'vcf911-m01'
        Datacenter      = 'vcf911-m01-dc01'
        Cluster         = 'vcf911-m01-cl01'
        Vds             = 'vcf911-m01-cl01-vds01'
        VsanVds         = 'vcf911-m01-cl01-vds02-vsan'
        NsxVds          = 'vcf911-m01-cl01-vds03-nsx'
        VsanDatastore   = 'vcf911-m01-cl01-ds-vsan01'
        # 0 = sem redundância (objeto num host só): escritas locais, bem mais rápido no nested e metade do
        # espaço. Custo: um ESX nested parado deixa as VMs dele inacessíveis até voltar. Campo oficial do
        # JSON do Installer 9.x (failuresToTolerate, 0 a 3). Se a validação recusar, volte para 1.
        VsanFtt         = 0
        # DRS durante o deploy: PartiallyAutomated (colocação automática, sem vMotion automático); no fim
        # volta para FinalDrsLevel. A etapa 9 aplica a cada 2 min por PowerCLI. '' desliga o controle.
        DeployDrsLevel  = 'PartiallyAutomated'
        FinalDrsLevel   = 'FullyAutomated'
        # Traffic shaping nas port groups dos VDS: o deploy desliga a cada 2 min (junto do controle de DRS) e
        # loga cada política desligada. Shaping com os valores sugeridos pelo vSphere (100.000 Kbit/s) segura
        # vSAN e vMotion em ~12 MB/s. $false = não mexe.
        DisableTrafficShaping = $true
        # Checksum do vSAN desligado na política padrão, no fim do deploy (lab: menos CPU por I/O dentro dos ESX
        # nested). Vale para o que for criado depois; as VMs do deploy mudam com REAPPLY no vCenter. $false = não mexe.
        VsanChecksumDisabled = $true
        # 'OSA' (padrão, o que funcionou no 5.2: discos PVSCSI marcados como SSD, cache + capacidade)
        # 'ESA' (discos em controladora NVMe, sem cache). No 9.0 deste host o NVMe virtual do
        #       Workstation deu timeout/reset; no ESXi físico o NVMe virtual é bem mais estável.
        # Trocar depois de criados os ESX exige recriar: .\Deploy-Lab.ps1 -From 5 -To 5 -Force
        VsanMode        = 'OSA'
        CeipEnabled     = $false
        FipsEnabled     = $true              # padrão do 9.1

        Vcenter = @{
            Hostname     = 'vc01'
            Ip           = '10.52.10.20'
            Size         = 'tiny'
            StorageSize  = 'lstorage'
            RootPassword = '<SENHA_DO_LAB>'
            SsoPassword  = '<SENHA_DO_LAB>'
        }
        Nsx = @{
            Size          = 'medium'
            VipHostname   = 'nsx01'
            VipIp         = '10.52.10.21'
            Nodes         = @( @{ Hostname = 'nsx01a'; Ip = '10.52.10.22' } )
            RootPassword  = '<SENHA_DO_LAB>'
            AdminPassword = '<SENHA_DO_LAB>'
            AuditPassword = '<SENHA_DO_LAB>'
        }
        SddcManager = @{
            Hostname      = 'sddcm01'
            Ip            = '10.52.10.25'
            RootPassword  = '<SENHA_DO_LAB>'
            VcfPassword   = '<SENHA_DO_LAB>'
            SshPassword   = '<SENHA_DO_LAB>'
            LocalPassword = '<SENHA_DO_LAB>'
        }
        Operations = @{
            Hostname          = 'vcf01'
            Ip                = '10.52.10.26'
            Size              = 'small'
            RootPassword      = '<SENHA_DO_LAB>'
            AdminPassword     = '<SENHA_DO_LAB>'
            CollectorHostname = 'vcf-proxy01'
            CollectorIp       = '10.52.10.27'
            CollectorSize     = 'small'
        }
        # VCF Management Services: os nomes precisam de IP próprio FORA do pool, dentro da gerência
        # (KB 440223), registros DNS em minúsculas (KB 445179) e o pool inteiro livre/sem ping (KB 443604).
        ManagementServices = @{
            Size               = 'small'      # 'small_ha' existe a partir do 9.1.1 (mais RAM)
            SystemPassword     = '<SENHA_DO_LAB>'
            RuntimeHostname    = 'vcf-msr01'; RuntimeIp  = '10.52.10.40'
            FleetHostname      = 'vcf-flt01'; FleetIp    = '10.52.10.41'
            InstanceHostname   = 'vcf-int01'; InstanceIp = '10.52.10.42'
            IdentityHostname   = 'vcf-idb01'; IdentityIp = '10.52.10.43'
            LicenseHostname    = 'vcf-lic01'; LicenseIp  = '10.52.10.44'
            PoolStart          = '10.52.10.64'
            PoolEnd            = '10.52.10.95'
            InternalClusterCidr = '198.18.0.0/15'
        }
        # VCF Automation: Day-N (Fleet LCM no VCF Operations). Reservado aqui para não reaproveitar os IPs.
        Automation = @{
            Deploy           = $false
            Hostname         = 'auto01';    Ip        = '10.52.10.45'
            RuntimeHostname  = 'vcf-asr01'; RuntimeIp = '10.52.10.46'
            IpPool           = @('10.52.10.96', '10.52.10.97', '10.52.10.98', '10.52.10.99', '10.52.10.100')
            NodePrefix       = 'vcf911-auto'
            Size             = 'small'
            AdminPassword    = '<SENHA_DO_LAB>'
        }
        # Edges (Day-N): IPs reservados como no 5.2; o VyOS já sobe com o BGP pronto para eles.
        Edge = @{
            Asn           = 65004
            TorAsn        = 65001
            BgpPassword   = '<SENHA_BGP>'
            Nodes = @(
                @{ Name = 'en01'; MgmtIp = '10.52.10.31'; Uplink1 = '10.52.15.2'; Uplink2 = '10.52.16.2' }
                @{ Name = 'en02'; MgmtIp = '10.52.10.32'; Uplink1 = '10.52.15.3'; Uplink2 = '10.52.16.3' }
            )
        }
    }
}
