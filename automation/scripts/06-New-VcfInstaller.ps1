#Requires -Version 7.2
<#
.SYNOPSIS
    VCF Installer 9.1.1 como VM do ESXi físico: importa o OVA com as propriedades OVF, aplica os
    ajustes de lab, conecta no depot offline (nginx da svc01) e baixa os bundles do 9.1.1.
.DESCRIPTION
      1. Lê as chaves de propriedade do próprio OVA (descritor .ovf de dentro do OVA)
      2. Importa:
           com ovftool (Paths.Ovftool): --X:injectOvfEnv --powerOn --prop:... (o ESXi sozinho não tem
             vApp; o ovftool injeta o ambiente OVF, como o William Lam faz em hosts sem vCenter)
           sem ovftool: Import-VApp + guestinfo.ovfEnv nas opções avançadas (mesmo método do Workstation)
      3. Espera https://<installer>/vcf-installer-ui e a API
      4. Ajustes de lab em /etc/vmware/vcf/domainmanager/application.properties pelo VMware Tools
         (Invoke-VMScript como root, sem SSH)
      5. VmwareCompatibilityData.json do depot para o appliance (KB 450175)
      6. API: depot offline por IP em HTTP (KB 456037), sync, download dos bundles de INSTALL
.PARAMETER Force
    Apaga a VM do Installer e recria.
.PARAMETER SkipBundles
    Só cria/configura o appliance; não mexe no depot nem nos bundles.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'),
    [switch]$Force,
    [switch]$SkipBundles
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EsxiPlatform.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'VcfInstaller.psm1') -Force
function Import-LabOvaGovc {
    # importa um OVA num ESXi sem vCenter com o govc (github.com/vmware/govmomi); baixa o govc se faltar
    param($Config, [string]$Ova, [string]$Name, [string]$Datastore, [string]$Portgroup)
    $govc = (Get-Command govc -ErrorAction SilentlyContinue).Source
    if (-not $govc) {
        Write-LabLog 'Baixando o govc (GitHub, vmware/govmomi)...'
        $tgz = Join-Path $Config.Paths.WorkDir 'govc.tar.gz'
        Invoke-WebRequest -Uri 'https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz' -OutFile $tgz
        & tar -xzf $tgz -C /usr/local/bin govc
        if ($LASTEXITCODE) { throw 'Não extraí o govc.' }
        $govc = '/usr/local/bin/govc'
    }
    $h = $Config.EsxiHost
    $env:GOVC_URL = "https://$($h.Address)/sdk"; $env:GOVC_USERNAME = $h.User; $env:GOVC_PASSWORD = $h.Password; $env:GOVC_INSECURE = '1'
    try {
        $spec = (& $govc import.spec $Ova) -join "`n" | ConvertFrom-Json
        if ($LASTEXITCODE) { throw 'govc import.spec falhou.' }
        $spec.Name = $Name; $spec.DiskProvisioning = 'thin'; $spec.PowerOn = $false
        if ($spec.PSObject.Properties['PropertyMapping']) { $spec.PropertyMapping = @() }   # ESXi sozinho não entrega vApp: vai pelo guestinfo.ovfEnv
        if ($spec.PSObject.Properties['NetworkMapping']) { foreach ($m in @($spec.NetworkMapping)) { $m.Network = $Portgroup } }
        $opt = Join-Path $Config.Paths.WorkDir 'govc-installer.json'
        $spec | ConvertTo-Json -Depth 10 | Set-Content -Path $opt -Encoding utf8
        Write-LabLog "govc import.ova -> [$Datastore] $Name (alguns minutos)..."
        & $govc import.ova "-ds=$Datastore" "-options=$opt" $Ova
        if ($LASTEXITCODE) { throw "govc import.ova falhou (código $LASTEXITCODE)." }
    } finally {
        Remove-Item Env:GOVC_PASSWORD -ErrorAction SilentlyContinue
    }
}

Assert-Admin
$cfg  = Get-LabConfig -Path $ConfigPath
$in   = $cfg.Installer
$n    = $cfg.Network
$fqdn = "$($in.Hostname).$($cfg.Domain)".ToLower()
$cred = @{ User = $in.AdminUser; Password = $in.AdminPassword }
Connect-LabEsxi -Config $cfg | Out-Null

Write-LabLog "VCF Installer $fqdn ($($in.Ip)) -> [$($in.Datastore)]" 'STEP'

$vm = Get-LabVm $in.VmName
if ($vm -and $Force) { Remove-LabVm $in.VmName | Out-Null; $vm = $null; Write-LabLog 'VM antiga apagada' }

$fresh = $false
if (-not $vm) {
    $ova = $cfg.Paths.OvaVcfInstaller
    if (-not $ova -or -not (Test-Path $ova)) { throw "OVA do VCF Installer não encontrado: $($cfg.Paths.OvaVcfInstaller)" }

    # ---------------- chaves de propriedade do OVA (lidas do descritor .ovf de dentro do OVA)
    # Nome completo = classe.chave.instância (ex.: vami.ip0.SDDC_Manager). O ovftool só mostra a chave curta.
    $ovfTmp = Join-Path ([System.IO.Path]::GetTempPath()) "vcf-ovf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $ovfTmp -Force | Out-Null
    $tarExe = if ($IsWindows) { Join-Path $env:windir 'System32\tar.exe' } else { 'tar' }
    $ovfName = (& $tarExe -tf "$ova" 2>$null | Where-Object { $_ -match '\.ovf$' } | Select-Object -First 1)
    if (-not $ovfName) { throw "Não achei o .ovf dentro de $ova" }
    & $tarExe -xf "$ova" -C $ovfTmp $ovfName
    [xml]$ovfXml = Get-Content -Raw -LiteralPath (Join-Path $ovfTmp $ovfName)
    Remove-Item $ovfTmp -Recurse -Force -ErrorAction SilentlyContinue
    $keys = @(foreach ($ps in $ovfXml.SelectNodes("//*[local-name()='ProductSection']")) {
        $cls  = $ps.GetAttribute('class', 'http://schemas.dmtf.org/ovf/envelope/1')
        $inst = $ps.GetAttribute('instance', 'http://schemas.dmtf.org/ovf/envelope/1')
        foreach ($pr in $ps.SelectNodes("*[local-name()='Property']")) {
            $k = $pr.GetAttribute('key', 'http://schemas.dmtf.org/ovf/envelope/1')
            if (-not $k) { continue }
            (@($cls, $k, $inst) | Where-Object { $_ }) -join '.'
        }
    })
    if (-not $keys) { throw "O descritor $ovfName não tem propriedades OVF." }
    Write-LabLog "OVA com $($keys.Count) propriedades: $($keys -join ', ')"

    $want = [ordered]@{
        '(^|\.)hostname(\.|$)'           = $fqdn
        '(^|\.)ip0(\.|$)'                = $in.Ip
        '(^|\.)netmask0(\.|$)'           = $n.MgmtNetmask
        '(^|\.)gateway(\.|$)'            = $n.MgmtGateway
        '(^|\.)DNS(\.|$)'                = $n.DnsServer
        '(^|\.)domain(\.|$)'             = $cfg.Domain
        '(^|\.)searchpath(\.|$)'         = $cfg.Domain
        '(^|\.)ntp(\.|$)'                = $n.NtpServer
        '(^|\.)ROOT_PASSWORD(\.|$)'      = $in.RootPassword
        '(^|\.)LOCAL_USER_PASSWORD(\.|$)' = $in.AdminPassword
        '(^|\.)VCF_PASSWORD(\.|$)'        = $in.RootPassword
        '(^|\.)BASIC_AUTH_PASSWORD(\.|$)' = $in.AdminPassword
        '(^|\.)BACKUP_PASSWORD(\.|$)'     = $in.AdminPassword
    }
    $props = [ordered]@{}
    foreach ($rx in $want.Keys) {
        $k = $keys | Where-Object { $_ -match $rx } | Select-Object -First 1
        if ($k) { $props[$k] = $want[$rx] }
        else { Write-LabLog "  o OVA não tem propriedade que case com '$rx' - ficou sem esse valor" 'WARN' }
    }
    foreach ($must in '(^|\.)ip0(\.|$)', '(^|\.)ROOT_PASSWORD(\.|$)', '(^|\.)LOCAL_USER_PASSWORD(\.|$)') {
        if (-not ($props.Keys | Where-Object { $_ -match $must })) { throw "Propriedade obrigatória ($must) não existe no OVA. Confira se é o VCF-SDDC-Manager-Appliance 9.1.1." }
    }

    $ovftool = $cfg.Paths.Ovftool
    if ($ovftool -and (Test-Path $ovftool)) {
        Write-LabLog 'Importando o OVA com ovftool + ambiente OVF injetado (alguns minutos)...'
        $h = $cfg.EsxiHost
        $target = "vi://$([uri]::EscapeDataString($h.User)):$([uri]::EscapeDataString($h.Password))@$($h.Address)/"
        $ovfArgs = @('--acceptAllEulas', '--noSSLVerify', '--skipManifestCheck', '--allowExtraConfig', '--X:injectOvfEnv', '--powerOn',
            '--diskMode=thin', "--datastore=$($in.Datastore)", "--network=$($n.MgmtPortgroup)", "--name=$($in.VmName)",
            "--X:logFile=$(Join-Path $cfg.Paths.WorkDir 'ovftool-installer.log')")
        foreach ($k in $props.Keys) { $ovfArgs += "--prop:$k=$($props[$k])" }
        & $ovftool @ovfArgs "$ova" $target
        if ($LASTEXITCODE) { throw 'ovftool falhou - veja ovftool-installer.log no WorkDir.' }
        $vm = Get-LabVm $in.VmName
    } else {
        Write-LabLog "ovftool não encontrado ($ovftool): importando com Import-VApp + guestinfo.ovfEnv" 'WARN'
        $vmhost = Get-VMHost | Select-Object -First 1
        try {
            $vm = Import-VApp -Source $ova -VMHost $vmhost -Datastore (Get-Datastore $in.Datastore) -Name $in.VmName -DiskStorageFormat Thin -Force
        } catch {
            # PowerCLI no Linux falha com ESXi direto ("Invalid URI", URL de NFC com '*'): importa com o govc
            Write-LabLog "Import-VApp falhou ($($_.Exception.Message)): importando com o govc" 'WARN'
            Import-LabOvaGovc -Config $cfg -Ova $ova -Name $in.VmName -Datastore $in.Datastore -Portgroup $n.MgmtPortgroup
            $vm = Get-LabVm $in.VmName
            if (-not $vm) { throw "O govc não criou a VM $($in.VmName)." }
        }
        $xmlProps = ($props.GetEnumerator() | ForEach-Object {
            "<Property oe:key=`"$($_.Key)`" oe:value=`"$([System.Security.SecurityElement]::Escape([string]$_.Value))`"/>"
        }) -join ''
        $ovfEnv = '<?xml version="1.0" encoding="UTF-8"?>' +
            '<Environment xmlns="http://schemas.dmtf.org/ovf/environment/1" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ' +
            'xmlns:oe="http://schemas.dmtf.org/ovf/environment/1" xmlns:ve="http://www.vmware.com/schema/ovfenv" oe:id="">' +
            '<PlatformSection><Kind>VMware ESXi</Kind><Locale>en</Locale></PlatformSection>' +
            "<PropertySection>$xmlProps</PropertySection></Environment>"
        New-AdvancedSetting -Entity $vm -Name 'guestinfo.ovfEnv' -Value $ovfEnv -Force -Confirm:$false | Out-Null
        Get-NetworkAdapter -VM $vm | Select-Object -First 1 | Set-NetworkAdapter -Portgroup (Get-VirtualPortGroup -Standard -Name $n.MgmtPortgroup) -StartConnected $true -Confirm:$false | Out-Null
        if ($in.MemoryGB) { Set-VM -VM $vm -MemoryGB $in.MemoryGB -Confirm:$false | Out-Null }
        Start-VM -VM $vm | Out-Null
    }
    if (-not $vm) { throw "A VM $($in.VmName) não apareceu no ESXi depois da importação." }
    Write-LabLog "Installer importado e ligado ($($vm.NumCpu) vCPU, $($vm.MemoryGB) GB)" 'OK'
    $fresh = $true
}

$vm = Get-LabVm $in.VmName
if ($vm.PowerState -ne 'PoweredOn') { Start-VM -VM $vm | Out-Null }

Write-LabLog 'Aguardando a interface do VCF Installer (primeiro boot: 10-20 min)...'
function Wait-InstallerApi([int]$Minutes = 30) {
    # A página de login responde antes dos serviços: 502/503 = ainda subindo. Só 401/403 indicam senha errada.
    Wait-VcfInstallerUi -Server $in.Ip -TimeoutMin 45 | Out-Null
    $deadline = (Get-Date).AddMinutes($Minutes); $lastMsg = ''
    while ($true) {
        try { Get-VcfToken -Server $in.Ip -User $in.AdminUser -Password $in.AdminPassword -Force | Out-Null; return }
        catch {
            $code = $_.Exception.Response.StatusCode.value__
            if ($code -in 401, 403) { throw "Login admin@local recusado (HTTP $code). A senha do OVF (Installer.AdminPassword) não foi aplicada? Veja a console da VM." }
            if ((Get-Date) -gt $deadline) { throw "Os serviços do Installer não responderam em $Minutes min (último erro: $($_.Exception.Message))." }
            $msg = "  serviços do Installer ainda subindo (HTTP $code) - aguardando..."
            if ($msg -ne $lastMsg) { Write-LabLog $msg; $lastMsg = $msg }
            Start-Sleep -Seconds 30
        }
    }
}
Wait-InstallerApi -Minutes 30
Write-LabLog "VCF Installer respondendo: https://$fqdn/vcf-installer-ui" 'OK'

# ---------------- ajustes de lab no domainmanager (pelo VMware Tools, como root)
function Invoke-Guest([string]$Cmd) {
    Invoke-LabGuestBash -VM (Get-LabVm $in.VmName) -User 'root' -Password $in.RootPassword -Script $Cmd
}
$propFile = '/etc/vmware/vcf/domainmanager/application.properties'
if ($cfg.Vcf.VsanMode -eq 'ESA' -and -not $in.DomainManagerProperties.Contains('vsan.esa.sddc.managed.disk.claim')) {
    # ESA em disco virtual (fora da HCL): o SDDC Manager reivindica os discos sozinho (lista do William Lam)
    $in.DomainManagerProperties['vsan.esa.sddc.managed.disk.claim'] = 'true'
}
$marker   = "$($in.Hostname)-lab-tuning"
$applied  = $false
$applied = Test-LabGuestFile -VM (Get-LabVm $in.VmName) -User 'root' -Password $in.RootPassword -Path "/root/.$marker"
if ($in.DomainManagerProperties.Count -and -not $applied) {
    $lines = foreach ($k in $in.DomainManagerProperties.Keys) {
        "sed -i '/^$([regex]::Escape($k))\s*=/d' $propFile; echo '$k=$($in.DomainManagerProperties[$k])' >> $propFile"
    }
    $script = ($lines -join '; ') + "; touch /root/.$marker; echo y | /opt/vmware/vcf/operationsmanager/scripts/cli/sddcmanager_restart_services.sh"
    Write-LabLog "Aplicando $($in.DomainManagerProperties.Count) ajuste(s) de lab e reiniciando os serviços do Installer..."
    try { Invoke-Guest $script | Out-Null }
    catch { throw "Não consegui rodar comando no appliance pelo VMware Tools/Invoke-VMScript ($($_.Exception.Message)). Confira a senha de root (Installer.RootPassword)." }
    Start-Sleep -Seconds 60
    Wait-InstallerApi -Minutes 20
    Write-LabLog 'Ajustes aplicados:' 'OK'
    $in.DomainManagerProperties.GetEnumerator() | ForEach-Object { Write-LabLog "    $($_.Key)=$($_.Value)" }
} elseif ($applied) {
    Write-LabLog 'Ajustes de lab já aplicados anteriormente' 'OK'
}

# ---------------- VmwareCompatibilityData.json (KB 450175)
$compatSrc = Join-Path $cfg.Depot.Root 'PROD\COMP\SDDC_MANAGER_VCF\Compatibility\VmwareCompatibilityData.json'
if (Test-Path $compatSrc) {
    $dst = '/nfs/vmware/vcf/nfs-mount/compatibility/VmwareCompatibilityData.json'
    Invoke-Guest 'mkdir -p /nfs/vmware/vcf/nfs-mount/compatibility' | Out-Null
    Copy-LabFileToGuest -VM (Get-LabVm $in.VmName) -User 'root' -Password $in.RootPassword -Source $compatSrc -Destination $dst
    Invoke-Guest 'chown -R vcf_lcm:vcf /nfs/vmware/vcf/nfs-mount/compatibility' | Out-Null
    Write-LabLog 'VmwareCompatibilityData.json copiado para o appliance (KB 450175)' 'OK'
} else {
    Write-LabLog "Sem VmwareCompatibilityData.json no depot: se o deploy parar em 'Configure Base Install Image Repository', veja o KB 450175." 'WARN'
}

if ($SkipBundles) { Write-LabLog 'Depot e bundles não alterados (-SkipBundles)' 'OK'; exit 0 }

# ---------------- depot offline + bundles
$v = $cfg.Vcf
$depotUrl = "http://$($cfg.Depot.BindIp):$($cfg.Depot.Port)"
Write-LabLog "Conectando o Installer ao depot $depotUrl (IP: o 9.1.1 recusa .lab - KB 456037)" 'STEP'
try { Invoke-WebRequest -Uri "$depotUrl/PROD/metadata/manifest/v1/vcfManifest.json" -Method Head -UseBasicParsing -TimeoutSec 10 | Out-Null }
catch { throw "O depot não responde em $depotUrl ($($_.Exception.Message)). Rode a etapa 3." }

Set-VcfOfflineDepot -Server $in.Ip -Cred $cred -Url $depotUrl
Write-LabLog 'Depot cadastrado; sincronizando metadata...'
Sync-VcfDepot -Server $in.Ip -Cred $cred -TimeoutMin 30 | Out-Null
Write-LabLog 'Depot sincronizado' 'OK'

$prefFile = Join-Path $cfg.Paths.WorkDir 'depot-versoes.json'
$pref = @{}
if (Test-Path $prefFile) { (Get-Content $prefFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $pref[$_.Name] = "$($_.Value)" } }
else { Write-LabLog "Sem $prefFile (rode a etapa 3): usando a versão mais nova oferecida de cada componente" 'WARN' }
$bundles = Get-VcfReleaseBundles -Server $in.Ip -Cred $cred -Sku $v.Sku -Version $v.Version -Preferred $pref
$release = $bundles['__release']; $bundles.Remove('__release')
$chosen  = $bundles['__chosen'];  $bundles.Remove('__chosen')
Write-LabLog 'Versões escolhidas (as completas no depot):'
foreach ($k in $chosen.Keys) { Write-LabLog ("    {0,-34} {1}" -f $k, $chosen[$k]) }
if ($release -ne $v.Version) { Write-LabLog "O depot oferece a release $release (config: $($v.Version)); usando $release no download e no JSON" 'WARN' }
$release | Set-Content (Join-Path $cfg.Paths.WorkDir 'release-version.txt')
Write-LabLog "Componentes de INSTALL da $($v.Sku) $($release): $($bundles.Keys -join ', ')"
$requested = @()
foreach ($c in $bundles.Keys) {
    if ($v.Sku -eq 'VVF' -and $c -eq 'SDDC_MANAGER') { continue }
    if (-not $v.Automation.Deploy -and $c -match 'VRA|VCF_AUTOMATION|VCD_MIGRATION') { Write-LabLog "  $c pulado (VCF Automation é Day-N)"; continue }
    Write-LabLog "  baixando $c $($chosen[$c]) ($($bundles[$c]))"
    Start-VcfBundleDownload -Server $in.Ip -Cred $cred -BundleId $bundles[$c]
    $requested += $bundles[$c]
}

$deadline = (Get-Date).AddHours(3); $last = ''; $retried = @{}
while ($true) {
    Start-Sleep -Seconds 60
    # só os bundles pedidos nesta execução (um FAILED antigo de outra versão não conta)
    $wanted = $requested
    try { $st = @(Get-VcfDownloadStatus -Server $in.Ip -Cred $cred -Version $release | Where-Object { $_.bundleId -in $wanted }) }
    catch { Write-LabLog "  Installer ocupado, sem resposta agora ($($_.Exception.Message)) - tentando de novo em 1 min" 'WARN'; continue }
    $sum = ($st | Group-Object downloadStatus | ForEach-Object { "$($_.Name)=$($_.Count)" }) -join ' '
    if ($sum -ne $last) { Write-LabLog "  bundles: $sum"; $last = $sum }
    $failed = @($st | Where-Object downloadStatus -eq 'FAILED')
    foreach ($f in $failed) {
        $retried[$f.bundleId] = 1 + ($retried[$f.bundleId] ?? 0)
        if ($retried[$f.bundleId] -gt 3) {
            throw "Bundle $($f.componentType) falhou 3 vezes. Confira em $($cfg.Depot.Root)/PROD/COMP se os arquivos dessa versão estão lá (depot-versoes.json no WorkDir) e o log /var/log/vmware/vcf/lcm/lcm.log no Installer."
        }
        Write-LabLog "  $($f.componentType) $($f.version) falhou - tentando de novo ($($retried[$f.bundleId])/3)" 'WARN'
        try { Start-VcfBundleDownload -Server $in.Ip -Cred $cred -BundleId $f.bundleId }
        catch { Write-LabLog "    nova tentativa recusada: $($_.Exception.Message)" 'WARN' }
    }
    $pending = @($st | Where-Object { $_.downloadStatus -in 'INPROGRESS', 'SCHEDULED', 'VALIDATING', 'FAILED' })
    if ($st.Count -and -not $pending.Count) { break }
    if ((Get-Date) -gt $deadline) { throw 'Download/validação dos bundles não terminou em 3 h.' }
}
Write-LabLog "Bundles da $release baixados e validados no Installer" 'OK'
$st | Sort-Object componentType | Format-Table componentType, version, downloadStatus -AutoSize | Out-String -Width 220 | Write-Host

exit 0
