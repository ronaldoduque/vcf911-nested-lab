# VCF 9.1.1 Nested Lab: deploy automatizado em um único servidor

Automação em PowerShell/PowerCLI e shell para implantar um **VMware Cloud Foundation 9.1.1** completo, 100% aninhado, em um único servidor físico com ESXi 8.0 U3. Do ESXi físico aos 4 hosts ESX 9.1.1 com vSAN, NSX, VCF Operations e VCF Management Services.

> Projeto de homelab, para estudo. Vários ajustes aqui (CPU fora de suporte, Memory Tiering em tech preview, vSAN FTT=0, appliances com menos memória) **não são suportados** em produção.

## Resultado

| | |
|---|---|
| Deploy no VCF Installer | **8h21min** registradas (~6h33 sem o incidente descrito abaixo) |
| Componentes | vCenter, NSX, SDDC Manager, VCF Operations, Cloud Proxy, VCF Management Services |
| Cluster | 4 hosts ESX 9.1.1 aninhados, vSAN OSA |

## Hardware

| Item | Especificação |
|---|---|
| Servidor | Dell Precision Tower 7810 |
| CPU | 2× Intel Xeon E5-2680 v4 (Broadwell, 28 núcleos / 56 threads) |
| RAM | 256 GB DDR4 |
| Boot e VMs de apoio | SSD SATA 512 GB |
| Hosts aninhados | 3× NVMe Kingston NV3 1 TB |
| Memory Tiering | NVMe Kingston 500 GB |
| Hipervisor | ESXi 8.0 U3 |

## Arquitetura

```
Servidor físico · ESXi 8.0 U3
├── svc01 (Ubuntu) .. DNS (BIND9), NTP (chrony), depot e kickstart (nginx), NAT; roda a automação
├── VyOS ............ gateway, VLANs, NAT, BGP pronto para os NSX Edges
├── VCF Installer ... usado só durante o deploy
└── Cluster VCF 9.1.1 (4× ESX aninhados, vSAN OSA)
    ├── vCenter
    ├── NSX
    ├── SDDC Manager
    ├── VCF Operations + Cloud Proxy
    └── VCF Management Services (Kubernetes)

Redes: vSwitches internos com MTU 9000 (gerência, vSAN e trunk NSX com VLANs 13 a 16)
```

Detalhes de rede, discos, memória e CPU em [docs/ARQUITETURA.md](docs/ARQUITETURA.md).

## Estrutura do repositório

```
host/esxi-host-setup.sh      no ESXi físico, por SSH: rede, datastores, Memory Tiering, VM svc01, status
host/hdd-nbd.py              no ESXi: entrega um HD local só leitura à svc01 pela rede
svc01/setup-svc01.sh         na svc01 Ubuntu: BIND9, chrony, nginx, NAT, PowerShell 7, PowerCLI, ovftool
automation/
  Deploy-Lab.ps1             orquestra as etapas 0 a 9
  config/                    lab-config.example.psd1 (copie para lab-config.psd1 e defina as senhas)
  scripts/                   etapas 00 a 09 e 99, e os módulos LabCommon, EsxiPlatform e VcfInstaller
docs/                        plano de migração, arquitetura, svc01, desempenho e histórico de problemas
```

## Etapas da automação

| Etapa | Script | O que faz |
|---|---|---|
| 0 | `00-Preflight.ps1` | módulos, serviços da svc01, mídias, depot, senhas; no ESXi: licença, tiering, port groups, datastores |
| 1 | `01-New-LabNetwork.ps1` | port groups e autostart no ESXi; confere a rede e os serviços da svc01 |
| 2 | `02-New-LabDns.ps1` | zonas do BIND9 (A + PTR) e conferência com `dig` |
| 3 | `03-New-OfflineDepot.ps1` | confere o depot offline contra a release e publica no nginx |
| 4 | `04-New-VyOS.ps1` | VM do VyOS, instalação pelo teclado da API e configuração por SSH |
| 5 | `05-New-NestedEsxi.ps1` | VMs dos ESX, kickstart, máscara de CPUID |
| 6 | `06-New-VcfInstaller.ps1` | VCF Installer por ovftool, depot, download e validação dos bundles |
| 7 | `07-New-DeploySpec.ps1` | JSON do deploy |
| 8 | `08-Test-LabReadiness.ps1` | DNS, NTP, pool do VCFMS, depot, VLANs e MTU ponta a ponta |
| 9 | `09-Invoke-VcfDeploy.ps1` | validação e deploy, com DRS segurado durante o processo; `-Retry` retoma após falha |
| – | `99-Remove-Lab.ps1` | remove as VMs do lab (nunca o depot) |

## Como usar

1. Siga o [plano de migração](docs/PLANO-MIGRACAO.md): ESXi físico, `host/esxi-host-setup.sh` e a [svc01](docs/svc01-ubuntu.md).
2. Na svc01, clone o repositório e crie a configuração:
   ```sh
   cd /opt/vcf911/vcf911-nested-lab/automation
   cp config/lab-config.example.psd1 config/lab-config.psd1   # defina IPs, caminhos e senhas
   ```
3. Rode a automação (como root, num `tmux`):
   ```sh
   pwsh ./Deploy-Lab.ps1 -To 8                    # tudo até o teste de prontidão
   pwsh ./Deploy-Lab.ps1 -From 9 -StartDeploy     # valida e dispara o deploy
   pwsh ./scripts/09-Invoke-VcfDeploy.ps1 -Retry  # retoma depois de corrigir uma falha
   ```

**Requisitos:** ESXi 8.0 U3, VCF 9.1.1 baixado com a sua conta Broadcom (depot offline, ISO do ESX e OVA do Installer), ISO do VyOS e ISO do Ubuntu Server. Nenhum binário faz parte deste repositório.

## Problemas resolvidos no caminho

| Problema | Solução |
|---|---|
| Broadwell não é suportada no ESX 9.x | máscara de CPUID apresentando a CPU como Cascade Lake nos hosts aninhados |
| Depot offline incompleto | cada componente do VCF Management Services exige binário, schema, manifesto e plugin; a etapa 3 confere tudo contra a release |
| Propriedades OVF do Installer não aplicadas | `ovftool --X:injectOvfEnv`, com as chaves completas lidas do `.ovf` |
| vMotion durante o deploy degradou o vSAN | DRS segurado e `ClomRepairDelay` reduzido durante o deploy |
| RDM de HD SATA local recusado no ESXi 8 | cópia pela rede com `host/hdd-nbd.py` (NBD só leitura) |
| Host aninhado congelou no meio do deploy | ver abaixo |

Lista completa em [docs/HISTORICO.md](docs/HISTORICO.md).

### O incidente

Com ~470 GB de RAM provisionada sobre 256 GB físicos (`TierNvmePct = 120`), ~220 GB de memória ativa foram para o NVMe do Memory Tiering e um host aninhado congelou. O I/O do vSAN travou, um nó Kubernetes do VCF Management Services perdeu os volumes e os bancos do LCM caíram.

**Recuperação:** o Cluster API substituiu o nó, os VolumeAttachments órfãos foram removidos e os bancos recriados via kubectl. O Installer retomou a tarefa sozinho, sem refazer o deploy.

**Prevenção, já aplicada neste repositório:** hosts com 58 GB em vez de 110 GB e `TierNvmePct = 25` em vez de 120. A RAM contratada pelas VMs cabe na DRAM, e o tiering fica só como folga.

## Próximos passos

- NSX Edges com BGP no VyOS
- vSAN ESA
- VCF Automation (exige mais RAM)

## Autor

Ronaldo Duque · https://www.linkedin.com/in/ronaldo-duque-64135a17/

Desenvolvido com apoio de IA como copiloto para a automação, a análise de logs e o troubleshooting. Arquitetura, decisões e validação são minhas.

## Licença

[MIT](LICENSE)
