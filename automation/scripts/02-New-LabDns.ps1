#Requires -Version 7.2
<#
.SYNOPSIS
    Gera as zonas do lab no BIND9 da svc01 (A + PTR de todos os nomes) e confere a resolução.
.DESCRIPTION
    - Zona direta <Domain> e zona reversa da rede de gerência (ex.: 10.10.52.in-addr.arpa)
      em Svc01.BindDir, mais o arquivo de zonas incluído pelo named.conf.local
    - Nomes em minúsculas (o bootstrap do VCFMS falha com maiúsculas - KB 445179)
    - Serial novo a cada execução, named-checkzone antes de recarregar (idempotente)
    - Confere direta e reversa de cada nome contra o DNS do lab (dig)
    O VCF Installer reprova a validação se QUALQUER ESX/appliance falhar na resolução direta ou reversa.
.PARAMETER Remove
    Regrava as zonas só com a svc01 (tira os registros do lab). Usado pelo 99-Remove-Lab.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'),
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Assert-Admin
$cfg = Get-LabConfig -Path $ConfigPath
$n = $cfg.Network

$zone    = $cfg.Domain.ToLower()
$revZone = Get-ReverseZoneName $n.MgmtCidr
$all     = @(Get-LabDnsRecords -Config $cfg)
$svcName = $cfg.Svc01.VmName.ToLower()
$records = if ($Remove) { @($all | Where-Object Name -eq $svcName) } else { $all }
$bindDir = $cfg.Svc01.BindDir
$serial  = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

Write-LabLog "DNS (BIND9): zona $zone / reversa $revZone - $($records.Count) registros" 'STEP'
foreach ($c in 'named-checkzone', 'named-checkconf', 'dig') {
    if (-not (Get-Command $c -ErrorAction SilentlyContinue)) { throw "$c não encontrado (svc01/setup-svc01.sh instala o bind9 e o bind9-utils)." }
}

$soa = @"
`$TTL 3600
@   IN SOA $svcName.$zone. hostmaster.$zone. ( $serial 3600 900 604800 300 )
    IN NS  $svcName.$zone.
"@
$fwd = [System.Text.StringBuilder]::new(); [void]$fwd.AppendLine($soa)
$rev = [System.Text.StringBuilder]::new(); [void]$rev.AppendLine($soa)
foreach ($r in $records) {
    [void]$fwd.AppendLine(('{0,-16} IN A   {1}' -f $r.Name, $r.Ip))
    [void]$rev.AppendLine(('{0,-16} IN PTR {1}.{2}.' -f $r.Ip.Split('.')[-1], $r.Name, $zone))
}
# a svc01 precisa resolver na zona direta mesmo com -Remove (é o NS da zona)
if (-not ($records | Where-Object Name -eq $svcName)) { [void]$fwd.AppendLine(('{0,-16} IN A   {1}' -f $svcName, $n.HostAdapterIp)) }

$fwdFile = Join-Path $bindDir "db.$zone"
$revFile = Join-Path $bindDir "db.$revZone"
Write-LabTextFile -Path $fwdFile -Content $fwd.ToString()
Write-LabTextFile -Path $revFile -Content $rev.ToString()
$zonesConf = Join-Path $bindDir 'named.conf.lab'
Write-LabTextFile -Path $zonesConf -Content @"
// gerado pela etapa 2 da automação do lab VCF 9.1.1
zone "$zone" { type master; file "$fwdFile"; };
zone "$revZone" { type master; file "$revFile"; };
"@
Invoke-LabNative chgrp @('-R', 'bind', $bindDir) | Out-Null
Invoke-LabNative chmod @('-R', 'g+r,o+r', $bindDir) | Out-Null

$local = '/etc/bind/named.conf.local'
$inc = "include `"$zonesConf`";"
if (-not (Select-String -Path $local -SimpleMatch $inc -Quiet)) { Add-Content -Path $local -Value $inc }

Invoke-LabNative named-checkzone @($zone, $fwdFile) -Check | Out-Null
Invoke-LabNative named-checkzone @($revZone, $revFile) -Check | Out-Null
Invoke-LabNative named-checkconf -Check | Out-Null
Invoke-LabNative systemctl @('reload-or-restart', 'named') -Check | Out-Null
Start-Sleep -Seconds 2
foreach ($r in $records) { Write-LabLog ("{0,-28} {1,-14} {2}" -f "$($r.Name).$zone", $r.Ip, $r.Role) 'OK' }
if ($Remove) { Write-LabLog 'Registros do lab removidos (ficou só a svc01)' 'OK'; exit 0 }

# Validação contra o IP que os ESX/VCF Installer vão usar
$bad = 0
foreach ($r in $records) {
    $fqdn = "$($r.Name).$zone"
    $a = Resolve-LabDns -Name $fqdn -Server $n.DnsServer -Type A
    $p = Resolve-LabDns -Name $r.Ip -Server $n.DnsServer -Type PTR
    if ($a -ne $r.Ip -or $p -ne $fqdn) { Write-LabLog "Falha de resolução: $fqdn -> '$a' / $($r.Ip) -> '$p'" 'ERROR'; $bad++ }
}
if ($bad) { throw "$bad registro(s) com resolução incorreta (journalctl -u named)." }
Write-LabLog 'Resolução direta e reversa OK para todos os registros' 'OK'
exit 0
