# svc01: VM Ubuntu 24.04 que substitui o Windows

A svc01 é uma VM no próprio ESXi físico, no **ds-ssd**. Ela faz tudo o que o Windows fazia para o lab:
DNS (BIND9), NTP (chrony), depot e kickstart (nginx), e é de onde a automação roda. Também é a "porta" do seu
notebook para o lab: o notebook manda o tráfego de `10.52.0.0/16` para ela, e ela entrega no lab.

```
notebook ──(rede de casa)──► svc01 placa "casa" 192.168.0.101 ──NAT──► lab-mgmt 10.52.10.2 ──► 10.52.x / 10.60.x
             SSH: ssh lab@192.168.0.101                                   DNS 53, NTP 123, depot 8091, kickstart 8080
```

| Item | Valor |
|---|---|
| Sistema | Ubuntu Server 24.04 LTS (ISO *live-server-amd64*) |
| VM | 4 vCPU, 8 GB, disco de 60 GB thin no ds-ssd, EFI |
| Placa 1, MAC `00:50:56:3B:01:00` | **VM Network** (casa): IP fixo, ex.: 192.168.0.101 |
| Placa 2, MAC `00:50:56:3B:01:01` | **VCF911-MGMT**: 10.52.10.2/24, MTU 9000 (o script configura) |
| Placa 3, MAC `00:50:56:3B:01:02` | **VCF911-VSAN**: 10.52.12.1/24, MTU 9000 (o script configura) |
| Dados | disco virtual de 300 GB (ext4, thin) no ds-ssd em `/srv/dados`, com o `_migracao` copiado do HD |
| Pacote e WorkDir | `/opt/vcf911/vcf911-nested-lab` e `/opt/vcf911/_work` |
| Usuário | `lab` (com sudo); a automação roda como root (`sudo -i`) |

## 1. ISO do Ubuntu no datastore

No notebook: baixe o **Ubuntu Server 24.04 LTS** (`ubuntu-24.04.x-live-server-amd64.iso`, ~3 GB).
Host Client (`https://<ip-do-esxi>/ui`) > **Armazenamento** > ds-ssd > **Navegador do armazenamento de dados** >
pasta **ISO** > **Carregar** > a ISO.

## 2. Criar a VM (no ESXi, por SSH)

```sh
vi /vmfs/volumes/ds-ssd/scripts/esxi-host-setup.sh   # SVC_ISO="ubuntu-24.04.x-live-server-amd64.iso" (o nome exato)
sh /vmfs/volumes/ds-ssd/scripts/esxi-host-setup.sh svc01
```

O script cria a VM com as 3 placas e os MACs fixos, liga o autostart (a svc01 sobe primeiro) e já liga a VM.
A VM nasce **sem** o HD de dados, de propósito: o instalador do Ubuntu só enxerga o disco de 60 GB.

## 3. Instalar o Ubuntu (console da VM no Host Client)

Host Client > **Máquinas virtuais** > svc01 > **Console** (abrir no navegador). Escolhas, tela a tela:

| Tela | Escolha |
|---|---|
| Idioma | English (ou Português; os comandos são os mesmos) |
| Teclado | o do seu teclado (ex.: Portuguese (Brazil) ABNT2) |
| Tipo de instalação | **Ubuntu Server** (não o *minimized*) |
| Rede | aparecem 3 placas. Na de MAC **00:50:56:3b:01:00**: *Edit IPv4* > **Manual**: Subnet `192.168.0.0/24`, Address `192.168.0.101`, Gateway `192.168.0.1`, Name servers `192.168.0.1`. Nas de MAC **…:01:01** e **…:01:02**: *Edit IPv4* > **Disabled** (e IPv6 Disabled). O script configura essas duas depois. |
| Proxy / Mirror | vazio / padrão |
| Armazenamento | **Use an entire disk** (o único, de 60 GB). **Desmarque** *Set up this disk as an LVM group* (com LVM o Ubuntu usa só metade do disco; se já marcou: `sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv`) |
| Perfil | Your name `lab`, Server name `svc01`, Username `lab`, senha sua |
| Ubuntu Pro | Skip |
| SSH | **Install OpenSSH server** marcado |
| Snaps | nenhum |

No fim, **Reboot Now**. Se pedir para remover a mídia, só aperte Enter.

> Use um IP da rede de casa que esteja **fora da faixa do DHCP** do roteador (ou faça uma reserva para o MAC
> 00:50:56:3b:01:00). Esse IP é por onde você vai entrar na svc01 e por onde o notebook alcança o lab.

Testado com **Ubuntu Server 26.04.1** (o 24.04 também serve). Confira depois do reboot se o IP ficou fixo:
`ip -4 addr show ens160` **não** pode mostrar `dynamic`. Se mostrar (a placa ficou em DHCP), fixe:

```bash
sudo tee /etc/netplan/90-casa-fixo.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    ens160:
      dhcp4: false
      addresses: [192.168.0.101/24]
      routes:
        - to: default
          via: 192.168.0.1
      nameservers:
        addresses: [127.0.0.1]
EOF
sudo chmod 600 /etc/netplan/90-casa-fixo.yaml && sudo netplan try      # Enter para confirmar
```

## 4. Disco de dados e cópia do HD

> **RDM não funciona aqui.** No ESXi 8, HD SATA local sai com `Is RDM Capable: false` e o Host Client recusa com
> *Incompatible device backing*; o controlador SATA não pode ir em passthrough porque o SSD do ESXi está nele.
> Por isso os dados vão para um disco virtual no ds-ssd, copiados uma vez do HD pela rede (NBD só leitura).

1. **Disco de dados:** Host Client > svc01 > Editar > Adicionar disco rígido > Novo disco rígido padrão: 300 GB,
   `[ds-ssd] svc01/`, **Thin**, NVMe controller 0. Na svc01:
   ```bash
   lsblk                                        # o novo é o nvme0n2 (300G, sem partição)
   sudo mkfs.ext4 -L dados /dev/nvme0n2
   sudo mkdir -p /srv/dados
   echo 'LABEL=dados /srv/dados ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
   sudo systemctl daemon-reload && sudo mount /srv/dados
   ```
2. **Servidor de disco no ESXi** (janela 1, fica aberta; o firewall do ESXi fica desligado só durante a cópia):
   ```powershell
   scp host\hdd-nbd.py root@192.168.0.100:/tmp/
   ssh root@192.168.0.100 "esxcli network firewall set --enabled false; python /tmp/hdd-nbd.py <ID do HD> 192.168.0.101"
   ```
3. **Montar e copiar** (janela 2, na svc01). O `ntfs3` falha no `$BadClus` desse volume: use o `ntfs-3g`.
   ```bash
   sudo apt-get install -y nbd-client ntfs-3g rsync
   sudo modprobe nbd max_part=8
   sudo nbd-client -N hdd 192.168.0.100 10809 /dev/nbd0
   sudo mkdir -p /mnt/hdd && sudo mount -t ntfs-3g -o ro /dev/nbd0p1 /mnt/hdd
   tmux new -s copia
   sudo rsync -a --info=progress2 /mnt/hdd/_migracao/ /srv/dados/_migracao/     # ~208 GB, ~30 min
   ```
4. **Desfazer:** `sudo umount /mnt/hdd && sudo nbd-client -d /dev/nbd0`; Ctrl+C na janela 1; e religar o firewall:
   `ssh root@192.168.0.100 "esxcli network firewall set --enabled true"`.

Quando precisar de algo do HD de novo, repita os passos 2 e 3 (só leitura).

## 5. Copiar o pacote e rodar o setup

Na svc01 (`ssh lab@192.168.0.101`), clone este repositório:

```sh
sudo apt-get install -y git
sudo mkdir -p /opt/vcf911 && sudo git clone https://github.com/<SEU_USUARIO>/vcf911-nested-lab.git /opt/vcf911/vcf911-nested-lab
cd /opt/vcf911/vcf911-nested-lab
sudo cp automation/config/lab-config.example.psd1 automation/config/lab-config.psd1   # e defina as senhas
sudo bash svc01/setup-svc01.sh
```

O `setup-svc01.sh` (idempotente, pode rodar de novo; uma parte só: `sudo bash svc01/setup-svc01.sh dns`):

| Parte | O que faz |
|---|---|
| base | pacotes (BIND9, chrony, nginx, tmux, nftables, ntfs-3g...), fuso, hostname, `/opt/vcf911/_work` |
| rede | placas do lab pelas MACs (`lab-mgmt` 10.52.10.2, `lab-vsan` 10.52.12.1, MTU 9000), rotas 10.52/16 e 10.60/16 via VyOS, resolvedor local = BIND |
| disco | monta o NTFS do HD de dados em `/srv/dados` pelo fstab (ntfs3; se o volume estiver "sujo", monta só leitura e avisa) |
| dns | BIND9 recursivo para casa, lab e Tailscale, com forwarders; inclui as zonas que a etapa 2 gera |
| ntp | chrony servindo hora para o lab e para a casa, `local stratum 10` |
| nginx | tira o site padrão (os sites do depot e do kickstart vêm das etapas 3 e 5) |
| nat | `ip_forward` + masquerade do que vem da casa/Tailscale para o lab |
| pwsh | PowerShell 7 (repositório da Microsoft), Posh-SSH, VCF.PowerCLI |
| proxy | tinyproxy :3128 + PAC em `http://192.168.0.101/lab.pac` (lab em qualquer aparelho da casa, seção 6) |
| ovftool | instala o `VMware-ovftool-*-lin.x86_64.zip` se achar em `/srv/dados` (recomendado; sem ele a etapa 6 tenta Import-VApp e govc) |
| status | resumo |

✅ Checagem: `sudo bash svc01/setup-svc01.sh status` com named, chrony, nginx e nftables `active`,
`/srv/dados` montado e `pwsh` com versão.

## 6. Notebook alcançando o lab

**Opção 0, proxy na svc01 (recomendado; não precisa do roteador nem de administrador):**

```bash
sudo bash svc01/setup-svc01.sh proxy
```

Em cada aparelho, proxy automático (PAC) = `http://192.168.0.101/lab.pac`:
Windows: Configurações > Rede e Internet > Proxy > *Usar script de instalação*; Android/iPhone: Wi-Fi > rede >
Proxy > Automático; navegadores Chromium (Brave/Chrome): `--proxy-pac-url="http://192.168.0.101/lab.pac"`.
Só `*.vcf.lab`, `10.52.x.x` e `10.60.x.x` passam pela svc01; o resto vai direto. No notebook da empresa a
política do domínio fez o Edge ignorar o proxy: use outro navegador ou o túnel
`ssh -N -L 8443:10.52.10.4:443 lab@192.168.0.101` (`https://localhost:8443/vcf-installer-ui`).
Teste na svc01: `sudo tail -f /var/log/tinyproxy/tinyproxy.log` mostra o IP do aparelho a cada página.

**Opção A, rota no notebook (Windows, PowerShell como Administrador):**

```powershell
route -p add 10.52.0.0 mask 255.255.0.0 192.168.0.101
route -p add 10.60.0.0 mask 255.255.0.0 192.168.0.101
Add-DnsClientNrptRule -Namespace ".vcf.lab" -NameServers 192.168.0.101   # só o domínio do lab vai para a svc01
```

**Opção B, rota no roteador de casa:** rota estática `10.52.0.0/16` e `10.60.0.0/16` → `192.168.0.101`. Vale para
todos os aparelhos da casa. O DNS do `vcf.lab` continua precisando da regra NRPT (ou use a svc01 como DNS).

**Opção C, de fora de casa: Tailscale na svc01:**

```sh
curl -fsSL https://tailscale.com/install.sh | sudo sh
sudo tailscale up --advertise-routes=10.52.0.0/16,10.60.0.0/16 --accept-dns=false
```

No painel do Tailscale: aprove as rotas da svc01 e, em DNS, um *split DNS* `vcf.lab` → IP Tailscale da svc01
(100.x). O BIND já aceita consultas da faixa do Tailscale (100.64.0.0/10).

Teste no notebook: `nslookup vc01.vcf.lab` e, depois do deploy, `https://vc01.vcf.lab`.

## 7. Rodar a automação

Sempre dentro de um `tmux`: se o SSH cair (ou você fechar o notebook), o deploy continua.

```sh
ssh lab@192.168.0.101
sudo -i
tmux new -s lab                       # depois: Ctrl+B e D para sair sem parar; voltar: tmux attach -t lab
cd /opt/vcf911/vcf911-nested-lab/automation
nano config/lab-config.psd1           # EsxiHost.Address = IP do ESXi físico (e a senha do root, se mudou)
pwsh ./Deploy-Lab.ps1 -To 8
```

Logs: `/opt/vcf911/_work/lab-AAAAMMDD.log`. Para copiar arquivos do WorkDir para o notebook:
`scp lab@192.168.0.101:/opt/vcf911/_work/deploy-falha.json .` (como root, os arquivos são do root: `sudo cp` para a
pasta do `lab` antes).
