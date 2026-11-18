# Arquitetura: SRV-LAB com ESXi 8 físico, svc01 Ubuntu e o lab VCF 9.1.1 nested

## Visão geral

```
                         Rede de casa (roteador, internet)  ex.: 192.168.0.0/24
        notebook ──────────────┬──────────────────────────────┬───────────────────────
                               │                              │
                       [placa física] vmnic0                  │
                               │                              │
 SRV-LAB  ESXi 8.0 U3 ── vSwitch0 ── "Management Network" vmk0 = 192.168.0.100 (Host Client, SSH)
 (físico)                       └── "VM Network" ─────┬───────────────┬──────────────
                                                      │               │
                                         svc01 placa "casa"     VyOS eth0 (DHCP)
                                         192.168.0.101           WAN + NAT do lab para a internet
                                         SSH, NAT notebook→lab        │
                                                      │               │
   vSwitch-VCF-MGMT (interno, MTU 9000)  "VCF911-MGMT"  VLAN 0        │
        svc01 lab-mgmt 10.52.10.2 ── VyOS eth1 10.52.10.1 (+10.52.11.1 vMotion)
        esx01..04 vmnic0/1 10.52.10.11-14 ── Installer 10.52.10.4 ── vc01, nsx01, sddcm01, vcf01...
   vSwitch-VCF-VSAN (interno, MTU 9000)  "VCF911-VSAN"  VLAN 0
        svc01 lab-vsan 10.52.12.1 (gateway "de mentira") ── esx01..04 vmnic2/3
   vSwitch-VCF-NSX  (interno, MTU 9000)  "VCF911-NSX-TRUNK"  VLAN 4095
        VyOS eth2 (VIFs 13 TEP host, 14 TEP edge, 15/16 uplinks BGP) ── esx01..04 vmnic4/5
```

Os IPs 192.168.0.x são exemplos: use os da sua rede. Os switches internos não têm placa física, então o
tráfego do lab nunca sai da máquina. Promíscuo, forged transmits e MAC changes são obrigatórios para ESX nested.

## Quem faz o quê

| Papel | Antes (Windows + Workstation) | Agora |
|---|---|---|
| Hypervisor | VMware Workstation | **ESXi 8.0 U3** no SSD |
| DNS do lab (A + PTR) | AD DNS | **BIND9** na svc01 (zonas geradas pela etapa 2) |
| NTP do lab | W32Time do DC | **chrony** na svc01 (`local stratum 10`: funciona sem internet) |
| Depot offline | IIS | **nginx** na svc01, lendo o depot oficial no HD de dados |
| Kickstart dos ESX | Packer (HTTP interno) | **nginx** na svc01, porta 8080 |
| Onde a automação roda | PowerShell no Windows | **PowerShell 7 na svc01** (via SSH, dentro de um `tmux`) |
| Criação das VMs | Packer + vmrun | **PowerCLI** (ConfigSpec, teclado pela API) |
| Acesso do notebook ao lab | era o próprio servidor | rota `10.52.0.0/16` e `10.60.0.0/16` **via svc01**, que faz NAT para o lab |
| Acesso de fora de casa | – | Tailscale na svc01 (opcional) |

## Discos

| Disco | Hoje (Windows) | Depois | Dados |
|---|---|---|---|
| SSD SATA 476 GB (D:) | ISOs, depot, scripts | **boot do ESXi** (`systemMediaSize=min`, ~32 GB) + **ds-ssd** (~440 GB): svc01, VyOS, Installer, ISOs, core dump | apagado |
| NVMe 500 GB (C:) | Windows Server | **Memory Tiering** (`TierNvmePct = 25`) | apagado |
| NVMe 1 TB (F:) | lab | **ds-nvme1**: esx01 + esx04 | só lab |
| NVMe 1 TB (G:) | lab | **ds-nvme2**: esx02 | só lab |
| NVMe 1 TB (H:) | lab | **ds-nvme3**: esx03 | só lab |
| HD 1 TB (E: "HDD-BKP") | backup | fica só como backup (intacto). O `_migracao` foi copiado para o disco de dados da svc01; leitura quando precisar via `host/hdd-nbd.py` | intacto |
| HD 1 TB (I: "HDD") | dados | desconectado durante a instalação; depois pode virar um 2º RDM | intacto |

O esx04 divide o ds-nvme1 com o esx01. No ESXi físico isso não pesa no desempenho (no Workstation o gargalo era
a latência da cadeia nested, não o NVMe). Com vSAN FTT=0 cada ESX ocupa ~350 GB (boot 40 + cache 40 + vSAN ~175
+ `.vswp` 110), então o ds-nvme1 fica em ~700 de 931 GB. Se um dia voltar para FTT=1, mova o `.vswp` dos dois
ESX desse disco para o ds-ssd.

## Memória

256 GB de RAM + Memory Tiering no NVMe de 500 GB. O `TierNvmePct` é uma porcentagem da RAM:

| TierNvmePct | Camada no NVMe | Total visto pelo ESXi | Folga no NVMe |
|---|---|---|---|
| **25 (este pacote)** | **~64 GB** | **~320 GB** | **~430 GB** |
| 100 | 256 GB | 512 GB | ~210 GB |
| 120 (usado no primeiro deploy) | ~307 GB | ~563 GB | ~160 GB |

| VM | RAM |
|---|---|
| esx01..04 | 4 × 58 GB = 232 GB |
| VCF Installer | 16 GB (desligue depois do deploy) |
| svc01 | 8 GB |
| VyOS | 2 GB |
| **Total** | **242 GB** na operação (258 GB durante o deploy) |

> **Lição do deploy real (17/11/2026):** com 4 × 110 GB e `TierNvmePct = 120`, ~220 GB de memória **ativa** foram
> para o NVMe e um ESX nested congelou no meio do deploy. A regra deste pacote: a RAM contratada pelas VMs não passa
> da DRAM. O tiering fica só como folga. Pelo plano de memória fechado depois do deploy, os appliances nos tamanhos padrão (~145 GB, sem Edges) cabem em 4 × 58 GB; depois do deploy, o
> vCenter e o SDDC Manager aceitam 12 GB e o NSX 20 GB (não suportado, só para lab).

O ESXi mantém as páginas ativas na RAM e manda as frias para o NVMe. Memory Tiering no 8.0 U3 é *tech preview*:
bom para lab, sem suporte. O NV3 é um NVMe de consumo; acompanhe o desgaste (SMART *Percentage Used*). Para mais
memória depois (ex.: VCF Automation): `esxcli system settings advanced set -o /Mem/TierNvmePct -i 150` e reboot.

## CPU

2 × E5-2680 v4 = 28 núcleos / 56 threads.

| VM | vCPU |
|---|---|
| esx01..04 | 14 cada (2 sockets × 7) = 56 |
| svc01 | 4 |
| VyOS | 2 |
| VCF Installer | 4 (desligado depois do deploy) |

O ESXi 8 físico instala no Broadwell só com aviso. Os ESX **9.1.1 nested** continuam com a máscara de CPUID
Cascade Lake (`cpuid.1.eax`), a mesma do lab Workstation.

## VMs no ESXi físico

| VM | Datastore | vCPU | RAM | Disco (thin) | Autostart |
|---|---|---|---|---|---|
| svc01 (Ubuntu 24.04) | ds-ssd | 4 | 8 GB | 60 GB + 300 GB de dados (thin) | 1º |
| vcf911-gw01 (VyOS) | ds-ssd | 2 | 2 GB | 10 GB | 2º |
| vcf911-esx01..04 (ESX 9.1.1) | ds-nvme1..3 | 14 | 58 GB | 40 + 40 + 600 GB | 3º-6º |
| vcf911-inst01 (VCF Installer) | ds-ssd | 4 | 16 GB | ~150 GB usados | não |

## vSAN dentro dos ESX nested

- **FTT=0** (`Vcf.VsanFtt = 0`): cada objeto num host só. Escritas locais, metade do espaço, bem mais rápido no
  nested. Custo: um ESX nested parado deixa as VMs dele inacessíveis até voltar. É campo oficial do JSON do
  Installer 9.x (`failuresToTolerate`, 0 a 3); se a validação recusar, volte para 1.
- **OSA** (cache + capacidade, PVSCSI marcado como SSD), como no lab que funcionou.
- `/VSAN/ClomRepairDelay = 5` no kickstart: uma cópia ausente é refeita em 5 min, não em 60.
- DRS em *PartiallyAutomated* durante o deploy (a etapa 9 aplica por PowerCLI e volta para *FullyAutomated* no fim).

## Licença do ESXi físico

- ISO **normal** do ESXi 8.0 U3: começa com **60 dias de avaliação**, todos os recursos e API de escrita.
- A licença gratuita (*Free Hypervisor*) não serve: API só leitura (o PowerCLI não cria VMs) e máximo de 8 vCPU por VM.
- Depois de 60 dias sem licença, as VMs ligadas continuam ligadas, mas nenhuma VM nova liga. Caminhos: VMUG
  Advantage, ou reinstalar o ESXi e recriar o lab (os scripts fazem isso em poucas horas).
- Os ESX nested e o fleet usam a avaliação do próprio VCF, independente do host físico.
