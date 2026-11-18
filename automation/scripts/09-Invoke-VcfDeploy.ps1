#Requires -Version 7.2
<#
.SYNOPSIS
    Valida o JSON no VCF Installer 9.1.1 e (opcionalmente) dispara e acompanha o deploy do fleet.
.DESCRIPTION
    - POST /v1/sddcs/validations -> acompanha até terminar e lista cada checagem com a mensagem
    - com -Start: POST /v1/sddcs -> acompanha as subtarefas até concluir (4-8 h em nested)
    - com -Retry: PATCH /v1/sddcs/{id} retoma um deploy que falhou, depois de corrigir a causa
    A interface https://<installer>/vcf-installer-ui mostra o mesmo progresso.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'),
    [string]$SpecPath,
    [switch]$Start,
    [switch]$Retry,
    [switch]$SkipValidation,
    [switch]$NoDrsGuard     # não mexe no DRS do cluster durante o deploy
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VcfInstaller.psm1') -Force
$cfg  = Get-LabConfig -Path $ConfigPath
$in   = $cfg.Installer
$srv  = $in.Ip
$cred = @{ User = $in.AdminUser; Password = $in.AdminPassword }
if (-not $SpecPath) { $SpecPath = Join-Path $cfg.Paths.WorkDir 'vcf911-deploy.json' }
if (-not (Test-Path $SpecPath)) { throw "JSON não encontrado: $SpecPath (rode o 07-New-DeploySpec.ps1)" }
$body   = Get-Content -Raw -Path $SpecPath
$idFile = Join-Path $cfg.Paths.WorkDir 'deploy-id.txt'
$ui     = "https://$($in.Hostname).$($cfg.Domain)/vcf-installer-ui"

function Get-Messages($obj) {
    # as mensagens ficam em níveis diferentes (errorResponse, nestedErrors, nestedValidationChecks...)
    $msgs = [System.Collections.Generic.List[string]]::new()
    $walk = {
        param($o)
        if ($null -eq $o) { return }
        if ($o -is [System.Collections.IEnumerable] -and $o -isnot [string]) { foreach ($x in $o) { & $walk $x }; return }
        if ($o -is [pscustomobject]) {
            foreach ($pr in $o.PSObject.Properties) {
                if ($pr.Name -in 'message', 'remediationMessage' -and $pr.Value -and -not $msgs.Contains([string]$pr.Value)) { $msgs.Add([string]$pr.Value) }
                elseif ($pr.Value -is [pscustomobject] -or ($pr.Value -is [System.Collections.IEnumerable] -and $pr.Value -isnot [string])) { & $walk $pr.Value }
            }
        }
    }
    & $walk $obj
    $msgs
}

# ---------------- Retomar
if ($Retry) {
    $id = (Get-Content $idFile -ErrorAction Stop).Trim()
    Write-LabLog "Retomando o deploy $id" 'STEP'
    Restart-VcfDeployment -Server $srv -Cred $cred -Id $id
    $Start = $true; $SkipValidation = $true
}

# ---------------- Validação
if (-not $SkipValidation) {
    Write-LabLog "Validando $SpecPath no VCF Installer" 'STEP'
    $val = Invoke-VcfSpecValidation -Server $srv -Cred $cred -SpecJson $body -TimeoutMin 60

    foreach ($c in @($val.validationChecks)) {
        # SUCCEEDED -> OK | qualquer status com WARN (WARNING, SUCCEEDED_WITH_WARNINGS, FAILED_WITH_WARNINGS) -> aviso | resto -> erro
        $lvl = if ($c.resultStatus -eq 'SUCCEEDED') { 'OK' } elseif ("$($c.resultStatus)" -match 'WARN') { 'WARN' } else { 'ERROR' }
        Write-LabLog ("  [{0}] {1}" -f $c.resultStatus, $c.description) $lvl
        if ($c.resultStatus -ne 'SUCCEEDED') {
            foreach ($msg in (Get-Messages $c)) { Write-LabLog "      -> $msg" $lvl }
            $file = Join-Path $cfg.Paths.WorkDir ("validacao-falha-{0}.json" -f ($c.description -replace '[^\w]+', '-'))
            $c | ConvertTo-Json -Depth 20 | Set-Content -Path $file -Encoding utf8NoBOM
            Write-LabLog "      detalhe completo: $file" $lvl
        }
    }
    $lv = if ($val.resultStatus -eq 'SUCCEEDED') { 'OK' } elseif ("$($val.resultStatus)" -match 'WARN') { 'WARN' } else { 'ERROR' }
    Write-LabLog "Resultado da validação: $($val.resultStatus)" $lv
    if ($val.resultStatus -eq 'FAILED') {
        Write-LabLog "Corrija e valide de novo. O mesmo resultado aparece em $ui." 'ERROR'
        exit 1
    }
}

if (-not $Start) {
    Write-LabLog 'Validação concluída. Para iniciar o deploy: ./scripts/09-Invoke-VcfDeploy.ps1 -Start -SkipValidation'
    exit 0
}

# ---------------- Deploy
if (-not $Retry) {
    Write-LabLog 'Disparando o deploy do fleet VCF 9.1.1 (4-8 h em nested)' 'STEP'
    $task = Start-VcfDeployment -Server $srv -Cred $cred -SpecJson $body
    $id = $task.id
    if (-not $id) { $id = (Get-VcfDeployment -Server $srv -Cred $cred).id }
    $id | Set-Content $idFile
}
Write-LabLog "Deploy id: $id - acompanhe também em $ui/portal/progress-viewer"

$drs = @{ Disabled = [bool]$NoDrsGuard; Last = '' }
$drsDeploy = if ($cfg.Vcf.ContainsKey('DeployDrsLevel')) { $cfg.Vcf.DeployDrsLevel } else { '' }
$drsFinal  = if ($cfg.Vcf.ContainsKey('FinalDrsLevel') -and $cfg.Vcf.FinalDrsLevel) { $cfg.Vcf.FinalDrsLevel } else { 'FullyAutomated' }
if ($drsDeploy -and -not $NoDrsGuard) { Write-LabLog "DRS fica em $drsDeploy enquanto o deploy rodar (Vcf.DeployDrsLevel)" }
$last = ''
while ($true) {
    Start-Sleep -Seconds 120
    Invoke-LabDrsGuard -Config $cfg -State $drs -Level $drsDeploy
    try { $s = Get-VcfDeployment -Server $srv -Cred $cred -Id $id }
    catch { Write-LabLog "  API indisponível ($($_.Exception.Message)), tentando de novo" 'WARN'; continue }
    $sub  = @(if ($s.PSObject.Properties['sddcSubTasks']) { $s.sddcSubTasks } elseif ($s.PSObject.Properties['subTasks']) { $s.subTasks })
    $done = @($sub | Where-Object { $_.status -match 'COMPLETED_WITH_SUCCESS|SUCCEEDED|SUCCESSFUL' }).Count
    $cur  = ($sub | Where-Object { $_.status -eq 'IN_PROGRESS' } | Select-Object -First 1)
    $curName = if ($cur) { if ($cur.PSObject.Properties['name']) { $cur.name } else { $cur.description } } else { '' }
    $line = "  $($s.status) - $done/$($sub.Count) subtarefas - atual: $curName"
    if ($line -ne $last) { Write-LabLog $line; $last = $line }

    if ($s.status -match 'COMPLETED_WITH_SUCCESS|^SUCCESSFUL$|^SUCCEEDED$') {
        $d = $cfg.Domain
        Write-LabLog 'Deploy concluído.' 'OK'
        if ($cfg.Vcf.ContainsKey('VsanChecksumDisabled') -and $cfg.Vcf.VsanChecksumDisabled) {
            $r = Set-LabVsanDefaultPolicyRules -Config $cfg -Rules @{ 'VSAN.checksumDisabled' = $true }
            if ($r -match '^(ok|alterado)') {
                Write-LabLog "Checksum do vSAN desligado na política padrão - $r" 'OK'
                if ($r -match '^alterado') { Write-LabLog '  VMs do deploy mudam com o REAPPLY: vCenter > Policies and Profiles > VM Storage Policies > política > VM Compliance' }
            } else { Write-LabLog "Não desliguei o checksum do vSAN ($r)" 'WARN' }
        }
        if ($drsDeploy -and -not $drs.Disabled) {
            $r = Set-LabClusterDrs -Config $cfg -Level $drsFinal
            if ($r -in 'ok', 'alterado') { Write-LabLog "DRS do cluster de volta para $drsFinal" 'OK' }
            else { Write-LabLog "Não consegui voltar o DRS para $drsFinal ($r): ajuste no vCenter" 'WARN' }
        }
        Write-LabLog "  VCF Operations: https://$($cfg.Vcf.Operations.Hostname).$d  (admin)"
        Write-LabLog "  vCenter:        https://$($cfg.Vcf.Vcenter.Hostname).$d  (administrator@vsphere.local)"
        Write-LabLog "  SDDC Manager:   https://$($cfg.Vcf.SddcManager.Hostname).$d"
        Write-LabLog "  NSX:            https://$($cfg.Vcf.Nsx.VipHostname).$d  (admin)"
        Write-LabLog "Desligue o VCF Installer para liberar $($in.MemoryGB) GB de RAM: Stop-VMGuest $($in.VmName) (ou desligar no Host Client)" 'INFO'
        break
    }
    if ($s.status -match 'FAIL') {
        foreach ($f in @($sub | Where-Object { $_.status -match 'FAIL' })) {
            $nm = if ($f.PSObject.Properties['name']) { $f.name } else { $f.description }
            Write-LabLog "  FALHOU: $nm" 'ERROR'
            foreach ($msg in (Get-Messages $f)) { Write-LabLog "      -> $msg" 'ERROR' }
        }
        $s | ConvertTo-Json -Depth 20 | Set-Content -Path (Join-Path $cfg.Paths.WorkDir 'deploy-falha.json') -Encoding utf8NoBOM
        if ($drsDeploy -and -not $drs.Disabled) { Write-LabLog "DRS fica em $drsDeploy para o -Retry" }
        Write-LabLog "Corrija a causa e rode: ./scripts/09-Invoke-VcfDeploy.ps1 -Retry  (log no Installer: /var/log/vmware/vcf/domainmanager/domainmanager.log)" 'ERROR'
        exit 1
    }
}

exit 0
