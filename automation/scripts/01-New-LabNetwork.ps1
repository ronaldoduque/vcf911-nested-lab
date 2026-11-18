#Requires -Version 7.2
<#
.SYNOPSIS
    Rede do lab no ESXi físico + preparo da svc01 (DNS/NTP/firewall/rota).
.DESCRIPTION
    No ESXi (PowerCLI):
      1. Confere/cria os vSwitches internos e port groups do lab (o host/esxi-host-setup.sh rede faz o
         mesmo; aqui garante): MTU jumbo, promíscuo + forged transmits + MAC changes (nested)
      2. Liga o autostart e coloca a svc01 em primeiro lugar
    Na svc01 (Ubuntu): confere os IPs do lab, a rota e os serviços (configurados pelo setup-svc01.sh)
#>
[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'))

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'EsxiPlatform.psm1') -Force
Assert-Admin
$cfg = Get-LabConfig -Path $ConfigPath
$n = $cfg.Network

# ---------------------------------------------------------------- ESXi
Write-LabLog "Port groups do lab no ESXi $($cfg.EsxiHost.Address)" 'STEP'
Connect-LabEsxi -Config $cfg | Out-Null
$vmhost = Get-VMHost | Select-Object -First 1
$plan = @(
    @{ Switch = 'vSwitch-VCF-MGMT'; Pg = $n.MgmtPortgroup;  Vlan = 0 }
    @{ Switch = 'vSwitch-VCF-VSAN'; Pg = $n.VsanPortgroup;  Vlan = 0 }
    @{ Switch = 'vSwitch-VCF-NSX';  Pg = $n.TrunkPortgroup; Vlan = 4095 }
)
foreach ($p in $plan) {
    $pg = Get-VirtualPortGroup -VMHost $vmhost -Standard -Name $p.Pg -ErrorAction SilentlyContinue
    if ($pg) {
        $vs = Get-VirtualSwitch -VMHost $vmhost -Standard -Name $pg.VirtualSwitchName
    } else {
        $vs = Get-VirtualSwitch -VMHost $vmhost -Standard -Name $p.Switch -ErrorAction SilentlyContinue
        if (-not $vs) { $vs = New-VirtualSwitch -VMHost $vmhost -Name $p.Switch -Mtu $n.JumboMtu -NumPorts 128 }
        $pg = New-VirtualPortGroup -VirtualSwitch $vs -Name $p.Pg -VLanId $p.Vlan
        Write-LabLog "  criado $($p.Switch) / $($p.Pg)" 'OK'
    }
    if ($vs.Mtu -lt $n.JumboMtu) { $vs = Set-VirtualSwitch -VirtualSwitch $vs -Mtu $n.JumboMtu -Confirm:$false }
    if ($pg.VLanId -ne $p.Vlan) { $pg = Set-VirtualPortGroup -VirtualPortGroup $pg -VLanId $p.Vlan }
    $sec = Get-SecurityPolicy -VirtualSwitch $vs
    if (-not ($sec.AllowPromiscuous -and $sec.ForgedTransmits -and $sec.MacChanges)) {
        $sec | Set-SecurityPolicy -AllowPromiscuous $true -ForgedTransmits $true -MacChanges $true | Out-Null
    }
    # port group sem sobrescrever a política do vSwitch
    Get-SecurityPolicy -VirtualPortGroup $pg | Set-SecurityPolicy -AllowPromiscuousInherited $true -ForgedTransmitsInherited $true -MacChangesInherited $true | Out-Null
    $nics = @($vs.Nic)
    if ($nics.Count) { Write-LabLog "  $($vs.Name) tem placa física ($($nics -join ', ')) - o lab espera um switch interno, sem uplink" 'WARN' }
    Write-LabLog ("  {0,-18} {1,-18} VLAN {2,-4} MTU {3}  promíscuo/forged/MAC ok" -f $vs.Name, $p.Pg, $p.Vlan, $vs.Mtu) 'OK'
}
if (-not (Get-VirtualPortGroup -VMHost $vmhost -Standard -Name $n.WanPortgroup -ErrorAction SilentlyContinue)) {
    Write-LabLog "Port group da rede de casa '$($n.WanPortgroup)' não existe (Network.WanPortgroup)" 'WARN'
}
$svc = Get-LabVm $cfg.Svc01.VmName
if ($svc) { Set-LabVmAutostart -VM $svc -Order 1 -DelaySec 180; Write-LabLog "Autostart: $($svc.Name) primeiro (180 s antes do próximo)" 'OK' }
else { Write-LabLog "VM $($cfg.Svc01.VmName) não encontrada no ESXi (Svc01.VmName) - autostart dela não configurado" 'WARN' }

# ---------------------------------------------------------------- svc01 (Ubuntu): só confere
# A rede, o NAT, o DNS, o NTP e o nginx da svc01 são configurados uma vez pelo svc01/setup-svc01.sh.
Write-LabLog 'Rede da svc01' 'STEP'
$ips = Get-LabLocalIps
$bad = 0
foreach ($ip in $n.HostAdapterIp, $n.Vlans.VSAN.Gateway) {
    if ($ips -contains $ip) { Write-LabLog "  $ip presente" 'OK' } else { Write-LabLog "  $ip ausente nesta máquina" 'ERROR'; $bad++ }
}
$route = (& ip route show $n.LabSupernet 2>$null) -join ' '
if ($route -match [regex]::Escape($n.MgmtGateway)) { Write-LabLog "  rota $($n.LabSupernet) via $($n.MgmtGateway)" 'OK' }
else { Write-LabLog "  rota $($n.LabSupernet) via $($n.MgmtGateway) ausente (ip route)" 'WARN' }
foreach ($svcName in 'named', 'chrony', 'nginx') {
    $st = (& systemctl is-active $svcName 2>$null) -join ''
    if ($st -eq 'active') { Write-LabLog "  $svcName ativo" 'OK' } else { Write-LabLog "  $svcName '$st'" 'ERROR'; $bad++ }
}
if ($bad) { throw "A svc01 não está pronta: rode de novo sudo bash svc01/setup-svc01.sh (confira os MACs no topo dele e no lab-config.psd1)." }
Write-LabLog 'Rede do lab pronta' 'OK'
exit 0
