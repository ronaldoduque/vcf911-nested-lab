# SRV-LAB com ESXi 8 físico, svc01 Ubuntu e VCF 9.1.1 nested

Este pacote troca o Windows Server 2025 + VMware Workstation do SRV-LAB por um **ESXi 8.0 U3 instalado direto na
máquina**, com **Memory Tiering** no NVMe de 500 GB (tier de 25%: folga, sem contratar memória acima da RAM), uma VM **svc01 Ubuntu 24.04**
no lugar do Windows (DNS, NTP, depot, kickstart e de onde a automação roda) e o lab VCF 9.1.1 com **4 ESX nested
e vSAN FTT=0**. Os IPs do lab (10.52.x) e o depot são os mesmos do Workstation.

**Pré-requisitos:** backup do Windows com **PRONTO-PARA-MIGRAR** e a cópia em `E:\_migracao` conferida.

## Por onde começar

1. `PLANO-MIGRACAO.md`: o passo a passo completo, em 8 fases, do pendrive ao deploy
2. `ARQUITETURA.md`: rede, discos, memória, CPU, VMs e licença
3. `svc01-ubuntu.md`: criar, instalar e preparar a svc01; acesso do notebook ao lab
4. `DESEMPENHO.md`: tudo o que acelera o vSAN nested (automático, à mão, BIOS e hardware)
5. `HISTORICO.md`: o que deu errado na instalação real e como foi corrigido

## O que tem aqui

```
host/esxi-host-setup.sh      no ESXi por SSH: listar, basico, rede, datastores, tiering, svc01, status
host/hdd-nbd.py              no ESXi: entrega um HD local só leitura à svc01 pela rede (o RDM não funciona no ESXi 8)
svc01/setup-svc01.sh         na svc01 Ubuntu: BIND9, chrony, nginx, NAT, HD de dados, PowerShell 7, PowerCLI, ovftool
automation/                  a automação do lab (etapas 0-9 e 99), rodando na svc01 com pwsh
  Deploy-Lab.ps1             orquestra as etapas
  config/lab-config.psd1     ÚNICO arquivo para editar (IP do ESXi físico, domínio, caminhos, tamanhos)
  scripts/                   00-09, 99; LabCommon (Linux: BIND, nginx, NTP, DRS), EsxiPlatform (VMs pela API)
docs/                        plano, arquitetura, svc01, acesso remoto
```

## Onde roda cada coisa

| Onde | O que | Como você chega |
|---|---|---|
| Console do servidor (monitor/teclado) | instalação do ESXi e IP inicial (DCUI) | só nas Fases 1 e 2 |
| ESXi físico | `host/esxi-host-setup.sh` | `ssh root@<ip-do-esxi>` do notebook |
| Host Client | console das VMs, upload de ISO | `https://<ip-do-esxi>/ui` |
| svc01 (Ubuntu) | `setup-svc01.sh` e toda a automação | `ssh lab@<ip-da-svc01>`, depois `sudo -i` e `tmux` |
| Notebook | navegador e terminal | rota 10.52.0.0/16 via svc01 (ou Tailscale) |

## O que mudou em relação ao lab Workstation

| Antes (Workstation) | Agora (ESXi físico) |
|---|---|
| Windows físico com AD/DNS, IIS, W32Time | VM **svc01 Ubuntu**: BIND9, nginx, chrony |
| VMnet10 / VMnet12 / LAN Segment | port groups **VCF911-MGMT / VCF911-VSAN / VCF911-NSX-TRUNK** em vSwitches internos |
| NAT do Workstation (vmnet8) | rede de casa (VyOS eth0 por DHCP) |
| Packer + vmrun | **PowerCLI**: VMs por ConfigSpec, teclado pela API, Invoke-VMScript |
| `.vmem` em disco, vSAN FTT=1, DRS automático | sem Workstation; **FTT=0**; DRS segurado durante o deploy; `ClomRepairDelay = 5` |
| 4 hosts × 54 GB | **4 hosts × 14 vCPU × 58 GB** (3 × 76 GB opcional) |
| 256 GB de RAM | 256 GB + **Memory Tiering a 25%** (~320 GB), tudo o que está ligado cabe na RAM |
| máscara de CPU Cascade Lake | a mesma (os ESX 9.1.1 nested continuam precisando) |

## Avisos honestos

- Executado no SRV-LAB real em 15/11/2026: Fases 0 a 5 e as etapas 0 a 6 da automação (correções no
  `HISTORICO.md`). Etapas 7 a 9 (JSON, teste e deploy) ainda não tinham rodado nesta versão.
- **FTT=0** no JSON do Installer é campo oficial da API 9.x, mas não foi testado neste lab.
- Memory Tiering no ESXi 8.0 U3 é **tech preview** (suportado só a partir do 9.0).
- A ISO **Free Hypervisor** do ESXi não serve: API só leitura e máximo de 8 vCPU por VM. Use a ISO normal.
- Placa de rede sem driver no ESXi 8 impede tudo. Por isso o teste de boot da Fase 0.
