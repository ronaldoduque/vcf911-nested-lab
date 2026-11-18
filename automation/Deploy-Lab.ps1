#Requires -Version 7.2
<#
.SYNOPSIS
    Orquestra a criação completa do lab VCF 9.1.1 nested no ESXi 8 físico (depot offline).
    Roda DENTRO da svc01 Ubuntu (sudo pwsh, de preferência num tmux), depois de host/esxi-host-setup.sh e svc01/setup-svc01.sh.
.DESCRIPTION
    Etapas (cada uma é um script independente e idempotente em .\scripts):
      0  Preflight          - checagens, nada é criado
      1  Rede               - port groups no ESXi, autostart; confere a rede e os serviços da svc01
      2  DNS                - zonas do BIND9 na svc01, A + PTR (inclui os nomes do VCFMS)
      3  Depot              - depot oficial (VCF Download Tool) conferido e publicado no nginx (HTTP)
      4  VyOS               - roteador das VLANs (VM no ESXi, instalado pela ISO via teclado da API)
      5  ESX                - 4 ESX 9.1.1 nested (kickstart no nginx, máscara de CPU, FTT=0)
      6  VCF Installer      - OVA + OVF env, ajustes de lab, depot, sync e download dos bundles
      7  JSON               - especificação de deploy 9.1.1
      8  Teste              - DNS, NTP, pool do VCFMS, depot, VLAN e MTU ponta a ponta
      9  Deploy             - validação no Installer (e execução com -StartDeploy)
.EXAMPLE
    ./Deploy-Lab.ps1                       # 0 a 9, só valida
    ./Deploy-Lab.ps1 -StartDeploy          # 0 a 9 e já dispara o deploy se a validação passar
    ./Deploy-Lab.ps1 -From 5 -To 5 -Force  # recria só os ESX
    ./Deploy-Lab.ps1 -HostCount 3          # lab com 3 ESX (76 GB cada) em vez de 4 (58 GB)
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config/lab-config.psd1'),
    [ValidateRange(0, 9)][int]$From = 0,
    [ValidateRange(0, 9)][int]$To = 9,
    [switch]$Force,
    [switch]$StartDeploy,
    [ValidateSet(3, 4)][int]$HostCount     # sobrepõe Esxi.HostCount do config nesta execução
)

$ErrorActionPreference = 'Stop'
$s = Join-Path $PSScriptRoot 'scripts'
$ConfigPath = (Resolve-Path $ConfigPath).Path

$steps = [ordered]@{
    0 = @{ Name = 'Preflight';      Script = '00-Preflight.ps1';         Args = @{} }
    1 = @{ Name = 'Rede';   Script = '01-New-LabNetwork.ps1';    Args = @{} }
    2 = @{ Name = 'DNS';            Script = '02-New-LabDns.ps1';        Args = @{} }
    3 = @{ Name = 'Depot offline';  Script = '03-New-OfflineDepot.ps1';  Args = @{} }
    4 = @{ Name = 'VyOS';           Script = '04-New-VyOS.ps1';          Args = @{ Force = $Force } }
    5 = @{ Name = 'ESX nested';     Script = '05-New-NestedEsxi.ps1';    Args = @{ Force = $Force } }
    6 = @{ Name = 'VCF Installer';  Script = '06-New-VcfInstaller.ps1';  Args = @{ Force = $Force } }
    7 = @{ Name = 'JSON de deploy'; Script = '07-New-DeploySpec.ps1';    Args = @{} }
    8 = @{ Name = 'Teste do lab';   Script = '08-Test-LabReadiness.ps1'; Args = @{} }
    9 = @{ Name = 'Deploy';         Script = '09-Invoke-VcfDeploy.ps1';  Args = @{ Start = $StartDeploy } }
}

if ($HostCount) { $env:VCF911_HOSTCOUNT = "$HostCount" } else { Remove-Item Env:VCF911_HOSTCOUNT -ErrorAction SilentlyContinue }
$hc = if ($HostCount) { $HostCount } else { (Import-PowerShellDataFile $ConfigPath).Esxi.HostCount }
Write-Host "Lab VCF 9.1.1 com $hc ESX nested" -ForegroundColor Cyan

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
foreach ($k in $steps.Keys) {
    if ($k -lt $From -or $k -gt $To) { continue }
    $st = $steps[$k]
    Write-Host ""
    Write-Host ("=" * 78) -ForegroundColor DarkCyan
    Write-Host (" ETAPA {0} - {1}   (decorrido {2:hh\:mm\:ss})" -f $k, $st.Name, $sw.Elapsed) -ForegroundColor Cyan
    Write-Host ("=" * 78) -ForegroundColor DarkCyan

    $a = @{ ConfigPath = $ConfigPath }
    foreach ($p in $st.Args.Keys) { if ($st.Args[$p]) { $a[$p] = $true } }

    $global:LASTEXITCODE = 0
    & (Join-Path $s $st.Script) @a
    if ($LASTEXITCODE) {
        $hint = if ($HostCount) { " -HostCount $HostCount" } else { '' }
        throw "Etapa $k ($($st.Name)) terminou com código $LASTEXITCODE. Corrija e rode: ./Deploy-Lab.ps1 -From $k$hint"
    }
}
} finally { Remove-Item Env:VCF911_HOSTCOUNT -ErrorAction SilentlyContinue }
Write-Host ("`nConcluído em {0:hh\:mm\:ss}" -f $sw.Elapsed) -ForegroundColor Green
