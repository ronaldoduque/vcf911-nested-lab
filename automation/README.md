# Automação do lab VCF 9.1.1 no ESXi 8 físico

Roda **dentro da svc01 Ubuntu**, como root e num `tmux`, depois das Fases 0-5 de `../docs/PLANO-MIGRACAO.md`.

```sh
ssh lab@<ip-da-svc01>
sudo -i
tmux new -s lab                               # Ctrl+B e D para sair sem parar; voltar: tmux attach -t lab
cd /opt/vcf911/vcf911-nested-lab/automation
pwsh ./Deploy-Lab.ps1 -To 8                   # tudo até o teste
pwsh ./Deploy-Lab.ps1 -From 9 -StartDeploy    # valida e dispara o deploy
pwsh ./scripts/09-Invoke-VcfDeploy.ps1 -Retry # retomar depois de uma falha
```

| Etapa | Script | O que faz |
|---|---|---|
| 0 | 00-Preflight.ps1 | módulos, BIND/chrony/nginx, IPs da svc01, HD de dados, mídias, depot; ESXi: licença, tiering, port groups, datastores |
| 1 | 01-New-LabNetwork.ps1 | port groups e autostart no ESXi; confere a rede e os serviços da svc01 |
| 2 | 02-New-LabDns.ps1 | zonas do BIND9 (A + PTR, minúsculas) e conferência com `dig` |
| 3 | 03-New-OfflineDepot.ps1 | confere o depot oficial contra a release, grava `depot-versoes.json`, publica no nginx (8091) |
| 4 | 04-New-VyOS.ps1 | VM no ESXi, instalação pelo teclado da API, configuração por SSH |
| 5 | 05-New-NestedEsxi.ps1 | VMs dos ESX, kickstart no nginx (8080), máscara de CPU, `ClomRepairDelay` |
| 6 | 06-New-VcfInstaller.ps1 | ovftool `--X:injectOvfEnv` (ou Import-VApp), ajustes, depot, bundles |
| 7 | 07-New-DeploySpec.ps1 | JSON do deploy (FTT do config) |
| 8 | 08-Test-LabReadiness.ps1 | DNS, NTP, pool do VCFMS, depot, VLAN e MTU ponta a ponta |
| 9 | 09-Invoke-VcfDeploy.ps1 | validação, deploy, DRS segurado e traffic shaping desligado nos VDS durante o deploy (`-NoDrsGuard` desliga) |
| – | 99-Remove-Lab.ps1 | apaga as VMs do lab no ESXi (`-IncludeRouter`, `-IncludeDns`, `-All`...); nunca apaga o depot |

Opções úteis: `-Force` (recria as VMs da etapa), `-HostCount 3`, `-From N -To M`.

Configuração: só `config/lab-config.psd1`. Crie a partir do exemplo (`cp config/lab-config.example.psd1 config/lab-config.psd1`) e defina as senhas: o `00-Preflight.ps1` confere as regras de cada uma. Logs e arquivos gerados:
`/opt/vcf911/_work`. Interfaces depois do deploy: Installer `https://10.52.10.4/vcf-installer-ui` (admin@local),
vCenter `https://vc01.vcf.lab`, SDDC Manager `https://sddcm01.vcf.lab`, Operations `https://vcf01.vcf.lab`.
