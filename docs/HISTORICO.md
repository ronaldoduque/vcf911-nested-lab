# Histórico da instalação real (SRV-LAB, 15/11/2026)

Dell Precision Tower 7810, 2× Xeon E5-2680 v4, 256 GB RAM, ESXi 8.0 U3j (build 25429389), svc01 em Ubuntu
Server 26.04.1, VCF 9.1.1. Tudo abaixo já está corrigido neste pacote; fica registrado para o próximo lab.

## Estado do host

| Item | Valor |
|---|---|
| ESXi físico | `192.168.0.100`, root / `<senha>`, licença Evaluation (até 14/01/2027) |
| svc01 | `192.168.0.101` (casa), `10.52.10.2` (lab-mgmt), `10.52.12.1` (lab-vsan); usuário `lab` / `<senha>` |
| VyOS gw01 | eth0 por DHCP (`192.168.0.102` em 15/11), `10.52.10.1` no lab |
| Placa física | Intel I210-T1 = `vmnic1` (driver `igbn`). A I217-LM da placa-mãe é `vmnic0`, sem cabo |
| Memória | 604 GB (256 GB RAM + tiering de 120% no NVMe de 500 GB) |
| Datastores | `ds-ssd` (SSD SATA 512 GB), `ds-nvme1..3` (Kingston NV3 1 TB) |
| HDs | WD10EZEX (o antigo E: "HDD-BKP", com o `_migracao`) e WD10SPZX, preservados, fora do ESXi |
| Dados do lab | disco de 300 GB thin no `ds-ssd`, ext4 em `/srv/dados` (depot 9.1.1 + ISO do VyOS) |

## Problemas e correções

| Onde | Problema | Correção |
|---|---|---|
| svc01 (`esxi-host-setup.sh svc01`) | "No PCIe slot available for Ethernet0": o `.vmx` não declarava as portas PCIe | `pciBridge0` e `pciBridge4..7` (pcieRootPort) no `.vmx` |
| HD de dados (RDM) | ESXi 8 marca HD SATA local como `Is RDM Capable: false`; a VM fica inválida e o Host Client recusa (*Incompatible device backing*). O controlador SATA não vai em passthrough porque o SSD do ESXi está nele | `svc01rdm` desativado. Disco de dados no `ds-ssd` + cópia pela rede com `host/hdd-nbd.py` (NBD só leitura no ESXi) e `ntfs-3g` |
| Montar o NTFS | o `ntfs3` do kernel falhou no `$BadClus` do HD | `ntfs-3g -o ro` |
| svc01 (instalador Ubuntu) | a placa da casa ficou em DHCP | netplan `90-casa-fixo.yaml` (docs/svc01-ubuntu.md, passo 3) |
| svc01 (LVM) | o instalador criou o LV com metade do disco | `lvextend -r -l +100%FREE` |
| `setup-svc01.sh ntp` | comentário na mesma linha do `local stratum 10` derruba o chrony | comentário em linha própria |
| `setup-svc01.sh pwsh` | Ubuntu 26.04 | repositório da Microsoft (já tem pacote) com fallback para o snap |
| `setup-svc01.sh nat` | nftables carregado mas `inactive` | `enable --now` |
| Etapa 0 | `$global:DefaultVIServer` lido antes de existir (StrictMode) | `Get-Variable ... -ErrorAction SilentlyContinue` |
| Etapa 4 (VyOS 2026.03) | a instalação digitada às cegas saiu fora de ordem (senha não gravada); a pergunta da trava do CD travou o "Reconfigure"; o VyOS (live e instalado) não tem VMware Tools | console só para login + DHCP/SSH; `install image` por SSH respondendo cada pergunta pelo texto; ISO tirada com a VM desligada; IP achado pelo MAC (ping + ARP da svc01) |
| Etapa 5 (ESX 9.1.1) | "CPU_SUPPORT OVERRIDEWARNING" (Broadwell) parava o kickstart mesmo com a máscara de CPU | `--forceunsupportedinstall` na linha `install` |
| Etapa 6 | `Import-VApp` no Linux contra ESXi direto: "Invalid URI" | OVF Tool para Linux instalado (`setup-svc01.sh ovftool`); fallback com govc |
| Etapa 6 (lentidão) | download e validação dos bundles levaram ~1 h: o depot (`/srv/dados`) e o Installer estavam ambos no ds-ssd (SSD SATA lendo, gravando e validando ao mesmo tempo) | `Installer.Datastore = 'ds-nvme3'` no config (o NVMe do esx03, quase vazio) |
| Acesso pelo navegador | sem acesso ao roteador da operadora; o Edge do notebook da empresa ignora proxy (política do domínio) | `setup-svc01.sh proxy` (tinyproxy + PAC); no notebook da empresa, túnel `ssh -L` ou outro navegador |

## Respostas do instalador do VyOS 2026.03 (para referência)

```
Would you like to continue? [y/N]                                   y
What would you like to name this image? (Default: 2026.03)          <Enter>
Please enter a password for the "vyos" user:                        (senha do config)
Please confirm password for the "vyos" user:                        (senha do config)
What console should be used by default? (K: KVM, S: Serial)?        K
Which one should be used for installation? (Default: /dev/sda)      <Enter>
Installation will delete all data on the drive. Continue? [y/N]     y
Would you like to use all the free space on the drive? [Y/n]        y
Which file would you like as boot config? (Default: 1)              1
```
