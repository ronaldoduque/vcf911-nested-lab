#Requires -Version 7.2
<#
.SYNOPSIS
    Desmonta o lab para um redeploy limpo.
.DESCRIPTION
    Sem opções: desliga e apaga (do disco) as VMs dos ESX nested e do VCF Installer no ESXi físico.
    Os appliances do fleet (vCenter, NSX, SDDC Manager, Ops, VCFMS) moram dentro dos ESX e somem junto.
    -IncludeRouter   apaga também o VyOS
    -IncludeDns      regrava as zonas do BIND9 só com a svc01 (tira os registros do lab)
    -IncludeNetwork  remove o site de kickstart do nginx (rede, NAT e serviços da svc01 ficam;
                     os vSwitches/port groups do ESXi também: são do host, não do lab)
    -IncludeDepot    remove o site do depot no nginx (os arquivos do depot oficial NUNCA são apagados)
    -IncludeWorkDir  apaga Paths.WorkDir (JSONs, logs, kickstarts)
    -All             tudo acima (inclusive o depot)

    Não mexe em: svc01, NTP, ISOs/OVAs, depot, datastores, tiering.
    Pede confirmação; use -Confirm:$false para não perguntar.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'),
    [switch]$IncludeRouter,
    [switch]$IncludeDns,
    [switch]$IncludeNetwork,
    [switch]$IncludeWorkDir,
    [switch]$IncludeDepot,
    [switch]$All
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Assert-Admin
$cfg = Get-LabConfig -Path $ConfigPath
Import-Module (Join-Path $PSScriptRoot 'EsxiPlatform.psm1') -Force
Connect-LabEsxi -Config $cfg | Out-Null
$n   = $cfg.Network
if ($All) { $IncludeRouter = $IncludeDns = $IncludeNetwork = $IncludeWorkDir = $IncludeDepot = $true }

# ---------------- VMs
$targets = @($cfg.Esxi.AllHosts | ForEach-Object { "$($cfg.LabName)-$($_.Name)" }) + $cfg.Installer.VmName
if ($IncludeRouter) { $targets += $cfg.VyOS.VmName }
Write-LabLog "Removendo VMs: $($targets -join ', ')" 'STEP'
foreach ($name in $targets) {
    if (-not (Get-LabVm $name)) { Write-LabLog "${name}: nada para remover"; continue }
    if ($PSCmdlet.ShouldProcess($name, 'Desligar e apagar a VM do disco')) {
        Remove-LabVm $name | Out-Null
        Write-LabLog "$name removida" 'OK'
    }
}

# ---------------- DNS
if ($IncludeDns -and $PSCmdlet.ShouldProcess($cfg.Domain, 'Remover registros DNS do lab')) {
    Write-LabLog 'Removendo registros DNS' 'STEP'
    $global:LASTEXITCODE = 0
    & (Join-Path $PSScriptRoot '02-New-LabDns.ps1') -ConfigPath $ConfigPath -Remove
}

# ---------------- Sites da svc01 (kickstart; a rede é do setup-svc01.sh e não é desfeita aqui)
if ($IncludeNetwork -and $PSCmdlet.ShouldProcess('svc01', 'Remover o site de kickstart do nginx')) {
    Remove-LabNginxSite -Config $cfg -Name 'vcf911-ks'
    Write-LabLog 'Site de kickstart removido (rede, NAT e serviços da svc01 continuam)' 'OK'
}

# ---------------- Depot: só o site; os arquivos do depot oficial NUNCA são apagados
if ($IncludeDepot -and $PSCmdlet.ShouldProcess($cfg.Depot.SiteName, 'Remover site do depot no nginx')) {
    Remove-LabNginxSite -Config $cfg -Name $cfg.Depot.SiteName
    Write-LabLog "Site $($cfg.Depot.SiteName) removido do nginx (arquivos em $($cfg.Depot.Root) intactos)" 'OK'
}

# ---------------- Pasta de trabalho
if ($IncludeWorkDir) {
    $wd = $cfg.Paths.WorkDir
    if ((Test-Path $wd) -and $PSCmdlet.ShouldProcess($wd, 'Apagar pasta de trabalho')) {
        Remove-Item $wd -Recurse -Force -ErrorAction SilentlyContinue
        Write-LabLog "$wd apagada" 'OK'
    }
} else {
    Remove-Item (Join-Path $cfg.Paths.WorkDir 'deploy-id.txt') -ErrorAction SilentlyContinue
}

Write-LabLog 'Teardown concluído.' 'OK'
if ($IncludeNetwork) { Write-LabLog 'Para recriar tudo: ./Deploy-Lab.ps1 (começa pela etapa 0)' }
elseif ($IncludeDns) { Write-LabLog 'Para recriar: ./Deploy-Lab.ps1 -From 2' }
elseif ($IncludeRouter) { Write-LabLog 'Para recriar: ./Deploy-Lab.ps1 -From 4' }
else { Write-LabLog 'Para recriar: ./Deploy-Lab.ps1 -From 5 -Force' }
exit 0
