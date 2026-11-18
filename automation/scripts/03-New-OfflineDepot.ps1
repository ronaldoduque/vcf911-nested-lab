#Requires -Version 7.2
<#
.SYNOPSIS
    Publica o VCF Offline Depot 9.1.1 (baixado pelo VCF Download Tool) no nginx da svc01 e confere se ele tem
    tudo o que a release precisa.
.DESCRIPTION
    1. Confere o metadata do depot (vcfManifest.json, productVersionCatalog.json) em Depot.Root/PROD
    2. Para cada componente de instalação automática da release, acha a versão mais nova com TODOS os
       arquivos presentes e grava depot-versoes.json (a etapa 6 pede exatamente essas versões ao Installer).
       O que faltar vai para depot-faltando.txt
    3. Site no nginx: HTTP sem autenticação em Depot.BindIp:Depot.Port, sem compressão e sem cache (KB 447589)
    4. Testa as URLs que o Installer consulta primeiro (manifesto, catálogo, um .yaml, um .tar.gz, o OVA)
    Nada é alterado no depot. Rodar de novo é seguro.
.NOTES
    VCF 9.1.1 recusa URL de depot com TLD fora da IANA (.lab, .local) - KB 456037: o Installer usa o IP.
#>
[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'))

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Assert-Admin
$cfg = Get-LabConfig -Path $ConfigPath
$d   = $cfg.Depot
$prod = Join-Path $d.Root 'PROD'
Write-LabLog "VCF Offline Depot $($cfg.Vcf.Version) em $($d.Root)" 'STEP'

# ---------------------------------------------------------------- 1. metadata
if (-not (Test-Path $prod)) { throw "Não achei $prod. O HD de dados está montado em $($cfg.Svc01.DataMount)? (mount | grep $($cfg.Svc01.DataMount))" }
$pvcFile = Join-Path $prod 'metadata/productVersionCatalog/v1/productVersionCatalog.json'
$manFile = Join-Path $prod 'metadata/manifest/v1/vcfManifest.json'
foreach ($f in $pvcFile, $manFile) { if (-not (Test-Path $f)) { throw "Depot sem $f - baixe de novo com o VCF Download Tool." } }
if (-not (Test-Path (Join-Path $prod 'COMP/SDDC_MANAGER_VCF/Compatibility/VmwareCompatibilityData.json'))) {
    Write-LabLog 'VmwareCompatibilityData.json ausente em PROD/COMP/SDDC_MANAGER_VCF/Compatibility (KB 450175): o deploy pode parar em "Configure Base Install Image Repository".' 'WARN'
}
if (-not (Test-Path (Join-Path $prod 'vsan/hcl/all.json'))) { Write-LabLog 'PROD/vsan/hcl/all.json ausente: a checagem de HCL do vSAN pode reclamar (no lab ela é desligada no Installer)' 'WARN' }

# ---------------------------------------------------------------- 2. catálogo x arquivos
$pvc = Get-Content -LiteralPath $pvcFile -Raw | ConvertFrom-Json -Depth 100
$man = Get-Content -LiteralPath $manFile -Raw | ConvertFrom-Json -Depth 100
$line = $cfg.Vcf.Version.Substring(0, 5)
function ConvertTo-VerKey([string]$v) { (([regex]::Matches($v, '\d+') | ForEach-Object { '{0:D10}' -f [int64]$_.Value }) -join '.') }
$release = @($man.releases | Where-Object version -eq $cfg.Vcf.Version)
if (-not $release) { $release = @($man.releases | Where-Object { $_.version -like "$line*" } | Sort-Object { ConvertTo-VerKey $_.version } -Descending) }
if (-not $release) { throw "O vcfManifest.json não tem release $line.x. Versões: $(($man.releases.version | Sort-Object -Unique) -join ', ')" }
$release = $release[0]
$needed  = @((($release.sku | Where-Object name -eq $cfg.Vcf.Sku).bom) | Where-Object { $_.automatedInstall } | ForEach-Object name)
$dayN    = if ($cfg.Vcf.Automation.Deploy) { @() } else { @('VRA', 'VCF_SERVICE_VCD_MIGRATION_BACKEND') }
Write-LabLog "release $($release.version) / $($cfg.Vcf.Sku): $($needed.Count) componentes de instalação automática"

$entries = foreach ($comp in $pvc.patches.PSObject.Properties) {
    foreach ($e in @($comp.Value)) {
        if ("$($e.productVersion)" -notlike "$line*") { continue }
        foreach ($bd in @($e.artifacts.bundles)) {
            if ($bd.type -ne 'INSTALL') { continue }
            [pscustomobject]@{
                Comp = $comp.Name; Version = "$($e.productVersion)"; Key = (ConvertTo-VerKey $e.productVersion)
                Files = @($bd.binaries | ForEach-Object { [pscustomobject]@{ Name = (Split-Path $_.fileName -Leaf); Rel = "COMP/$($comp.Name)/$($_.fileName)"; Size = [int64]$_.size } })
            }
        }
    }
}
$report = @(); $faltam = [System.Collections.Generic.List[string]]::new(); $versoes = [ordered]@{}
foreach ($comp in $needed) {
    $vers = @($entries | Where-Object Comp -eq $comp | Sort-Object Key -Descending)
    if (-not $vers) { $report += [pscustomobject]@{ Componente = $comp; Versao = '-'; Situacao = 'sem versão no catálogo' }; continue }
    $state = foreach ($v in $vers) {
        $miss = @($v.Files | Where-Object { $p = Join-Path $prod $_.Rel; -not (Test-Path -LiteralPath $p) -or ($_.Size -and (Get-Item -LiteralPath $p).Length -ne $_.Size) })
        [pscustomobject]@{ V = $v; Miss = $miss; Have = $v.Files.Count - $miss.Count }
    }
    $full = $state | Where-Object { $_.Miss.Count -eq 0 } | Select-Object -First 1
    if ($full) {
        $versoes[$comp] = $full.V.Version
        $report += [pscustomobject]@{ Componente = $comp; Versao = $full.V.Version; Situacao = $(if ($vers[0].Version -ne $full.V.Version) { "OK (existe $($vers[0].Version) mais nova)" } else { 'OK' }) }
    } else {
        $part = ($state | Where-Object Have -gt 0 | Select-Object -First 1); if (-not $part) { $part = $state[0] }
        $tag = if ($comp -in $dayN) { 'Day-N, pode faltar' } else { 'FALTA' }
        $report += [pscustomobject]@{ Componente = $comp; Versao = $part.V.Version; Situacao = "$tag ($($part.Have)/$($part.V.Files.Count))" }
        if ($comp -notin $dayN) { foreach ($m in $part.Miss) { $faltam.Add("$comp`t$($part.V.Version)`t$($m.Name)") } }
    }
}
Write-LabLog "Componentes da release $($release.version) no depot:" 'STEP'
$report | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$versoes | ConvertTo-Json | Set-Content -Path (Join-Path $cfg.Paths.WorkDir 'depot-versoes.json') -Encoding utf8NoBOM
$faltaFile = Join-Path $cfg.Paths.WorkDir 'depot-faltando.txt'
if ($faltam.Count) {
    (@("componente`tversão`tarquivo") + $faltam) | Set-Content -Path $faltaFile -Encoding utf8NoBOM
    Write-LabLog "$($faltam.Count) arquivo(s) obrigatório(s) faltando ou com tamanho errado: $faltaFile" 'WARN'
} else {
    Remove-Item $faltaFile -ErrorAction SilentlyContinue
    Write-LabLog 'Todos os componentes obrigatórios estão completos no depot' 'OK'
}

# ---------------------------------------------------------------- 3. nginx
Set-LabNginxSite -Config $cfg -Name $d.SiteName -Listen "$($d.BindIp):$($d.Port)" -Root $d.Root

# ---------------------------------------------------------------- 4. teste
$base = "http://$($d.BindIp):$($d.Port)"
$probes = @('PROD/metadata/manifest/v1/vcfManifest.json', 'PROD/metadata/productVersionCatalog/v1/productVersionCatalog.json')
foreach ($ext in '*.yaml', '*.tar.gz', '*.ova') {
    $f = Get-ChildItem -Path (Join-Path $prod 'COMP') -Recurse -File -Filter $ext -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($f) { $probes += 'PROD/' + [System.IO.Path]::GetRelativePath($prod, $f.FullName).Replace('\', '/') }
}
$ok = $true
foreach ($u in $probes) {
    try { $r = Invoke-WebRequest -Uri ("$base/" + (($u -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')) -Method Head -TimeoutSec 15
          Write-LabLog "  $u -> HTTP $($r.StatusCode)" 'OK' }
    catch { Write-LabLog "  $u -> $($_.Exception.Message)" 'ERROR'; $ok = $false }
}
if (-not $ok) { throw "O depot não respondeu como esperado (tail /var/log/nginx/$($d.SiteName).error.log)." }
Write-LabLog "Depot no ar: $base  (é essa URL, com IP, que vai no VCF Installer)" 'OK'
if ($faltam.Count) { Write-LabLog "Depot INCOMPLETO: complete com o VCF Download Tool e rode esta etapa de novo." 'ERROR'; exit 2 }
exit 0
