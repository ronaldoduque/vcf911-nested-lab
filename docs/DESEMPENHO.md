# Desempenho do vSAN nested: o que o pacote faz e o que é com você

No lab do Workstation (14-15/11/2026), o clone de template no vSAN andava a ~10-12 MB/s com os NVMe a 0,2 ms e
1% de uso: o freio estava nas camadas virtuais, não no disco. Abaixo, cada alavanca por camada, do vSAN até o
hardware, e quem cuida dela.

## 1. Dentro do vSAN nested (os três pacotes, automático)

| Ajuste | Efeito | Onde |
|---|---|---|
| **FTT=0** (9.1.1 no JSON; 5.2 na política, depois do bring-up) | escrita local, sem esperar a cópia em outro ESX pela rede virtual: o maior ganho | `Vcf.VsanFtt` |
| **Checksum do vSAN desligado** na política padrão, no fim do deploy | menos CPU por I/O dentro dos ESX nested | `Vcf.VsanChecksumDisabled` |
| Dedup e compressão desligados (OSA) | sem custo de CPU e de metadado | JSON do deploy |
| **Traffic shaping desligado** nas port groups dos VDS, a cada 2 min durante o deploy | shaping com os valores sugeridos (100.000 Kbit/s) segura vSAN/vMotion em ~12 MB/s | `Vcf.DisableTrafficShaping` |
| **DRS em PartiallyAutomated** durante o deploy | sem vMotion automático disputando disco e rede (e sem o vMotion falho que degradou o vSAN) | `Vcf.DeployDrsLevel` |
| `ClomRepairDelay = 5` | cópia ausente refeita em 5 min, não 60 | kickstart |
| **Anéis da vmxnet3 em 4096** (a cada boot, pelo `local.sh`) | menos pacotes descartados ("High pNic error rate") | kickstart |
| **CPU policy High Performance** nos ESX nested | sem estados de economia atrasando o agendamento | kickstart |
| MTU 9000 em vSAN, vMotion e TEP | menos pacotes por I/O | rede + JSON |

As VMs criadas pelo próprio deploy ficam com a política antiga (FTT, checksum) até o **REAPPLY**: vCenter >
Policies and Profiles > VM Storage Policies > a política > VM Compliance > REAPPLY. Faça com o lab ocioso:
pode gerar resync.

## 2. A VM de cada ESX nested

| Ajuste | Workstation | ESXi físico |
|---|---|---|
| Memória sem arquivo `.vmem` (`mainMem.useNamedFile = FALSE`) | ✅ automático | não se aplica |
| `MemTrimRate = 0`, sem page sharing | ✅ automático | não se aplica |
| vmxnet3, discos PVSCSI marcados como SSD (OSA) | ✅ | ✅ |
| **Disco de cache eager-zeroed** (sem custo de alocar/zerar na 1a escrita; 40 GB por host) | – (Packer cria todos iguais) | ✅ `Esxi.CacheEagerZero` |
| **Vários threads de transmissão por vNIC** (`ethernetN.ctxPerDev = 3`) | – (não existe no Workstation) | ✅ `Esxi.NicTxThreads` |
| VCF Installer longe do depot (`Installer.Datastore = 'ds-nvme3'`) | – | ✅ (no 15/11, com os dois no ds-ssd, os bundles levaram ~1 h) |
| Um ESX por NVMe | `-HostCount 3` | `-HostCount 3` (no físico, 2 por NVMe também vai bem) |

## 3. O host

### ESXi físico (automático pelo `esxi-host-setup.sh`)
- Política de energia **High Performance** (`basico`).
- vSwitches internos com MTU 9000 e **sem traffic shaping** (`rede`).
- Memory Tiering a 25%: a RAM das VMs cabe na DRAM e o NV3 fica só como folga. A 120%, com memória ativa no NVMe, um ESX nested congelou no deploy real.

### Windows + Workstation (`00-Preflight.ps1 -FixHost`, que o `Deploy-Lab` já passa)
- Plano de energia Alto desempenho.
- Defender sem analisar as pastas das VMs e o `vmware-vmx.exe`.
- **NTFS sem "último acesso"** (`fsutil behavior set disablelastaccess 1`): cada leitura de `.vmdk` deixava de virar uma escrita de metadado.
- **Pastas das VMs fora do Windows Search** (atributo "não indexar").
- Aviso de `.vmem` em lab antigo e do limite de memória comprometida.

### Windows: à mão (só no lab, com o risco entendido)
1. **Cache de escrita sem flush nos NVMe das VMs:** Gerenciador de Dispositivos > Unidades de disco > o NVMe
   > Políticas > **Desativar a liberação do buffer de cache de gravação do Windows**. O vSAN nested pede flush o
   tempo todo e o NV3, sem proteção contra queda de energia, para tudo a cada flush. Ganho grande em escrita;
   risco: queda de energia corrompe as VMs do lab (aceitável num lab que se recria em horas; nunca no C:).
2. **TRIM ligado:** `fsutil behavior query DisableDeleteNotify` tem de mostrar `NTFS DisableDeleteNotify = 0`.
3. **Cluster de 64 KB** ao formatar um disco só de VMs (`Format-Volume -AllocationUnitSize 65536`): menos
   fragmentação dos `.vmdk` grandes. Só ao recriar o disco.
4. **Pelo menos 20% livres** em cada NV3: o cache SLC usa o espaço livre; disco cheio = escrita lenta.

## 4. BIOS do SRV-LAB (vale para os dois cenários)

| Opção | Valor |
|---|---|
| Perfil de energia | **Performance** / Maximum Performance (não *OS Control* nem *Balanced*) |
| C-states / C1E | desligados |
| Turbo Boost | ligado |
| Hyper-Threading | ligado |
| NUMA | ligado (*Node Interleaving* desligado) |
| Intel VT-x / VT-d | ligados |
| Memória | frequência máxima suportada pelos pentes (2400 MT/s no E5-2680 v4 com 1 pente por canal) |
| Slots PCIe dos NVMe | ligados à CPU, em x4 cada (com placa adaptadora de 4 NVMe: *bifurcation* x4x4x4x4) |

## 5. Hardware: o que mais rende por real gasto

| Troca | Por quê | Ordem |
|---|---|---|
| **NVMe com proteção contra queda de energia (PLP)** para os datastores do lab, no lugar dos Kingston NV3. Usados de servidor: Samsung PM983/PM9A3, Micron 7300/7400/7450, Intel/Solidigm P4510/P5510 (U.2 com adaptador PCIe, ou M.2 22110) | o NV3 é DRAM-less: escrita contínua cai muito quando o cache SLC enche, e cada flush espera a gravação na flash. Com PLP o disco confirma o flush pelo cache (com energia garantida): escrita síncrona muitas vezes mais rápida, que é exatamente o padrão do vSAN | **1º** |
| **NVMe de alta resistência para o Memory Tiering** (mesmos modelos acima) | o tiering escreve sem parar; o NV3 de 500 GB tem baixa resistência (TBW) | 2º |
| **512 GB de RAM** (16 × 32 GB DDR4 RDIMM, baratos usados) | menos páginas indo para o NVMe; dá para baixar o tiering ou subir os ESX | 3º |
| **E5-2697A v4 (16 núcleos) ou E5-2699 v4 (22)**, troca direta na mesma placa (confira o suporte do BIOS) | 56 vCPU de ESX nested hoje dividem 28 núcleos | 4º |
| Placa de rede | não muda nada no vSAN do lab: o tráfego é todo interno | – |

Confira na placa-mãe: quantos slots PCIe ligados à CPU existem, se o BIOS faz *bifurcation* e se aceita boot
por NVMe, antes de comprar adaptadores.
