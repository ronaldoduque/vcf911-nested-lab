# Plano de migração: SRV-LAB de Windows + Workstation para ESXi 8 físico + svc01 Ubuntu + VCF 9.1.1

Cada fase termina com uma checagem. **Não passe de fase com a checagem falhando.** Rollback em qualquer ponto
antes da Fase 3: `srv-lab-backup-windows\docs\RESTAURAR-WINDOWS.md`.

| Fase | O que | Onde você está | Tempo | Destrutivo? |
|---|---|---|---|---|
| 0 | Backup, cópias, downloads, pendrive, teste de hardware | Windows atual | 3-5 h | não |
| 1 | Instalar o ESXi 8.0 U3 no SSD | console do servidor (monitor e teclado) | 30 min | **SSD apagado** |
| 2 | Configuração inicial do ESXi (IP, SSH) | console do servidor (DCUI) | 10 min | não |
| 3 | Preparar o host: rede, datastores, tiering | notebook, SSH no ESXi | 30 min | **NVMe 1 TB e NVMe do Windows apagados** |
| 4 | Criar e instalar a svc01 (Ubuntu) | notebook: SSH no ESXi + Host Client | 40 min | não |
| 5 | Preparar a svc01 | notebook, SSH na svc01 | 20 min | não |
| 6 | Automação: etapas 0 a 8 | SSH na svc01 (tmux) | 2-3 h | não |
| 7 | Deploy do fleet VCF 9.1.1 | SSH na svc01 (tmux) | 4-8 h | não |

**De onde você opera:** depois da Fase 2 o servidor não tem mais área de trabalho. Tudo é feito de um
**notebook/PC na mesma rede de casa**: navegador (Host Client do ESXi, interfaces do VCF) e terminal (SSH).
No Windows, o PowerShell já tem `ssh` e `scp`.

## Plano de IPs da rede de casa (192.168.0.0/24)

| Quem | IP | Como |
|---|---|---|
| Roteador | 192.168.0.1 | – |
| ESXi físico (vmk0) | **192.168.0.100** | fixo, na DCUI (Fase 2) |
| svc01, placa "casa" | **192.168.0.101** | fixo, no instalador do Ubuntu (Fase 4) |
| VyOS eth0 | DHCP | (opcional) reserva no roteador para o MAC 00:50:56:3b:02:00 |

O 192.168.0.100 era o IP do Windows e fica para o ESXi. O 192.168.0.101 estava livre em 15/11: confirme que está
fora da faixa do DHCP do roteador (ou reserve para o MAC 00:50:56:3b:01:00).

**Antes de apagar o Windows:** ele é DNS de si mesmo (192.168.0.100). Se o roteador entrega esse IP como DNS
para os aparelhos da casa (`ipconfig /all` num notebook ou celular), troque no DHCP do roteador para 192.168.0.1
ou 1.1.1.1, ou a internet da casa para junto com o Windows.

---

## Fase 0: ainda no Windows

1. **Backup:** rode o `srv-lab-backup-windows` até o **PRONTO-PARA-MIGRAR**.
2. **Cópia dos dados** para o HD que fica (E: "HDD-BKP"): já feita em `E:\_migracao\D` (`ISOs` sem a 9.1.1,
   `SCRIPTs_LAB`, `VCF`, `VCF-Depot-911`). O depot do 5.2 já está em `E:\VCF-Depot`.
3. **Downloads**, para `E:\_migracao` e uma cópia no notebook:

   | Arquivo | De onde | Para quê |
   |---|---|---|
   | ESXi 8.0 U3 (`VMware-VMvisor-Installer-8.0U3*.iso`), a ISO **normal** | portal Broadcom (provavelmente já está em `D:\ISOs`) | pendrive do ESXi físico |
   | Ubuntu Server 24.04 LTS (`ubuntu-24.04.x-live-server-amd64.iso`) | ubuntu.com/download/server | VM svc01 |
   | OVF Tool para Linux (`VMware-ovftool-*-lin.x86_64.zip`) | portal Broadcom > OVF Tool | importar o Installer (opcional, há alternativa) |
   | Rufus | rufus.ie | gravar o pendrive |
   | Este repositório | – | clonado na svc01 com `git clone` (docs/svc01-ubuntu.md, passo 5) |

4. **Placa de rede:** precisa ter driver nativo no ESXi 8.0 U3. Veja o modelo:
   ```powershell
   Get-PnpDevice -Class Net -PresentOnly | Where-Object { $_.FriendlyName -notmatch 'VMware|Virtual|WAN|Bluetooth|Hyper-V' } |
     ForEach-Object { '{0} | {1}' -f $_.FriendlyName, (($_ | Get-PnpDeviceProperty DEVPKEY_Device_HardwareIds).Data[0]) }
   ```
   Intel de servidor (I350, X540, X710...) costuma ter. Realtek e Intel I219/I225 de desktop, não.
5. **Pendrive do ESXi** (8 GB ou mais) com o Rufus: a ISO do ESXi 8.0 U3, esquema **GPT**, destino **UEFI (não CSM)**.
   Se o Rufus perguntar sobre substituir o `menu.c32`, responda **Sim**.
6. **Teste de hardware sem instalar nada:** dê boot pelo pendrive (menu de boot da placa, F11/F12) e deixe o
   instalador carregar.
   - **"No Network Adapters"**: PARE. A placa de rede não tem driver no ESXi 8.
   - Na tela **Select a Disk**, confira se aparecem o SSD SATA, os 4 NVMe e os HDs. Anote o **modelo** do SSD SATA.
   - **ESC** e desligue. Nada foi gravado.

✅ Checagem: PRONTO-PARA-MIGRAR; `_migracao` conferido; o instalador vê a rede e todos os discos.

## Fase 1: instalar o ESXi 8.0 U3 (console do servidor)

1. **Desconecte o HD I:** ("HDD", cabo de energia ou SATA). O E: ("HDD-BKP", com o `_migracao`) fica ligado.
2. **Setup da placa-mãe (BIOS/UEFI):** boot **UEFI**; **Intel VT-x** e **VT-d** ligados; *Execute Disable* ligado;
   *Above 4G decoding* ligado, se houver; perfil de energia **Performance** (não *OS Control*/*Balanced*).
3. Boot pelo pendrive. Na contagem *"Automatic boot in 5 seconds"*, aperte **Shift+O** e acrescente no fim da linha:
   ```
    systemMediaSize=min
   ```
   Enter. (Sistema do ESXi com ~32 GB em vez de 128 GB; o resto do SSD vira datastore.)
4. Enter na tela de boas-vindas, **F11** para aceitar a licença.
5. **Select a Disk:** escolha o **SSD SATA** pelo **modelo e tipo** que você anotou. **Não** escolha o NVMe
   Kingston de 500 GB (é o Windows; o tamanho é parecido). Se perguntar sobre VMFS existente: *Install ESXi,
   overwrite VMFS datastore*.
6. Teclado: **Portuguese (Brazilian)** ou US Default. Senha de root: `<SENHA_DO_LAB>` (a mesma do lab).
7. Aviso de CPU (Broadwell *deprecated* no 8.x): **Enter** para continuar. **F11** para instalar.
8. Fim: tire o pendrive e **Enter** para reiniciar. No setup da placa, o **SSD (VMware ESXi)** como primeiro boot.

✅ Checagem: o servidor sobe na tela amarela/cinza do ESXi (DCUI) mostrando um IP (de DHCP).

## Fase 2: configuração inicial do ESXi (DCUI, no console)

**F2** e login com `root`:

1. **Configure Management Network**
   - **Network Adapters**: marque (barra de espaço) a placa com *Connected* (a que está com cabo).
   - **IPv4 Configuration**: *Set static IPv4 address*: `192.168.0.100`, máscara `255.255.255.0`, gateway `192.168.0.1`.
   - **IPv6 Configuration**: desligue (opcional).
   - **DNS Configuration**: primário `192.168.0.1` (o roteador); hostname `srv-lab`.
   - **Esc** e **Y** para aplicar e reiniciar a rede.
2. **Troubleshooting Options** > **Enable SSH** (e *Enable ESXi Shell*, opcional).
3. **Esc** até sair.

No notebook: `https://192.168.0.100/ui` (aceite o certificado), login `root`.
Confira em **Host > Licenciamento**: *Evaluation Mode*, 60 dias.

✅ Checagem: Host Client abre; licença em avaliação; **Armazenamento > Dispositivos** mostra os discos.

## Fase 3: preparar o host (notebook, SSH no ESXi)

```sh
scp host/esxi-host-setup.sh root@192.168.0.100:/tmp/
ssh root@192.168.0.100
sh /tmp/esxi-host-setup.sh listar
```

1. O `listar` mostra cada disco com o papel sugerido e o **ID**. Edite o topo do script
   (`vi /tmp/esxi-host-setup.sh`: `i` para editar, `Esc` e `:wq` para salvar) e preencha:
   - `DS_LIST="ds-nvme1=<id> ds-nvme2=<id> ds-nvme3=<id>"`: os três NVMe de ~1 TB
   - `TIER_DEVICE="<id>"`: o NVMe de ~500 GB que aparece como NTFS/Windows
   - `HDD_DADOS="<id>"`: o HD de 1 TB que ficou ligado (o E:, com o `_migracao`)
2. Rode, nesta ordem:
   ```sh
   sh /tmp/esxi-host-setup.sh basico        # hostname, NTP, energia High Performance, autostart
   sh /tmp/esxi-host-setup.sh rede          # 3 vSwitches internos + port groups VCF911-*
   sh /tmp/esxi-host-setup.sh datastores    # pede para digitar o nome de cada datastore; core dump no ds-ssd
   sh /tmp/esxi-host-setup.sh tiering       # pede para digitar APAGAR-WINDOWS; TierNvmePct = 25
   reboot
   ```
   O `datastores` guarda uma cópia do script (com os IDs) em `/vmfs/volumes/ds-ssd/scripts/`, porque o `/tmp`
   do ESXi some no reboot. Depois do reboot, use sempre essa cópia.
3. Depois do reboot:
   ```sh
   ssh root@192.168.0.100
   sh /vmfs/volumes/ds-ssd/scripts/esxi-host-setup.sh status
   ```
   - Memória: ~320 GB (256 GB de RAM + ~64 GB de tier)
   - 3 vSwitches VCF com MTU 9000 e os port groups VCF911-MGMT / VCF911-VSAN / VCF911-NSX-TRUNK
   - ds-ssd, ds-nvme1, ds-nvme2, ds-nvme3

> O `tiering` é o ponto sem volta para o Windows **no disco**. Volta só pela imagem do backup.
> Para adiar, pule o `tiering`: o lab sobe com 256 GB se você usar 3 hosts (`HostCount = 3`, `MemoryGB3 = 72`).

✅ Checagem: `status` com tiering, rede e os 4 datastores.

## Fase 4: VM svc01 (Ubuntu)

Siga **`docs/svc01-ubuntu.md`, passos 1 a 4**: enviar a ISO do Ubuntu para o ds-ssd, `esxi-host-setup.sh svc01`,
instalar o Ubuntu pela console (placa da casa com IP fixo, as outras duas desabilitadas, disco inteiro sem LVM,
OpenSSH) e, no passo 4, criar o disco de dados de 300 GB e copiar o `_migracao` do HD pela rede (o RDM não
funciona no ESXi 8 com HD SATA local).

✅ Checagem: `ssh lab@192.168.0.101` entra na svc01.

## Fase 5: preparar a svc01

**`docs/svc01-ubuntu.md`, passos 5 e 6:** copiar o pacote por `scp`, `sudo bash svc01/setup-svc01.sh` e configurar
o notebook para alcançar o lab (rota + DNS do `vcf.lab`, ou Tailscale).

✅ Checagem: `sudo bash svc01/setup-svc01.sh status` todo ativo; `/srv/dados/_migracao/D/VCF-Depot-911` visível;
no notebook, `ping 10.52.10.2` responde.

## Fase 6: automação (etapas 0 a 8)

Na svc01, como root, dentro do tmux (**`docs/svc01-ubuntu.md`, passo 7**):

```sh
sudo -i
tmux new -s lab
cd /opt/vcf911/vcf911-nested-lab/automation
nano config/lab-config.psd1          # EsxiHost.Address = 192.168.0.100 (o IP do ESXi físico)
pwsh ./Deploy-Lab.ps1 -To 8
```

| Etapa | O que acontece | Se falhar |
|---|---|---|
| 0 Preflight | módulos, BIND/chrony/nginx, IPs da svc01, HD montado, mídias, licença do ESXi, tiering, port groups, datastores, senhas | leia cada [ERROR] |
| 1 Rede | port groups no ESXi, autostart; confere a rede da svc01 | `sudo bash svc01/setup-svc01.sh rede` |
| 2 DNS | zonas do BIND9: 22 registros A + PTR, conferidos com `dig` | `journalctl -u named` |
| 3 Depot | confere o depot oficial contra a release e publica no nginx (porta 8091) | `depot-faltando.txt` no WorkDir |
| 4 VyOS | live: login + DHCP/SSH pela console; `install image` por SSH respondendo cada pergunta; ISO tirada com a VM desligada; configura por SSH. IP achado pelo MAC (o VyOS não tem Tools) | console da VM; `-Force` recria |
| 5 ESX | 4 VMs com máscara de CPU, kickstart no nginx (porta 8080) com `--forceunsupportedinstall` (Broadwell) | console da VM no Host Client |
| 6 Installer | importa o OVA (ovftool; sem ele Import-VApp e, se falhar, govc), ajustes, depot, bundles (~40 min) | `ovftool-installer.log` no WorkDir |
| 7 JSON | especificação de deploy (FTT=0) | – |
| 8 Teste | DNS, NTP, pool VCFMS, depot, VLAN e MTU 9000 ponta a ponta | – |

Retomar de uma etapa: `pwsh ./Deploy-Lab.ps1 -From 5 -To 8` (com `-Force` recria as VMs daquela etapa).
Sair do tmux sem parar nada: **Ctrl+B** e **D**. Voltar: `sudo tmux attach -t lab`.

✅ Checagem: etapa 8 toda verde.

## Fase 7: deploy

```sh
pwsh ./Deploy-Lab.ps1 -From 9 -StartDeploy
```

- A etapa 9 valida, dispara e acompanha. Enquanto roda, segura o **DRS em PartiallyAutomated** (sem vMotion
  automático) e no fim volta para *FullyAutomated*. Na mesma checagem, a cada 2 min, desliga qualquer **traffic
  shaping** nas port groups dos VDS e loga o que desligou (`Vcf.DisableTrafficShaping`). `-NoDrsGuard` desliga as duas.
- Interface: `https://10.52.10.4/vcf-installer-ui` (admin@local / <SENHA_DO_LAB>), do notebook com a rota da Fase 5.
- Se a validação recusar **FTT=0**: `Vcf.VsanFtt = 1` no config e `pwsh ./scripts/07-New-DeploySpec.ps1`, depois a etapa 9 de novo.
- Falhou? Corrija e `pwsh ./scripts/09-Invoke-VcfDeploy.ps1 -Retry`.
- Depois do deploy: desligue o VCF Installer (libera 16 GB).

## Depois do deploy

- **Memória:** Host Client > Monitorar. Se o tier estiver muito cheio, desligue o Installer ou suba o `TierNvmePct` para 150.
- **Licença:** anote quando acaba a avaliação de 60 dias do ESXi físico.
- **HD I:** reconecte quando quiser. Para a svc01 ler também: outro `vmkfstools -z` e o disco na mesma controladora PVSCSI.
- **3 hosts:** `pwsh ./Deploy-Lab.ps1 -HostCount 3 -From 5 -Force` (120 GB por host, um por NVMe).
- **ESA:** `VsanMode = 'ESA'` no config e `pwsh ./Deploy-Lab.ps1 -From 5 -Force`.
