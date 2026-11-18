#Requires -Version 7.2
<#
.SYNOPSIS
    Verifica se a svc01 e o ESXi físico estão prontos para montar o lab VCF 9.1.1 (nada é criado aqui).
.DESCRIPTION
    - PowerShell 7 como root (dentro da svc01 Ubuntu)
    - Módulos Posh-SSH e PowerCLI (VCF.PowerCLI); dig, BIND9, nginx, chrony ativos; ovftool (opcional)
    - IPs da svc01, HD de dados montado, ISOs/OVA e depot presentes
    - Senhas dentro das regras do VCF 9.1
    - ESXi: versão 8.0 U3+, licença (avaliação com dias restantes x gratuita, que bloqueia a API),
      CPU (Broadwell é Discontinued no ESX 9.x), Memory Tiering, port groups, datastores e espaço
    - RAM (incluindo o tier de NVMe) e IPs da svc01
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'),
    [switch]$InstallMissingModules
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
$cfg = Get-LabConfig -Path $ConfigPath

$fail = 0; $warn = 0
function Pass([string]$m) { Write-LabLog $m 'OK' }
function Fail([string]$m) { Write-LabLog $m 'ERROR'; $script:fail++ }
function Warn([string]$m) { Write-LabLog $m 'WARN'; $script:warn++ }

Write-LabLog "Preflight do lab '$($cfg.LabName)' - domínio $($cfg.Domain)" 'STEP'

# --- Execução
try { Assert-Admin; Pass 'PowerShell em modo Administrador' } catch { Fail $_.Exception.Message }
Pass "PowerShell $($PSVersionTable.PSVersion)"

# --- Ferramentas (svc01 Ubuntu)
if (-not $IsLinux) { Warn 'Este pacote foi feito para rodar na svc01 Ubuntu (svc01/setup-svc01.sh).' }
foreach ($mod in 'Posh-SSH', 'VMware.VimAutomation.Core') {
    if (Get-Module -ListAvailable -Name $mod) { Pass "Módulo $mod disponível" }
    elseif ($InstallMissingModules) {
        $pkg = if ($mod -eq 'Posh-SSH') { 'Posh-SSH' } else { 'VCF.PowerCLI' }
        Install-Module $pkg -Scope AllUsers -Force -AllowClobber
        Pass "Módulo $pkg instalado"
    }
    else { Fail "Módulo $mod ausente (rode com -InstallMissingModules ou svc01/setup-svc01.sh)" }
}
foreach ($c in 'dig', 'named-checkzone', 'nginx', 'tar', 'chronyc') {
    if (Get-Command $c -ErrorAction SilentlyContinue) { Pass "Comando $c" } else { Fail "Comando $c ausente (svc01/setup-svc01.sh instala)" }
}
foreach ($svcName in 'named', 'chrony', 'nginx') {
    $st = (& systemctl is-active $svcName 2>$null) -join ''
    if ($st -eq 'active') { Pass "Serviço $svcName ativo" } else { Fail "Serviço $svcName está '$st' (systemctl status $svcName)" }
}
$ntp = Test-LabNtp -Server $cfg.Network.NtpServer
if ($ntp.Ok) { Pass "NTP da svc01 responde (stratum $($ntp.Stratum))" } else { Fail "NTP em $($cfg.Network.NtpServer) não respondeu: $($ntp.Error) (chronyc sources)" }
if ($cfg.Paths.Ovftool -and (Test-Path $cfg.Paths.Ovftool)) { Pass "ovftool: $($cfg.Paths.Ovftool)" }
else { Warn "ovftool não encontrado ($($cfg.Paths.Ovftool)): a etapa 6 usa Import-VApp + guestinfo.ovfEnv" }
$ips = Get-LabLocalIps
foreach ($ip in $cfg.Network.HostAdapterIp, $cfg.Network.Vlans.VSAN.Gateway) {
    if ($ips -contains $ip) { Pass "svc01 com o IP $ip" } else { Fail "svc01 sem o IP $ip (svc01/setup-svc01.sh configura pelas MACs Svc01.*Mac)" }
}
$mnt = $cfg.Svc01.DataMount
if ((& findmnt -n $mnt 2>$null)) { Pass "HD de dados montado em $mnt" } else { Fail "HD de dados não está montado em $mnt (findmnt $mnt; setup-svc01.sh monta pelo fstab)" }
$wdFree = [math]::Round((Get-PSDrive -PSProvider FileSystem | Where-Object { $cfg.Paths.WorkDir.StartsWith($_.Root) } | Sort-Object { $_.Root.Length } -Descending | Select-Object -First 1).Free / 1GB)
if ($wdFree -lt 10) { Warn "Só $wdFree GB livres no disco do WorkDir ($($cfg.Paths.WorkDir))" } else { Pass "WorkDir $($cfg.Paths.WorkDir) com $wdFree GB livres" }

# --- Mídias
foreach ($k in 'IsoEsxi', 'IsoVyos', 'OvaVcfInstaller') {
    $p = $cfg.Paths.$k
    if ($p -and (Test-Path $p)) { Pass "$k : $p ($([math]::Round((Get-Item $p).Length/1GB,2)) GB)" } else { Fail "$k não encontrado: $p" }
}
$ver = $cfg.Vcf.Version.Substring(0, 5)   # 9.1.1
if ($cfg.Paths.OvaVcfInstaller -and $cfg.Paths.OvaVcfInstaller -notmatch [regex]::Escape($ver)) { Warn "O OVA do VCF Installer não contém $ver no nome - use o Installer da mesma versão do deploy (KB 416861)." }
if ($cfg.Paths.IsoEsxi -and $cfg.Paths.IsoEsxi -notmatch [regex]::Escape($ver)) { Warn "A ISO do ESX não contém $ver no nome - confira a versão." }

# --- Depot (o completo/incompleto é conferido na etapa 3)
$d = $cfg.Depot
$manifest = Join-Path $d.Root 'PROD/metadata/manifest/v1/vcfManifest.json'
if (Test-Path $manifest) { Pass "Depot: $($d.Root)" } else { Fail "Depot sem $manifest" }
if ($d.BindIp -ne $cfg.Network.HostAdapterIp) { Warn "Depot.BindIp ($($d.BindIp)) diferente do IP da svc01 no lab ($($cfg.Network.HostAdapterIp))." }

# --- vSAN
if ($cfg.Vcf.VsanMode -notin 'OSA', 'ESA') { Fail "Vcf.VsanMode precisa ser 'OSA' ou 'ESA' (está '$($cfg.Vcf.VsanMode)')" }
elseif ($cfg.Vcf.VsanMode -eq 'ESA') { Warn 'vSAN ESA: discos em NVMe virtual (no ESXi físico é estável; o lab Workstation testou só OSA).' }
else { Pass "vSAN OSA: cache $($cfg.Esxi.CacheDiskGB) GB + capacidade $($cfg.Esxi.CapacityDiskGB) GB por host (thin)" }

# --- Senhas
$v = $cfg.Vcf
$pw = @(
    @{ N = 'Installer.AdminPassword';   V = $cfg.Installer.AdminPassword;   Min = 15; Max = 127 }
    @{ N = 'Installer.RootPassword';    V = $cfg.Installer.RootPassword;    Min = 15; Max = 127 }
    @{ N = 'Nsx.RootPassword';          V = $v.Nsx.RootPassword;            Min = 12; Max = 127 }
    @{ N = 'Nsx.AdminPassword';         V = $v.Nsx.AdminPassword;           Min = 12; Max = 127 }
    @{ N = 'Nsx.AuditPassword';         V = $v.Nsx.AuditPassword;           Min = 12; Max = 127 }
    @{ N = 'Vcenter.RootPassword';      V = $v.Vcenter.RootPassword;        Min = 8;  Max = 20 }
    @{ N = 'Vcenter.SsoPassword';       V = $v.Vcenter.SsoPassword;         Min = 8;  Max = 20 }
    @{ N = 'SddcManager.LocalPassword'; V = $v.SddcManager.LocalPassword;   Min = 15; Max = 127 }
    @{ N = 'SddcManager.RootPassword';  V = $v.SddcManager.RootPassword;    Min = 15; Max = 127 }
    @{ N = 'Operations.AdminPassword';  V = $v.Operations.AdminPassword;    Min = 15; Max = 127 }
    @{ N = 'ManagementServices.SystemPassword'; V = $v.ManagementServices.SystemPassword; Min = 15; Max = 127 }
    @{ N = 'Esxi.Password';             V = $cfg.Esxi.Password;             Min = 8;  Max = 40 }
)
foreach ($p in $pw) {
    $val = [string]$p.V
    $complex = ($val -cmatch '[A-Z]') -and ($val -cmatch '[a-z]') -and ($val -match '\d') -and ($val -match '[^A-Za-z0-9]')
    if ($val.Length -lt $p.Min -or $val.Length -gt $p.Max) { Fail "$($p.N): precisa ter entre $($p.Min) e $($p.Max) caracteres (tem $($val.Length))" }
    elseif (-not $complex) { Fail "$($p.N): precisa de maiúscula, minúscula, número e caractere especial" }
    else { Pass "$($p.N): ok" }
}

# --- Plano de IPs: nomes do VCFMS fora do pool e sem IP repetido (KB 440223)
$m = $v.ManagementServices
$pool = @(Get-IpRange -Start $m.PoolStart -End $m.PoolEnd)
$recs = Get-LabDnsRecords -Config $cfg
$dup = $recs | Group-Object Ip | Where-Object Count -gt 1
foreach ($g in $dup) { Fail "IP $($g.Name) repetido em: $($g.Group.Name -join ', ')" }
$inPool = $recs | Where-Object { $_.Ip -in $pool }
foreach ($r in $inPool) { Fail "$($r.Name) ($($r.Ip)) está dentro do pool do VCFMS ($($m.PoolStart)-$($m.PoolEnd))" }
if ($v.Automation.IpPool | Where-Object { $_ -in $pool }) { Fail 'O pool do VCF Automation cruza com o pool do VCFMS' }
if ($pool.Count -lt 12) { Warn "Pool do VCFMS com $($pool.Count) IPs; o recomendado é uma /27 (32), para os serviços Day-N." }
if (-not $dup -and -not $inPool) { Pass "Plano de IPs: $($recs.Count) nomes únicos, pool do VCFMS com $($pool.Count) IPs livres de conflito" }

# --- ESXi físico
try {
    Import-Module (Join-Path $PSScriptRoot 'EsxiPlatform.psm1') -Force
    Connect-LabEsxi -Config $cfg | Out-Null
    $vmhost = Get-VMHost | Select-Object -First 1
    Pass "ESXi $($cfg.EsxiHost.Address): $($vmhost.Version) build $($vmhost.Build)"
    if ([version]$vmhost.Version -lt [version]$cfg.EsxiHost.MinVersion) { Fail "ESXi $($vmhost.Version) < $($cfg.EsxiHost.MinVersion) (Memory Tiering precisa do 8.0 U3)" }

    $lic = Get-LabEsxiLicense
    if ($lic.Free) { Fail "Licença '$($lic.Name)' (gratuita): API só leitura e máximo de 8 vCPU por VM - a automação não funciona. Use o modo de avaliação (reinstale) ou uma licença paga/VMUG." }
    elseif ($lic.Evaluation) {
        if ($null -ne $lic.DaysLeft -and $lic.DaysLeft -lt 15) { Warn "ESXi em avaliação: faltam $($lic.DaysLeft) dia(s). Depois disso nenhuma VM liga até aplicar uma licença." }
        else { Pass "ESXi em avaliação (todos os recursos)$(if ($null -ne $lic.DaysLeft) { ": faltam $($lic.DaysLeft) dias" })" }
    } else { Pass "Licença: $($lic.Name)" }

    $cpuModel = $vmhost.ProcessorType
    if ($cpuModel -match 'E5-26\d\d v4|E5-16\d\d v4|E7-\d{4} v4') {
        if ($cfg.Esxi.LegacyCpu -or $cfg.Esxi.CpuidMask) { Warn "CPU '$cpuModel' é Broadwell-EP (Discontinued no ESX 9.x). CpuidMask ligado: os ESX nested instalam como Cascade Lake, fora de suporte." }
        else { Fail "CPU '$cpuModel' é Broadwell-EP: ligue Esxi.CpuidMask/LegacyCpu no config." }
    } else { Pass "CPU: $cpuModel" }

    # memória: com tiering, o host informa RAM + NVMe
    $esxcli = Get-EsxCli -VMHost $vmhost -V2
    $tierOn = $false
    try { $tierOn = [bool](@($esxcli.system.settings.kernel.list.Invoke(@{ option = 'MemoryTiering' }))[0].Configured -match 'TRUE') } catch {}
    $memGB = [math]::Round($vmhost.MemoryTotalGB)
    if ($tierOn) { Pass "Memory Tiering ligado; memória total do host $memGB GB" }
    else { Warn "Memory Tiering desligado (host com $memGB GB). Rode host/esxi-host-setup.sh tiering e reinicie o ESXi." }
    $totalVmRamGB = $cfg.Esxi.MemoryGB * $cfg.Esxi.Hosts.Count + $cfg.Installer.MemoryGB + [math]::Ceiling($cfg.VyOS.MemoryMB / 1024) + [int]$cfg.Svc01.MemoryGB
    if ($totalVmRamGB -gt ($memGB - 8)) { Fail "As VMs do lab (+svc01) somam $totalVmRamGB GB e o host tem $memGB GB. Ligue o tiering, aumente TierNvmePct ou reduza Esxi.MemoryGB." }
    else { Pass "RAM: VMs do lab ~$totalVmRamGB GB de $memGB GB do host" }

    # port groups
    foreach ($pg in $cfg.Network.MgmtPortgroup, $cfg.Network.VsanPortgroup, $cfg.Network.TrunkPortgroup, $cfg.Network.WanPortgroup) {
        if (Get-VirtualPortGroup -VMHost $vmhost -Standard -Name $pg -ErrorAction SilentlyContinue) { Pass "Port group $pg" }
        else { Warn "Port group $pg não existe (host/esxi-host-setup.sh rede ou etapa 1)" }
    }

    # datastores e espaço (thin: uso real esperado + arquivo de swap .vswp do tamanho da RAM da VM)
    $need = @{}; $max = @{}
    foreach ($h in $cfg.Esxi.Hosts) {
        $need[$h.Datastore] = ($need[$h.Datastore] ?? 0) + 350 + $cfg.Esxi.MemoryGB
        $max[$h.Datastore]  = ($max[$h.Datastore] ?? 0) + $cfg.Esxi.BootDiskGB + $cfg.Esxi.CapacityDiskGB + $cfg.Esxi.MemoryGB + $(if ($cfg.Vcf.VsanMode -eq 'ESA') { 0 } else { $cfg.Esxi.CacheDiskGB })
    }
    $need[$cfg.Installer.Datastore] = ($need[$cfg.Installer.Datastore] ?? 0) + 150 + $cfg.Installer.MemoryGB
    $need[$cfg.VyOS.Datastore] = ($need[$cfg.VyOS.Datastore] ?? 0) + 12
    $need[$cfg.EsxiHost.IsoDatastore] = ($need[$cfg.EsxiHost.IsoDatastore] ?? 0) + 5
    foreach ($dsName in $need.Keys) {
        $ds = Get-Datastore -Name $dsName -ErrorAction SilentlyContinue
        if (-not $ds) { Fail "Datastore $dsName não existe (host/esxi-host-setup.sh datastores)"; continue }
        $free = [math]::Round($ds.FreeSpaceGB)
        if ($free -lt $need[$dsName]) { Fail "$dsName com $free GB livres; estimativa do lab nele: $($need[$dsName]) GB" }
        elseif ($max[$dsName] -and $free -lt $max[$dsName]) { Warn "$dsName : $free GB livres; uso esperado $($need[$dsName]) GB, se os discos thin enchessem: $($max[$dsName]) GB" }
        else { Pass "$dsName : $free GB livres (estimativa $($need[$dsName]) GB)" }
    }
} catch { Fail "ESXi: $($_.Exception.Message)" }

# --- Resultado
Write-LabLog "Preflight terminado: $fail falha(s), $warn aviso(s)" ($(if ($fail) { 'ERROR' } elseif ($warn) { 'WARN' } else { 'OK' }))
if ($fail) { exit 1 }

exit 0
